# argocd-agent synctest fixtures

Throwaway apps for reproducing the argocd-agent sync stall: syncing several
apps at once (or one app whose resources sit on separate sync-waves) applies
the first item and then sits with the operation neither progressing nor
failing.

`app1`, `app2` and `app3` are identical apart from their namespace. Each ships
a Namespace, Deployment (`ubi9/httpd-24`), Service and Route on sync-waves
0/1/2/3, so a single app sync has four sequential phases and three apps synced
together give twelve.

Declared on sno as `synctest-1/2/3` at sync-wave 20 (`clusters/sno/values.yaml`).
All three are manual-sync like every other child app.

## Driving the experiment

Applications live in two namespaces (see the argocd-agent notes): `argocd-agent`
is the agent-side copy the local application-controller acts on, and
`argocd-agent-sno` is the principal mirror that the Argo CD UI shows. Watching
both at once separates a real sync stall from a status that simply never
propagates back up.

Trigger a sync the same way the UI does (principal side):

```
oc patch applications.argoproj.io/synctest-1 -n argocd-agent-sno --type merge \
  -p '{"operation":{"initiatedBy":{"username":"kube:admin"},"sync":{"syncStrategy":{"apply":{}},"syncOptions":["ServerSideApply=false"]}}}'
```

Same patch against `-n argocd-agent` drives the local controller directly and
takes the principal out of the loop - if that path always completes, the fault
is in the principal/agent event round trip rather than in the sync itself.

Reset between runs:

```
oc delete ns synctest-1 synctest-2 synctest-3 --ignore-not-found
```

## Removing

Do not drop the entries from `clusters/sno/values.yaml` - autonomous mode
recreates deleted Applications. Point the three `source.path` values at an
empty overlay and sync with prune, as with `components/aap-instance/disabled`.
