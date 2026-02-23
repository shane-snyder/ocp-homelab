# GitOps Homelab

OpenShift GitOps repository for managing homelab clusters following the [Red Hat CoP GitOps pattern](https://github.com/redhat-cop/gitops-standards-repo-template).

## Repository Structure

```
gitops-homelab/
├── .bootstrap/          # One-time bootstrap manifests (applied manually)
├── .helm-charts/        # Helm charts used by Kustomize
│   └── argocd-app-of-app/   # Renders Application + AppProject CRs from values
├── clusters/            # Per-cluster entry points
│   ├── sno/             # SNO cluster (sno.shanehomelab.com)
│   └── sno-mini/        # SNO-Mini cluster (sno-mini.shanehomelab.com)
├── components/          # Reusable, environment-agnostic building blocks
├── groups/              # Shared configurations applied to sets of clusters
│   └── all/             # Applied to every cluster
└── .github/workflows/   # CI/CD pipeline
```

## How It Works

1. A single **root Application** (`root-applications`) points at `clusters/<cluster_name>/`
2. Each cluster's `kustomization.yaml` includes shared groups and renders cluster-specific apps
3. The `argocd-app-of-app` Helm chart generates `Application` and `AppProject` CRs from `values.yaml`
4. **Components** hold base manifests; **cluster overlays** add environment-specific patches

## Clusters

| Cluster   | Domain                      | Description                |
|-----------|-----------------------------|----------------------------|
| sno       | sno.shanehomelab.com        | Primary SNO cluster        |
| sno-mini  | sno-mini.shanehomelab.com   | Secondary SNO cluster      |

## Bootstrap

```bash
export INFRA_GITOPS_REPO=https://github.com/shane-snyder/gitops-homelab.git
export CLUSTER_NAME=sno           # or sno-mini
export CLUSTER_BASE_DOMAIN=shanehomelab.com

oc apply -f .bootstrap/subscription.yaml
# Wait for the OpenShift GitOps operator to install...
oc apply -f .bootstrap/cluster-rolebinding.yaml
envsubst < .bootstrap/argocd.yaml | oc apply -f -
envsubst < .bootstrap/root-application.yaml | oc apply -f -
```

## Adding a New Cluster

1. Create `clusters/<new-cluster>/kustomization.yaml` (include desired groups)
2. Create `clusters/<new-cluster>/values.yaml` (list cluster-specific applications)
3. Add cluster overlays under `clusters/<new-cluster>/overlays/` as needed
4. Bootstrap the cluster using the instructions above

## Adding a New Application

1. Create the component under `components/<app-name>/`
2. Add the application entry to `groups/all/values.yaml` (if shared) or the cluster's `values.yaml`
3. If cluster-specific config is needed, create an overlay under `clusters/<cluster>/overlays/<app>/`
