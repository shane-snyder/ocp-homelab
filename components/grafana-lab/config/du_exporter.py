#!/usr/bin/env python3
"""Prometheus exporter for on-disk bytes, broken down one level deep.

The Mimir PVC is shared by both ingest paths, so `kubelet_volume_stats_used_bytes`
only ever gives a combined total. Mimir's own per-tenant metrics describe the
ingester's rolling head, not the durable blocks. This walks the block directory
instead and reports the number the sizing question actually asks for: bytes on
disk, per tenant.

Emitted series:

    telemetry_lab_dir_bytes{component="mimir",scope="blocks",dir="otlp"}  <bytes>
    telemetry_lab_scope_bytes{component="mimir",scope="blocks"}           <bytes>
    telemetry_lab_scan_duration_seconds{component="mimir",scope="blocks"} <seconds>
    telemetry_lab_scan_timestamp_seconds{component="mimir"}               <unix ts>

For Mimir, `dir` is the tenant id. For Loki, the scopes are the chunk and index
directories, so `dir` is a per-tenant chunk shard rather than a tenant.

Configuration (environment):
    COMPONENT    label value applied to every series (default "unknown")
    SCAN_PATHS   comma-separated "<scope>=<path>" pairs
    SCAN_INTERVAL  seconds between rescans (default 120)
    LISTEN_PORT  HTTP port (default 9110)

Scanning is done on a timer in a background thread and the result is cached, so
a scrape never blocks on walking a large directory tree.
"""

import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

COMPONENT = os.environ.get("COMPONENT", "unknown")
SCAN_INTERVAL = int(os.environ.get("SCAN_INTERVAL", "120"))
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9110"))


def parse_scan_paths(raw):
    """"blocks=/data/blocks,tsdb=/data/tsdb" -> [("blocks", "/data/blocks"), ...]"""
    pairs = []
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        scope, _, path = item.partition("=")
        if not path:
            raise ValueError("SCAN_PATHS entry %r is not <scope>=<path>" % item)
        pairs.append((scope.strip(), path.strip()))
    return pairs


SCAN_PATHS = parse_scan_paths(os.environ.get("SCAN_PATHS", ""))


def tree_bytes(path):
    """Apparent size of everything under path, following no symlinks."""
    total = 0
    for root, dirnames, filenames in os.walk(path, followlinks=False):
        for name in filenames:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                # Blocks are compacted and deleted underneath us constantly; a
                # file vanishing mid-walk is normal, not an error.
                continue
    return total


def scan():
    """Return the full metric snapshot as a list of (name, labels, value)."""
    samples = []
    for scope, path in SCAN_PATHS:
        started = time.time()
        scope_total = 0
        try:
            entries = sorted(
                e.name for e in os.scandir(path) if e.is_dir(follow_symlinks=False)
            )
        except OSError:
            # Directory not created yet (nothing ingested for this scope).
            entries = []
        for name in entries:
            size = tree_bytes(os.path.join(path, name))
            scope_total += size
            samples.append(
                ("telemetry_lab_dir_bytes", {"scope": scope, "dir": name}, size)
            )
        samples.append(("telemetry_lab_scope_bytes", {"scope": scope}, scope_total))
        samples.append(
            (
                "telemetry_lab_scan_duration_seconds",
                {"scope": scope},
                time.time() - started,
            )
        )
    samples.append(("telemetry_lab_scan_timestamp_seconds", {}, time.time()))
    return samples


HELP = {
    "telemetry_lab_dir_bytes": (
        "gauge",
        "Bytes on disk under one immediate subdirectory of a scanned path.",
    ),
    "telemetry_lab_scope_bytes": (
        "gauge",
        "Bytes on disk under a scanned path, all subdirectories summed.",
    ),
    "telemetry_lab_scan_duration_seconds": (
        "gauge",
        "Seconds the last scan of this scope took.",
    ),
    "telemetry_lab_scan_timestamp_seconds": (
        "gauge",
        "Unix timestamp of the last completed scan.",
    ),
}


def render(samples):
    lines = []
    seen = set()
    for name, labels, value in samples:
        if name not in seen:
            seen.add(name)
            kind, doc = HELP[name]
            lines.append("# HELP %s %s" % (name, doc))
            lines.append("# TYPE %s %s" % (name, kind))
        all_labels = dict(labels, component=COMPONENT)
        rendered = ",".join(
            '%s="%s"' % (k, str(v).replace("\\", "\\\\").replace('"', '\\"'))
            for k, v in sorted(all_labels.items())
        )
        lines.append("%s{%s} %r" % (name, rendered, float(value)))
    return "\n".join(lines) + "\n"


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.body = "# no scan completed yet\n"

    def set(self, body):
        with self.lock:
            self.body = body

    def get(self):
        with self.lock:
            return self.body


state = State()


def scan_loop():
    while True:
        try:
            state.set(render(scan()))
        except Exception as exc:  # keep serving the previous snapshot
            print("scan failed: %r" % (exc,), flush=True)
        time.sleep(SCAN_INTERVAL)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] not in ("/metrics", "/"):
            self.send_error(404)
            return
        body = state.get().encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # a log line per scrape would be ingested by the very stack we measure


def main():
    if not SCAN_PATHS:
        raise SystemExit("SCAN_PATHS is empty; nothing to export")
    threading.Thread(target=scan_loop, daemon=True).start()
    ThreadingHTTPServer(("", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
