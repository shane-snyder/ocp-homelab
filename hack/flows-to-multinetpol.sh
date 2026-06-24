#!/usr/bin/env bash
#
# flows-to-multinetpol.sh
# -----------------------
# Discover NetObserv flows on a secondary (localnet) network and generate a
# MultiNetworkPolicy set from them.
#
# It reads flows from the NetObserv LokiStack, scopes them to a subnet (the
# secondary network), resolves each in-cluster endpoint to its POD LABELS
# (so you get real podSelector rules, not brittle ipBlock), and prints a
# default-deny + per-workload allow policy set.
#
# This is a REVIEW aid, not automation: it prints YAML to stdout and a flow
# summary to stderr. It never applies anything. Read it, edit it, commit it.
#
# Requires: oc (cluster-admin), jq, curl, awk.
#
# Usage:
#   ./hack/flows-to-multinetpol.sh [-n ns] [-s subnet-prefix] [-d nad]
#                                  [-w since] [-l "label keys"] [-o out.yaml]
#
# Defaults target this repo's demo: rhel10-vm / 192.168.100. / vlan100.
# Example:
#   ./hack/flows-to-multinetpol.sh -w 30m -o /tmp/vlan100-policies.yaml
#
set -euo pipefail

NAMESPACE=rhel10-vm
SUBNET_PREFIX="192.168.100."
NAD=vlan100
SINCE=1h
LABEL_KEYS="role app kubevirt.io/domain"
EPHEMERAL_MIN=32768   # drop flows whose DstPort >= this (return traffic to client
                      # ephemeral ports, not real services). Set huge to disable.
OUT=""
LOKI_NS=netobserv
LOKI_SELECTOR='{app="netobserv-flowcollector"}'
LPORT=18080

while getopts "n:s:d:w:l:e:o:h" opt; do
  case "$opt" in
    n) NAMESPACE=$OPTARG ;;
    s) SUBNET_PREFIX=$OPTARG ;;
    d) NAD=$OPTARG ;;
    w) SINCE=$OPTARG ;;
    l) LABEL_KEYS=$OPTARG ;;
    e) EPHEMERAL_MIN=$OPTARG ;;
    o) OUT=$OPTARG ;;
    h) sed -n '2,30p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done

for c in oc jq curl awk; do command -v "$c" >/dev/null || { echo "need $c in PATH" >&2; exit 1; }; done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [ -n "${PF:-}" ] && kill "$PF" 2>/dev/null || true' EXIT

# --- 1. Map secondary-network IPs -> pod {namespace,labels}, pick a selector key ---
echo "# [1/4] mapping ${SUBNET_PREFIX}* IPs to pod labels..." >&2
oc get pods -A -o json \
| jq -r --arg p "$SUBNET_PREFIX" --arg keys "$LABEL_KEYS" '
    ($keys | split(" ")) as $kk
    | .items[] as $pod
    | (($pod.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] // "[]")
        | (fromjson? // [])) as $arr
    | $arr[]? | (.ips // [])[]? | select(startswith($p)) as $ip
    | ($pod.metadata.labels // {}) as $lab
    | ($kk | map(select($lab[.] != null)) | .[0]) as $sel
    | [ $ip, $pod.metadata.namespace, ($sel // ""), (if $sel then $lab[$sel] else "" end) ]
    | @tsv
  ' > "$TMP/ipmap.tsv" || true
echo "#       found $(wc -l < "$TMP/ipmap.tsv" | tr -d ' ') secondary IPs" >&2

# --- 2. Query Loki (port-forward the gateway) ---
echo "# [2/4] querying NetObserv Loki (last ${SINCE})..." >&2
GW=$(oc get svc -n "$LOKI_NS" -o name 2>/dev/null | sed 's#service/##' | grep -E 'gateway-http$' | head -1)
[ -n "$GW" ] || { echo "no loki gateway-http svc in ns/$LOKI_NS" >&2; exit 1; }
oc -n "$LOKI_NS" port-forward "svc/$GW" "$LPORT:8080" >"$TMP/pf.log" 2>&1 &
PF=$!
for _ in $(seq 1 10); do grep -q "Forwarding from" "$TMP/pf.log" 2>/dev/null && break; sleep 1; done
TOKEN=$(oc whoami -t)

# Reduce volume with a line filter on the subnet; jq re-filters precisely below.
QUERY="${LOKI_SELECTOR} |~ \`${SUBNET_PREFIX}\`"
fetch() { # $1 = scheme
  curl -s${2:-} -G "$1://localhost:${LPORT}/api/logs/v1/network/loki/api/v1/query_range" \
    -H "Authorization: Bearer ${TOKEN}" \
    --data-urlencode "query=${QUERY}" \
    --data-urlencode "since=${SINCE}" \
    --data-urlencode "limit=5000"
}
RAW=$(fetch https k || true)
echo "$RAW" | jq -e '.data.result' >/dev/null 2>&1 || RAW=$(fetch http || true)
if ! echo "$RAW" | jq -e '.data.result' >/dev/null 2>&1; then
  echo "Loki query failed. Response:" >&2; echo "$RAW" | head -c 400 >&2; echo >&2
  echo "Tip: confirm the stream selector (LOKI_SELECTOR) and that you have access to the 'network' tenant." >&2
  exit 1
fi

# --- 3. Reduce to unique directed (src,dst,dport,proto) tuples in the subnet ---
echo "# [3/4] aggregating flows..." >&2
echo "$RAW" | jq -r --arg p "$SUBNET_PREFIX" --argjson emin "$EPHEMERAL_MIN" '
    .data.result[]?.values[]?[1]
    | (fromjson? // empty)
    | select(.DstPort != null and .Proto != null)
    | select((.DstPort|tonumber) < $emin)
    | select((.SrcAddr // "" | startswith($p)) or (.DstAddr // "" | startswith($p)))
    | [ .SrcAddr, .DstAddr, (.DstPort|tostring),
        (.Proto as $pr | if $pr==6 or $pr=="6" then "TCP"
                         elif $pr==17 or $pr=="17" then "UDP"
                         else ($pr|tostring) end) ]
    | @tsv
  ' | sort -u > "$TMP/flows.tsv"
NFLOWS=$(wc -l < "$TMP/flows.tsv" | tr -d ' ')
echo "#       $NFLOWS unique src->dst:port/proto tuples" >&2
if [ "$NFLOWS" = "0" ]; then
  echo "No flows found. Generate some traffic and/or widen -w, then re-run." >&2
  exit 0
fi

# Human-readable summary to stderr
{ echo "#"; echo "# discovered flows:"; printf '#   %-16s %-16s %-7s %s\n' SRC DST PORT PROTO
  awk -F'\t' '{printf "#   %-16s %-16s %-7s %s\n",$1,$2,$3,$4}' "$TMP/flows.tsv"; echo "#"; } >&2

# --- 4. Resolve + generate MultiNetworkPolicy (portable awk; no bash assoc arrays) ---
echo "# [4/4] generating MultiNetworkPolicy..." >&2
gen() {
  awk -F'\t' -v NS="$NAMESPACE" -v NAD="$NAD" '
    function san(s){ gsub(/[^a-zA-Z0-9]+/,"-",s); gsub(/^-|-$/,"",s); return tolower(s) }
    # descriptor: sel|<key>|<val> for in-namespace pods, else ip|<addr>
    function desc(a){ if (a in KEY && NSMAP[a]==NS && KEY[a]!="") return "sel|" KEY[a] "|" VAL[a]; return "ip|" a }
    function emit_peer(p,  x){ n=split(p,x,"|");
      if (x[1]=="sel"){ print "        - podSelector:"; print "            matchLabels:"; print "              " x[2] ": \"" x[3] "\"" }
      else            { print "        - ipBlock:"; print "            cidr: " x[2] "/32" } }
    function emit_ports(listkey,  i,m,pp,y){ m=split(PORTS[listkey],pp," ");
      for(i=1;i<=m;i++){ if(pp[i]=="")continue; split(pp[i],y,":"); print "        - protocol: " y[1]; print "          port: " y[2] } }
    # file 1: ipmap.tsv (ip, ns, key, val)
    FNR==NR { if($1!=""){ NSMAP[$1]=$2; KEY[$1]=$3; VAL[$1]=$4 } next }
    # file 2: flows.tsv (src, dst, port, proto)
    {
      s=desc($1); d=desc($2); port=$3; proto=$4
      if (d ~ /^sel\|/) {
        if(!(d in dstSeen)){dstSeen[d]=1; DST[++nd]=d}
        pk=d SUBSEP s; if(!(pk in iPeerSeen)){iPeerSeen[pk]=1; IPEERS[d]=IPEERS[d] " " s}
        ppk=pk SUBSEP proto SUBSEP port; if(!(ppk in iPortSeen)){iPortSeen[ppk]=1; PORTS["I" pk]=PORTS["I" pk] " " proto ":" port}
      }
      if (s ~ /^sel\|/) {
        if(!(s in srcSeen)){srcSeen[s]=1; SRC[++ng]=s}
        ek=s SUBSEP d; if(!(ek in ePeerSeen)){ePeerSeen[ek]=1; EPEERS[s]=EPEERS[s] " " d}
        eppk=ek SUBSEP proto SUBSEP port; if(!(eppk in ePortSeen)){ePortSeen[eppk]=1; PORTS["E" ek]=PORTS["E" ek] " " proto ":" port}
      }
    }
    END {
      print "# Generated by flows-to-multinetpol.sh — REVIEW before applying."
      print "# default-deny + allows derived from observed flows on " NS "/" NAD "."
      print "---"
      print "apiVersion: k8s.cni.cncf.io/v1beta1"
      print "kind: MultiNetworkPolicy"
      print "metadata:"
      print "  name: " NAD "-default-deny"
      print "  namespace: " NS
      print "  annotations:"
      print "    k8s.v1.cni.cncf.io/policy-for: " NS "/" NAD
      print "spec:"
      print "  podSelector: {}"
      print "  policyTypes: [Ingress, Egress]"
      # ingress allows (target = in-namespace workloads)
      for(i=1;i<=nd;i++){ d=DST[i]; split(d,da,"|")
        print "---"
        print "apiVersion: k8s.cni.cncf.io/v1beta1"
        print "kind: MultiNetworkPolicy"
        print "metadata:"
        print "  name: " NAD "-allow-" san(da[3]) "-ingress"
        print "  namespace: " NS
        print "  annotations:"
        print "    k8s.v1.cni.cncf.io/policy-for: " NS "/" NAD
        print "spec:"
        print "  podSelector:"
        print "    matchLabels:"
        print "      " da[2] ": \"" da[3] "\""
        print "  policyTypes: [Ingress]"
        print "  ingress:"
        np=split(IPEERS[d],pa," ")
        for(j=1;j<=np;j++){ p=pa[j]; if(p=="")continue
          print "    - from:"; emit_peer(p); print "      ports:"; emit_ports("I" d SUBSEP p) }
      }
      # egress allows (target = in-namespace workloads)
      for(i=1;i<=ng;i++){ s=SRC[i]; split(s,sa,"|")
        print "---"
        print "apiVersion: k8s.cni.cncf.io/v1beta1"
        print "kind: MultiNetworkPolicy"
        print "metadata:"
        print "  name: " NAD "-allow-" san(sa[3]) "-egress"
        print "  namespace: " NS
        print "  annotations:"
        print "    k8s.v1.cni.cncf.io/policy-for: " NS "/" NAD
        print "spec:"
        print "  podSelector:"
        print "    matchLabels:"
        print "      " sa[2] ": \"" sa[3] "\""
        print "  policyTypes: [Egress]"
        print "  egress:"
        np=split(EPEERS[s],pa," ")
        for(j=1;j<=np;j++){ p=pa[j]; if(p=="")continue
          print "    - to:"; emit_peer(p); print "      ports:"; emit_ports("E" s SUBSEP p) }
      }
    }
  ' "$TMP/ipmap.tsv" "$TMP/flows.tsv"
}

if [ -n "$OUT" ]; then gen > "$OUT"; echo "# wrote $OUT" >&2; else gen; fi
