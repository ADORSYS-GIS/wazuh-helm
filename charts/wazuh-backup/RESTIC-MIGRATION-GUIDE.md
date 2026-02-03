# Restic Incremental Backup Migration Guide

This guide walks you through enabling and migrating to the new Restic-based incremental backup system for Wazuh.

## Overview

The Wazuh backup system now supports **Restic** for incremental, deduplicated backups with the following benefits:

- **90%+ storage savings** through block-level deduplication
- **80-90% faster backups** after initial backup (2-5 minutes vs 25 minutes)
- **No staging PVC required** - backups directly to S3
- **Built-in encryption** - AES-256 encryption at rest
- **Automatic retention management** - policy-based cleanup
- **Easy restore** - point-in-time recovery from any snapshot

## Prerequisites

1. **Kubernetes cluster** with Tekton Pipelines installed
2. **S3-compatible storage** (AWS S3, MinIO, etc.)
3. **AWS credentials** configured as Kubernetes secret
4. **Restic password secret** (will be created during setup)

## Setup Instructions

### Step 1: Create Restic Password Secret

The Restic repository requires a password for encryption. Create a strong password and store it in a Kubernetes secret:

```bash
# Generate a strong random password
RESTIC_PASSWORD=$(openssl rand -base64 32)

# Create the secret
kubectl create secret generic restic-password \
  --from-literal=password="$RESTIC_PASSWORD" \
  -n wazuh

# IMPORTANT: Save this password in your password manager!
# You will need it to restore backups.
echo "Restic password: $RESTIC_PASSWORD"
```

### Step 2: Update Helm Values

Update your `values.yaml` or create an override file:

```yaml
# Enable Restic backup system
features:
  resticBackup:
    enabled: true
  legacyBackup:
    enabled: true  # Keep legacy backups during migration

# Restic configuration
backup:
  restic:
    enabled: true
    repository: "s3:s3.amazonaws.com/wazuh-dev-backup/restic-repo"
    passwordSecretName: "restic-password"
    passwordSecretKey: "password"

    # Retention policy (customize as needed)
    retention:
      enabled: true
      keepLast: 7      # Keep last 7 snapshots
      keepDaily: 30    # Keep daily snapshots for 30 days
      keepWeekly: 12   # Keep weekly snapshots for 3 months
      keepMonthly: 12  # Keep monthly snapshots for 1 year

    # Performance tuning
    cache:
      enabled: true
      size: "1Gi"

    # Cleanup schedule
    cleanup:
      schedule: "0 3 * * *"  # Daily at 3 AM
```

### Step 3: Deploy the Updated Chart

```bash
# Update Helm dependencies
cd charts/wazuh-backup
helm dependency update

# Deploy with Restic enabled
helm upgrade --install wazuh-backup . \
  --namespace wazuh \
  --values values.yaml
```

### Step 4: Verify Restic Initialization

Check that the Restic repository was initialized successfully:

```bash
# Check the init job
kubectl get job -n wazuh | grep restic-init
kubectl logs -n wazuh job/wazuh-backup-restic-init

# You should see output like:
# ✅ Repository initialized successfully!
```

### Step 5: Test Manual Backup

Trigger a manual backup to test the Restic system:

```bash
# Trigger a backup for the master component
kubectl create job --from=cronjob/wazuh-backup-master-0-graceful-cron \
  wazuh-backup-restic-test-master -n wazuh

# Watch the pipeline run
kubectl get pipelinerun -n wazuh -w

# Check logs
kubectl logs -n wazuh -l tekton.dev/pipelineRun=wazuh-backup-restic-test-master --all-containers
```

### Step 6: Verify Backup Success

List the snapshots in the Restic repository:

```bash
# Create a temporary pod to access Restic
kubectl run restic-cli --rm -it \
  --image=restic/restic:0.17.3 \
  --env="RESTIC_REPOSITORY=s3:s3.amazonaws.com/wazuh-dev-backup/restic-repo" \
  --env="RESTIC_PASSWORD=$(kubectl get secret restic-password -n wazuh -o jsonpath='{.data.password}' | base64 -d)" \
  --env="AWS_ACCESS_KEY_ID=$(kubectl get secret aws-creds -n wazuh -o jsonpath='{.data.aws_access_key_id}' | base64 -d)" \
  --env="AWS_SECRET_ACCESS_KEY=$(kubectl get secret aws-creds -n wazuh -o jsonpath='{.data.aws_secret_access_key}' | base64 -d)" \
  -n wazuh \
  -- restic snapshots

# You should see output like:
# ID        Time                 Host                Tags
# --------------------------------------------------------
# abc12345  2025-01-12 14:30:00  wazuh-manager-...   component=master
```

## Migration Strategy

### Gradual Migration (Recommended)

Run both backup systems in parallel for 1-2 weeks:

#### Week 1: Enable Restic for Master Only

```yaml
features:
  resticBackup:
    enabled: true
  legacyBackup:
    enabled: true  # Keep legacy running

backup:
  components:
    - name: master
      enabled: true  # Restic will handle this
    - name: worker
      enabled: false  # Disable for now, legacy continues
```

#### Week 2: Enable for All Components

After verifying master backups work correctly:

```yaml
backup:
  components:
    - name: master
      enabled: true
    - name: worker
      enabled: true  # Enable Restic for workers
```

#### Week 3-4: Disable Legacy Backups

After confirming Restic backups are successful:

```yaml
features:
  resticBackup:
    enabled: true
  legacyBackup:
    enabled: false  # Disable legacy system
```

## Restoring from Restic Backups

### List Available Snapshots

```bash
# Access Restic CLI (as shown in Step 6)
restic snapshots --tag component=master
```

### Restore to Local Directory

```bash
# Restore latest snapshot
restic restore latest --tag component=master --target /tmp/restore

# Restore specific snapshot
restic restore abc12345 --target /tmp/restore
```

### Restore to Wazuh Pod

```bash
# 1. Restore to temporary directory
restic restore latest --tag component=master --target /tmp/wazuh-restore

# 2. Copy to pod
kubectl cp /tmp/wazuh-restore/var/ossec/ \
  wazuh/wazuh-manager-master-0:/var/ossec/

# 3. Restart Wazuh
kubectl exec -n wazuh wazuh-manager-master-0 -- \
  /var/ossec/bin/wazuh-control restart
```

## Monitoring and Maintenance

### Check Backup Status

```bash
# List recent pipeline runs
kubectl get pipelinerun -n wazuh --sort-by=.metadata.creationTimestamp

# Check specific run logs
kubectl logs -n wazuh -l tekton.dev/pipelineRun=<run-name> --all-containers
```

### Monitor Repository Size

```bash
# Get repository statistics
restic stats --mode raw-data

# Expected output:
# Total Size: 5.2 GiB
# Total File Count: 12345
```

### Manual Cleanup (if needed)

The cleanup runs automatically via CronJob, but you can trigger it manually:

```bash
kubectl create job --from=cronjob/wazuh-backup-restic-cleanup \
  restic-cleanup-manual -n wazuh
```

## Rollback Plan

If you encounter issues with Restic:

### Option 1: Disable Restic via Helm

```yaml
features:
  resticBackup:
    enabled: false
  legacyBackup:
    enabled: true
```

Then upgrade:

```bash
helm upgrade wazuh-backup . --namespace wazuh
```

### Option 2: Helm Rollback

```bash
# List releases
helm history wazuh-backup -n wazuh

# Rollback to previous version
helm rollback wazuh-backup <revision> -n wazuh
```

### Option 3: Restore from Legacy Backups

Legacy tar.gz backups remain in S3:

```bash
# Download legacy backup
aws s3 cp s3://wazuh-dev-backup/master/master-backup-*.tar.gz /tmp/

# Extract
tar -xzf /tmp/master-backup-*.tar.gz -C /restore/path/

# Copy to pod
kubectl cp /restore/path/ wazuh/wazuh-manager-master-0:/var/ossec/
```

## Troubleshooting

### Repository Not Accessible

**Error**: `Fatal: unable to open config file: Stat: The specified bucket does not exist`

**Solution**: Check S3 bucket name and AWS credentials:

```bash
# Verify secret exists
kubectl get secret aws-creds -n wazuh

# Check S3 bucket
aws s3 ls s3://wazuh-dev-backup/
```

### Backup Takes Too Long

**Issue**: First backup is slower than expected

**Explanation**: The initial Restic backup is a full backup and will take ~20 minutes. Subsequent incremental backups will be much faster (2-5 minutes).

### Password Lost

**Issue**: Cannot access Restic repository

**Solution**: If you lose the Restic password, you **cannot** recover the backups. Always store the password securely in a password manager.

### High Memory Usage

**Issue**: Restic backup pod crashes with OOM

**Solution**: Increase memory limits in task definition or reduce cache size:

```yaml
backup:
  restic:
    cache:
      size: "512Mi"  # Reduce from 1Gi
```

## Performance Expectations

### Storage Savings

| Scenario | Legacy (Full) | Restic (Incremental) | Savings |
|----------|---------------|----------------------|---------|
| Initial backup | 8GB | 8GB | 0% |
| Daily backup (5% change) | 8GB | 400MB | 95% |
| 30-day retention | 240GB | 20GB | **92%** |
| 90-day retention | 720GB | 44GB | **94%** |

### Backup Duration

| Backup Type | Legacy | Restic | Improvement |
|-------------|--------|--------|-------------|
| Initial | 25 min | 20 min | 20% faster |
| Incremental | 25 min | 2-5 min | **80-90% faster** |

## Best Practices

1. **Test Restores Regularly**: Schedule monthly restore tests to verify backup integrity
2. **Monitor Storage Growth**: Use `restic stats` to track repository size
3. **Adjust Retention**: Tune retention policy based on compliance requirements
4. **Backup the Password**: Store Restic password in multiple secure locations
5. **Keep Legacy Backups**: Maintain legacy backups for 30-90 days during migration

## Support

For issues or questions:
- Check logs: `kubectl logs -n wazuh -l app.kubernetes.io/name=wazuh-backup`
- Review [Restic documentation](https://restic.readthedocs.io/)
- Open an issue in the repository

## Next Steps

After successful migration:
1. ✅ Monitor Restic backups for 2-4 weeks
2. ✅ Verify storage savings in S3
3. ✅ Perform test restores
4. ✅ Update backup SOP/runbooks
5. ✅ Schedule cleanup of old legacy backups (after 90 days)
6. ✅ Update monitoring/alerting for new backup metrics
