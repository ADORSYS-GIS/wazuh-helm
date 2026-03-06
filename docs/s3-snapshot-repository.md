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

## Automated Snapshot CronJob

A daily CronJob triggers an OpenSearch snapshot to S3 at 2am UTC. It is enabled via `indexer.s3Snapshot.cronjob.enabled` and requires the S3 repository to be registered first (see [Registering the S3 Snapshot Repository](#registering-the-s3-snapshot-repository)).

### How It Works

The CronJob runs a lightweight `curlimages/curl` container that executes `files/scripts/s3-snapshot.sh`. Before triggering the snapshot, the script:

1. Checks cluster health — aborts if the cluster is RED
2. Verifies the snapshot repository exists
3. Checks if today's snapshot (`snapshot-YYYYMMDD`) already succeeded — skips if so
4. Appends a `HHMMSS` time suffix if a failed/partial snapshot exists with the same name
5. Triggers `PUT /_snapshot/{repo}/{name}?wait_for_completion=true`
6. Validates the response state is `SUCCESS`
7. Retries up to `MAX_RETRIES` (default 3) on transient failures with `RETRY_DELAY` (default 30s) between attempts

`concurrencyPolicy: Forbid` prevents overlapping runs.

### Values Configuration

```yaml
indexer:
  s3Snapshot:
    enabled: true
    credentialsSecret: "ext-wazuh-aws-s3-snapshot-credentials"
    repository: "s3-repo"
    cronjob:
      enabled: true
      schedule: "0 2 * * *"          # 2am UTC daily
      successfulJobsHistoryLimit: 3
      failedJobsHistoryLimit: 1
      image:
        registry: docker.io
        repository: curlimages/curl
        tag: "8.11.1"
```

### Verifying the CronJob

```bash
# Check CronJob is registered
kubectl get cronjob -n wazuh

# View the last run
kubectl get jobs -n wazuh | grep snapshot

# Check logs of the last run
kubectl logs -n wazuh job/<release>-indexer-s3-snapshot-<suffix>

# Manually trigger a run to test
kubectl create job --from=cronjob/<release>-indexer-s3-snapshot manual-test -n wazuh
kubectl logs -n wazuh job/manual-test -f
```

---

## Automated Snapshot Cleanup CronJob

A daily CronJob at 3am UTC deletes snapshots older than a configurable retention window (default: 30 days). It runs one hour after the snapshot job to ensure the day's snapshot has completed before cleanup begins.

### How It Works

The CronJob runs `files/scripts/s3-snapshot-cleanup.sh`, which:

1. Checks cluster health — aborts on RED to avoid deleting snapshots during a degraded state
2. Verifies the snapshot repository exists
3. Lists all snapshots via `GET /_snapshot/{repo}/_all`
4. For each snapshot, extracts the first 8-digit sequence in its name as a `YYYYMMDD` date
5. Compares the date against the cutoff (`today - retentionDays`)
6. Deletes snapshots whose date is older than the cutoff
7. Snapshots whose names contain **no 8-digit date are skipped and preserved** — this protects any manually-created snapshots with custom names
8. Reports a summary of deleted / kept / failed counts; exits non-zero if any deletion failed (but continues processing remaining snapshots)

`concurrencyPolicy: Forbid` prevents overlapping runs.

### Values Configuration

```yaml
indexer:
  s3Snapshot:
    cleanup:
      enabled: true
      schedule: "0 3 * * *"          # 3am UTC daily
      retentionDays: 30
      successfulJobsHistoryLimit: 3
      failedJobsHistoryLimit: 1
      image:
        registry: docker.io
        repository: curlimages/curl
        tag: "8.11.1"
```

### Verifying the Cleanup CronJob

```bash
# Manually trigger to test
kubectl create job --from=cronjob/<release>-indexer-s3-snapshot-cleanup manual-cleanup -n wazuh
kubectl logs -n wazuh job/manual-cleanup -f

# Confirm old snapshots were removed
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:<password> \
  "https://localhost:9200/_snapshot/s3-repo/_all?pretty" \
  | grep '"snapshot"'
```

---

## On-Demand Snapshot Restore Job

A one-shot Kubernetes Job that restores the Wazuh Indexer from a named S3 snapshot. Unlike the CronJobs, this is not scheduled — it is triggered intentionally by the operator at deploy time by setting `indexer.s3Snapshot.restore.enabled: true` and providing the target `snapshotName`.

### Timing and Hook Mechanism

The restore Job is a Helm `post-install,post-upgrade` hook, meaning it fires **after all regular Kubernetes resources have been deployed** (StatefulSets, Services, etc.). This ensures the Indexer pod exists before the Job tries to connect.

| Hook phase | Weight | Resource |
|---|---|---|
| `post-install,post-upgrade` | 5 | ConfigMap (restore script) |
| `post-install,post-upgrade` | 10 | Job (restore) |

The Job uses `helm.sh/hook-delete-policy: before-hook-creation`, so the previous Job is automatically removed each time `helm upgrade` is run. This means a restore can be re-triggered simply by running `helm upgrade` again with the same flags.

### Authentication

The restore job uses **mTLS authentication** with the OpenSearch admin certificate (`admin.pem` / `admin-key.pem` from the `{release}-certificates` secret). This bypasses the OpenSearch security plugin entirely, granting full cluster admin access. This is required because the `admin` user's basic auth credentials lack the `cluster:admin/snapshot/restore` and `indices:admin/close` permissions in Wazuh's security configuration.

The admin certificate DN (`CN=admin,O=Adorsys,L=Bayern,C=DE`) is listed in `plugins.security.authcz.admin_dn` in `opensearch.yml`, which is what grants the bypass.

### How It Works

`files/scripts/s3-snapshot-restore.sh` executes the following steps:

1. **Wait for OpenSearch** — polls `/_cluster/health` every 10s up to `WAIT_TIMEOUT` (default 300s); exits if the indexer doesn't start in time
2. **Cluster health check** — aborts on RED
3. **Verify repository** — actionable error if repo not registered
4. **Verify snapshot** — confirms the named snapshot exists and has state `SUCCESS`; refuses to restore FAILED or PARTIAL snapshots
5. **Close all indices** (if `closeIndices: true`) — calls `POST /_all/_close?expand_wildcards=all` to close all indices including hidden system indices (e.g. `.opensearch-notifications-config`), preventing restore conflicts
6. **Trigger restore** — `POST /_snapshot/{repo}/{name}/_restore?wait_for_completion=true`
7. **Validate results** — checks HTTP 200 and reports total/successful/failed shard counts; exits non-zero if any shards failed

### Values Configuration

```yaml
indexer:
  s3Snapshot:
    restore:
      enabled: false          # set to true at deploy time to trigger
      snapshotName: ""        # required when enabled
      closeIndices: true      # close existing indices before restoring
      waitTimeout: 300        # seconds to wait for OpenSearch readiness
      image:
        registry: docker.io
        repository: curlimages/curl
        tag: "8.11.1"
```

### Triggering a Restore

```bash
helm upgrade -i wazuh ./ -n wazuh \
  --values values-eks.yaml \
  --set indexer.s3Snapshot.restore.enabled=true \
  --set indexer.s3Snapshot.restore.snapshotName=snapshot-20260301
```

To re-trigger (e.g. after fixing an issue), run the same command again. The previous Job is deleted by the `before-hook-creation` policy and a new one is created.

### Verifying a Successful Restore

```bash
# 1. Check job logs completed successfully
kubectl logs -n wazuh job/<release>-indexer-s3-snapshot-restore
# Should end with: INFO  === S3 Snapshot Restore Job Completed ===

# 2. Verify indices are green and open
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:<password> \
  "https://localhost:9200/_cat/indices?v&h=index,health,status,docs.count,store.size" \
  | sort

# 3. Check cluster health
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:<password> \
  "https://localhost:9200/_cluster/health?pretty"
# Expect: "status": "green", "unassigned_shards": 0

# 4. Confirm Wazuh alert document count matches pre-backup data
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:<password> \
  "https://localhost:9200/wazuh-alerts-*/_count?pretty"
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
| Snapshot CronJob shows `state: PARTIAL` | Some shards unavailable at snapshot time | Check cluster health; if cluster was yellow during snapshot, consider retaining and taking a new snapshot once green |
| Cleanup CronJob skips a snapshot | Snapshot name contains no 8-digit date | Expected behaviour for manually-named snapshots; rename it to include a date if you want it managed by the cleanup job |
| Restore job exits with HTTP 000 | Cert files not readable by container user | Confirm `defaultMode: 0444` is set on the `admin-certs` volume in the Job template |
| Restore job exits with HTTP 403 | mTLS not being used (fell back to basic auth) | Confirm `admin.pem` and `admin-key.pem` are correctly mounted at the paths specified by `ADMIN_CERT` / `ADMIN_KEY` env vars |
| Restore fails: `cannot restore index [.opensearch-*] because an open index with same name already exists` | Hidden system indices not closed | Confirm `expand_wildcards=all` is present in the `/_all/_close` call in `s3-snapshot-restore.sh` |
| Restore fails: `snapshot state is not SUCCESS` | Trying to restore a FAILED or PARTIAL snapshot | List snapshots, identify a SUCCESS one, and set `snapshotName` to that |
| Restore job not re-triggered on second `helm upgrade` | Hook delete policy issue | Confirm `helm.sh/hook-delete-policy: before-hook-creation` is set; check if old Job still exists: `kubectl get job -n wazuh` |

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
| `charts/wazuh/files/scripts/s3-snapshot.sh` | Created | Snapshot trigger script with health checks, idempotency, and retry logic |
| `charts/wazuh/templates/indexer/configmap.s3-snapshot.yaml` | Created | ConfigMap embedding `s3-snapshot.sh` |
| `charts/wazuh/templates/indexer/cronjob.s3-snapshot.yaml` | Created | CronJob — daily at 2am, `concurrencyPolicy: Forbid` |
| `charts/wazuh/files/scripts/s3-snapshot-cleanup.sh` | Created | Cleanup script — deletes snapshots older than `retentionDays` by date in name |
| `charts/wazuh/templates/indexer/configmap.s3-snapshot-cleanup.yaml` | Created | ConfigMap embedding `s3-snapshot-cleanup.sh` |
| `charts/wazuh/templates/indexer/cronjob.s3-snapshot-cleanup.yaml` | Created | CronJob — daily at 3am, `concurrencyPolicy: Forbid` |
| `charts/wazuh/files/scripts/s3-snapshot-restore.sh` | Created | Restore script — mTLS admin cert auth, waits for readiness, closes all indices, validates shard counts |
| `charts/wazuh/templates/indexer/configmap.s3-snapshot-restore.yaml` | Created | ConfigMap embedding `s3-snapshot-restore.sh` (post-install hook, weight 5) |
| `charts/wazuh/templates/indexer/job.s3-snapshot-restore.yaml` | Created | One-shot Job — post-install/post-upgrade hook, weight 10, `backoffLimit: 0` |

### `wazuh` repository

| File | Type | Description |
|------|------|-------------|
| `argocd-repo/dev/wazuh/indexer-s3-snapshot-secrets.yaml` | Created | ExternalSecret for dev (pulls from `dev/github/wazuh-manager-backup`) |
| `argocd-repo/prod/wazuh/indexer-s3-snapshot-secrets.yaml` | Created | ExternalSecret for prod (pulls from `prod/wazuh/aws`) |
| `argocd-repo/dev/wazuh/kustomization.yaml` | Modified | Added `indexer-s3-snapshot-secrets.yaml` to resources |
| `argocd-repo/prod/wazuh/kustomization.yaml` | Modified | Added `indexer-s3-snapshot-secrets.yaml` to resources |
