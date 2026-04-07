# Garage Operations Guide

This document covers day-2 operations for the Garage S3-compatible object store deployed in the `garage` namespace.

## Accessing the CLI

The `garage` binary inside the pod serves as both the server and the CLI.

```bash
oc exec -it -n garage garage-0 -- /bin/sh
```

Or run individual commands without a shell:

```bash
oc exec -n garage garage-0 -- /garage <command>
```

---

## Initial Bootstrap (first-time setup)

### 1. Assign the node layout

After the pod first starts, the node has no role. Assign it a zone and capacity:

```bash
# Get the node ID
oc exec -n garage garage-0 -- /garage status

# Assign layout (capacity is in KB; example: 2.2TB = 2200000000 KB)
oc exec -n garage garage-0 -- /garage layout assign -z dc1 -c <capacity-kb> <node-id>

# Stage and apply
oc exec -n garage garage-0 -- /garage layout apply --version 1
```

---

## Bucket Management

### Create a bucket

```bash
oc exec -n garage garage-0 -- /garage bucket create <bucket-name>
```

### List buckets

```bash
oc exec -n garage garage-0 -- /garage bucket list
```

### Inspect a bucket

```bash
oc exec -n garage garage-0 -- /garage bucket info <bucket-name>
```

---

## Access Key Management

### Create an access key

```bash
oc exec -n garage garage-0 -- /garage key create <key-name>
```

The output includes the **Key ID** (access key) and **Secret key** — save these immediately, the secret key cannot be retrieved later.

### Grant a key access to a bucket

```bash
oc exec -n garage garage-0 -- /garage bucket allow <bucket-name> \
  --read --write --owner \
  --key <key-id>
```

Permissions:
- `--read` — allow GetObject, ListBucket
- `--write` — allow PutObject, DeleteObject
- `--owner` — allow bucket policy and ACL operations (needed by some workloads)

### Revoke a key's access to a bucket

```bash
oc exec -n garage garage-0 -- /garage bucket deny <bucket-name> \
  --read --write --owner \
  --key <key-id>
```

### List all keys

```bash
oc exec -n garage garage-0 -- /garage key list
```

### Delete a key

```bash
oc exec -n garage garage-0 -- /garage key delete <key-id>
```

---

## Adding a New Workload

Full workflow for onboarding a new application to Garage:

```bash
# 1. Create the bucket
oc exec -n garage garage-0 -- /garage bucket create <bucket-name>

# 2. Create an access key for the workload
oc exec -n garage garage-0 -- /garage key create <workload-name>
# → note the Key ID and Secret key from the output

# 3. Grant the key read/write/owner access to the bucket
oc exec -n garage garage-0 -- /garage bucket allow <bucket-name> \
  --read --write --owner \
  --key <key-id>

# 4. Store credentials in Vault (via sno-mini cluster vault pod)
#    oc exec -n vault hashicorp-vault-operator-0 -- sh -c \
#      "export VAULT_TOKEN=<token> && vault kv put sno/garage/<workload-name> \
#       accessKey=<key-id> secretKey=<secret-key>"

# 5. Add an ExternalSecret under clusters/sno/overlays/garage-secrets/
#    referencing sno/garage/<workload-name> in Vault,
#    and add it to the kustomization.yaml in that directory.
```

---

## Credentials Storage Convention

All Garage access keys are stored in Vault under the `sno/` KV engine:

| Vault path                         | Workload                    |
|------------------------------------|-----------------------------|
| `sno/garage/quay`                  | Quay container registry     |
| `sno/garage/oadp`                  | OADP / Velero backups       |
| `sno/garage/tempo`                 | Tempo distributed tracing   |
| `sno/garage/acm-observability`     | ACM Thanos metrics          |
| `sno/garage/ansible`               | Ansible Automation Platform |

Each path contains two fields: `accessKey` and `secretKey`.

ExternalSecrets for each workload are defined in `clusters/sno/overlays/garage-secrets/`.

---

## S3 Endpoint Reference

| Endpoint          | URL                                        |
|-------------------|--------------------------------------------|
| Internal (in-cluster) | `http://garage.garage.svc:3900`        |
| External (OCP Route)  | `https://garage-s3.apps.sno.shanehomelab.com` |

S3 region string: `us-east-1`
Path-style access required: `s3ForcePathStyle=true`
