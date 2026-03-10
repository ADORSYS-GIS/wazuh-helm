# Manager Configuration Backup and Restore

## Overview

This document describes the automated backup and on-demand restore solution for Wazuh Manager
configuration. The Wazuh Manager stores critical operational data — agent enrollment keys
(`client.keys`), `ossec.conf`, custom rules, decoders, CDB lists, and shared agent group
configurations — on a ReadWriteOnce PVC. These are not covered by the OpenSearch S3 snapshots,
which only back up index data.

The solution provides:

- **Daily backup CronJob** — tars the manager's `/var/ossec/etc/` tree, Kubernetes secrets, and
  Helm release values, then uploads them to S3
- **On-demand restore Job** — a Helm post-install/post-upgrade hook that streams a chosen backup
  from S3 back into the manager pod; opt-in, disabled by default

Both use a custom Docker image (`ghcr.io/adorsys-gis/wazuh-manager-backup`) that bundles
`aws-cli`, `kubectl`, and `helm` in a single container.

---

## Architecture

```
GitHub Actions
    │
    └── Builds & pushes custom backup image
        ghcr.io/adorsys-gis/wazuh-manager-backup:<tag>
                │
                ▼
        Kubernetes CronJob (daily at 1am UTC)
                │
                ├── kubectl exec → manager-master-0
                │       tar czf - /var/ossec/etc/...
                │       (streams tar to stdout)
                │
                ├── aws s3 cp - s3://{bucket}/manager-backups/
                │       manager-config-YYYYMMDD-HHMMSS.tar.gz
                │       secrets-YYYYMMDD-HHMMSS.yaml
                │       helm-values-YYYYMMDD-HHMMSS.yaml
                │       helm-values-all-YYYYMMDD-HHMMSS.yaml
                │       manifest-YYYYMMDD-HHMMSS.yaml
                │       secrets/{name}-YYYYMMDD-HHMMSS.yaml
                │
                └── Retention cleanup
                        Deletes objects with date < (today - retentionDays)

AWS credentials ──► K8s Secret (indexer.s3Snapshot.credentialsSecret)
                        AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
```

```
On-demand restore (helm upgrade --set master.backup.restore.enabled=true ...)
        │
        └── Helm post-install/post-upgrade hook Job
                │
                ├── Detects read-only paths in shared/ (ConfigMap mounts)
                │       find /var/ossec/etc/shared -not -writable
                │
                ├── aws s3 cp s3://{bucket}/manager-backups/{BACKUP_FILE} -
                │
                └── kubectl exec -i → manager-master-0
                        tar xzf - -C / --overwrite --exclude=<read-only paths>
```

---

## Design: Why `kubectl exec` Instead of a Shared Volume

The manager StatefulSet PVC (`{release}-manager-backup`) is **ReadWriteOnce** — Kubernetes does
not allow a second pod to mount it while the manager is running. The only way to read the
manager's live filesystem without stopping it is via `kubectl exec`.

The backup streams the tar archive directly from the manager pod to S3:

```sh
kubectl exec -n $NAMESPACE $MANAGER_POD -- tar czf - $BACKUP_PATHS \
  | aws s3 cp - s3://$S3_BUCKET/$S3_KEY
```

No intermediate file is written to disk. The tar data flows from the manager pod's filesystem,
through the exec channel, through the backup container's memory, and into S3 in a single pipe.

---

## Files Created

### `utils/packages/wazuh-manager-backup/Dockerfile`

Multi-stage Docker image that bundles `aws-cli`, `kubectl`, and `helm`:

```dockerfile
ARG AWS_CLI_VERSION=2.22.35
ARG KUBECTL_VERSION=v1.31.0
ARG HELM_VERSION=v3.17.1

## Stage 1: download and verify kubectl + helm in Alpine (has curl, tar, sha256sum)
FROM alpine:3.21 AS builder
RUN apk add --no-cache curl tar
ARG KUBECTL_VERSION
ARG HELM_VERSION
RUN curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" \
    && echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c \
    && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl \
    && rm kubectl kubectl.sha256 \
    && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
        -o "helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" \
        -o "helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" \
    && sha256sum -c "helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" \
    && tar -zxf "helm-${HELM_VERSION}-linux-amd64.tar.gz" linux-amd64/helm \
    && install -o root -g root -m 0755 linux-amd64/helm /usr/local/bin/helm \
    && rm -rf "helm-${HELM_VERSION}-linux-amd64.tar.gz"* linux-amd64

## Stage 2: amazon/aws-cli runtime — kubectl and helm copied from builder
FROM amazon/aws-cli:${AWS_CLI_VERSION}
COPY --from=builder /usr/local/bin/kubectl /usr/local/bin/kubectl
COPY --from=builder /usr/local/bin/helm    /usr/local/bin/helm
```

**Why multi-stage?** The `amazon/aws-cli` runtime image does not include `curl`, `tar`, or
`sha256sum`. The Alpine builder stage has all of these and produces clean, checksum-verified
binaries that are copied into the final image with no build tools or layer bloat.

**Why Alpine as builder?** `amazonlinux:2023` (the natural choice) also lacks `tar` by default.
Alpine has `curl`, `tar`, and BusyBox `sha256sum` available in a single `apk add`. Note that
BusyBox `sha256sum` uses `-c` (not `--check`) for verification.

### `.github/workflows/build-wazuh-manager-backup.yml`

GitHub Actions workflow that builds and pushes the image to GHCR on any push that changes the
Dockerfile or the workflow itself.

**Key properties:**
- **Registry:** `ghcr.io/adorsys-gis/wazuh-manager-backup`
- **Build args:** `KUBECTL_VERSION`, `AWS_CLI_VERSION`, `HELM_VERSION` (all pinned)
- **Tagging strategy:** `latest` on main, `<branch>-<sha>` for feature branches, semver on tags

### `charts/wazuh/files/scripts/manager-backup.sh`

The backup script executed inside the CronJob container. Runs the following steps:

1. **Configure kubectl** — reads the auto-mounted ServiceAccount token and CA cert from
   `/var/run/secrets/kubernetes.io/serviceaccount/` and sets up an in-cluster context
2. **Verify manager pod** — checks the pod exists and is in `Running` phase
3. **Stream tar to S3** — `kubectl exec ... -- tar czf - $BACKUP_PATHS | aws s3 cp - s3://...`
4. **Verify upload** — `aws s3 ls` confirms the object exists after upload
5. **Back up Kubernetes secrets** — full namespace dump + individual critical secrets to
   `secrets/{name}-YYYYMMDD-HHMMSS.yaml`; helm data is stored in Kubernetes Secrets so
   `secrets get/list` RBAC is also needed for `helm get values`
6. **Back up Helm release values** — `helm get values` (user-supplied) and
   `helm get values --all` (including chart defaults) for full reproducibility
7. **Create backup manifest** — a YAML summary of the backup run (date, pod, files, secret count)
8. **Retention cleanup** — lists objects under the S3 prefix and deletes those whose name
   contains an 8-digit date (`YYYYMMDD`) older than `retentionDays`; objects without a date in
   their name are preserved (e.g. manually uploaded objects)

**S3 object layout after a backup run:**

```
s3://{bucket}/manager-backups/
├── manager-config-20260309-231725.tar.gz      ← main config archive
├── secrets-20260309-231725.yaml               ← full namespace secrets dump
├── helm-values-20260309-231725.yaml           ← user-supplied values
├── helm-values-all-20260309-231725.yaml       ← all values incl. chart defaults
├── manifest-20260309-231725.yaml              ← run summary
└── secrets/
    ├── wazuh-root-ca-20260309-231725.yaml
    ├── {fullname}-api-cred-20260309-231725.yaml
    ├── {fullname}-indexer-cred-20260309-231725.yaml
    ├── {fullname}-certificates-20260309-231725.yaml
    └── {fullname}-dashboard-cred-20260309-231725.yaml
```

**Paths backed up inside the manager pod:**

| Path | Contents |
|------|----------|
| `/var/ossec/etc/ossec.conf` | Main manager configuration |
| `/var/ossec/etc/client.keys` | Agent enrollment keys |
| `/var/ossec/etc/rules/` | Custom detection rules |
| `/var/ossec/etc/decoders/` | Custom log decoders |
| `/var/ossec/etc/lists/` | CDB threat intelligence lists |
| `/var/ossec/etc/shared/` | Agent group configs (incl. dashboard-created groups) |

### `charts/wazuh/files/scripts/manager-restore.sh`

The restore script executed inside the restore Job container. Runs the following steps:

1. **Configure kubectl** — same in-cluster token setup as the backup script
2. **Verify S3 object** — `aws s3 ls` confirms the requested backup file exists before attempting
   download
3. **Verify manager pod** — checks the pod exists and is `Running`
4. **Detect read-only paths** — runs `find /var/ossec/etc/shared -not -writable` inside the
   manager pod to discover ConfigMap-mounted paths (e.g. `dlp/agent.conf` which is read-only);
   builds `--exclude` flags for only those paths — dashboard-configured group configs in the same
   directory are writable (PVC) and are always restored
5. **Stream tar from S3** — `aws s3 cp s3://... - | kubectl exec -i ... -- tar xzf - -C / --overwrite`
   with dynamic exclude flags; `--overwrite` forces replacement of existing files
6. **Verify key files** — checks that `ossec.conf` and `client.keys` exist in the pod after
   extraction
7. **Summary** — logs the `kubectl rollout restart` command needed to reload the restored
   configuration

### `charts/wazuh/templates/manager/`

| File | Kind | Purpose |
|------|------|---------|
| `serviceaccount.manager-backup.yaml` | ServiceAccount | Identity for both backup and restore containers |
| `role.manager-backup.yaml` | Role | Grants `pods get/list`, `pods/exec create`, `secrets get/list` |
| `rolebinding.manager-backup.yaml` | RoleBinding | Binds the Role to the ServiceAccount |
| `configmap.manager-backup.yaml` | ConfigMap | Embeds `manager-backup.sh` for the CronJob |
| `configmap.manager-restore.yaml` | ConfigMap | Embeds `manager-restore.sh` for the restore Job |
| `cronjob.manager-backup.yaml` | CronJob | Daily backup at 1am UTC |
| `job.manager-restore.yaml` | Job | On-demand restore hook |

All resources are guarded by `{{- if and .Values.master .Values.master.backup .Values.master.backup.enabled }}`.

---

## RBAC

The backup and restore share a single ServiceAccount and Role. The `secrets get/list` permission
is needed for two reasons: exporting Kubernetes secrets during backup, and because Helm stores
release data as Kubernetes Secrets (type `helm.sh/release.v1`), so `helm get values` requires
read access to secrets.

```yaml
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
```

---

## Values Configuration

```yaml
master:
  backup:
    ## Enable the daily manager configuration backup CronJob.
    enabled: false

    ## Cron schedule in UTC. Default: 1am daily (before the indexer snapshot at 2am).
    schedule: "0 1 * * *"

    ## Number of days to retain backup objects in S3.
    ## Objects whose filenames contain a date older than this are deleted.
    retentionDays: 30

    ## S3 key prefix for manager backup objects.
    ## Backups land at s3://{bucket}/{s3BasePath}/manager-config-YYYYMMDD-HHMMSS.tar.gz
    s3BasePath: "manager-backups"

    ## Number of successfully completed CronJob runs to retain in Kubernetes.
    successfulJobsHistoryLimit: 3

    ## Number of failed CronJob runs to retain for debugging.
    failedJobsHistoryLimit: 1

    ## Custom image with aws-cli + kubectl + helm pre-installed.
    ## Built from utils/packages/wazuh-manager-backup/Dockerfile.
    image:
      registry: ghcr.io
      repository: adorsys-gis/wazuh-manager-backup
      tag: "latest"

    ## On-demand restore of a manager configuration backup from S3.
    ## Runs as a Helm post-install/post-upgrade hook — only when enabled=true.
    ## After the restore completes, redeploy without these flags to prevent re-running.
    restore:
      ## Set to true to trigger a restore on the next helm install/upgrade.
      ## IMPORTANT: set back to false after the restore completes.
      enabled: false

      ## Name of the backup file to restore (required when enabled=true).
      ## Find available backups with: aws s3 ls s3://<bucket>/manager-backups/
      backupFile: ""
```

The backup CronJob reuses the same AWS credentials secret and S3 bucket as the indexer snapshots:

```yaml
indexer:
  s3Snapshot:
    credentialsSecret: "aws-s3-credentials"   # ← also used by manager backup
    s3Settings:
      bucket: "your-wazuh-bucket"             # ← also used by manager backup
      region: "eu-central-1"
```

---

## Automated Backup CronJob

### Timing

The backup runs at **1am UTC daily**, one hour before the indexer snapshot at 2am. This ensures
the manager configuration is captured before the night's OpenSearch snapshot, giving a consistent
point-in-time pair.

| Job | Time | What it backs up |
|-----|------|-----------------|
| Manager backup CronJob | 1am UTC | `/var/ossec/etc/` + secrets + Helm values |
| Indexer snapshot CronJob | 2am UTC | OpenSearch indices |
| Indexer snapshot cleanup | 3am UTC | Removes old indexer snapshots |

`concurrencyPolicy: Forbid` prevents overlapping runs if a backup takes longer than expected.

### Verifying the CronJob

```bash
# Check CronJob is registered
kubectl get cronjob -n wazuh | grep manager-backup

# Check logs of the last completed run
kubectl logs -n wazuh job/<release>-manager-backup-<suffix>
# Should end with: INFO  === Manager Configuration Backup Completed ===

# Manually trigger a run
kubectl create job --from=cronjob/<release>-manager-backup manual-backup -n wazuh
kubectl logs -n wazuh job/manual-backup -f

# List all objects uploaded
aws s3 ls s3://<bucket>/manager-backups/
aws s3 ls s3://<bucket>/manager-backups/secrets/
```

---

## On-Demand Restore Job

### Timing and Hook Mechanism

The restore Job is a Helm `post-install,post-upgrade` hook, meaning it fires **after all regular
Kubernetes resources have been deployed** (StatefulSets, Services, etc.). This ensures the
manager pod is running before the restore attempts to exec into it.

| Hook phase | Weight | Resource |
|------------|--------|---------|
| `post-install,post-upgrade` | — | All regular resources (StatefulSets, etc.) |
| `post-install,post-upgrade` | 10 | Restore Job |

The Job uses `helm.sh/hook-delete-policy: before-hook-creation`, so the previous Job is
automatically removed each time `helm upgrade` is run. A restore can be re-triggered simply by
running `helm upgrade` again with the same flags.

`backoffLimit: 0` and `restartPolicy: Never` mean the Job does not retry on failure — the
operator inspects the logs and re-triggers after fixing the underlying issue.

### Handling Read-Only Paths

The Wazuh Manager StatefulSet mounts one file inside `shared/` from a ConfigMap (read-only):

| Path | Source |
|------|--------|
| `/var/ossec/etc/shared/dlp/agent.conf` | ConfigMap `{release}-wazuh-conf`, key `dlp.xml` |

Attempting to overwrite a ConfigMap-mounted file during tar extraction causes a
`Read-only file system` error. The restore script handles this by running
`find /var/ossec/etc/shared -not -writable` inside the manager pod **before** extraction and
building `--exclude` flags for only the paths that are actually read-only. Dashboard-configured
agent group configs in the same `shared/` directory live on the PVC (writable) and are always
restored.

### Triggering a Restore

```bash
# 1. Find the backup file you want to restore
aws s3 ls s3://<bucket>/manager-backups/
# Example output:
#   2026-03-09 23:17:30   45231 manager-config-20260309-231725.tar.gz

# 2. Trigger the restore via helm upgrade
helm upgrade -i wazuh ./ -n wazuh \
  --values values-local.yaml \
  --values values-s3.yaml \
  --set master.backup.restore.enabled=true \
  --set master.backup.restore.backupFile=manager-config-20260309-231725.tar.gz

# 3. Watch the restore job logs
kubectl logs -n wazuh job/<release>-manager-restore -f
# Expect:
#   INFO  Backup object found: s3://...
#   INFO  Manager pod is Running.
#   WARN  Excluding read-only path (ConfigMap-managed): /var/ossec/etc/shared/dlp/agent.conf
#   INFO  Restore stream completed.
#   INFO  OK: /var/ossec/etc/ossec.conf
#   INFO  OK: /var/ossec/etc/client.keys
#   INFO  === Manager Configuration Restore Completed ===
#   INFO  IMPORTANT: Restart the manager pod to reload the restored configuration:
#   INFO    kubectl rollout restart statefulset/<release>-manager-master -n wazuh

# 4. Reload the manager with the restored config
kubectl rollout restart statefulset/<release>-manager-master -n wazuh
kubectl rollout status statefulset/<release>-manager-master -n wazuh

# 5. Disable the restore for future upgrades
helm upgrade -i wazuh ./ -n wazuh \
  --values values-local.yaml \
  --values values-s3.yaml
# (master.backup.restore.enabled defaults to false)
```

### Verifying a Successful Restore

```bash
# Confirm key files exist
kubectl exec -n wazuh <release>-manager-master-0 -- \
  ls -la /var/ossec/etc/ossec.conf /var/ossec/etc/client.keys

# Inspect restored rules
kubectl exec -n wazuh <release>-manager-master-0 -- \
  ls /var/ossec/etc/rules/

# Check shared agent group configs (dashboard-created groups should be present)
kubectl exec -n wazuh <release>-manager-master-0 -- \
  ls /var/ossec/etc/shared/

# Verify manager is healthy after restart
kubectl get pod -n wazuh <release>-manager-master-0
# STATUS should be Running, RESTARTS should be low
```

---

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---------|-------------|------------|
| Backup CronJob fails with `manager pod not found` | Manager StatefulSet isn't running | Check `kubectl get pods -n wazuh`; ensure `master.enabled: true` |
| Backup fails with `pod is not Running (phase: Pending)` | Manager pod stuck in init | Check init container logs: `kubectl logs <pod> -c <init-container>` |
| `helm get values` uploads empty file | `helm` binary missing from image | Confirm image tag has the multi-stage build; check `command -v helm` log line |
| Secrets backup shows `Secret not found, skipping` | Secret names use different prefix in this cluster | Set `master.backup.criticalSecrets` to the correct space-separated secret names |
| Restore fails with `Backup object not found` | Wrong `backupFile` value or wrong bucket/prefix | Run `aws s3 ls s3://<bucket>/<s3BasePath>/` to find valid filenames |
| Restore fails with `pod is not Running` | Restore hook ran before manager pod was ready | The hook fires after StatefulSet apply but the pod may still be initialising; re-trigger with `helm upgrade` once the pod is `Running` |
| `tar: Cannot open: Read-only file system` | A ConfigMap-mounted path wasn't excluded | The dynamic detection should handle this; run `kubectl exec ... -- find /var/ossec/etc/shared -not -writable` to inspect |
| `tar: Exiting with failure status` but most files restored | File type conflict (`--overwrite` insufficient) | Check which file caused the failure in the tar stderr output |
| Restore job not re-triggered on second `helm upgrade` | Old Job not cleaned up | Confirm `helm.sh/hook-delete-policy: before-hook-creation` is set; check `kubectl get job -n wazuh` |
| Manager doesn't pick up restored config | Pod not restarted after restore | Run `kubectl rollout restart statefulset/<release>-manager-master -n wazuh` |
| `helm upgrade` fails with `StorageClass is invalid` | Existing StorageClass has immutable fields | `kubectl delete storageclass <release>` then re-upgrade; or set `storageClasses.<name>.enabled: false` in your local values |
| Individual secret backup missing `{fullname}-api-cred` | Release fullname differs from default | Override `CRITICAL_SECRETS` or `master.backup.criticalSecrets` with the correct names |

---

## Summary of All Changed Files

| File | Type | Description |
|------|------|-------------|
| `utils/packages/wazuh-manager-backup/Dockerfile` | Created | Multi-stage image: Alpine builder for `kubectl` + `helm`, `amazon/aws-cli` runtime |
| `.github/workflows/build-wazuh-manager-backup.yml` | Created | CI pipeline to build and push image to GHCR on Dockerfile changes |
| `charts/wazuh/files/scripts/manager-backup.sh` | Created | Backup script: tar → S3, secrets, Helm values, manifest, retention cleanup |
| `charts/wazuh/files/scripts/manager-restore.sh` | Created | Restore script: dynamic read-only detection, S3 → tar → pod extraction, verification |
| `charts/wazuh/templates/manager/serviceaccount.manager-backup.yaml` | Created | ServiceAccount for backup and restore containers |
| `charts/wazuh/templates/manager/role.manager-backup.yaml` | Created | Role: `pods get/list`, `pods/exec create`, `secrets get/list` |
| `charts/wazuh/templates/manager/rolebinding.manager-backup.yaml` | Created | Binds Role to ServiceAccount |
| `charts/wazuh/templates/manager/configmap.manager-backup.yaml` | Created | ConfigMap embedding `manager-backup.sh` |
| `charts/wazuh/templates/manager/configmap.manager-restore.yaml` | Created | ConfigMap embedding `manager-restore.sh` |
| `charts/wazuh/templates/manager/cronjob.manager-backup.yaml` | Created | Daily CronJob at 1am UTC, `concurrencyPolicy: Forbid` |
| `charts/wazuh/templates/manager/job.manager-restore.yaml` | Created | Helm hook Job: `post-install,post-upgrade`, weight 10, `backoffLimit: 0`, opt-in |
| `charts/wazuh/values.yaml` | Modified | Added `master.backup` configuration block including `restore` sub-block |
