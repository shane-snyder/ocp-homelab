# vm-multinetworkpolicies

Phase 3 of the "discover then lock down" workflow for CNV VMs on the
`vm-network/vlan100` OVN-K localnet secondary network.

**Do not wire this into `clusters/sno/values.yaml` until discovery is complete.**
Once the default-deny policy below is applied, every secondary-network flow that
isn't explicitly allowed is dropped. During Phase 2 (discovery) there should be
*no* MultiNetworkPolicy on the NAD so traffic flows freely and NetObserv can see
all of it.

**Namespace matters.** MultiNetworkPolicy resources select pods in their *own*
namespace. The VM pods run in `rhel10-vm` (the NAD lives in `vm-network` and is
referenced cross-namespace), so these policies live in `rhel10-vm`. If you add
VMs in other namespaces, replicate the policies there too.

## Prerequisite: enable MultiNetworkPolicy cluster-wide

MultiNetworkPolicy enforcement is **off** by default. Turn it on once (this
restarts the multus/OVN pods, so expect brief secondary-network disruption):

```sh
oc patch network.operator.openshift.io cluster --type=merge \
  -p '{"spec":{"useMultiNetworkPolicy":true}}'
```

`000-enable-multinetworkpolicy.yaml.disabled` holds the GitOps equivalent if you
prefer to manage the flag declaratively — rename off `.disabled`, but read the
warning in that file first (it server-side-applies a field on the singleton
Network CR).

## Workflow

1. Finish Phase 2 discovery; read flows from the NetObserv Topology view
   filtered to the VM namespace (`rhel10-vm`) + the `vlan100` secondary network.
2. Translate the observed `(src, dst, port, proto)` tuples into `allow-*`
   policies (see `020-allow-example.yaml`). The `hack/flows-to-multinetpol.sh`
   script in the repo root can bootstrap these from Loki.
3. Commit `010-default-deny.yaml` **and** your allow rules together, then wire
   this component into `values.yaml`. Applying default-deny without the allows
   will blackhole the VMs' secondary traffic.
4. Keep NetObserv running afterward as a regression detector.

Every policy here targets the secondary network via the
`k8s.v1.cni.cncf.io/policy-for: vm-network/vlan100` annotation. Without that
annotation a MultiNetworkPolicy does nothing.
