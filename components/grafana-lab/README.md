# Telemetry storage sizing lab

A single Grafana fronting two independent telemetry pipelines, instrumented so
the on-disk cost of each can be measured separately.

```
                         ┌──────────────────────────────┐
 OTel node collector ────┤ OTLP logs    → Loki          │  own PVC (100Gi)
   filelog               └──────────────────────────────┘
   kubeletstats     ┐
   hostmetrics      ├───▶ OTLP metrics → Mimir tenant "otlp"        ┐
 OTel cluster coll. ┘                                               │ shared
   k8s_cluster                                                      │ PVC
   k8s_events ──────────▶ OTLP logs    → Loki                       │ (200Gi)
                                                                    │
 platform Prometheus ───▶ remote_write → Mimir tenant "remotewrite"  ┘
```

Both metric paths land in **the same Mimir** with the same TSDB engine, the
same replication factor and the same retention. That is the only way the two
numbers are comparable — a different backend per path would measure the
backends, not the pipelines.

## Reading the results

Open Grafana (`oc -n grafana-lab get route grafana-lab-route`) and the
**Telemetry storage sizing** dashboard. Credentials:

```sh
oc -n grafana-lab get secret grafana-lab-admin-credentials \
  -o go-template='{{index .data "GF_SECURITY_ADMIN_USER"|base64decode}}{{"\n"}}{{index .data "GF_SECURITY_ADMIN_PASSWORD"|base64decode}}{{"\n"}}'
```

Everything below runs against the **OpenShift Monitoring (Thanos)** datasource,
not against Loki or Mimir. Measuring a store by querying that same store makes
the measurement part of what is being measured.

That is also why `clusters/sno/overlays/cluster-monitoring` raises the
user-workload Prometheus to 30d retention on a real PVC. Its defaults — 24h and
emptyDir — would have limited every query below to a single day and thrown the
history away on the next restart.

### Before trusting any number

Let it run for at least 24 hours, then confirm nothing is being dropped:

```promql
# Must be zero. Non-zero means a limit is being hit and every size below is an undercount.
sum by (user, reason) (rate(cortex_discarded_samples_total{namespace="grafana-lab"}[5m]))
sum by (reason)       (rate(loki_discarded_samples_total{namespace="grafana-lab"}[5m]))
sum by (exporter)     (rate(otelcol_exporter_send_failed_metric_points_total{namespace="grafana-lab"}[5m]))
sum by (exporter)     (rate(otelcol_exporter_send_failed_log_records_total{namespace="grafana-lab"}[5m]))
sum(rate(prometheus_remote_storage_samples_failed_total{namespace="openshift-monitoring"}[5m]))
```

Also confirm the PVCs are not about to fill, which would silently end the test:

```promql
kubelet_volume_stats_available_bytes{namespace="grafana-lab"}
```

### 1. Bytes on disk, per ingest path

The `telemetry_lab_*` series come from the `du-exporter` sidecar, which walks
the actual directory tree every two minutes. This is a measurement, not an
estimate derived from sample counts.

```promql
# Metrics that arrived over OTLP from the OTel collectors
telemetry_lab_dir_bytes{component="mimir", scope="blocks", dir="otlp"}

# Metrics that arrived over Prometheus remote_write
telemetry_lab_dir_bytes{component="mimir", scope="blocks", dir="remotewrite"}

# Logs that arrived over OTLP — payload, and the index tax paid for it
telemetry_lab_scope_bytes{component="loki", scope="chunks"}
telemetry_lab_scope_bytes{component="loki", scope="index"}
```

`kubelet_volume_stats_used_bytes{namespace="grafana-lab"}` gives whole-PVC
totals instead. Those are always larger — they include the WAL, compactor
scratch space and sync directories, none of which grow with retention.

### 2. Growth rate → the projection

```promql
# Bytes per day, per path. Needs a full 24h of history behind it.
deriv(telemetry_lab_dir_bytes{component="mimir", scope="blocks", dir="otlp"}[24h])        * 86400
deriv(telemetry_lab_dir_bytes{component="mimir", scope="blocks", dir="remotewrite"}[24h]) * 86400
deriv(telemetry_lab_scope_bytes{component="loki", scope="chunks"}[24h])                   * 86400
deriv(telemetry_lab_scope_bytes{component="loki", scope="index"}[24h])                    * 86400
```

Multiply by the retention you are sizing for — 7, 30, 90:

```promql
deriv(telemetry_lab_dir_bytes{component="mimir", scope="blocks", dir="remotewrite"}[24h]) * 86400 * 30
```

Two corrections before quoting a figure:

- **Replication.** This lab runs `replication_factor: 1`. A real Mimir or
  Grafana Cloud writes three copies. Multiply metric figures by 3.
- **Compaction lag.** Mimir compacts blocks over the following hours, which
  *shrinks* them. A projection taken from the first day will overstate steady
  state by roughly 20–40%. Take the rate from a window at least 48h old.

### 3. Normalising away this cluster's size

The lab's absolute numbers only describe the lab. These ratios transfer:

```promql
# Bytes of disk per metric sample ingested, per path
deriv(telemetry_lab_dir_bytes{component="mimir", scope="blocks", dir="otlp"}[6h])
  / clamp_min(sum(rate(cortex_distributor_received_samples_total{namespace="grafana-lab", user="otlp"}[6h])), 0.001)

deriv(telemetry_lab_dir_bytes{component="mimir", scope="blocks", dir="remotewrite"}[6h])
  / clamp_min(sum(rate(cortex_distributor_received_samples_total{namespace="grafana-lab", user="remotewrite"}[6h])), 0.001)

# Log compression ratio: uncompressed bytes received / bytes actually stored
clamp_min(sum(rate(loki_distributor_bytes_received_total{namespace="grafana-lab"}[6h])), 0.001)
  / clamp_min(deriv(telemetry_lab_scope_bytes{component="loki", scope="chunks"}[6h]), 0.001)
```

With those, any workload's own volume answers the question directly:

```
metric bytes/day = its samples/sec × bytes-per-sample × 86400 × replication
log    bytes/day = its raw log bytes/day ÷ compression ratio
```

### 4. Supporting series

```promql
# Active series and ingest rate, per path
sum by (user) (cortex_ingester_active_series{namespace="grafana-lab"})
sum by (user) (rate(cortex_distributor_received_samples_total{namespace="grafana-lab"}[5m]))

# Log volume arriving at Loki
sum(rate(loki_distributor_bytes_received_total{namespace="grafana-lab"}[5m]))
sum(rate(loki_distributor_lines_received_total{namespace="grafana-lab"}[5m]))

# What the collectors believe they sent — cross-check against the above
sum by (exporter) (rate(otelcol_exporter_sent_metric_points_total{namespace="grafana-lab"}[5m]))
sum by (exporter) (rate(otelcol_exporter_sent_log_records_total{namespace="grafana-lab"}[5m]))
```

Loki can also break volume down by stream, which is where log cost usually
hides. From the **Loki - OTLP logs** datasource:

```logql
sum by (k8s_namespace_name) (bytes_over_time({k8s_namespace_name=~".+"}[24h]))
```

## Caveats that change the answer

- **The two metric paths do not carry the same data.** OTel sends kubeletstats,
  hostmetrics and k8s_cluster; remote_write sends everything platform
  Prometheus scrapes (~900k series on this cluster). Compare the *ratios* in
  §3, not the absolute totals — the absolute totals mostly measure how much
  each path was pointed at.
- **remote_write is deliberately unfiltered.** No `writeRelabelConfigs`
  keep-list, because the question is what a full feed costs. Real deployments
  usually filter, so treat the remote_write figure as an upper bound.
- **OTLP metrics carry more resource attributes than scraped metrics.** More
  labels per series means a larger index for the same sample count; that
  difference is real and is part of what this lab is measuring.
- **Retention is 30d on both backends.** Projections beyond 30 days are
  extrapolation, not measurement.

## Turning it off

The expensive part is the remote_write feed. Remove the `remoteWrite` block
from `clusters/sno/overlays/cluster-monitoring/cluster-monitoring-config.yaml`
and re-sync; nothing else depends on it. Deleting the `grafana-lab` Application
removes the rest, but the PVCs are retained by the StatefulSets and must be
deleted by hand:

```sh
oc -n grafana-lab delete pvc --all
```
