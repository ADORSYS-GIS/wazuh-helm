# Wazuh Backup Helm Chart

A comprehensive Kubernetes backup solution for Wazuh components using Tekton Pipelines and S3 storage.

## 🎯 Overview

This Helm chart provides automated backup capabilities for Wazuh security platform components running on Kubernetes. It supports both **automatic scheduled backups** (via CronJobs) and **manual on-demand backups** (via HTTP triggers).

### Key Features

- ✅ **Hybrid Backup System**: Automatic CronJobs + Manual HTTP triggers
- ✅ **Multi-Component Support**: Manager Master, Indexer, Worker nodes
- ✅ **S3 Integration**: Organized, date-based backup storage
- ✅ **Safety First**: Automatic service recovery on failures
- ✅ **Parameterized**: Fully configurable via values.yaml
- ✅ **Debug Support**: Built-in troubleshooting capabilities

---

## 📦 Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           WAZUH BACKUP SYSTEM                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  📅 AUTOMATIC (CronJobs)           🖱️  MANUAL (HTTP Triggers)               |
│  ┌─────────────────────┐            ┌─────────────────────────────────────┐ │
│  │ master-cron         │──┐         │ HTTP Request                        │ │
│  │ indexer-cron        │──┤         │ ↓                                   │ │
│  │ worker-cron         │──┤         │ EventListener                       │ │
│  └─────────────────────┘  │         │ ↓                                   │ │
│                           │         │ TriggerBinding → TriggerTemplate    │ |
│                           ↓         │ ↓                                   │ | 
│                    ┌─────────────────────────────────────────────┐          | 
│                    │            Tekton Pipeline                  │          | 
│                    │  scale-down → rsync → scale-up + s3-upload  │          | 
│                    └─────────────────────────────────────────────┘          | 
│                                                                             |
└─────────────────────────────────────────────────────────────────────────────┘ 
```

### Backup Process Flow

1. **Scale Down**: Stop the Wazuh component for data consistency
2. **Copy Data**: Use rsync to copy data to staging PVC
3. **Scale Up**: Restore the component to normal operation
4. **Upload**: Create tarball and upload to S3 (parallel with scale-up)
5. **Cleanup**: Remove staging files
6. **Safety Net**: Emergency scale-up if any step fails

---

## 🗂️ File Structure

```
📦wazuh-backup/
 ┣ 📜Chart.yaml                     # Helm chart metadata
 ┣ 📜values.yaml                    # Configuration values
 ┣ 📂templates/
 ┃ ┣ 📂cronjob/
 ┃ ┃ ┗ 📜cronjobs.yaml             # Automatic backup schedules
 ┃ ┣ 📂pipeline/
 ┃ ┃ ┗ 📜wazuh-component-backup.yaml # Main backup pipeline
 ┃ ┣ 📂tasks/
 ┃ ┃ ┣ 📜cleanup-pvc-directory.yaml # PVC cleanup task
 ┃ ┃ ┣ 📜rsync-pvc-to-pvc.yaml     # Data copy task
 ┃ ┃ ┣ 📜s3-upload-directory.yaml  # S3 upload task
 ┃ ┃ ┗ 📜scale-statefulset.yaml    # StatefulSet scaling task
 ┃ ┣ 📂triggers/
 ┃ ┃ ┣ 📜event-listener.yaml       # HTTP endpoint
 ┃ ┃ ┣ 📜trigger-binding.yaml      # Parameter binding
 ┃ ┃ ┣ 📜trigger-template.yaml     # Pipeline templates
 ┃ ┃ ┗ 📜triggers.yaml             # Trigger definitions
 ┃ ┣ 📜pvc.yaml                    # Staging storage
 ┃ ┣ 📜rbac.yaml                   # EventListener permissions
 ┃ ┣ 📜secret-aws-creds.yaml       # AWS credentials
 ┃ ┗ 📜serviceaccount.yaml         # Service account & RBAC
```

---

## ⚙️ Configuration

### Core Configuration (values.yaml)

```yaml
# Namespace for all resources
namespace: wazuh

# Backup configuration
backup:
  # Enable/disable backup methods
  mode:
    cronjobs: true    # Automatic scheduled backups
    triggers: true    # Manual HTTP-triggered backups
  
  # S3 storage configuration
  s3:
    bucketName: "your-backup-bucket"
    endpointUrl: ""   # Leave empty for AWS S3
    pathPrefix: "wazuh-backup"
  
  # Component-specific settings
  components:
    master:           # Wazuh Manager Master
      enabled: true
      statefulsetName: "wazuh-wazuh-helm-manager-master"
      pvcName: "wazuh-wazuh-helm-manager-master-wazuh-wazuh-helm-manager-master-0"
      replicas: 1
      sourcePvcPath: "var/lib/wazuh/data/"
      backupSubdir: "master-backup"
      schedule: "0 2 * * *"  # Daily at 2 AM
    
    indexer:          # Wazuh Indexer
      enabled: true
      statefulsetName: "wazuh-wazuh-helm-indexer"
      pvcName: "wazuh-wazuh-helm-indexer-wazuh-wazuh-helm-indexer-0"
      replicas: 2
      sourcePvcPath: "usr/share/wazuh-indexer/data/"
      backupSubdir: "indexer-backup"
      schedule: "0 3 * * *"  # Daily at 3 AM
    
    worker:           # Wazuh Manager Worker
      enabled: true
      statefulsetName: "wazuh-wazuh-helm-manager-worker"
      pvcName: "wazuh-wazuh-helm-manager-worker-wazuh-wazuh-helm-manager-worker-0"
      replicas: 2
      sourcePvcPath: "var/lib/wazuh/data/"
      backupSubdir: "worker-backup"
      schedule: "0 4 * * *"  # Daily at 4 AM

# AWS credentials
aws:
  region: eu-central-1
  secretName: aws-creds
  accessKeyId: "YOUR_ACCESS_KEY"
  secretAccessKey: "YOUR_SECRET_KEY"
  sessionToken: "YOUR_SESSION_TOKEN"  # Optional

# Storage configuration
pvc:
  staging:
    name: "backup-staging-pvc"
    size: "20Gi"
    accessMode: "ReadWriteOnce"
    storageClass: "standard"  # Adjust for your cluster
```

### Component Data Breakdown

| Component | Source Path | Data Backed Up |
|-----------|-------------|----------------|
| **Master** | `/var/lib/wazuh/data/` | Agent keys, rules, decoders, logs, configurations |
| **Indexer** | `/usr/share/wazuh-indexer/data/` | Security events, indices, cluster state, plugins |
| **Worker** | `/var/lib/wazuh/data/` | Worker processing data, agent communications, queues |

---

## 🚀 Installation

### Prerequisites

1. **Kubernetes cluster** with kubectl access
2. **Tekton Pipelines** installed
3. **Existing Wazuh deployment** on Kubernetes
4. **S3 bucket** with write permissions
5. **AWS credentials** with S3 access

### Install Tekton Pipelines

```bash
# Install Tekton Pipelines
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

# Install Tekton Triggers
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml

# Verify installation
kubectl get pods -n tekton-pipelines
```

### Verify Wazuh Resources

```bash
# Check your Wazuh StatefulSets
kubectl get statefulsets -n wazuh

# Check your Wazuh PVCs
kubectl get pvc -n wazuh

# Note the exact names for your values.yaml
```

### Deploy the Backup Chart

```bash
# 1. Clone or create the chart directory
mkdir wazuh-backup
cd wazuh-backup

# 2. Update values.yaml with your specific configuration
# - Update AWS credentials
# - Update StatefulSet names to match your deployment
# - Update PVC names to match your deployment
# - Set appropriate storage class

# 3. Validate the template
helm template wazuh-backup . --namespace wazuh --debug

# 4. Deploy the chart
helm install wazuh-backup . --namespace wazuh --create-namespace

# 5. Verify deployment
kubectl get all -n wazuh -l app.kubernetes.io/instance=wazuh-backup
```

---

## 🧪 Testing

### Test 1: Verify Components

```bash
# Check CronJobs (automatic backups)
kubectl get cronjobs -n wazuh

# Check EventListener (manual triggers)
kubectl get eventlistener,service -n wazuh

# Check pipeline and tasks
kubectl get pipeline,tasks -n wazuh

# Check staging PVC
kubectl get pvc backup-staging-pvc -n wazuh
```

### Test 2: Manual Backup Triggers

```bash
# 1. Port forward the EventListener
kubectl port-forward svc/wazuh-backup-listener-svc 8080:8080 -n wazuh

# 2. In another terminal, test each component
# Test master backup
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"component": "master", "triggeredBy": "test"}'

# Test indexer backup
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"component": "indexer", "triggeredBy": "test"}'

# Test worker backup
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"component": "worker", "triggeredBy": "test"}'
```

### Test 3: Monitor Backup Execution

```bash
# Watch PipelineRuns
kubectl get pipelineruns -n wazuh -w

# Check specific component logs
kubectl logs -n wazuh -l component=master -f

# Check backup progress
kubectl get pipelineruns -n wazuh -o custom-columns=NAME:.metadata.name,COMPONENT:.metadata.labels.component,STATUS:.status.conditions[0].reason,AGE:.metadata.creationTimestamp
```

### Test 4: Verify S3 Uploads

```bash
# Check S3 bucket contents
aws s3 ls s3://your-backup-bucket/ --recursive

# Expected structure:
# DD-MM-YY-wazuh-backup/master/master-backup-DD-MM-YY-HHMMSS.tar.gz
# DD-MM-YY-wazuh-backup/indexer/indexer-backup-DD-MM-YY-HHMMSS.tar.gz
# DD-MM-YY-wazuh-backup/worker/worker-backup-DD-MM-YY-HHMMSS.tar.gz
```

---

## 🔧 Usage

### Automatic Backups

Automatic backups run based on the schedule in `values.yaml`:

```yaml
components:
  master:
    schedule: "0 2 * * *"    # Daily at 2 AM
  indexer:
    schedule: "0 3 * * *"    # Daily at 3 AM
  worker:
    schedule: "0 4 * * *"    # Daily at 4 AM
```

**Manage automatic backups:**
```bash
# Suspend all automatic backups
kubectl patch cronjob wazuh-backup-master-cron -n wazuh -p '{"spec":{"suspend":true}}'
kubectl patch cronjob wazuh-backup-indexer-cron -n wazuh -p '{"spec":{"suspend":true}}'
kubectl patch cronjob wazuh-backup-worker-cron -n wazuh -p '{"spec":{"suspend":true}}'

# Resume automatic backups
kubectl patch cronjob wazuh-backup-master-cron -n wazuh -p '{"spec":{"suspend":false}}'
kubectl patch cronjob wazuh-backup-indexer-cron -n wazuh -p '{"spec":{"suspend":false}}'
kubectl patch cronjob wazuh-backup-worker-cron -n wazuh -p '{"spec":{"suspend":false}}'

# Trigger immediate backup from CronJob
kubectl create job --from=cronjob/wazuh-backup-master-cron manual-backup-$(date +%s) -n wazuh
```

### Manual Backups

**Basic manual backup:**
```bash
# Set up port forward
kubectl port-forward svc/wazuh-backup-listener-svc 8080:8080 -n wazuh

# Trigger backup
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{"component": "master"}'
```

**Advanced manual backup with custom settings:**
```bash
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{
    "component": "master",
    "triggeredBy": "maintenance",
    "s3BucketName": "emergency-backup-bucket",
    "s3EndpointUrl": "https://custom-s3-endpoint.com"
  }'
```

**Emergency backup of all components:**
```bash
#!/bin/bash
components=("master" "indexer" "worker")
for component in "${components[@]}"; do
  echo "Backing up $component..."
  curl -X POST http://localhost:8080 \
    -H "Content-Type: application/json" \
    -d "{\"component\": \"$component\", \"triggeredBy\": \"emergency\"}"
  sleep 30  # Wait between backups
done
```

### Monitoring

**Check backup status:**
```bash
# Recent PipelineRuns
kubectl get pipelineruns -n wazuh --sort-by=.metadata.creationTimestamp

# Detailed status with components
kubectl get pipelineruns -n wazuh -o custom-columns=NAME:.metadata.name,COMPONENT:.metadata.labels.component,TRIGGERED_BY:.metadata.labels.triggered-by,STATUS:.status.conditions[0].reason

# Check for failures
kubectl get pipelineruns -n wazuh -o json | jq '.items[] | select(.status.conditions[0].reason == "Failed") | .metadata.name'
```

**Monitor active backups:**
```bash
# Watch all backup activity
kubectl get pipelineruns -n wazuh -w

# Monitor specific component
kubectl logs -n wazuh -l component=master -f

# Monitor EventListener
kubectl logs -n wazuh -l eventlistener=wazuh-backup-listener -f
```

---

## 🔍 Troubleshooting

### Common Issues

#### 1. PipelineRun Not Created

**Symptoms:** HTTP request succeeds but no PipelineRun appears

**Debug:**
```bash
# Check EventListener logs
kubectl logs -n wazuh -l eventlistener=wazuh-backup-listener

# Check trigger configuration
kubectl get triggers,triggerbindings,triggertemplates -n wazuh

# Test component validation
curl -X POST http://localhost:8080 -H "Content-Type: application/json" -d '{"component": "invalid"}'
```

**Common fixes:**
- Verify component name matches trigger filters
- Check EventListener service and pod status
- Verify RBAC permissions

#### 2. Pipeline Fails During Scale-Down

**Symptoms:** Pipeline fails at scale-down task

**Debug:**
```bash
# Check StatefulSet permissions
kubectl auth can-i patch statefulsets --as=system:serviceaccount:wazuh:wazuh-backup-sa -n wazuh

# Check StatefulSet exists
kubectl get statefulset wazuh-wazuh-helm-manager-master -n wazuh

# Check scale task logs
kubectl logs -n wazuh -l tekton.dev/task=scale-statefulset
```

**Common fixes:**
- Update StatefulSet names in values.yaml
- Verify RBAC includes all StatefulSets
- Check ServiceAccount permissions

#### 3. Rsync Task Fails

**Symptoms:** Pipeline fails during copy-data task

**Debug:**
```bash
# Check source PVC exists
kubectl get pvc wazuh-wazuh-helm-manager-master-wazuh-wazuh-helm-manager-master-0 -n wazuh

# Check staging PVC
kubectl get pvc backup-staging-pvc -n wazuh

# Debug with endless shell
kubectl apply -f - <<EOF
apiVersion: tekton.dev/v1beta1
kind: TaskRun
metadata:
  name: debug-rsync
  namespace: wazuh
spec:
  serviceAccountName: wazuh-backup-sa
  taskRef:
    name: rsync-pvc-to-pvc
  params:
    - name: sourcePvcName
      value: "wazuh-wazuh-helm-manager-master-wazuh-wazuh-helm-manager-master-0"
    - name: sourcePath
      value: "var/lib/wazuh/data/"
    - name: destinationPath
      value: "debug-test"
  timeout: "30m"
EOF
```

**Common fixes:**
- Update PVC names in values.yaml
- Verify PVCs are bound and accessible
- Check source paths exist
- Ensure staging PVC has sufficient space

#### 4. S3 Upload Fails

**Symptoms:** Pipeline fails during upload-s3 task

**Debug:**
```bash
# Check AWS credentials secret
kubectl get secret aws-creds -n wazuh -o yaml

# Test AWS credentials
kubectl run aws-test --image=amazon/aws-cli:2.13.0 --rm -it --restart=Never \
  --env AWS_ACCESS_KEY_ID="your-key" \
  --env AWS_SECRET_ACCESS_KEY="your-secret" \
  --env AWS_DEFAULT_REGION="eu-central-1" \
  -- aws s3 ls s3://your-bucket/

# Check S3 upload task logs
kubectl logs -n wazuh -l tekton.dev/task=s3-upload-directory
```

**Common fixes:**
- Verify AWS credentials are correct
- Check S3 bucket permissions
- Verify bucket exists and is accessible
- Check network connectivity to S3

#### 5. Emergency Scale-Up Not Working

**Symptoms:** StatefulSet remains at 0 replicas after pipeline failure

**Debug:**
```bash
# Check if emergency scale-up task ran
kubectl get pipelineruns -n wazuh -o jsonpath='{.items[*].status.taskRuns}' | jq '.[] | select(.taskRef.name == "scale-statefulset" and .spec.params[] | select(.name == "mode" and .value == "emergency"))'

# Check emergency task logs
kubectl logs -n wazuh -l tekton.dev/task=scale-statefulset | grep "EMERGENCY MODE"

# Manually scale up if needed
kubectl scale statefulset wazuh-wazuh-helm-manager-master -n wazuh --replicas=1
```

### Debug Mode

**Enable debug mode for cleanup task:**
```bash
kubectl apply -f - <<EOF
apiVersion: tekton.dev/v1beta1
kind: TaskRun
metadata:
  name: debug-cleanup
  namespace: wazuh
spec:
  serviceAccountName: wazuh-backup-sa
  taskRef:
    name: cleanup-pvc-directory
  params:
    - name: directoryPath
      value: "master-backup"
    - name: debug
      value: "true"
  timeout: "30m"
EOF

# Shell into the debug container
kubectl exec -it debug-cleanup-pod-xxxxx -n wazuh -c endless-debug -- /bin/sh
```

### Health Checks

**Comprehensive health check script:**
```bash
#!/bin/bash
# health-check.sh

echo "🏥 Wazuh Backup Health Check"
echo "============================"

# Check all components
kubectl get cronjobs,eventlistener,pipeline,tasks -n wazuh
echo ""

# Check recent backup status
echo "📊 Recent Backup Status:"
kubectl get pipelineruns -n wazuh --sort-by=.metadata.creationTimestamp | tail -5
echo ""

# Check StatefulSet status
echo "🔍 Wazuh StatefulSet Status:"
kubectl get statefulsets -n wazuh -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas,READY:.status.readyReplicas
echo ""

# Check PVC status
echo "💾 PVC Status:"
kubectl get pvc -n wazuh
echo ""

# Check S3 connectivity
echo "☁️  S3 Connectivity Test:"
aws s3 ls s3://your-backup-bucket/ --region eu-central-1 || echo "S3 test failed"
```

---

## 🔐 Security Considerations

### RBAC Permissions

The chart creates minimal required permissions:
- **StatefulSet scaling**: Get, patch, update StatefulSets and scale subresource
- **PVC access**: Read PVCs for backup operations
- **Secret access**: Read AWS credentials secret
- **Pipeline execution**: Create and manage Tekton resources

### AWS IAM Permissions

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

1. **Rotate credentials regularly**
2. **Use dedicated S3 bucket for backups**
3. **Enable S3 bucket versioning**
4. **Set up S3 lifecycle policies for old backups**
5. **Monitor backup success/failure**
6. **Test restore procedures regularly**

---

## 📊 Monitoring & Alerting

### Log Aggregation

Key log sources:
- **EventListener**: HTTP trigger events
- **PipelineRuns**: Backup execution logs
- **Tasks**: Individual task execution details
- **CronJobs**: Scheduled backup triggers

---

## 🔄 Backup Retention & Lifecycle

Using S3 bucket rules.

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

### Cleanup Old Backups

```bash
# Delete backups older than 30 days
aws s3 ls s3://your-backup-bucket/ --recursive | \
  awk '$1 < "'$(date -d '30 days ago' '+%Y-%m-%d')'" {print $4}' | \
  xargs -I {} aws s3 rm s3://your-backup-bucket/{}
```

---

## 🚀 Advanced Usage

### Custom Backup Schedules

```yaml
# Different schedules per component
backup:
  components:
    master:
      schedule: "0 1 * * *"      # 1 AM daily
    indexer:
      schedule: "0 2 * * 0"      # 2 AM every Sunday  
    worker:
      schedule: "0 3 * * 1,3,5"  # 3 AM Mon, Wed, Fri
```

### Multiple S3 Destinations

```bash
# Backup to different buckets
curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{
    "component": "master",
    "s3BucketName": "prod-backup-bucket",
    "triggeredBy": "prod-backup"
  }'

curl -X POST http://localhost:8080 \
  -H "Content-Type: application/json" \
  -d '{
    "component": "master", 
    "s3BucketName": "dr-backup-bucket",
    "triggeredBy": "dr-backup"
  }'
```
---

## 🔧 Maintenance

### Regular Maintenance Tasks

1. **Monitor disk usage** of staging PVC
2. **Review backup logs** for errors or warnings
3. **Test restore procedures** monthly
4. **Update AWS credentials** when they rotate
5. **Check S3 bucket costs** and optimize lifecycle policies

### Upgrading the Chart

```bash
# Check current version
helm list -n wazuh

# Upgrade to new version
helm upgrade wazuh-backup ./wazuh-backup -n wazuh

# Rollback if needed
helm rollback wazuh-backup 1 -n wazuh
```

### Backup Validation

```bash
# Download and verify a backup
aws s3 cp s3://your-backup-bucket/09-07-25-wazuh-backup/master/master-backup-09-07-25-143022.tar.gz ./

# Extract and verify contents
tar -tzf master-backup-09-07-25-143022.tar.gz | head -20

# Check backup size
ls -lh master-backup-09-07-25-143022.tar.gz
```

