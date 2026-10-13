# ocp-lifecycle-exporter

Exports Red Hat lifecycle data for this cluster's OpenShift version and every
installed operator: support phase, end dates, and OpenShift compatibility for
both the current minor and the update channel's target. Source, metric
reference and status meanings:
<https://github.com/shane-snyder/ocp-lifecycle-dashboard>.

Deployed on every cluster (`clusters/*/values.yaml`). The namespace is
platform-monitored so ACM observability forwards the `ocp_lifecycle_*` series
(listed in `acm-observability/05-observability-metrics-custom-allowlist.yaml`)
to the hub, where grafana-lab's **OpenShift & operator lifecycle** dashboard
reads them through the `acm-observability` datasource.

The image is built into the homelab Quay by
`components/ocp-lifecycle-exporter-pipeline` (sno only).

Needs egress to `access.redhat.com`. `LifecycleDataStale` fires if it hasn't
reached it in 24h.

```sh
oc -n ocp-lifecycle logs deploy/ocp-lifecycle-exporter
oc -n ocp-lifecycle exec deploy/ocp-lifecycle-exporter -- \
  python3.12 -c "import urllib.request as u; print(u.urlopen('http://localhost:9120/metrics').read().decode())" \
  | grep operator_status
```
