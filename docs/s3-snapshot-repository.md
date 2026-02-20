# S3 Snapshot Repository for Wazuh Indexer

## Overview

This document describes the implementation of Amazon S3 as a snapshot repository for the Wazuh Indexer (OpenSearch). Snapshots allow point-in-time backups of OpenSearch indices that can be stored durably in S3 and restored on demand.

The implementation spans two repositories:
- **`wazuh-helm`** — Helm chart and Docker image changes
- **`wazuh`** — ArgoCD deployment and secrets management changes

---

## Architecture

```
GitHub Actions
    │
    └── Builds & pushes custom indexer image
        ghcr.io/adorsys-gis/wazuh-indexer-s3:<tag>
                │
                ▼
        Kubernetes StatefulSet (Wazuh Indexer)
                │
                ├── [init] setup-s3-keystore
                │       Reads AWS credentials from K8s Secret
                │       Writes opensearch.keystore to shared emptyDir
                │
                └── [main] wazuh-indexer
                        Mounts keystore from emptyDir
                        repository-s3 plugin pre-installed
                        Connects to S3 for snapshots

AWS Secrets Manager ──► External-Secrets Operator ──► K8s Secret
dev/github/wazuh-manager-backup                   ext-wazuh-aws-s3-snapshot-credentials
```

---

## Repository: `wazuh-helm`

### Files Created

#### `utils/packages/wazuh-indexer-s3/Dockerfile`

Custom Docker image extending the official `wazuh/wazuh-indexer` image with the OpenSearch `repository-s3` plugin pre-installed.

```dockerfile
ARG WAZUH_VERSION=4.14.2
FROM wazuh/wazuh-indexer:${WAZUH_VERSION}

USER root

ENV OPENSEARCH_PATH_CONF=/usr/share/wazuh-indexer/config

# Create missing sysconfig file that opensearch-env expects, then install the S3 repository plugin
RUN touch /etc/sysconfig/wazuh-indexer && \
    /usr/share/wazuh-indexer/bin/opensearch-plugin install --batch repository-s3

USER wazuh-indexer
```

**Why the workarounds?**
- `touch /etc/sysconfig/wazuh-indexer` — the `opensearch-env` script sources this file but it doesn't exist in the base image, causing a build failure
- `ENV OPENSEARCH_PATH_CONF` — the plugin installer requires this to be set to find the config directory
- `USER root` / `USER wazuh-indexer` — the base image runs as a non-root user; root is required only for plugin installation, then reverted

#### `.github/workflows/build-wazuh-indexer-s3.yml`

GitHub Actions workflow that automatically builds and pushes the custom indexer image to GHCR on every push that changes the Dockerfile or the workflow file itself.

**Key properties:**
- **Registry:** `ghcr.io/adorsys-gis/wazuh-indexer-s3`
- **Triggers:** Any push touching `utils/packages/wazuh-indexer-s3/**` or the workflow file
- **Platforms:** `linux/amd64`
- **Build arg:** `WAZUH_VERSION=4.14.2` passed to Dockerfile
- **Security:** All GitHub Actions pinned to full commit SHAs (not mutable tags) to prevent supply chain attacks
- **Tagging strategy:**
  - `4.14.2` on the default branch
  - `<branch>-<sha>` for feature branches
  - Semver tags on version tags (`v*`)

### Files Modified

#### `charts/wazuh/values.yaml`

Added the `indexer.s3Snapshot` configuration block:

```yaml
indexer:
  # ...existing config...

  ## S3 snapshot repository configuration
  ## Requires a custom indexer image with the repository-s3 plugin installed.
  ## See utils/packages/wazuh-indexer-s3/Dockerfile for building the image.
  s3Snapshot:
    ## Enable S3 snapshot repository support
    enabled: false
    ## Name of an existing Kubernetes Secret with keys:
    ##   AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY
    credentialsSecret: ""
```

#### `charts/wazuh/values-eks.yaml`

Added production S3 snapshot configuration for EKS deployments:

```yaml
indexer:
  replicas: 2
  persistence:
    size: 50Gi
  image:
    registry: ghcr.io
    repository: adorsys-gis/wazuh-indexer-s3
    tag: release-candidate-indexer-snapshots-c3dbb18
  s3Snapshot:
    enabled: true
    credentialsSecret: ext-wazuh-aws-s3-snapshot-credentials
```

This overrides the default `wazuh/wazuh-indexer` image with the custom GHCR-hosted image and enables the S3 snapshot feature pointing at the secret created by External-Secrets.

#### `charts/wazuh/values-remote-secrets.yaml`

Added the S3 snapshot credentials secret pattern for documentation and reference:

```yaml
indexer:
  auth: ~
  authSecret: "<example>-indexer-secrets"
  s3Snapshot:
    credentialsSecret: "<example>-s3-snapshot-credentials"
```

#### `charts/wazuh/templates/indexer/sts.indexer.yaml`

Three conditional additions guarded by `{{- if and .s3Snapshot .s3Snapshot.enabled }}`:

**1. emptyDir volume** — shared storage for the keystore between init and main containers:
```yaml
- name: indexer-keystore
  emptyDir: {}
```

**2. `setup-s3-keystore` init container** — runs before OpenSearch starts, creates the keystore with AWS credentials and copies it to the shared volume:
```yaml
- name: setup-s3-keystore
  image: <same as indexer>
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
  command:
    - /bin/sh
    - -c
    - |
      set -e
      /usr/share/wazuh-indexer/bin/opensearch-keystore create
      echo "$AWS_ACCESS_KEY_ID" | opensearch-keystore add --stdin s3.client.default.access_key
      echo "$AWS_SECRET_ACCESS_KEY" | opensearch-keystore add --stdin s3.client.default.secret_key
      cp /usr/share/wazuh-indexer/config/opensearch.keystore /keystore/opensearch.keystore
  env:
    - name: OPENSEARCH_PATH_CONF
      value: /usr/share/wazuh-indexer/config
    - name: AWS_ACCESS_KEY_ID
      valueFrom:
        secretKeyRef:
          name: <credentialsSecret>
          key: AWS_ACCESS_KEY_ID
    - name: AWS_SECRET_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: <credentialsSecret>
          key: AWS_SECRET_ACCESS_KEY
  volumeMounts:
    - name: indexer-keystore
      mountPath: /keystore
```

**3. Keystore volume mount** in the main container — mounts the keystore written by the init container as a read-only file:
```yaml
- name: indexer-keystore
  mountPath: /usr/share/wazuh-indexer/config/opensearch.keystore
  subPath: opensearch.keystore
  readOnly: true
```

#### `charts/wazuh/Chart.yaml`

Chart version bumped to `0.8.2-rc.105` to trigger republication to the Helm chart repository so ArgoCD can pick up the changes.

---

## Repository: `wazuh`

### Files Created

#### `argocd-repo/dev/wazuh/indexer-s3-snapshot-secrets.yaml`

`ExternalSecret` resource that pulls AWS credentials from AWS Secrets Manager and creates the Kubernetes secret consumed by the `setup-s3-keystore` init container.

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: wazuh-indexer-s3-snapshot-external-secret
  namespace: wazuh
spec:
  refreshInterval: 10m
  secretStoreRef:
    name: wazuh-secret-store        # Dev ClusterSecretStore (IRSA-backed)
    kind: ClusterSecretStore
  target:
    name: ext-wazuh-aws-s3-snapshot-credentials
    creationPolicy: Owner
    template:
      type: Opaque
  data:
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef:
        key: dev/github/wazuh-manager-backup   # Reuses backup S3 credentials
        property: aws_access_key_id
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef:
        key: dev/github/wazuh-manager-backup
        property: aws_secret_access_key
```

**Why reuse the backup credentials?**

The same S3 credentials used by the Tekton backup solution (`dev/github/wazuh-manager-backup`) have the necessary permissions to write to the S3 bucket. Rather than provisioning a separate IAM user/key, this ExternalSecret pulls the same underlying credentials but formats them as plain key-value pairs (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`) — as opposed to the backup secret which formats them as an AWS CLI INI credentials file.

#### `argocd-repo/prod/wazuh/indexer-s3-snapshot-secrets.yaml`

Same pattern as dev but referencing the prod `ClusterSecretStore` and pulling from `prod/wazuh/aws` (the main AWS credentials key used in production, since prod has no dedicated backup credentials):

```yaml
spec:
  secretStoreRef:
    name: prod-wazuh-secret-store
  data:
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef:
        key: prod/wazuh/aws
        property: aws_access_key_id
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef:
        key: prod/wazuh/aws
        property: aws_secret_access_key
```

### Files Modified

#### `argocd-repo/dev/wazuh/kustomization.yaml`

Added `indexer-s3-snapshot-secrets.yaml` to the resources list so ArgoCD applies it:

```yaml
resources:
  - aws-secrets.yaml
  - backup-s3-secrets.yaml
  - indexer-secrets.yaml
  - indexer-s3-snapshot-secrets.yaml   # ← added
  - root-ca-secrets.yaml
  - secrets-store.yaml
  - slack-secrets.yaml
```

#### `argocd-repo/prod/wazuh/kustomization.yaml`

Same addition for prod:

```yaml
resources:
  - aws-secrets.yaml
  - indexer-secrets.yaml
  - indexer-s3-snapshot-secrets.yaml   # ← added
  - root-ca-secrets.yaml
  - secrets-store.yaml
  - slack-secrets.yaml
```

---

## End-to-End Deployment Flow (Dev)

```
1. Push to release-candidate/indexer-snapshots branch
        │
        ├── GitHub Actions: build-wazuh-indexer-s3.yml
        │       Builds Dockerfile, pushes to GHCR
        │       Image: ghcr.io/adorsys-gis/wazuh-indexer-s3:<branch-sha>
        │
        └── GitHub Actions: helm-publish.yml
                Packages & publishes chart v0.8.2-rc.105
                to https://adorsys-gis.github.io/wazuh-helm

2. ArgoCD detects new chart version (values-dev.yaml targetRevision updated)
        │
        ├── Kustomize applies indexer-s3-snapshot-secrets.yaml
        │       External-Secrets reads dev/github/wazuh-manager-backup
        │       from AWS Secrets Manager
        │       Creates K8s Secret: ext-wazuh-aws-s3-snapshot-credentials
        │
        └── Helm renders wazuh chart with values-eks.yaml overlay
                Indexer StatefulSet uses ghcr.io/adorsys-gis/wazuh-indexer-s3
                s3Snapshot.enabled=true

3. Indexer pod starts
        │
        ├── [init] volume-mount-hack         Fix volume permissions
        ├── [init] increase-vm-max-map-count Set vm.max_map_count=262144
        ├── [init] config-init               Generate bcrypt auth hashes
        ├── [init] setup-s3-keystore         ← New
        │       Reads AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
        │       from ext-wazuh-aws-s3-snapshot-credentials
        │       Runs: opensearch-keystore create
        │       Runs: opensearch-keystore add s3.client.default.access_key
        │       Runs: opensearch-keystore add s3.client.default.secret_key
        │       Copies keystore to shared emptyDir volume
        │
        └── [main] wazuh-indexer
                Mounts keystore from emptyDir (read-only)
                repository-s3 plugin available
                OpenSearch starts with S3 client credentials loaded
```

---

## Registering the S3 Snapshot Repository

After deployment, the S3 repository must be registered with OpenSearch once via the API. This is a one-time operation that persists in the cluster state.

```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:<password> \
  -X PUT "https://localhost:9200/_snapshot/s3-repo" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "s3",
    "settings": {
      "bucket": "your-bucket-name",
      "region": "eu-central-1",
      "base_path": "snapshots"
    }
  }'
# Expected response: {"acknowledged":true}
```

---

## Verification Checklist

### 1. ExternalSecret synced
```bash
kubectl get externalsecret -n wazuh wazuh-indexer-s3-snapshot-external-secret
# READY should be "True"

kubectl get secret -n wazuh ext-wazuh-aws-s3-snapshot-credentials
# Should exist with 2 data keys
```

### 2. Init container completed successfully
```bash
kubectl describe pod -n wazuh wazuh-wazuh-helm-indexer-0 | grep -A 5 "setup-s3-keystore"
# State: Terminated, Reason: Completed, Exit Code: 0
```

### 3. Plugin is loaded
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  /usr/share/wazuh-indexer/bin/opensearch-plugin list
# Output must include: repository-s3
```

### 4. S3 repository registration succeeds
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:<password> \
  "https://localhost:9200/_snapshot/s3-repo"
# Returns repository settings (not a 404)
```

### 5. Test snapshot completes
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:<password> \
  -X PUT "https://localhost:9200/_snapshot/s3-repo/test-snapshot?wait_for_completion=true"
# "state": "SUCCESS"
```

---

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---------|-------------|------------|
| `setup-s3-keystore` init container crashes | `ext-wazuh-aws-s3-snapshot-credentials` secret doesn't exist | Check ExternalSecret status; verify AWS Secrets Manager key exists |
| Plugin list doesn't include `repository-s3` | Wrong image being used | Check pod image with `kubectl get pod -o jsonpath='{.spec.containers[0].image}'` |
| Repository registration returns `500` | AWS credentials invalid or missing S3 bucket permissions | Verify IAM permissions allow `s3:PutObject`, `s3:GetObject`, `s3:ListBucket` on the bucket |
| Init container logs show `OPENSEARCH_PATH_CONF must be set` | Running old image without `ENV OPENSEARCH_PATH_CONF` baked in | Rebuild and push the Dockerfile; the env var is now set in the init container spec as well |
| `StorageClass is invalid` error on `helm upgrade` | Existing StorageClass can't be updated in-place | `kubectl delete storageclass wazuh-wazuh-helm` then re-upgrade |

---

## Summary of All Changed Files

### `wazuh-helm` repository

| File | Type | Description |
|------|------|-------------|
| `utils/packages/wazuh-indexer-s3/Dockerfile` | Created | Custom image with `repository-s3` plugin |
| `.github/workflows/build-wazuh-indexer-s3.yml` | Created | CI pipeline to build and push image to GHCR |
| `charts/wazuh/values.yaml` | Modified | Added `indexer.s3Snapshot` config block |
| `charts/wazuh/values-eks.yaml` | Modified | Set GHCR image and enabled S3 snapshots for EKS |
| `charts/wazuh/values-remote-secrets.yaml` | Modified | Added S3 credentials secret name pattern |
| `charts/wazuh/templates/indexer/sts.indexer.yaml` | Modified | Added keystore init container, emptyDir volume, and volume mount |
| `charts/wazuh/Chart.yaml` | Modified | Bumped version to `0.8.2-rc.105` |

### `wazuh` repository

| File | Type | Description |
|------|------|-------------|
| `argocd-repo/dev/wazuh/indexer-s3-snapshot-secrets.yaml` | Created | ExternalSecret for dev (pulls from `dev/github/wazuh-manager-backup`) |
| `argocd-repo/prod/wazuh/indexer-s3-snapshot-secrets.yaml` | Created | ExternalSecret for prod (pulls from `prod/wazuh/aws`) |
| `argocd-repo/dev/wazuh/kustomization.yaml` | Modified | Added `indexer-s3-snapshot-secrets.yaml` to resources |
| `argocd-repo/prod/wazuh/kustomization.yaml` | Modified | Added `indexer-s3-snapshot-secrets.yaml` to resources |
