# Restic Backup Restore Guide

This guide provides comprehensive instructions for restoring Wazuh data from Restic incremental backups.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Understanding Snapshots](#understanding-snapshots)
- [Restore Methods](#restore-methods)
  - [Method 1: Temporary Pod Restore (Recommended)](#method-1-temporary-pod-restore-recommended)
  - [Method 2: Interactive Restore Script](#method-2-interactive-restore-script)
  - [Method 3: Direct Pod Restore (Advanced)](#method-3-direct-pod-restore-advanced)
  - [Method 4: Tekton Pipeline Restore (Production)](#method-4-tekton-pipeline-restore-production)
- [Common Restore Scenarios](#common-restore-scenarios)
- [Verification Steps](#verification-steps)
- [Quick Reference](#quick-reference)
- [Troubleshooting](#troubleshooting)

---

## Overview

Restic stores backups as **snapshots** - point-in-time captures of your Wazuh data. Each snapshot is:

- **Deduplicated**: Only unique data blocks are stored
- **Encrypted**: AES-256 encryption using your Restic password
- **Tagged**: Labeled with component name, pod, and timestamp
- **Immutable**: Once created, snapshots cannot be modified

### What Gets Backed Up

Each Wazuh component backup includes:

| Component | Backed Up Directories |
|-----------|----------------------|
| Master | `/var/ossec/etc/`, `/var/ossec/logs/`, `/var/ossec/queue/`, `/var/ossec/stats/` |
| Worker | `/var/ossec/etc/`, `/var/ossec/logs/`, `/var/ossec/queue/` |
| Indexer | `/var/lib/wazuh-indexer/` |
| Dashboard | `/usr/share/wazuh-dashboard/data/` |

---

## Prerequisites

Before performing a restore, ensure you have:

1. **Restic Password**: The encryption password stored in the Kubernetes secret
2. **AWS Credentials**: Access to the S3 bucket containing backups
3. **kubectl Access**: Configured access to your Kubernetes cluster
4. **Sufficient Permissions**: RBAC permissions to create pods and exec into them

### Retrieve Required Credentials

```bash
# Get the Restic password
RESTIC_PASSWORD=$(kubectl get secret restic-password -n wazuh \
  -o jsonpath='{.data.password}' | base64 -d)

# Get AWS credentials
AWS_ACCESS_KEY_ID=$(kubectl get secret aws-creds -n wazuh \
  -o jsonpath='{.data.aws_access_key_id}' | base64 -d)
AWS_SECRET_ACCESS_KEY=$(kubectl get secret aws-creds -n wazuh \
  -o jsonpath='{.data.aws_secret_access_key}' | base64 -d)
AWS_REGION=$(kubectl get secret aws-creds -n wazuh \
  -o jsonpath='{.data.region}' | base64 -d)

# Get the repository URL from values or ConfigMap
RESTIC_REPOSITORY="s3:s3.amazonaws.com/YOUR-BUCKET/restic-repo"
```

---

## Understanding Snapshots

### List All Snapshots

```bash
# Create a temporary pod to interact with Restic
kubectl run restic-cli --rm -it \
  --image=restic/restic:0.17.3 \
  --env="RESTIC_REPOSITORY=$RESTIC_REPOSITORY" \
  --env="RESTIC_PASSWORD=$RESTIC_PASSWORD" \
  --env="AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" \
  --env="AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" \
  -n wazuh \
  -- restic snapshots
```

### Example Output

```
ID        Time                 Host                           Tags
─────────────────────────────────────────────────────────────────────────────
abc12345  2025-01-28 14:30:00  wazuh-manager-master-0         component=master
def67890  2025-01-28 14:35:00  wazuh-manager-worker-0         component=worker
ghi11223  2025-01-29 02:00:00  wazuh-manager-master-0         component=master
jkl44556  2025-01-29 02:05:00  wazuh-manager-worker-0         component=worker
```

### Filter Snapshots by Component

```bash
# List only master snapshots
restic snapshots --tag component=master

# List only worker snapshots
restic snapshots --tag component=worker

# List snapshots from a specific host
restic snapshots --host wazuh-manager-master-0
```

### View Snapshot Contents

```bash
# List files in a specific snapshot
restic ls abc12345

# List files in the latest snapshot for a component
restic ls latest --tag component=master
```

---

## Restore Methods

### Method 1: Temporary Pod Restore (Recommended)

This is the safest method - restore to a temporary location, verify the data, then copy to the target pod.

#### Step 1: Create Restore Pod

```bash
kubectl run restic-restore --rm -it \
  --image=restic/restic:0.17.3 \
  --env="RESTIC_REPOSITORY=$RESTIC_REPOSITORY" \
  --env="RESTIC_PASSWORD=$RESTIC_PASSWORD" \
  --env="AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" \
  --env="AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" \
  -n wazuh \
  -- /bin/sh
```

#### Step 2: Restore Data Inside the Pod

```bash
# Restore latest master backup
restic restore latest --tag component=master --target /tmp/restore

# Or restore a specific snapshot
restic restore abc12345 --target /tmp/restore

# Verify the restored data
ls -la /tmp/restore/var/ossec/
```

#### Step 3: Copy to Target Pod

From another terminal:

```bash
# Stop Wazuh services on target pod first
kubectl exec -n wazuh wazuh-manager-master-0 -- \
  /var/ossec/bin/wazuh-control stop

# Copy restored data (from the restore pod or local machine)
kubectl cp wazuh/restic-restore:/tmp/restore/var/ossec/etc \
  wazuh/wazuh-manager-master-0:/var/ossec/etc

kubectl cp wazuh/restic-restore:/tmp/restore/var/ossec/logs \
  wazuh/wazuh-manager-master-0:/var/ossec/logs

# Restart Wazuh services
kubectl exec -n wazuh wazuh-manager-master-0 -- \
  /var/ossec/bin/wazuh-control start
```

---

### Method 2: Interactive Restore Script

The Helm chart includes a restore script that can be used interactively.

#### Step 1: Create a Restore Job Pod

```bash
kubectl run restic-restore-job --rm -it \
  --image=restic/restic:0.17.3 \
  --env="RESTIC_REPOSITORY=$RESTIC_REPOSITORY" \
  --env="RESTIC_PASSWORD=$RESTIC_PASSWORD" \
  --env="AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" \
  --env="AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" \
  --env="COMPONENT=master" \
  --env="RESTORE_TARGET=/tmp/restore" \
  -n wazuh \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "restic-restore-job",
      "image": "restic/restic:0.17.3",
      "stdin": true,
      "tty": true,
      "volumeMounts": [{
        "name": "scripts",
        "mountPath": "/scripts"
      }]
    }],
    "volumes": [{
      "name": "scripts",
      "configMap": {
        "name": "wazuh-backup-scripts",
        "defaultMode": 493
      }
    }]
  }
}' \
  -- /bin/sh
```

#### Step 2: Run the Restore Script

```bash
# Inside the pod
chmod +x /scripts/restic-restore.sh
/scripts/restic-restore.sh
```

The script will:
1. List available snapshots for the component
2. Prompt for snapshot selection (or use latest)
3. Restore to the target directory
4. Verify the restore integrity

---

### Method 3: Direct Pod Restore (Advanced)

> **Warning**: This method modifies the running pod directly. Use with caution and only when necessary.

#### Step 1: Stop Wazuh Services

```bash
kubectl exec -n wazuh wazuh-manager-master-0 -- \
  /var/ossec/bin/wazuh-control stop
```

#### Step 2: Install Restic in Target Pod

```bash
kubectl exec -n wazuh wazuh-manager-master-0 -- /bin/sh -c '
  # For Alpine-based images
  apk add --no-cache restic

  # Or download binary directly
  wget https://github.com/restic/restic/releases/download/v0.17.3/restic_0.17.3_linux_amd64.bz2
  bunzip2 restic_0.17.3_linux_amd64.bz2
  chmod +x restic_0.17.3_linux_amd64
  mv restic_0.17.3_linux_amd64 /usr/local/bin/restic
'
```

#### Step 3: Restore Directly

```bash
kubectl exec -n wazuh wazuh-manager-master-0 -- /bin/sh -c '
  export RESTIC_REPOSITORY="s3:s3.amazonaws.com/YOUR-BUCKET/restic-repo"
  export RESTIC_PASSWORD="YOUR-PASSWORD"
  export AWS_ACCESS_KEY_ID="YOUR-KEY"
  export AWS_SECRET_ACCESS_KEY="YOUR-SECRET"

  # Backup current data first
  cp -r /var/ossec/etc /var/ossec/etc.bak

  # Restore from latest snapshot
  restic restore latest --tag component=master --target /
'
```

#### Step 4: Restart Services

```bash
kubectl exec -n wazuh wazuh-manager-master-0 -- \
  /var/ossec/bin/wazuh-control start
```

---

### Method 4: Tekton Pipeline Restore (Production)

This is the recommended method for **production environments**. It provides automated, auditable, and repeatable restores using Tekton pipelines with the staging PVC.

#### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        TEKTON RESTORE PIPELINE FLOW                          │
└─────────────────────────────────────────────────────────────────────────────┘

     Trigger (Manual PipelineRun or EventListener)
              │
              ▼
┌─────────────────────────────┐
│  1. Restic Restore Task     │  ◄── Mounts staging PVC
│     - restic-restore.sh     │      Restores to /backup/restore/
│     - Downloads from S3     │
└─────────────────────────────┘
              │
              ▼
┌─────────────────────────────┐
│  2. Wazuh Control Task      │  ◄── Stop services gracefully
│     - wazuh-control stop    │      Before modifying files
└─────────────────────────────┘
              │
              ▼
┌─────────────────────────────┐
│  3. Data Copy Task          │  ◄── Mounts BOTH PVCs:
│     - rsync/tar from staging│      - Staging PVC (source)
│       to target pod         │      - Target via kubectl exec
└─────────────────────────────┘
              │
              ▼
┌─────────────────────────────┐
│  4. Wazuh Control Task      │  ◄── Start services
│     - wazuh-control start   │      After restore complete
└─────────────────────────────┘
              │
              ▼
┌─────────────────────────────┐
│  5. Cleanup Task            │  ◄── Remove staging data
│     - Clear /backup/restore │      Free up PVC space
└─────────────────────────────┘
```

#### Benefits of Tekton Pipeline Restore

| Feature | Manual Methods | Tekton Pipeline |
|---------|---------------|-----------------|
| **Repeatability** | Prone to human error | Consistent every time |
| **Audit Trail** | Manual logging | Full PipelineRun history |
| **Automation** | Requires operator | Can be triggered automatically |
| **Error Handling** | Manual recovery | Built-in `finally` tasks |
| **Rollback** | Complex | Emergency start on failure |

#### Step 1: Create the Restore Task

Add this task to your `values.yaml` under `tekton.tasks`:

```yaml
- name: '{{ include "common.names.fullname" $ }}-restic-restore'
  enabled: '{{ .Values.features.resticBackup.enabled }}'
  additionalLabels: {}
  additionalAnnotations:
    tekton.dev/displayName: "Restic Restore from Backup"
  spec:
    description: |
      Restores Wazuh component data from Restic backup to staging PVC.
    params:
      - name: componentName
        type: string
        description: Component to restore (master-0, worker-0, etc.)
      - name: snapshotId
        type: string
        default: "latest"
        description: Snapshot ID or 'latest'
      - name: targetPath
        type: string
        default: "/backup/restore"
    steps:
      - name: restic-restore
        image: '{{ include "common.images.image" ( dict "imageRoot" .Values.tekton.taskImages.restic "global" .Values.global ) }}'
        script: |
          apk add --no-cache bash jq grep
          cp /scripts/restic-restore.sh /tmp/restic-restore.sh
          chmod +x /tmp/restic-restore.sh
          bash /tmp/restic-restore.sh "$(params.componentName)" "$(params.targetPath)" "$(params.snapshotId)"
        env:
          - name: RESTIC_REPOSITORY
            value: '{{ tpl .Values.backup.restic.repository $ }}'
          - name: RESTIC_PASSWORD
            valueFrom:
              secretKeyRef:
                name: '{{ .Values.backup.restic.passwordSecretName }}'
                key: '{{ .Values.backup.restic.passwordSecretKey }}'
          - name: AWS_ACCESS_KEY_ID
            valueFrom:
              secretKeyRef:
                name: '{{ .Values.aws.secretName }}'
                key: aws_access_key_id
          - name: AWS_SECRET_ACCESS_KEY
            valueFrom:
              secretKeyRef:
                name: '{{ .Values.aws.secretName }}'
                key: aws_secret_access_key
        volumeMounts:
          - name: staging-volume
            mountPath: /backup
          - name: scripts-volume
            mountPath: /scripts
    volumes:
      - name: staging-volume
        persistentVolumeClaim:
          claimName: '{{ include "wazuh-backup.stagingPvcName" $ }}'
      - name: scripts-volume
        configMap:
          name: '{{ include "common.names.fullname" $ }}-scripts'
          defaultMode: 0755
```

#### Step 2: Create the Copy-to-Pod Task

```yaml
- name: '{{ include "common.names.fullname" $ }}-restore-copy'
  enabled: '{{ .Values.features.resticBackup.enabled }}'
  additionalLabels: {}
  additionalAnnotations:
    tekton.dev/displayName: "Copy Restored Data to Pod"
  spec:
    description: |
      Copies restored data from staging PVC to target Wazuh pod.
    params:
      - name: podName
        type: string
      - name: podNamespace
        type: string
        default: "wazuh"
      - name: sourcePath
        type: string
        default: "/backup/restore"
      - name: targetPaths
        type: string
        description: "Comma-separated list of paths to restore (e.g., /var/ossec/etc,/var/ossec/logs)"
        default: "/var/ossec/etc,/var/ossec/logs,/var/ossec/queue"
    steps:
      - name: copy-data
        image: '{{ include "common.images.image" ( dict "imageRoot" .Values.tekton.taskImages.scaleStatefulset "global" .Values.global ) }}'
        script: |
          #!/bin/bash
          set -e

          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "📂 Copying restored data to pod"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          echo "📦 Source:      $(params.sourcePath)"
          echo "🎯 Target pod:  $(params.podName)"
          echo "📁 Paths:       $(params.targetPaths)"
          echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

          # Find the actual restore directory (handles nested paths)
          RESTORE_ROOT=$(find $(params.sourcePath) -name "var" -type d | head -1 | sed 's|/var$||')

          if [[ -z "$RESTORE_ROOT" ]]; then
            echo "❌ ERROR: Could not find restored data in $(params.sourcePath)"
            exit 1
          fi

          echo "📁 Found restore root: $RESTORE_ROOT"

          # Copy each target path using tar pipe
          IFS=',' read -ra PATHS <<< "$(params.targetPaths)"
          for path in "${PATHS[@]}"; do
            path=$(echo "$path" | xargs)  # trim whitespace
            if [[ -d "$RESTORE_ROOT$path" ]]; then
              echo "📤 Copying $path..."
              tar cf - -C "$RESTORE_ROOT" ".${path}" | \
                kubectl exec -i -n $(params.podNamespace) $(params.podName) -- tar xf - -C /
              echo "✅ Copied $path"
            else
              echo "⚠️  Skipping $path (not found in backup)"
            fi
          done

          echo ""
          echo "✅ Data copy completed!"
        volumeMounts:
          - name: staging-volume
            mountPath: /backup
    volumes:
      - name: staging-volume
        persistentVolumeClaim:
          claimName: '{{ include "wazuh-backup.stagingPvcName" $ }}'
```

#### Step 3: Create the Restore Pipeline

```yaml
- name: '{{ include "common.names.fullname" $ }}-component-restore'
  enabled: '{{ .Values.features.resticBackup.enabled }}'
  additionalLabels: {}
  additionalAnnotations: {}
  spec:
    description: |
      Restore a Wazuh component from Restic backup.
      Restores data → Stops services → Copies to target → Starts services
    params:
      - name: componentName
        type: string
        description: "Component name (e.g., master-0, worker-0)"
      - name: snapshotId
        type: string
        default: "latest"
        description: "Snapshot ID to restore or 'latest'"
      - name: podName
        type: string
        description: "Target pod name"
      - name: podNamespace
        type: string
        default: "wazuh"
      - name: containerName
        type: string
        default: "wazuh-manager"
      - name: wazuhControlPath
        type: string
        default: "/var/ossec/bin/wazuh-control"
    finally:
      - name: emergency-start
        when:
          - input: "$(tasks.status)"
            operator: notin
            values: ["Succeeded"]
        taskRef:
          name: '{{ include "common.names.fullname" $ }}-wazuh-control'
        params:
          - name: podName
            value: "$(params.podName)"
          - name: namespace
            value: "$(params.podNamespace)"
          - name: containerName
            value: "$(params.containerName)"
          - name: wazuhControlPath
            value: "$(params.wazuhControlPath)"
          - name: action
            value: "start"
          - name: mode
            value: "emergency"
          - name: componentName
            value: "$(params.componentName)"
          - name: pipelineStatus
            value: "$(tasks.status)"
      - name: final-cleanup
        taskRef:
          name: '{{ include "common.names.fullname" $ }}-cleanup-pvc'
        params:
          - name: directoryPath
            value: "restore"
    tasks:
      - name: restore-to-staging
        taskRef:
          name: '{{ include "common.names.fullname" $ }}-restic-restore'
        params:
          - name: componentName
            value: "$(params.componentName)"
          - name: snapshotId
            value: "$(params.snapshotId)"
          - name: targetPath
            value: "/backup/restore"

      - name: stop-wazuh
        taskRef:
          name: '{{ include "common.names.fullname" $ }}-wazuh-control'
        params:
          - name: podName
            value: "$(params.podName)"
          - name: namespace
            value: "$(params.podNamespace)"
          - name: containerName
            value: "$(params.containerName)"
          - name: wazuhControlPath
            value: "$(params.wazuhControlPath)"
          - name: action
            value: "stop"
          - name: mode
            value: "normal"
          - name: componentName
            value: "$(params.componentName)"
          - name: pipelineStatus
            value: ""
        runAfter:
          - restore-to-staging

      - name: copy-to-target
        taskRef:
          name: '{{ include "common.names.fullname" $ }}-restore-copy'
        params:
          - name: podName
            value: "$(params.podName)"
          - name: podNamespace
            value: "$(params.podNamespace)"
          - name: sourcePath
            value: "/backup/restore"
        runAfter:
          - stop-wazuh

      - name: start-wazuh
        taskRef:
          name: '{{ include "common.names.fullname" $ }}-wazuh-control'
        params:
          - name: podName
            value: "$(params.podName)"
          - name: namespace
            value: "$(params.podNamespace)"
          - name: containerName
            value: "$(params.containerName)"
          - name: wazuhControlPath
            value: "$(params.wazuhControlPath)"
          - name: action
            value: "start"
          - name: mode
            value: "normal"
          - name: componentName
            value: "$(params.componentName)"
          - name: pipelineStatus
            value: ""
        runAfter:
          - copy-to-target
```

#### Step 4: Trigger the Restore Pipeline

After deploying the updated Helm chart, trigger a restore:

```bash
# Create a PipelineRun to restore master-0 from latest snapshot
cat <<EOF | kubectl apply -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: restore-master-
  namespace: wazuh
spec:
  pipelineRef:
    name: wazuh-backup-component-restore
  params:
    - name: componentName
      value: "master-0"
    - name: snapshotId
      value: "latest"
    - name: podName
      value: "wazuh-wazuh-helm-manager-master-0"
    - name: podNamespace
      value: "wazuh"
EOF
```

Or restore a specific snapshot:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: restore-master-
  namespace: wazuh
spec:
  pipelineRef:
    name: wazuh-backup-component-restore
  params:
    - name: componentName
      value: "master-0"
    - name: snapshotId
      value: "9909904b"  # Specific snapshot ID
    - name: podName
      value: "wazuh-wazuh-helm-manager-master-0"
    - name: podNamespace
      value: "wazuh"
EOF
```

#### Step 5: Monitor the Restore

```bash
# Watch PipelineRun status
kubectl get pipelinerun -n wazuh -w

# View detailed logs
tkn pipelinerun logs -n wazuh -f <pipelinerun-name>

# Or using kubectl
kubectl logs -n wazuh -l tekton.dev/pipelineRun=<pipelinerun-name> --all-containers -f
```

#### Error Handling

The pipeline includes automatic error handling:

- **`finally` block**: If any task fails, the `emergency-start` task ensures Wazuh services are restarted
- **Cleanup**: The `final-cleanup` task always runs to clear the staging PVC
- **Audit trail**: All PipelineRuns are retained for debugging

```bash
# Check failed PipelineRuns
kubectl get pipelinerun -n wazuh --field-selector=status.conditions[0].status=False

# View failure reason
kubectl describe pipelinerun <pipelinerun-name> -n wazuh
```

---

## Common Restore Scenarios

### Scenario 1: Restore Specific Files Only

Sometimes you only need to restore specific files (e.g., configuration):

```bash
# Inside a Restic pod
restic restore latest --tag component=master \
  --include "/var/ossec/etc/ossec.conf" \
  --include "/var/ossec/etc/rules/*" \
  --target /tmp/restore
```

### Scenario 2: Point-in-Time Recovery

Restore from a specific date/time:

```bash
# List snapshots with timestamps
restic snapshots --tag component=master

# Find the snapshot ID closest to your target time
# Then restore that specific snapshot
restic restore abc12345 --target /tmp/restore
```

### Scenario 3: Disaster Recovery (Full Cluster Restore)

For complete cluster recovery:

```bash
# 1. Deploy fresh Wazuh cluster
helm install wazuh charts/wazuh -n wazuh

# 2. Wait for pods to be ready
kubectl wait --for=condition=ready pod -l app=wazuh-manager -n wazuh --timeout=300s

# 3. Stop all Wazuh services
for pod in $(kubectl get pods -n wazuh -l app=wazuh-manager -o name); do
  kubectl exec -n wazuh $pod -- /var/ossec/bin/wazuh-control stop
done

# 4. Restore master first
kubectl run restic-restore --rm -it \
  --image=restic/restic:0.17.3 \
  --env="RESTIC_REPOSITORY=$RESTIC_REPOSITORY" \
  --env="RESTIC_PASSWORD=$RESTIC_PASSWORD" \
  --env="AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" \
  --env="AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" \
  -n wazuh \
  -- restic restore latest --tag component=master --target /tmp/master-restore

# 5. Copy data to master pod
kubectl cp /tmp/master-restore/var/ossec/ wazuh/wazuh-manager-master-0:/var/ossec/

# 6. Repeat for workers
# ... (similar process for each worker)

# 7. Restart all services
for pod in $(kubectl get pods -n wazuh -l app=wazuh-manager -o name); do
  kubectl exec -n wazuh $pod -- /var/ossec/bin/wazuh-control start
done
```

### Scenario 4: Restore to Different Namespace/Cluster

```bash
# 1. Create restore pod in target namespace
kubectl run restic-restore -n target-namespace \
  --image=restic/restic:0.17.3 \
  ... (same env vars)

# 2. Restore data
restic restore latest --tag component=master --target /tmp/restore

# 3. The data is now available to copy to any destination
```

---

## Verification Steps

After any restore operation, verify the data integrity:

### 1. Check File Permissions

```bash
kubectl exec -n wazuh wazuh-manager-master-0 -- \
  ls -la /var/ossec/etc/
```

Expected: Files owned by `wazuh:wazuh` (or `ossec:ossec`)

### 2. Verify Configuration Syntax

```bash
kubectl exec -n wazuh wazuh-manager-master-0 -- \
  /var/ossec/bin/wazuh-control config-test
```

Expected: "Configuration OK"

### 3. Check Service Status

```bash
kubectl exec -n wazuh wazuh-manager-master-0 -- \
  /var/ossec/bin/wazuh-control status
```

Expected: All services running

### 4. Verify Agent Connectivity

```bash
kubectl exec -n wazuh wazuh-manager-master-0 -- \
  /var/ossec/bin/agent_control -l
```

Expected: Agents listed and connected

### 5. Check Logs for Errors

```bash
kubectl exec -n wazuh wazuh-manager-master-0 -- \
  tail -50 /var/ossec/logs/ossec.log
```

Expected: No critical errors after restart

---

## Quick Reference

### Essential Commands

| Task | Command |
|------|---------|
| List all snapshots | `restic snapshots` |
| List snapshots for component | `restic snapshots --tag component=master` |
| View snapshot contents | `restic ls <snapshot-id>` |
| Restore latest | `restic restore latest --target /tmp/restore` |
| Restore specific snapshot | `restic restore <id> --target /tmp/restore` |
| Restore specific files | `restic restore latest --include "/path/*" --target /tmp/restore` |
| Check repository | `restic check` |
| Get repository stats | `restic stats` |

### Environment Variables Required

```bash
export RESTIC_REPOSITORY="s3:s3.amazonaws.com/bucket/restic-repo"
export RESTIC_PASSWORD="your-encryption-password"
export AWS_ACCESS_KEY_ID="your-aws-key"
export AWS_SECRET_ACCESS_KEY="your-aws-secret"
```

### One-Liner: Quick Restore Pod

```bash
kubectl run restic-cli --rm -it --image=restic/restic:0.17.3 \
  --env="RESTIC_REPOSITORY=s3:s3.amazonaws.com/YOUR-BUCKET/restic-repo" \
  --env="RESTIC_PASSWORD=$(kubectl get secret restic-password -n wazuh -o jsonpath='{.data.password}' | base64 -d)" \
  --env="AWS_ACCESS_KEY_ID=$(kubectl get secret aws-creds -n wazuh -o jsonpath='{.data.aws_access_key_id}' | base64 -d)" \
  --env="AWS_SECRET_ACCESS_KEY=$(kubectl get secret aws-creds -n wazuh -o jsonpath='{.data.aws_secret_access_key}' | base64 -d)" \
  -n wazuh -- /bin/sh
```

---

## Troubleshooting

### Error: "repository does not exist"

**Cause**: Wrong repository URL or repository not initialized

**Solution**:
```bash
# Verify repository URL
echo $RESTIC_REPOSITORY

# Check if you can connect to S3
aws s3 ls s3://your-bucket/restic-repo/
```

### Error: "wrong password or no key found"

**Cause**: Incorrect Restic password

**Solution**:
```bash
# Verify password secret exists and has correct value
kubectl get secret restic-password -n wazuh -o yaml

# Re-create secret if needed
kubectl delete secret restic-password -n wazuh
kubectl create secret generic restic-password \
  --from-literal=password="correct-password" -n wazuh
```

### Error: "permission denied" during copy

**Cause**: File ownership mismatch

**Solution**:
```bash
# Fix ownership after restore
kubectl exec -n wazuh wazuh-manager-master-0 -- \
  chown -R wazuh:wazuh /var/ossec/
```

### Error: "no snapshot found"

**Cause**: No snapshots with matching tags/filters

**Solution**:
```bash
# List ALL snapshots without filters
restic snapshots

# Check what tags exist
restic snapshots --json | jq '.[].tags'
```

### Restore is Very Slow

**Cause**: Large dataset or slow network

**Solutions**:
1. Use Restic cache:
   ```bash
   export RESTIC_CACHE_DIR=/tmp/restic-cache
   mkdir -p $RESTIC_CACHE_DIR
   ```

2. Restore only needed files:
   ```bash
   restic restore latest --include "/var/ossec/etc/*" --target /tmp/restore
   ```

### Wazuh Won't Start After Restore

**Cause**: Corrupted or incompatible configuration

**Solutions**:
1. Check configuration:
   ```bash
   kubectl exec -n wazuh wazuh-manager-master-0 -- \
     /var/ossec/bin/wazuh-control config-test
   ```

2. Restore only data, not config:
   ```bash
   restic restore latest \
     --exclude "/var/ossec/etc/ossec.conf" \
     --target /tmp/restore
   ```

3. Check logs:
   ```bash
   kubectl logs wazuh-manager-master-0 -n wazuh
   ```

---

## Best Practices

1. **Test Restores Regularly**: Schedule monthly restore drills to verify backup integrity
2. **Document Your Repository**: Keep the repository URL and password in a secure password manager
3. **Restore to Staging First**: When possible, restore to a staging environment before production
4. **Keep Multiple Snapshots**: Don't rely on just the latest snapshot - keep historical snapshots
5. **Verify After Restore**: Always run verification steps after any restore operation
6. **Backup Before Restore**: Before overwriting data, create a manual backup of current state

---

## Support

For issues or questions:
- Check Wazuh logs: `kubectl logs -n wazuh -l app=wazuh-manager`
- Review [Restic documentation](https://restic.readthedocs.io/)
- Check the [RESTIC-MIGRATION-GUIDE.md](./RESTIC-MIGRATION-GUIDE.md) for setup information
- Open an issue in the repository
