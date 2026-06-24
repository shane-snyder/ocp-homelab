#!/usr/bin/env bash
#
# flows-to-multinetpol.sh
# -----------------------
# Bootstrap MultiNetworkPolicy allow-rules from NetObserv flows stored in Loki.
#
# This is a STARTING POINT, not a turnkey generator. It pulls flows for a
# namespace over a time window, reduces them to unique
#   (srcOwner, dstOwner, dstPort, proto)
# tuples, and prints them so you can hand them into allow-* policies. NetObserv
# has no native "export MultiNetworkPolicy" feature, so some human judgment is
# expected (collapsing ephemeral ports, grouping by app, etc.).
#
# Requires: oc (logged in, cluster-admin), curl, jq.
#
# Usage:
#   ./hack/flows-to-multinetpol.sh vm-network 6h
#
set -euo pipefail

NS="${1:?usage: flows-to-multinetpol.sh <namespace> [duration e.g. 6h]}"
SINCE="${2:-6h}"
LOKI_NS="netobserv"

# NetObserv exposes Loki behind the loki-gateway route in its namespace.
GATEWAY="$(oc get route -n "$LOKI_NS" netobserv-loki-gateway-http \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -z "${GATEWAY}" ]]; then
  echo "Could not find the loki-gateway route in ns/$LOKI_NS." >&2
  echo "Check 'oc get route -n $LOKI_NS' and adjust GATEWAY in this script." >&2
  exit 1
fi
TOKEN="$(oc whoami -t)"

# LogQL: NetObserv 'network' tenant. Filter to the namespace on either end.
# Adjust the stream selector if your NetObserv labels differ.
QUERY="{app=\"netobserv-flowcollector\"} | json | SrcK8S_Namespace=\`${NS}\` or DstK8S_Namespace=\`${NS}\`"

echo "# Querying Loki for ${NS} flows over the last ${SINCE}..." >&2

curl -sG "https://${GATEWAY}/api/logs/v1/network/loki/api/v1/query_range" \
  -H "Authorization: Bearer ${TOKEN}" \
  --data-urlencode "query=${QUERY}" \
  --data-urlencode "since=${SINCE}" \
  --data-urlencode "limit=5000" \
| jq -r '
    .data.result[].values[][1]
    | fromjson
    | select(.Proto != null and .DstPort != null)
    | [ (.SrcK8S_OwnerName // .SrcK8S_Name // .SrcAddr),
        (.DstK8S_OwnerName // .DstK8S_Name // .DstAddr),
        .DstPort,
        (if .Proto == 6 then "TCP" elif .Proto == 17 then "UDP" else (.Proto|tostring) end)
      ] | @tsv
  ' \
| sort -u \
| awk 'BEGIN{
        print "# unique (src -> dst : port/proto) flows — turn these into allow-* rules";
        printf "# %-28s %-28s %-8s %s\n","SRC","DST","PORT","PROTO"
      }
      { printf "  %-28s %-28s %-8s %s\n",$1,$2,$3,$4 }'

echo >&2
echo "# Next: group these by app/role and write allow-* MultiNetworkPolicies in" >&2
echo "#       components/vm-multinetworkpolicies/ (annotated policy-for the NAD)." >&2
