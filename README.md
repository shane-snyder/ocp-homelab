# GitOps Homelab

OpenShift GitOps repository for managing homelab clusters using the ArgoCD Agent architecture, following the [Red Hat CoP GitOps pattern](https://github.com/redhat-cop/gitops-standards-repo-template).

## Repository Structure

```
ocp-homelab/
├── .bootstrap/                 # One-time bootstrap manifests (applied manually)
│   ├── subscription.yaml       # OpenShift GitOps operator Subscription
│   └── agent/
│       ├── hub-argocd.yaml             # Hub ArgoCD instance with Principal
│       ├── spoke-argocd.yaml           # Spoke ArgoCD instance (no server)
│       ├── spoke-network-policy.yaml   # NetworkPolicy for Agent ↔ Redis
│       └── spoke-root-application.yaml # Root app template for spoke clusters
├── .helm-charts/
│   └── argocd-app-of-app/      # Helm chart that renders Application + AppProject CRs
├── clusters/                   # Per-cluster app definitions
│   ├── sno/                    # Hub cluster (argocd-agent-sno)
│   │   ├── kustomization.yaml
│   │   ├── values.yaml
│   │   └── overlays/           # Cluster-specific Kustomize patches
│   └── sno-mini/               # Spoke cluster (argocd-agent-sno-mini)
│       ├── kustomization.yaml
│       ├── values.yaml
│       └── overlays/
├── components/                 # Reusable, environment-agnostic manifests
│   ├── argocd-hub/             # Hub ArgoCD instance, RBAC, root apps
│   ├── argocd-agent-spoke/     # Spoke ArgoCD instance
│   ├── acm-policies-argocd-agent/  # ACM policies for agent PKI automation
│   ├── cert-manager-operator/
│   ├── external-secrets-operator/
│   └── ...                     # One directory per application/operator
├── groups/                     # Shared app definitions applied to multiple clusters
│   └── all/
└── .github/workflows/          # CI/CD pipeline
```

## Architecture

All clusters use the ArgoCD Agent model (GA in OpenShift GitOps 1.19+) in
**autonomous mode**. The hub runs an ArgoCD Principal with no application
controller — all reconciliation happens through agents, including on the hub
cluster itself. Each agent is the authority for its own applications; the
principal provides centralized UI visibility without controlling what runs where.

```
┌────────────────────────────────────────┐      ┌──────────────────────────────┐
│            sno (hub)                   │      │       sno-mini (spoke)       │
│                                        │      │                              │
│  ┌──────────────────────────────────┐  │      │  ┌────────────────────────┐  │
│  │ ArgoCD Principal (argocd)        │  │      │  │ ArgoCD (argocd)        │  │
│  │  - No app controller            │  │      │  │  - App controller      │  │
│  │  - Server / UI                  │  │      │  │  - No server           │  │
│  │  - ApplicationSet controller    │◄─┼──────┼──│ Agent (autonomous)     │  │
│  │  - Redis proxy for agents       │  │      │  └────────────────────────┘  │
│  └──────────────────────────────────┘  │      │                              │
│                                        │      │  Agent namespace:            │
│  ┌──────────────────────────────────┐  │      │    argocd-agent-sno-mini     │
│  │ Local Agent (argocd-agent)       │  │      │                              │
│  │  - App controller               │  │      │  Apps: clusters/sno-mini/    │
│  │  - Reconciles hub's own apps    │  │      │    values.yaml               │
│  └──────────────────────────────────┘  │      │                              │
│                                        │      │  mTLS certs copied via       │
│  ┌──────────────────────────────────┐  │      │    ACM policy                │
│  │ ACM + cert-manager               │  │      │                              │
│  │  - CA + per-agent TLS certs     │──┼─────>│                              │
│  │  - ACM policies distribute PKI  │  │      │                              │
│  └──────────────────────────────────┘  │      │                              │
└────────────────────────────────────────┘      └──────────────────────────────┘
```

**Key points:**
- **Autonomous mode** — each agent is self-governing; the hub is an observer, not a controller
- The hub's application controller is **disabled** — a local agent in `argocd-agent` reconciles the hub's own apps
- Spoke agents connect to the hub Principal over mTLS (no cluster credentials stored on the hub)
- Each cluster manages its own apps locally via an app-of-apps pattern
- The hub provides centralized visibility through the ArgoCD UI
- PKI is fully automated via cert-manager + ACM policies

## How It Works

1. Each cluster has a **root Application** that points at `clusters/<cluster>/`
2. The cluster's `kustomization.yaml` renders the `argocd-app-of-app` Helm chart into the agent namespace (e.g., `argocd-agent-sno`)
3. The Helm chart generates `Application` and `AppProject` CRs from `values.yaml`
4. Each generated Application points to a **component** (reusable base manifests) with optional **cluster overlays** for environment-specific patches
5. The agent's application controller reconciles these Applications locally

## Clusters

| Cluster  | Domain                     | Role  | Agent Namespace         |
|----------|----------------------------|-------|-------------------------|
| sno      | sno.shanehomelab.com       | Hub   | argocd-agent-sno        |
| sno-mini | sno-mini.shanehomelab.com  | Spoke | argocd-agent-sno-mini   |

## Prerequisites

- OpenShift 4.x clusters
- OpenShift GitOps 1.19+ (ArgoCD Agent GA)
- cert-manager operator on the hub
- Advanced Cluster Management (ACM) for multi-cluster PKI distribution
- External Secrets Operator + HashiCorp Vault (for Git repo credentials)

## Bootstrap — Hub Cluster (sno)

### 1. Install OpenShift GitOps operator

```bash
oc apply -f .bootstrap/subscription.yaml
# Wait for the operator to install...
```

### 2. Deploy the hub ArgoCD instance

The hub ArgoCD configuration is managed declaratively in `components/argocd-hub/`.
Apply it initially, then ArgoCD self-manages it going forward via the
`gitops-configuration` app.

```bash
oc apply -k components/argocd-hub/base/
```

This creates:
- The `argocd` namespace
- ArgoCD instance with Principal enabled and application controller disabled
- RBAC for the principal, server, and ApplicationSet controller across agent namespaces
- Root application for sno-mini (managed by the hub)
- ExternalSecret for Git repo credentials
- cert-manager certificate for the principal

### 3. Label managed clusters in ACM

```bash
# Hub cluster — the label value becomes the agent identifier
oc label managedcluster local-cluster argocd-agent=sno

# Control plane label (triggers hub-side ACM policies)
oc label managedcluster local-cluster argocd-agent-control-plane=""

# Spoke cluster
oc label managedcluster sno-mini argocd-agent=sno-mini
```

ACM policies in `components/acm-policies-argocd-agent/` automatically:
- Create a cert-manager CA issuer
- Issue per-agent mTLS certificates
- Create agent namespaces (`argocd-agent-<name>`), AppProjects, and cluster secrets on the hub
- Copy CA and client TLS certs to spoke clusters

### 4. Apply the root application for sno

The hub's root application is applied directly into the agent namespace:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-applications
  namespace: argocd-agent-sno
spec:
  destination:
    namespace: argocd-agent-sno
    server: https://kubernetes.default.svc
  project: argocd-agent-sno
  source:
    repoURL: https://github.com/shane-snyder/ocp-homelab.git
    targetRevision: HEAD
    path: clusters/sno
  syncPolicy:
    automated:
      prune: false
      selfHeal: false
    syncOptions:
      - CreateNamespace=true
EOF
```

## Bootstrap — Spoke Cluster (sno-mini)

### 1. Install OpenShift GitOps operator on the spoke

```bash
oc apply -f .bootstrap/subscription.yaml
# Wait for the operator to install...
```

### 2. Deploy the spoke ArgoCD instance

```bash
oc apply -f .bootstrap/agent/spoke-argocd.yaml
oc apply -f .bootstrap/agent/spoke-network-policy.yaml
```

### 3. Install the ArgoCD Agent

```bash
PRINCIPAL_ROUTE=argocd-server-argocd.apps.sno.shanehomelab.com

helm install argocd-agent openshift-helm-charts/redhat-argocd-agent \
  --namespace argocd \
  --set agentMode="autonomous" \
  --set server="${PRINCIPAL_ROUTE}" \
  --set argoCdRedisSecretName="argocd-redis-initial-password" \
  --set argoCdRedisPasswordKey="admin.password" \
  --set redisAddress="argocd-redis:6379"
```

### 4. Apply the spoke root application

The sno-mini root application is managed declaratively by the hub via
`components/argocd-hub/base/root-application-sno-mini.yaml`, so it is
created automatically when the hub syncs. No manual step is needed.

## ACM Policies — Agent PKI

The `acm-policies-argocd-agent` component automates all certificate and
registration lifecycle. It deploys two ACM policies:

| Policy | Runs On | What It Does |
|--------|---------|--------------|
| `argocd-agent-registration` | Hub (`argocd-agent-control-plane` label) | Creates cert-manager Issuers, per-agent Certificates, Namespaces, AppProjects, and cluster Secrets |
| `argocd-agent` | Spokes (`argocd-agent` label) | Copies CA cert and client TLS cert from hub to spoke via hub templates |

## Adding a New Cluster

1. Create `clusters/<cluster>/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
helmGlobals:
  chartHome: ../../.helm-charts
helmCharts:
  - name: argocd-app-of-app
    releaseName: <cluster>-apps
    namespace: argocd-agent-<cluster>
    valuesFile: values.yaml
```

2. Create `clusters/<cluster>/values.yaml` with the cluster's applications (use `sno/values.yaml` as a template, set `project: argocd-agent-<cluster>`)
3. Add cluster overlays under `clusters/<cluster>/overlays/` as needed
4. Label the ManagedCluster in ACM: `oc label managedcluster <cluster> argocd-agent=<cluster>`
5. Add a root application for the new cluster in `components/argocd-hub/base/` (following `root-application-sno-mini.yaml` as a template)
6. Bootstrap the spoke using the spoke instructions above

## Adding a New Application

1. Create the component under `components/<app-name>/` with a `kustomization.yaml`
2. Add the application entry to the cluster's `values.yaml`:

```yaml
applications:
  my-new-app:
    annotations:
      argocd.argoproj.io/sync-wave: "5"
    source:
      path: components/my-new-app
    destination:
      namespace: my-namespace
```

3. If shared across all clusters, add it to `groups/all/values.yaml` instead
4. For cluster-specific config, create an overlay at `clusters/<cluster>/overlays/<app>/`

## Useful Commands

```bash
# Check all apps on the hub agent
oc get applications.argoproj.io -n argocd-agent-sno

# Check all apps on the sno-mini agent
oc get applications.argoproj.io -n argocd-agent-sno-mini

# Trigger a manual sync on the root application
oc patch application.argoproj.io root-applications -n argocd-agent-sno \
  --type merge -p '{"operation":{"initiatedBy":{"username":"admin","automated":false},"sync":{"revision":"HEAD"}}}'

# Safely delete an ArgoCD application without deleting workloads
oc patch application.argoproj.io <app> -n <namespace> \
  --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
oc delete application.argoproj.io <app> -n <namespace>
```
