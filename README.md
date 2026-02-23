# GitOps Homelab

OpenShift GitOps repository for managing homelab clusters following the [Red Hat CoP GitOps pattern](https://github.com/redhat-cop/gitops-standards-repo-template).

## Repository Structure

```
ocp-homelab/
├── .bootstrap/              # One-time bootstrap manifests (applied manually)
│   ├── subscription.yaml    # OpenShift GitOps operator install
│   ├── argocd.yaml          # ArgoCD instance configuration
│   ├── cluster-rolebinding.yaml
│   ├── root-application.yaml        # Root app for standalone mode
│   └── agent/
│       └── hub-root-application.yaml # Root app for agent (hub/spoke) mode
├── .helm-charts/            # Helm charts used by Kustomize
│   └── argocd-app-of-app/   # Renders Application + AppProject CRs from values
├── clusters/                # Per-cluster entry points
│   ├── sno/                 # SNO standalone mode
│   ├── sno-mini/            # SNO-Mini standalone mode
│   └── sno-hub/             # SNO as hub (agent mode — manages sno + sno-mini)
├── components/              # Reusable, environment-agnostic building blocks
├── groups/                  # Shared configurations applied to sets of clusters
│   └── all/                 # Applied to every cluster
└── .github/workflows/       # CI/CD pipeline
```

## How It Works

1. A single **root Application** (`root-applications`) points at `clusters/<cluster_name>/`
2. Each cluster's `kustomization.yaml` includes shared groups and renders cluster-specific apps
3. The `argocd-app-of-app` Helm chart generates `Application` and `AppProject` CRs from `values.yaml`
4. **Components** hold base manifests; **cluster overlays** add environment-specific patches

## Deployment Modes

This repository supports two deployment modes:

### Standalone Mode (ArgoCD per cluster)

Each cluster runs its own ArgoCD instance and manages itself. This is the default.

```
┌─────────────┐    ┌─────────────────┐
│     sno      │    │    sno-mini      │
│  ┌────────┐  │    │  ┌────────┐     │
│  │ ArgoCD │──┼──> │  │ ArgoCD │──┐  │
│  └────────┘  │    │  └────────┘  │  │
│   manages    │    │   manages    │  │
│   itself     │    │   itself     │  │
└─────────────┘    └─────────────────┘
```

### Agent Mode (hub/spoke)

A single ArgoCD instance on the hub cluster (sno) manages both clusters. The hub
re-uses the existing `groups/all/values.yaml` and `clusters/<cluster>/values.yaml`
files -- no app duplication required. The hub kustomization overrides the destination
server and adds a `namePrefix` via `valuesInline` so the same values files produce
correctly-targeted, uniquely-named Application CRs.

ACM's `GitOpsCluster` resource automatically registers managed clusters with ArgoCD.
Label a managed cluster `gitops-mode: agent` and ACM creates + maintains the ArgoCD
cluster secret -- no manual credential management needed.

```
┌──────────────────────────────────┐    ┌─────────────────┐
│          sno (hub)                │    │  sno-mini        │
│  ┌────────┐                      │    │  (managed)       │
│  │ ArgoCD │──── manages sno ──┐  │    │                  │
│  │        │                   │  │    │                  │
│  │        │── manages sno-mini┼──┼───>│  no ArgoCD       │
│  └────────┘                      │    │                  │
│  ┌─────┐                         │    │                  │
│  │ ACM │─── GitOpsCluster ───────┼───>│  auto-registered │
│  └─────┘  (cluster secret)       │    │                  │
└──────────────────────────────────┘    └─────────────────┘
```

## Clusters

| Cluster   | Domain                      | Description                |
|-----------|-----------------------------|----------------------------|
| sno       | sno.shanehomelab.com        | Primary SNO cluster        |
| sno-mini  | sno-mini.shanehomelab.com   | Secondary SNO cluster      |

## Bootstrap — Standalone Mode

Each cluster gets its own ArgoCD instance and manages itself.

```bash
export INFRA_GITOPS_REPO=https://github.com/shane-snyder/ocp-homelab.git
export CLUSTER_NAME=sno           # or sno-mini
export CLUSTER_BASE_DOMAIN=shanehomelab.com

oc apply -f .bootstrap/subscription.yaml
# Wait for the OpenShift GitOps operator to install...
oc apply -f .bootstrap/cluster-rolebinding.yaml
envsubst < .bootstrap/argocd.yaml | oc apply -f -
envsubst < .bootstrap/root-application.yaml | oc apply -f -
```

## Bootstrap — Agent Mode (Hub/Spoke)

A single ArgoCD instance on sno manages both clusters. Only bootstrap the hub.

### 1. Label managed clusters in ACM

```bash
oc label managedcluster sno-mini gitops-mode=agent
```

The `acm-gitops-cluster` component deploys a `GitOpsCluster` resource with a
`Placement` that selects clusters with this label. ACM automatically creates and
maintains the ArgoCD cluster secret in `openshift-gitops` -- no manual token
extraction or Vault storage needed for cluster credentials.

### 2. Bootstrap the hub cluster (sno)

```bash
export INFRA_GITOPS_REPO=https://github.com/shane-snyder/ocp-homelab.git
export CLUSTER_NAME=sno
export CLUSTER_BASE_DOMAIN=shanehomelab.com

oc apply -f .bootstrap/subscription.yaml
# Wait for the OpenShift GitOps operator to install...
oc apply -f .bootstrap/cluster-rolebinding.yaml
envsubst < .bootstrap/argocd.yaml | oc apply -f -
envsubst < .bootstrap/agent/hub-root-application.yaml | oc apply -f -
```

The only difference from standalone is the last command -- `hub-root-application.yaml`
points to `clusters/sno-hub/` which includes sno's own apps and re-renders the
existing sno-mini values targeting the remote cluster.

**On sno-mini:** No bootstrap needed. The hub's ArgoCD manages everything.

## Adding a New Cluster

1. Create `clusters/<new-cluster>/kustomization.yaml` (include desired groups)
2. Create `clusters/<new-cluster>/values.yaml` (list cluster-specific applications)
3. Add cluster overlays under `clusters/<new-cluster>/overlays/` as needed
4. Bootstrap the cluster using the standalone instructions above

### Adding a managed cluster (agent mode)

In addition to steps 1-3 above:

4. Label the cluster in ACM: `oc label managedcluster <cluster> gitops-mode=agent`
5. ACM automatically creates the ArgoCD cluster secret via `GitOpsCluster`
6. Add two `helmCharts` entries to `clusters/<hub>-hub/kustomization.yaml`:

```yaml
  # Shared apps for <new-cluster>
  - name: argocd-app-of-app
    releaseName: <new-cluster>-shared-apps
    namespace: openshift-gitops
    valuesFile: ../../groups/all/values.yaml
    valuesInline:
      disableProjects: true
      default:
        app:
          namePrefix: "<new-cluster>-"
          project: managed-clusters
          labels:
            cluster: <new-cluster>
          destination:
            server: https://api.<new-cluster>.<domain>:6443

  # Cluster-specific apps for <new-cluster>
  - name: argocd-app-of-app
    releaseName: <new-cluster>-cluster-apps
    namespace: openshift-gitops
    valuesFile: ../new-cluster/values.yaml
    valuesInline:
      disableProjects: true
      default:
        app:
          namePrefix: "<new-cluster>-"
          project: managed-clusters
          labels:
            cluster: <new-cluster>
          destination:
            server: https://api.<new-cluster>.<domain>:6443
```

No app definitions need to be duplicated — the hub references the cluster's
existing values files directly.

## Adding a New Application

1. Create the component under `components/<app-name>/`
2. Add the application entry to `groups/all/values.yaml` (if shared) or the cluster's `values.yaml`
3. If cluster-specific config is needed, create an overlay under `clusters/<cluster>/overlays/<app>/`

In agent mode, shared and cluster-specific apps are picked up automatically from
the existing values files — no additional changes needed.
