# Wazuh Backup Helm Chart

> **Fully Templatized, Array-Based Architecture** - A Kubernetes-native backup solution for Wazuh components using Tekton Pipelines and S3 storage.

[![Helm](https://img.shields.io/badge/Helm-v3-blue)](https://helm.sh)
[![Tekton](https://img.shields.io/badge/Tekton-Pipelines-orange)](https://tekton.dev)
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](LICENSE)

## 🎯 Overview

This Helm chart provides automated, event-driven backup capabilities for Wazuh security platform components running on Kubernetes. Built with a **modern array-based architecture**, the chart follows Bitnami common chart patterns and enables complete configuration through `values.yaml` without editing templates.

### ✨ Key Features

- 🎨 **Fully Templatized**: Everything configurable via `values.yaml` - no template editing required
- 🔄 **Array-Based Architecture**: Add/remove components by editing values only
- 🎛️ **Feature Flags**: Granular enable/disable control for all resources
- 🔀 **Hybrid Trigger System**: Automatic CronJobs + Manual HTTP triggers
- 🔐 **Multi-Component Support**: Manager Master, Indexer, Worker nodes
- 📦 **Advanced Backup Paths**: Include/exclude patterns for granular control
- ☁️ **S3 Integration**: Date-based, organized backup storage
- 🛡️ **Safety First**: Emergency scale-up on failures, dual-mode scripts
- 🐛 **Debug Support**: Built-in troubleshooting capabilities

---

## 🏗️ Architecture Highlights

### Modern Design Patterns

This chart implements industry-standard patterns:

1. **Array-Based Resources**: All resources defined as arrays in `values.yaml`, rendered using `{{ range }}`
2. **Generic Templates**: Single template files for each resource type (no duplication)
3. **Bitnami Conventions**: Uses `common.names.*`, `common.labels.*`, `common.images.*` helpers
4. **Template Value Rendering**: Supports Go template syntax in values for dynamic configuration
5. **Feature Toggles**: Enable/disable entire resource groups via `features.*` flags

### How It Works

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        WAZUH BACKUP SYSTEM                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  📅 AUTOMATIC (CronJobs)           🖱️  MANUAL (HTTP Triggers)               │
│  ┌─────────────────────┐            ┌─────────────────────────────────────┐ │
│  │ Component CronJobs  │──┐         │ HTTP POST Request                   │ │
│  │ (Dynamic per config)│  │         │ ↓                                   │ │
│  └─────────────────────┘  │         │ EventListener                       │ │
│                           │         │ ↓                                   │ │
│                           │         │ CEL Interceptor (validates)         │ │
│                           │         │ ↓                                   │ │
│                           ↓         │ TriggerBinding → TriggerTemplate    │ │
│                    ┌─────────────────────────────────────────────┐         │
│                    │         Tekton Pipeline (Per Component)      │         │
│                    │  clean → scale-down → rsync → scale-up ‖ s3 │         │
│                    │  FINALLY: emergency-scale-up (never fails)  │         │
│                    └─────────────────────────────────────────────┘         │
│                                                                             │
│  All resources dynamically generated from values.yaml arrays!              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Backup Process Flow

1. **Clean Staging** - Prepare staging PVC directory
2. **Scale Down** - Stop component for consistency (normal mode)
3. **Copy Data** - Rsync PVC → Staging PVC (supports include/exclude)
4. **Scale Up + Upload** - Restore service ‖ Create tarball & upload to S3 (parallel)
5. **Cleanup** - Remove staging files
6. **FINALLY** - Emergency scale-up (always runs, never fails - emergency mode)

---

## 📦 What's New in This Version

### Refactored Architecture

**Before:**
- Hardcoded component-specific templates
- Required editing templates to add components
- Map-based configuration (`components.master`, `components.indexer`)
- Duplicate template code for each component

**After:**
- ✅ Dynamic component generation via `{{ range .Values.backup.components }}`
- ✅ Add components by editing `values.yaml` only
- ✅ Array-based configuration (`components[0].name: master`)
- ✅ Single generic templates using Bitnami patterns
- ✅ Feature flags for all resource types
- ✅ Template value rendering for dynamic configurations

### Component-Driven Resources

These resources are **automatically generated** for each enabled component:
- TriggerTemplates
- TriggerBindings
- Triggers (with CEL validation)
- CronJobs
- EventListener trigger references

Simply add a component to the array, and all resources are created automatically!

---

## 🗂️ Project Structure

```
📦 wazuh-backup/
 ┣ 📜 Chart.yaml                        # Chart metadata (v0.1.2-rc.2)
 ┣ 📜 values.yaml                       # Configuration (931 lines, array-based)
 ┣ 📜 README.md                         # This file
 ┣ 📜 REFACTORING-SUMMARY.md            # Detailed refactoring documentation
 ┣ 📜 GRACEFUL-SHUTDOWN.md              # Graceful shutdown feature docs
 ┣ 📂 charts/
 ┃ ┗ 📦 common-2.31.4.tgz              # Bitnami common chart dependency
 ┣ 📂 scripts/
 ┃ ┣ 📜 cleanup-pvc-directory.sh       # Staging cleanup
 ┃ ┣ 📜 make-tar.sh                    # Tarball creation
 ┃ ┣ 📜 rsync-pvc-to-pvc.sh            # Dual-mode rsync (simple/advanced)
 ┃ ┣ 📜 s3-upload.sh                   # S3 upload with date-based paths
 ┃ ┣ 📜 scale-statefulset.sh           # Dual-mode scaling (normal/emergency)
 ┃ ┗ 📜 wazuh-control.sh               # Graceful shutdown support
 ┣ 📂 templates/
 ┃ ┣ 📂 cronjob/
 ┃ ┃ ┣ 📜 cronjobs.yaml                # Dynamic CronJobs ({{ range components }})
 ┃ ┃ ┗ 📜 cronjobs-graceful.yaml       # Graceful shutdown variant
 ┃ ┣ 📂 triggers/
 ┃ ┃ ┣ 📜 event-listener.yaml          # Dynamic EventListener
 ┃ ┃ ┣ 📜 triggerbindings.yaml         # Dynamic TriggerBindings
 ┃ ┃ ┣ 📜 triggers.yaml                # Dynamic Triggers with CEL
 ┃ ┃ ┗ 📜 triggertemplates.yaml        # Dynamic TriggerTemplates
 ┃ ┣ 📜 _helpers.tpl                   # Chart-specific helpers
 ┃ ┣ 📜 _annotations.tpl               # Common annotations helper
 ┃ ┣ 📜 _backup-paths.tpl              # Backup path conversion helpers
 ┃ ┣ 📜 _images.tpl                    # Image reference helper
 ┃ ┣ 📜 configmaps.yaml                # Generic ConfigMaps ({{ range }})
 ┃ ┣ 📜 pipelines.yaml                 # Generic Pipelines ({{ range }})
 ┃ ┣ 📜 pvcs.yaml                      # Generic PVCs ({{ range }})
 ┃ ┣ 📜 secrets.yaml                   # Generic Secrets ({{ range }})
 ┃ ┣ 📜 serviceaccounts.yaml           # Generic ServiceAccounts ({{ range }})
 ┃ ┗ 📜 tasks.yaml                     # Generic Tasks ({{ range }})
```

---

## ⚙️ Configuration

### Feature Flags

Control which resources are created:

```yaml
features:
  eventListener:
    enabled: true       # HTTP-triggered backups
  cronjobs:
    enabled: true       # Scheduled automatic backups
  triggers:
    enabled: true       # Tekton Trigger resources
  debug:
    enabled: true       # Debug pod for troubleshooting
  gracefulShutdown:
    enabled: false      # Graceful shutdown mode (experimental)
```

### Components Configuration

Components are defined as an **array**, making it easy to add/remove/modify:

```yaml
backup:
  schedule: "0 2 * * *"  # Default schedule for all components

  s3:
    bucketName: "your-backup-bucket"
    endpointUrl: ""      # Leave empty for AWS S3, or use custom endpoint
    region: "eu-central-1"

  components:
    # Component 1: Master
    - name: master
      enabled: true
      statefulsetName: "wazuh-wazuh-helm-manager-master"
      podName: "wazuh-wazuh-helm-manager-master-0"
      pvcName: "wazuh-wazuh-helm-manager-master-wazuh-wazuh-helm-manager-master-0"
      replicas: 1
      backupSubdir: "master-backup"
      schedule: "0 2 * * *"  # Override default schedule

      # Advanced Mode: Include/Exclude patterns
      backupPaths:
        include:
          - "wazuh/var/ossec/etc"              # Configs, rules, decoders
          - "wazuh/var/ossec/api/configuration" # API configuration
          - "wazuh/var/ossec/logs"             # Logs
          - "wazuh/var/ossec/queue"            # Event queues
          - "wazuh/var/ossec/var/multigroups"  # Agent groups
          - "wazuh/var/ossec/integrations"     # Integration scripts
        exclude:
          - "*.tmp"                            # Skip temp files
          - "*.log.gz"                         # Skip compressed logs
          - ".cache/"                          # Skip cache directories

    # Component 2: Indexer
    - name: indexer
      enabled: false   # Disabled by default - enable when ready
      statefulsetName: "wazuh-wazuh-helm-indexer"
      podName: "wazuh-wazuh-helm-indexer-0"
      pvcName: "wazuh-wazuh-helm-indexer-wazuh-wazuh-helm-indexer-0"
      replicas: 2
      backupSubdir: "indexer-backup"
      schedule: "0 3 * * *"

      backupPaths:
        include:
          - "nodes"      # Elasticsearch node data
          - "indices"    # All indices
          - "_state"     # Cluster state
        exclude:
          - "*.lock"
          - "write.lock"

    # Component 3: Worker
    - name: worker
      enabled: false   # Workers typically sync from master
      statefulsetName: "wazuh-wazuh-helm-manager-worker"
      podName: "wazuh-wazuh-helm-manager-worker-0"
      pvcName: "wazuh-wazuh-helm-manager-worker-wazuh-wazuh-helm-manager-worker-0"
      replicas: 2
      backupSubdir: "worker-backup"
      schedule: "0 4 * * *"

      backupPaths:
        include:
          - "wazuh/var/ossec/logs"
          - "wazuh/var/ossec/queue"
        exclude:
          - "*.tmp"
```

### Backup Path Modes

#### **Simple Mode** (Backward Compatible)

Back up a single path or entire PVC:

```yaml
components:
  - name: master
    sourcePvcPath: "./"  # Entire PVC
    # OR
    sourcePvcPath: "wazuh/var/ossec/"  # Specific directory
```

#### **Advanced Mode** (Recommended)

Granular control with include/exclude patterns:

```yaml
components:
  - name: master
    backupPaths:
      include:
        - "path/to/config"
        - "path/to/data"
      exclude:
        - "*.tmp"
        - "*.cache"
        - "temp/"
```

**Benefits:**
- ✅ Backup only what you need (smaller backups)
- ✅ Exclude temporary files and caches
- ✅ Faster backups and restores
- ✅ Lower S3 storage costs

---

## 🚀 Installation

### Prerequisites

1. **Kubernetes cluster** (v1.24+) with kubectl access
2. **Tekton Pipelines** (v0.40+) and **Tekton Triggers** (v0.20+)
3. **Existing Wazuh deployment** on Kubernetes
4. **S3 bucket** with write permissions
5. **AWS credentials** with S3 access

### Step 1: Install Tekton

```bash
# Install Tekton Pipelines
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

# Install Tekton Triggers
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml

# Verify installation
kubectl get pods -n tekton-pipelines
```

### Step 2: Configure values.yaml

```bash
# 1. Update AWS credentials
aws:
  region: eu-central-1
  accessKeyId: "YOUR_ACCESS_KEY"
  secretAccessKey: "YOUR_SECRET_KEY"
  sessionToken: ""  # Optional

# 2. Update S3 bucket
backup:
  s3:
    bucketName: "your-wazuh-backup-bucket"
    endpointUrl: ""  # Leave empty for AWS S3

# 3. Update component names to match your deployment
backup:
  components:
    - name: master
      statefulsetName: "wazuh-wazuh-helm-manager-master"  # ← Update this
      pvcName: "wazuh-wazuh-helm-manager-master-wazuh-wazuh-helm-manager-master-0"  # ← And this
      replicas: 1

# 4. Update storage class
pvc:
  staging:
    storageClass: "gp3"  # Or your cluster's storage class
```

### Step 3: Verify Wazuh Resources

```bash
# Check StatefulSet names
kubectl get statefulsets -n wazuh

# Check PVC names
kubectl get pvc -n wazuh

# Update values.yaml with the exact names shown above
```

### Step 4: Install the Chart

```bash
# Install with Helm
cd charts/wazuh-backup
helm dependency update
helm install wazuh-backup . --namespace wazuh --create-namespace

# Verify deployment
kubectl get all -n wazuh -l app.kubernetes.io/instance=wazuh-backup
```

### Step 5: Verify Installation

```bash
# Check CronJobs (only for enabled components)
kubectl get cronjobs -n wazuh

# Check EventListener
kubectl get eventlistener,service -n wazuh

# Check Pipeline and Tasks
kubectl get pipeline,tasks -n wazuh

# Check staging PVC
kubectl get pvc -n wazuh | grep staging
```

---

## 🧪 Testing & Usage

### Test Manual Backup

```bash
# 1. Port forward the EventListener
kubectl port-forward svc/wazuh-backup-listener-svc 8080:8080 -n wazuh

# 2. In another terminal, trigger a test backup
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{
    "component": "master",
    "triggeredBy": "test"
  }'

# 3. Watch the PipelineRun
kubectl get pipelineruns -n wazuh -w

# 4. Check logs
kubectl logs -n wazuh -l component=master -f
```

### Monitor Backup Status

```bash
# View recent backups
kubectl get pipelineruns -n wazuh \
  -o custom-columns=NAME:.metadata.name,COMPONENT:.metadata.labels.component,STATUS:.status.conditions[0].reason,AGE:.metadata.creationTimestamp

# Check specific component
kubectl get pipelineruns -n wazuh -l component=master

# View detailed logs
kubectl logs -n wazuh -l tekton.dev/pipelineRun=<pipelinerun-name>
```

### Verify S3 Upload

```bash
# List backups in S3
aws s3 ls s3://your-backup-bucket/ --recursive

# Expected structure:
# DD-MM-YY-wazuh-backup/master/master-backup-DD-MM-YY-HHMMSS.tar.gz
# DD-MM-YY-wazuh-backup/indexer/indexer-backup-DD-MM-YY-HHMMSS.tar.gz
```

### Automatic Backups

Automatic backups run based on the schedule in each component's configuration:

```bash
# Check CronJob schedules
kubectl get cronjobs -n wazuh -o wide

# Suspend automatic backups
kubectl patch cronjob wazuh-backup-master-cron -n wazuh -p '{"spec":{"suspend":true}}'

# Resume automatic backups
kubectl patch cronjob wazuh-backup-master-cron -n wazuh -p '{"spec":{"suspend":false}}'

# Trigger immediate backup from CronJob
kubectl create job --from=cronjob/wazuh-backup-master-cron manual-backup-$(date +%s) -n wazuh
```

---

## 🎨 Adding New Components

One of the key benefits of the array-based architecture is how easy it is to add new components.

### Example: Add a new "Dashboard" component

Simply add to the `components` array in `values.yaml`:

```yaml
backup:
  components:
    - name: master
      enabled: true
      # ... existing config

    - name: indexer
      enabled: true
      # ... existing config

    # NEW: Dashboard component
    - name: dashboard
      enabled: true
      statefulsetName: "wazuh-wazuh-helm-dashboard"
      podName: "wazuh-wazuh-helm-dashboard-0"
      pvcName: "wazuh-wazuh-helm-dashboard-pvc"
      replicas: 1
      backupSubdir: "dashboard-backup"
      schedule: "0 5 * * *"
      backupPaths:
        include:
          - "config"
          - "plugins"
        exclude:
          - "*.log"
```

**That's it!** Helm will automatically create:
- ✅ TriggerTemplate for dashboard
- ✅ TriggerBinding for dashboard
- ✅ Trigger with CEL validation for dashboard
- ✅ CronJob for scheduled dashboard backups
- ✅ EventListener trigger reference for dashboard
- ✅ All necessary RBAC permissions

**No template editing required!**

---

## 🔍 Troubleshooting

### Common Issues

#### PipelineRun Not Created

**Symptoms:** HTTP request succeeds but no PipelineRun appears

**Debug:**
```bash
# Check EventListener logs
kubectl logs -n wazuh -l eventlistener=wazuh-backup-listener

# Verify component name matches enabled components
kubectl get triggers -n wazuh

# Test invalid component (should be rejected by CEL)
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"component": "invalid-name"}'
```

**Fix:** Ensure component name in request matches an enabled component in `values.yaml`

#### Scale-Down Fails

**Symptoms:** Pipeline fails at scale-down task

**Debug:**
```bash
# Check RBAC permissions
kubectl auth can-i patch statefulsets --as=system:serviceaccount:wazuh:wazuh-backup-sa -n wazuh

# Verify StatefulSet exists and name is correct
kubectl get statefulset <name-from-values.yaml> -n wazuh

# Check scale task logs
kubectl logs -n wazuh -l tekton.dev/task=scale-statefulset
```

**Fix:**
1. Update StatefulSet names in `values.yaml` to match actual names
2. Verify ServiceAccount has scaling permissions
3. Check StatefulSet is not protected by PodDisruptionBudget

#### Rsync Fails

**Symptoms:** Pipeline fails during copy-data task

**Debug:**
```bash
# Verify source PVC exists
kubectl get pvc <pvc-name-from-values.yaml> -n wazuh

# Check staging PVC has space
kubectl exec -it <debug-pod> -n wazuh -- df -h /backup

# Verify source paths exist
kubectl exec -it <debug-pod> -n wazuh -- ls -la /source/
```

**Fix:**
1. Update PVC names in `values.yaml`
2. Increase staging PVC size if needed
3. Verify backup paths exist in source PVC

#### S3 Upload Fails

**Symptoms:** Pipeline fails during upload-s3 task

**Debug:**
```bash
# Check AWS credentials secret
kubectl get secret aws-creds -n wazuh -o jsonpath='{.data.accessKeyId}' | base64 -d

# Test S3 access
kubectl run aws-test --image=amazon/aws-cli:latest --rm -it --restart=Never \
  --env AWS_ACCESS_KEY_ID="$(kubectl get secret aws-creds -n wazuh -o jsonpath='{.data.accessKeyId}' | base64 -d)" \
  --env AWS_SECRET_ACCESS_KEY="$(kubectl get secret aws-creds -n wazuh -o jsonpath='{.data.secretAccessKey}' | base64 -d)" \
  --env AWS_DEFAULT_REGION="eu-central-1" \
  -- aws s3 ls s3://your-bucket/

# Check upload task logs
kubectl logs -n wazuh -l tekton.dev/task=s3-upload
```

**Fix:**
1. Verify AWS credentials are correct and not expired
2. Check S3 bucket exists and IAM policy allows PutObject
3. Verify network connectivity to S3 endpoint

### Debug Pod

Enable the debug pod for PVC inspection:

```yaml
features:
  debug:
    enabled: true
```

```bash
# Access debug pod
kubectl exec -it deployment/wazuh-backup-debug -n wazuh -- /bin/sh

# Inside debug pod:
ls -la /source/        # Source PVC (read-only)
ls -la /backup/        # Staging PVC (read-write)
ls -la /scripts/       # All backup scripts

# Test scripts manually
cd /tmp
cp /scripts/* .
chmod +x *.sh
./rsync-pvc-to-pvc.sh  # etc.
```

---

## 🔐 Security

### RBAC Permissions

The chart creates three RBAC layers:

1. **ServiceAccount Role**: StatefulSet scaling, PVC access, secrets
2. **EventListener Role**: Tekton resources, deployments, services
3. **ClusterRole**: Cluster-scoped trigger resources (optional)

All permissions use `resourceNames` for least privilege where possible.

### AWS IAM Policy

Minimum required S3 permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:PutObjectAcl",
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::your-backup-bucket",
        "arn:aws:s3:::your-backup-bucket/*"
      ]
    }
  ]
}
```

### Best Practices

1. ✅ Rotate AWS credentials regularly
2. ✅ Use dedicated S3 bucket for backups
3. ✅ Enable S3 bucket versioning
4. ✅ Set up S3 lifecycle policies
5. ✅ Monitor backup success/failure
6. ✅ Test restore procedures regularly
7. ✅ Use Kubernetes Secrets for credentials (not plain text in values)

---

## 📊 S3 Backup Structure

Backups are organized with date-based paths:

```
s3://your-backup-bucket/
└── DD-MM-YY-wazuh-backup/
    ├── master/
    │   └── master-backup-DD-MM-YY-HHMMSS.tar.gz
    ├── indexer/
    │   └── indexer-backup-DD-MM-YY-HHMMSS.tar.gz
    └── worker/
        └── worker-backup-DD-MM-YY-HHMMSS.tar.gz
```

### S3 Lifecycle Policy Example

```json
{
  "Rules": [
    {
      "ID": "WazuhBackupRetention",
      "Status": "Enabled",
      "Filter": {
        "Prefix": "wazuh-backup/"
      },
      "Transitions": [
        {
          "Days": 30,
          "StorageClass": "STANDARD_IA"
        },
        {
          "Days": 90,
          "StorageClass": "GLACIER"
        }
      ],
      "Expiration": {
        "Days": 365
      }
    }
  ]
}
```

---

## 🔄 Migration Guide

### Migrating from Old Version

If you're upgrading from the pre-refactoring version:

1. **Backup existing `values.yaml`**
   ```bash
   cp values.yaml values.yaml.backup
   ```

2. **Convert map-based to array-based components**

   **Old format:**
   ```yaml
   backup:
     components:
       master:
         enabled: true
         statefulsetName: "..."
   ```

   **New format:**
   ```yaml
   backup:
     components:
       - name: master
         enabled: true
         statefulsetName: "..."
   ```

3. **Add feature flags**
   ```yaml
   features:
     eventListener:
       enabled: true
     cronjobs:
       enabled: true
     triggers:
       enabled: true
   ```

4. **Test with `helm template`**
   ```bash
   helm template wazuh-backup . --namespace wazuh --debug
   ```

5. **Upgrade the release**
   ```bash
   helm upgrade wazuh-backup . --namespace wazuh
   ```

See [REFACTORING-SUMMARY.md](REFACTORING-SUMMARY.md) for complete migration details.

---

## 📚 Additional Documentation

- **[REFACTORING-SUMMARY.md](REFACTORING-SUMMARY.md)** - Detailed refactoring documentation, design decisions, and benefits
- **[GRACEFUL-SHUTDOWN.md](GRACEFUL-SHUTDOWN.md)** - Graceful shutdown feature documentation (experimental)
- **[values.yaml](values.yaml)** - Complete configuration reference with inline comments

---

## 🤝 Contributing

Contributions are welcome! The array-based architecture makes it easy to add new features:

- **Add new component types**: Just add to the components array
- **Add new resource types**: Add array to values.yaml + create generic template
- **Add new features**: Add feature flag + conditional rendering

---

## 📄 License

Apache License 2.0

---

## 🙏 Acknowledgments

- Built with [Tekton Pipelines](https://tekton.dev)
- Uses [Bitnami Common Chart](https://github.com/bitnami/charts/tree/main/bitnami/common) patterns
- Designed for [Wazuh](https://wazuh.com) security platform

---

## 💡 Tips & Tricks

### Quick Health Check

```bash
# One-liner to check everything
kubectl get cronjobs,eventlistener,pipeline,tasks,pvc -n wazuh -l app.kubernetes.io/instance=wazuh-backup
```

### Backup All Components at Once

```bash
#!/bin/bash
for component in master indexer worker; do
  curl -X POST http://localhost:8080 \
    -H "Content-Type: application/json" \
    -d "{\"component\": \"$component\", \"triggeredBy\": \"manual\"}"
  sleep 60  # Wait between backups
done
```

### Monitor Backup Sizes

```bash
# Check recent backup sizes in S3
aws s3 ls s3://your-backup-bucket/ --recursive --human-readable --summarize | tail -20
```

### Test Backup Path Patterns

Before configuring `backupPaths`, test what will be included:

```bash
# Access debug pod
kubectl exec -it deployment/wazuh-backup-debug -n wazuh -- /bin/sh

# Test rsync with --dry-run
rsync -avh --dry-run --relative \
  --include="wazuh/var/ossec/etc" \
  --exclude="*.tmp" \
  /source/./ /backup/test/
```

---

**Ready to protect your Wazuh deployment?** Install the chart and start backing up! 🚀
