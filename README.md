# GitOps Homelab

OpenShift GitOps repository for managing homelab clusters following the [Red Hat CoP GitOps pattern](https://github.com/redhat-cop/gitops-standards-repo-template).

## Repository Structure

```
ocp-homelab/
├── .bootstrap/              # One-time bootstrap manifests (applied manually)
│   ├── subscription.yaml    # OpenShift GitOps operator install
│   ├── argocd.yaml          # ArgoCD instance configuration (standalone)
│   ├── cluster-rolebinding.yaml
│   ├── root-application.yaml        # Root app (standalone mode)
│   └── agent/
│       ├── hub-argocd.yaml          # Hub ArgoCD instance (with Principal)
│       ├── spoke-argocd.yaml        # Spoke ArgoCD instance (lightweight, no server)
│       ├── spoke-network-policy.yaml # NetworkPolicy for Agent ↔ Redis
│       └── spoke-root-application.yaml # Root app for spoke cluster
├── .helm-charts/            # Helm charts used by Kustomize
│   └── argocd-app-of-app/   # Renders Application + AppProject CRs from values
├── clusters/                # Per-cluster entry points
│   ├── sno/                 # SNO cluster apps
│   └── sno-mini/            # SNO-Mini cluster apps
├── components/              # Reusable, environment-agnostic building blocks
│   └── acm-policies-argocd-agent/  # ACM policies for ArgoCD Agent PKI
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
│  │ ArgoCD │  │    │  │ ArgoCD │     │
│  └────────┘  │    │  └────────┘     │
│   manages    │    │   manages       │
│   itself     │    │   itself        │
└─────────────┘    └─────────────────┘
```

### Agent Mode (ArgoCD Agent — Autonomous)

Uses the ArgoCD Agent (GA in OpenShift GitOps 1.19+) in **autonomous mode**.
Each cluster remains the source of truth for its own applications. The Agent
running on the spoke syncs app specs and status back to the hub for centralized
visibility. Communication uses mTLS — no cluster credentials stored on the hub.

mTLS certificates are managed automatically by **cert-manager** and distributed
to spoke clusters via **ACM policies** — no manual `argocd-agentctl` usage required.

```
┌──────────────────────────────────┐    ┌──────────────────────────────┐
│        sno (hub)                  │    │       sno-mini (spoke)        │
│  ┌────────────────────────────┐  │    │  ┌────────────────────────┐  │
│  │ ArgoCD + Principal         │  │    │  │ ArgoCD (lightweight)   │  │
│  │   manages sno apps         │  │    │  │   manages sno-mini     │  │
│  │   receives spoke state     │◄─┼────┼──│ Agent (autonomous)     │  │
│  └────────────────────────────┘  │    │  └────────────────────────┘  │
│  ┌────────────────────────────┐  │    │                              │
│  │ ACM Policies               │  │    │  CA + client TLS certs       │
│  │   cert-manager CA + certs  │──┼───>│  copied via ACM policy       │
│  │   cluster secrets          │  │    │                              │
│  └────────────────────────────┘  │    │                              │
└──────────────────────────────────┘    └──────────────────────────────┘
```

**Key benefits:**
- No cluster credentials stored on the hub
- Each cluster manages its own apps locally (full app-of-apps support)
- Hub provides centralized observability without being a single point of failure
- Secure mTLS communication initiated by the spoke
- PKI fully automated via cert-manager + ACM policies

## Clusters

| Cluster   | Domain                      | Description                |
|-----------|-----------------------------|----------------------------|
| sno       | sno.shanehomelab.com        | Primary SNO cluster        |
| sno-mini  | sno-mini.shanehomelab.com   | Secondary SNO cluster      |

## Prerequisites

- OpenShift GitOps 1.19+ (ArgoCD Agent is GA in 1.19, released Jan 2026)
- cert-manager operator installed on the hub (for automated PKI)
- `helm` CLI v3.8.0+ (for Agent Helm chart on spoke)

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

## Bootstrap — Agent Mode (Autonomous)

### 1. Label managed clusters in ACM

```bash
# Label the hub cluster as the control plane
oc label managedcluster local-cluster argocd-agent-control-plane=""

# Label spoke clusters — the value becomes the agent name
oc label managedcluster sno-mini argocd-agent=sno-mini
```

### 2. Bootstrap the hub (sno)

```bash
export INFRA_GITOPS_REPO=https://github.com/shane-snyder/ocp-homelab.git
export CLUSTER_NAME=sno
export CLUSTER_BASE_DOMAIN=shanehomelab.com

oc apply -f .bootstrap/subscription.yaml
# Wait for the OpenShift GitOps operator to install...
oc apply -f .bootstrap/cluster-rolebinding.yaml
envsubst < .bootstrap/agent/hub-argocd.yaml | oc apply -f -
envsubst < .bootstrap/root-application.yaml | oc apply -f -
```

The hub uses the standard root application (pointing to `clusters/sno`). The
ArgoCD CR enables the Principal component with `insecureGenerate: true` for
gRPC/JWT, while cert-manager handles the CA and resource proxy TLS certs.

The `acm-policies-argocd-agent` app (synced from `clusters/sno/values.yaml`)
deploys ACM policies that automatically:
- Create a self-signed cert-manager CA in `openshift-gitops`
- Issue per-agent client and principal TLS certificates
- Create per-agent namespaces, AppProjects, and cluster secrets on the hub
- Copy the CA cert and client TLS cert to spoke clusters

### 3. Bootstrap the spoke (sno-mini)

```bash
export INFRA_GITOPS_REPO=https://github.com/shane-snyder/ocp-homelab.git
export CLUSTER_NAME=sno-mini
export CLUSTER_BASE_DOMAIN=shanehomelab.com

oc apply -f .bootstrap/subscription.yaml
# Wait for the OpenShift GitOps operator to install...
oc apply -f .bootstrap/cluster-rolebinding.yaml
oc apply -f .bootstrap/agent/spoke-argocd.yaml
oc apply -f .bootstrap/agent/spoke-network-policy.yaml
```

### 4. Install the ArgoCD Agent on the spoke

```bash
PRINCIPAL_ROUTE=openshift-gitops-server-openshift-gitops.apps.sno.shanehomelab.com

helm install argocd-agent openshift-helm-charts/redhat-argocd-agent \
  --namespace openshift-gitops \
  --set namespaceOverride=openshift-gitops \
  --set agentMode="autonomous" \
  --set server="${PRINCIPAL_ROUTE}" \
  --set argoCdRedisSecretName="openshift-gitops-redis-initial-password" \
  --set argoCdRedisPasswordKey="admin.password" \
  --set redisAddress="openshift-gitops-redis:6379"
```

### 5. Apply the root application on the spoke

```bash
envsubst < .bootstrap/agent/spoke-root-application.yaml | oc apply -f -
```

The spoke manages its own apps from `clusters/sno-mini/` — the same path used
in standalone mode. The Agent syncs state back to the hub for visibility.

## ACM Policies — ArgoCD Agent PKI

The `acm-policies-argocd-agent` component manages all certificate lifecycle
automatically. It deploys two ACM policies:

| Policy | Runs on | What it does |
|--------|---------|--------------|
| `argocd-agent-registration` | Hub (`argocd-agent-control-plane` label) | Creates cert-manager Issuers, per-agent Certificates, Namespaces, AppProjects, and cluster Secrets |
| `argocd-agent` | Spokes (`argocd-agent` label) | Copies CA cert and client TLS cert from hub to spoke via hub templates |

The ServiceAccount `argocd-agent-policy` in `acm-policies` namespace has
permissions to read secrets from `openshift-gitops` (via RoleBinding) and
ManagedCluster resources (via ClusterRoleBinding), enabling the hub templates
to propagate certificates to spoke clusters.

## Adding a New Cluster

1. Create `clusters/<new-cluster>/kustomization.yaml` (include desired groups)
2. Create `clusters/<new-cluster>/values.yaml` (list cluster-specific applications)
3. Add cluster overlays under `clusters/<new-cluster>/overlays/` as needed
4. Bootstrap the cluster using the standalone instructions above

### Adding a spoke cluster (agent mode)

In addition to steps 1-3 above:

4. Label the ManagedCluster: `oc label managedcluster <cluster> argocd-agent=<cluster>`
5. Add `argocd-agent-<cluster>` to `sourceNamespaces` in `.bootstrap/agent/hub-argocd.yaml`
6. Re-apply the hub ArgoCD CR
7. Bootstrap the spoke using the agent mode instructions above (steps 3-5)

The ACM policies automatically handle certificate generation and distribution
for any ManagedCluster with the `argocd-agent` label.

## Adding a New Application

1. Create the component under `components/<app-name>/`
2. Add the application entry to `groups/all/values.yaml` (if shared) or the cluster's `values.yaml`
3. If cluster-specific config is needed, create an overlay under `clusters/<cluster>/overlays/<app>/`

In agent mode, apps are managed locally on each spoke — no hub-side changes
needed for spoke-specific applications.
