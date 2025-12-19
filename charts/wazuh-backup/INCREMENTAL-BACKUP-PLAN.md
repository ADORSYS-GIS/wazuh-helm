# Incremental Backup Strategy with Restic

## Table of Contents
- [Overview](#overview)
- [Current State](#current-state)
- [Why Restic?](#why-restic)
- [Expected Benefits](#expected-benefits)
- [Implementation Plan](#implementation-plan)
- [Migration Strategy](#migration-strategy)
- [Files to Create/Modify](#files-to-createmodify)
- [Testing & Validation](#testing--validation)
- [Rollback Plan](#rollback-plan)
- [Questions & Decisions](#questions--decisions)

---

## Overview

Transform the Wazuh backup pipeline from **full backups** to **incremental backups** using **Restic**, a modern backup tool designed for incremental, encrypted, deduplicated backups.

### Goals
- **Reduce storage costs** by 90%+ through block-level deduplication
- **Reduce backup duration** from 25 minutes → 2-5 minutes (after initial backup)
- **Reduce network bandwidth** by 95% (only upload changed blocks)
- **Eliminate staging PVC** requirement (backup directly to S3)

---

## Current State

### Current Backup Implementation

**Method**: Full backup on every execution

| Aspect | Current Implementation |
|--------|----------------------|
| **Copy Tool** | `kubectl cp` (pod → staging PVC) |
| **Compression** | `tar -czf` (in-place on staging PVC) |
| **Upload** | `aws s3 cp` (single tarball per backup) |
| **Versioning** | Date-time stamped files (`DD-MM-YY-HHMMSS.tar.gz`) |
| **Deduplication** | None - every backup is a complete copy |
| **Duration** | 5-30+ minutes per component |
| **Staging PVC** | 20Gi required |

### S3 Storage Structure (Current)

```
s3://wazuh-dev-backup/
└── 19-12-25-wazuh-backup/
    ├── master/
    │   └── master-backup-19-12-25-022345.tar.gz  (full 2GB)
    ├── worker-0/
    │   └── worker-0-backup-19-12-25-022415.tar.gz  (full 3GB)
    └── worker-1/
        └── worker-1-backup-19-12-25-022445.tar.gz  (full 3GB)
```

### Data Being Backed Up

| Component | Paths | Typical Size |
|-----------|-------|--------------|
| **Master** | `/var/ossec/etc`, `/var/ossec/queue`, `/var/ossec/logs`, `/var/ossec/stats` | 100-500MB configs + 1-10GB logs |
| **Worker** | `/var/ossec/logs`, `/var/ossec/queue` | 1-5GB per worker |
| **Indexer** | OpenSearch data (disabled by default) | 10GB-1TB+ |

### Current Limitations

1. ❌ **Full filesystem copy** every backup (even if only 1 file changed)
2. ❌ **Full tar compression** every time (CPU-intensive)
3. ❌ **Upload entire tarball** to S3 (bandwidth-intensive)
4. ❌ **Unbounded S3 storage growth** (no automatic retention)
5. ❌ **Staging PVC required** (must be larger than largest backup)
6. ❌ **No block-level deduplication**
7. ❌ **No encryption at rest** (relies on S3 encryption)

### Resource Usage Example

**Scenario**: 3 components, daily backups for 30 days

- Master: 2GB × 30 days = 60GB
- Worker-0: 3GB × 30 days = 90GB
- Worker-1: 3GB × 30 days = 90GB
- **Total S3 storage**: 240GB (with 90%+ duplicate data)

---

## Why Restic?

### Key Features

| Feature | Benefit | Current vs Restic |
|---------|---------|-------------------|
| **Content-Defined Chunking** | Block-level deduplication | tar: file-level only |
| **Native S3 Support** | Direct S3 backend, no staging | Current: requires 20Gi staging PVC |
| **Snapshot-Based** | Point-in-time recovery | Current: single tarball per backup |
| **Encryption** | AES-256 encryption at rest | Current: S3-dependent |
| **Incremental by Default** | Only uploads changed blocks | Current: uploads everything |
| **Retention Policies** | Automatic old snapshot cleanup | Current: manual S3 lifecycle |
| **Verification** | Built-in `check` and `verify` commands | Current: none |
| **Fast** | Uses local cache for metadata | Current: full filesystem scan |

### Comparison to Alternatives

| Tool | Pros | Cons | Decision |
|------|------|------|----------|
| **Incremental tar** | No new dependencies | Complex snapshot file management, no block-level dedup | ❌ Rejected |
| **Borg Backup** | Excellent deduplication | No direct S3 support, needs FUSE/borgbase | ❌ Rejected |
| **AWS S3 Sync + rsync** | Simple, built-in | Only file-level dedup, still needs staging PVC | ❌ Rejected |
| **Restic** | Block-level dedup, native S3, encryption, snapshot management | New dependency, learning curve | ✅ **Selected** |

### Restic Repository Architecture

Stored in S3, all backups for all components share one repository:

```
s3://wazuh-dev-backup/restic-repo/
├── config              # Repository configuration
├── keys/               # Encrypted repository keys
│   └── abc123...       # Key ID
├── snapshots/          # Snapshot metadata
│   ├── snapshot-1      # Master component backup (2025-12-19 02:00)
│   ├── snapshot-2      # Worker-0 component backup (2025-12-19 02:05)
│   └── snapshot-3      # Worker-1 component backup (2025-12-19 02:10)
├── index/              # Content index (maps files → chunks)
│   ├── abc123...
│   └── def456...
└── data/               # Deduplicated data chunks
    ├── 00/             # Chunk subdirectories (first 2 hex digits)
    │   ├── 00abc123... # Data chunk (encrypted)
    │   └── 00def456...
    ├── 01/
    └── ...
```

**Key Concepts**:
- **Repository**: S3 bucket containing all backups for all components
- **Snapshot**: Point-in-time backup of a component (tagged with component name)
- **Chunk**: Fixed-size deduplicated data blocks
- **Index**: Metadata mapping files to chunks (cached locally for speed)

---

## Expected Benefits

### Storage Savings

**Scenario**: 3 components, 5% daily change rate, 30-day retention

| Metric | Legacy (Full Backups) | Restic (Incremental) | Savings |
|--------|----------------------|----------------------|---------|
| **Initial Backup** | 8GB | 8GB | 0% |
| **Daily Incremental** | 8GB | 400MB | 95% |
| **30-Day Total** | 240GB | 20GB | **92%** |
| **90-Day Total** | 720GB | 44GB | **94%** |

### Performance Improvements

| Metric | Legacy | Restic | Improvement |
|--------|--------|--------|-------------|
| **Initial Backup** | 25 min | 20 min | 20% faster |
| **Incremental Backup** | 25 min | 2-5 min | **80-90% faster** |
| **Staging PVC Usage** | 20Gi | 0Gi (direct S3) | **100% freed** |
| **Network Bandwidth** | 8GB | 400MB | **95% reduction** |

### Operational Benefits

| Feature | Legacy | Restic |
|---------|--------|--------|
| **Retention Management** | Manual S3 lifecycle | Automatic (`restic forget`) |
| **Encryption** | S3-dependent | Built-in AES-256 |
| **Verification** | None | Built-in `restic check` |
| **Point-in-Time Recovery** | Daily snapshots only | Hourly/on-demand snapshots |
| **Deduplication** | None | Block-level across all backups |

---

## Implementation Plan

### Phase 1: Restic Integration (Core Changes)

#### 1.1 Add Restic Container Image

**File**: `charts/wazuh-backup/values.yaml`

Add new image configuration:

```yaml
images:
  restic:
    registry: docker.io
    repository: restic/restic
    tag: "0.17.3"  # Latest stable as of Dec 2024
    digest: ""
    pullPolicy: IfNotPresent

  awsCli:  # Keep existing for migration scripts
    registry: docker.io
    repository: amazon/aws-cli
    tag: "2.13.0"
    digest: ""
    pullPolicy: IfNotPresent
```

#### 1.2 Add Restic Configuration

**File**: `charts/wazuh-backup/values.yaml`

Add new `restic` section:

```yaml
backup:
  # ... existing s3 configuration ...

  restic:
    enabled: true  # Feature flag for gradual rollout
    repository: "s3:s3.amazonaws.com/wazuh-dev-backup/restic-repo"
    passwordSecretName: "restic-password"
    passwordSecretKey: "password"

    # Retention policy (auto-cleanup old snapshots)
    retention:
      enabled: true
      keepLast: 7      # Keep last 7 snapshots
      keepDaily: 30    # Keep daily snapshots for 30 days
      keepWeekly: 12   # Keep weekly snapshots for 3 months
      keepMonthly: 12  # Keep monthly snapshots for 1 year

    # Performance tuning
    cache:
      enabled: true
      size: "1Gi"  # Local cache size for index metadata

    # Parallel upload optimization
    packSize: "128"  # MB per pack file (default: 16MB)

    # Verification (optional but recommended)
    verification:
      enabled: true
      schedule: "0 4 * * 0"  # Weekly on Sunday at 4 AM
```

#### 1.3 Create Restic Repository Init Job

**File**: `charts/wazuh-backup/templates/jobs/restic-init.yaml` (new file)

Creates the Restic repository in S3 on first installation/upgrade. See implementation plan for full YAML.

**Key features**:
- Helm hook (`post-install`, `post-upgrade`)
- Idempotent (checks if repo exists before initializing)
- Uses same S3 credentials as current backup system

#### 1.4 Create Restic Backup Script

**File**: `charts/wazuh-backup/scripts/restic-backup.sh` (new file)

**Purpose**: Perform incremental backup with Restic

**Usage**:
```bash
restic-backup.sh <component-name> <pod-name> <pod-namespace> <include-paths>
```

**Features**:
- Backs up directly from pod to S3 (no staging PVC)
- Uses tags for component/pod/namespace identification
- Provides detailed statistics (new/changed/unchanged files)
- Shows data deduplication savings

**Environment variables required**:
- `RESTIC_REPOSITORY`: S3 repository URL
- `RESTIC_PASSWORD`: Repository encryption password
- AWS credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)

#### 1.5 Create Restic Restore Script

**File**: `charts/wazuh-backup/scripts/restic-restore.sh` (new file)

**Purpose**: Restore from Restic backup

**Usage**:
```bash
restic-restore.sh <component-name> <target-path> [snapshot-id]
```

**Features**:
- Lists available snapshots for component
- Restores to specified target path
- Verifies restore integrity

#### 1.6 Create Restic Cleanup Script

**File**: `charts/wazuh-backup/scripts/restic-forget.sh` (new file)

**Purpose**: Cleanup old snapshots based on retention policy

**Usage**:
```bash
restic-forget.sh [component-name]  # Optional: cleanup specific component only
```

**Features**:
- Applies retention policy (keep last N, daily, weekly, monthly)
- Prunes unused data to free storage
- Shows repository stats after cleanup

### Phase 2: Pipeline Integration

#### 2.1 Create Restic-Based Pipeline

**File**: `charts/wazuh-backup/templates/pipelines.yaml`

Add new pipeline alongside existing one:

```yaml
apiVersion: tekton.dev/v1beta1
kind: Pipeline
metadata:
  name: {{ include "common.names.fullname" $ }}-component-backup-restic-graceful
spec:
  tasks:
    # Task 1: Stop Wazuh services
    - name: stop-wazuh
      taskRef:
        name: {{ include "common.names.fullname" $ }}-wazuh-control
      params:
        - name: action
          value: "stop"

    # Task 2: Restic incremental backup
    - name: restic-backup
      runAfter: ["stop-wazuh"]
      taskRef:
        name: {{ include "common.names.fullname" $ }}-restic-backup

    # Task 3: Start Wazuh services
    - name: start-wazuh
      runAfter: ["restic-backup"]
      taskRef:
        name: {{ include "common.names.fullname" $ }}-wazuh-control
      params:
        - name: action
          value: "start"

  finally:
    # Emergency start if pipeline fails
    - name: emergency-start
      taskRef:
        name: {{ include "common.names.fullname" $ }}-wazuh-control
      params:
        - name: action
          value: "start"
        - name: emergencyMode
          value: "true"
```

**Simpler than current pipeline**:
- Only 3 steps: stop → backup → start (vs 6 steps currently)
- No staging PVC tasks needed
- Reuses existing `wazuh-control` task
- Emergency recovery preserved

#### 2.2 Create Restic Backup Task

**File**: `charts/wazuh-backup/templates/tasks.yaml`

Add Restic backup task definition that executes the `restic-backup.sh` script.

#### 2.3 Create Restic Cleanup CronJob

**File**: `charts/wazuh-backup/templates/cronjob/restic-cleanup-cron.yaml` (new file)

**Schedule**: Daily at 3 AM (after backups complete)

Runs `restic forget` with retention policy to automatically clean up old snapshots.

### Phase 3: Update Trigger Templates

**File**: `charts/wazuh-backup/templates/triggers/triggertemplates.yaml`

Update to reference the new Restic pipeline when Restic is enabled:

```yaml
{{- if .Values.backup.restic.enabled }}
pipelineRef:
  name: {{ include "common.names.fullname" $ }}-component-backup-restic-graceful
{{- else }}
pipelineRef:
  name: {{ include "common.names.fullname" $ }}-component-backup-graceful
{{- end }}
```

---

## Migration Strategy

### Parallel Deployment Approach (Recommended)

Run both old and new backup systems in parallel during migration.

**Feature Flags** (`values.yaml`):

```yaml
features:
  # Legacy backup system (tar + aws-cli)
  legacyBackup:
    enabled: true  # Keep running during migration

  # New Restic backup system
  resticBackup:
    enabled: true  # Enable alongside legacy

backup:
  restic:
    enabled: true
```

### Gradual Rollout Timeline

| Week | Action | Notes |
|------|--------|-------|
| **Week 1** | Enable Restic for master component only | Test incremental backups |
| **Week 2** | Compare Restic vs legacy backups, validate restores | Ensure data integrity |
| **Week 3** | Enable Restic for worker components | Full deployment |
| **Week 4** | Disable legacy backups, clean up old S3 data | Migration complete |

### Validation Checklist

**Before disabling legacy backups**:

- [ ] Restic backups completing successfully for 1+ week
- [ ] Incremental backups showing expected deduplication savings
- [ ] Test restore from Restic snapshot succeeds
- [ ] Compare restored data with legacy backup (spot check)
- [ ] Verify S3 storage usage decreasing over time
- [ ] No errors in Restic logs
- [ ] Retention policy working (old snapshots being cleaned up)

---

## Files to Create/Modify

### New Files (Create)

1. **`charts/wazuh-backup/templates/jobs/restic-init.yaml`**
   - Repository initialization Job
   - Helm hook: post-install, post-upgrade
   - Idempotent repository creation

2. **`charts/wazuh-backup/scripts/restic-backup.sh`**
   - Incremental backup script
   - Backs up pod directly to S3
   - Provides statistics on deduplication savings

3. **`charts/wazuh-backup/scripts/restic-restore.sh`**
   - Restore script
   - Lists available snapshots
   - Verifies restore integrity

4. **`charts/wazuh-backup/scripts/restic-forget.sh`**
   - Cleanup/retention script
   - Applies retention policy
   - Prunes unused data

5. **`charts/wazuh-backup/templates/cronjob/restic-cleanup-cron.yaml`**
   - Cleanup CronJob
   - Runs daily to clean old snapshots
   - Automatic retention management

6. **`charts/wazuh-backup/templates/servicemonitor.yaml`** (optional)
   - Prometheus monitoring
   - Backup metrics collection
   - Grafana dashboard integration

7. **`INCREMENTAL-BACKUP-PLAN.md`** (this file)
   - Implementation documentation
   - Reference guide

### Modified Files

1. **`charts/wazuh-backup/values.yaml`**
   - Add Restic image configuration
   - Add Restic configuration section
   - Add retention policy settings

2. **`charts/wazuh-backup/templates/pipelines.yaml`**
   - Add Restic-based pipeline
   - Keep legacy pipeline for migration

3. **`charts/wazuh-backup/templates/tasks.yaml`**
   - Add Restic backup task

4. **`charts/wazuh-backup/templates/triggers/triggertemplates.yaml`**
   - Reference Restic pipeline when enabled
   - Conditional logic for feature flag

5. **`charts/wazuh-backup/Chart.yaml`**
   - Bump version: `0.1.2-rc.15` → `0.2.0`
   - Document breaking changes in changelog

6. **`charts/wazuh-backup/README.md`**
   - Document Restic usage
   - Add migration guide
   - Update configuration examples

---

## Testing & Validation

### Phase 1: Template Validation (No K8s Required)

```bash
cd charts/wazuh-backup

# Lint the chart
helm lint .

# Render templates with Restic enabled
helm template wazuh-backup . \
  --set backup.restic.enabled=true \
  --debug > /tmp/restic-backup.yaml

# Verify Restic resources created
grep "kind: Job" /tmp/restic-backup.yaml | grep restic-init
grep "restic-backup" /tmp/restic-backup.yaml
```

### Phase 2: K3s Deployment Testing

```bash
# 1. Create Restic password secret
kubectl create secret generic restic-password \
  --from-literal=password=$(openssl rand -base64 32) \
  -n wazuh

# 2. Deploy Restic-enabled chart
helm upgrade --install wazuh-backup . \
  --namespace wazuh \
  --set backup.restic.enabled=true

# 3. Verify Restic repository initialized
kubectl logs -n wazuh job/wazuh-backup-restic-init

# 4. Trigger manual backup
kubectl create job --from=cronjob/wazuh-backup-master-0-graceful-cron \
  manual-restic-test -n wazuh

# 5. Watch PipelineRun
kubectl get pipelinerun -n wazuh -w

# 6. Check backup logs
kubectl logs -n wazuh -l tekton.dev/pipelineRun=<name> --all-containers
```

### Phase 3: Restore Testing

```bash
# 1. List snapshots
kubectl exec -n wazuh deployment/wazuh-backup-tools -- \
  restic snapshots --tag component=master

# 2. Restore to test directory
kubectl exec -n wazuh deployment/wazuh-backup-tools -- \
  restic restore latest --tag component=master --target /tmp/restore-test

# 3. Verify restored files
kubectl exec -n wazuh deployment/wazuh-backup-tools -- \
  ls -lah /tmp/restore-test/var/ossec/etc/

# 4. Compare with production (optional)
kubectl exec -n wazuh wazuh-manager-master-0 -- \
  ls -lah /var/ossec/etc/
```

### Phase 4: Performance Validation

**Metrics to collect**:

| Metric | Command | Expected Result |
|--------|---------|-----------------|
| **Backup Duration** | Check PipelineRun completion time | 2-5 min (after initial 20 min) |
| **Data Added** | `restic stats latest` | ~400MB daily (5% change) |
| **Repository Size** | `restic stats --mode raw-data` | Growing slower than legacy |
| **Files Changed** | `restic snapshots latest --json` | `files_changed` < `files_total` |
| **Deduplication Ratio** | Compare repo size vs data added | 90%+ dedup expected |

---

## Rollback Plan

### Immediate Rollback (If Issues Arise)

**Option 1: Disable Restic via Helm values**

```yaml
# values.yaml
backup:
  restic:
    enabled: false  # Disable Restic

features:
  legacyBackup:
    enabled: true   # Re-enable legacy
```

Then run:
```bash
helm upgrade wazuh-backup . --namespace wazuh
```

**Option 2: Helm Rollback**

```bash
# List releases
helm history wazuh-backup -n wazuh

# Rollback to previous version
helm rollback wazuh-backup <revision> -n wazuh
```

### Emergency Restore (From Legacy Backups)

Legacy tar.gz backups remain in S3 during migration:

```bash
# 1. Download legacy backup
aws s3 cp s3://wazuh-dev-backup/19-12-25-wazuh-backup/master/master-backup-*.tar.gz /tmp/

# 2. Extract to target location
tar -xzf /tmp/master-backup-*.tar.gz -C /restore/path/

# 3. Copy to pod (if needed)
kubectl cp /restore/path/ wazuh/wazuh-manager-master-0:/var/ossec/
```

### Post-Rollback Cleanup

```bash
# Remove Restic repository (optional - keeps data for forensics)
aws s3 rm s3://wazuh-dev-backup/restic-repo/ --recursive

# Delete Restic password secret
kubectl delete secret restic-password -n wazuh
```

---

## Questions & Decisions

Before implementing, confirm the following:

### 1. S3 Bucket Structure

**Question**: Should Restic use the same S3 bucket or a separate one?

**Options**:
- **Option A** (Recommended): Same bucket, new prefix (`s3://wazuh-dev-backup/restic-repo/`)
  - Pros: Simpler configuration, same IAM permissions
  - Cons: Mixed legacy and Restic data
- **Option B**: New bucket (`s3://wazuh-dev-backup-restic`)
  - Pros: Clean separation
  - Cons: Need new IAM policies, separate bucket management

**Decision**: _______________

### 2. Migration Strategy

**Question**: Gradual migration or clean cut-over?

**Options**:
- **Option A** (Recommended): Gradual - run both systems for 2 weeks
  - Pros: Safe, can compare backups, easy rollback
  - Cons: Temporarily higher S3 costs
- **Option B**: Clean cut-over - switch immediately after testing
  - Pros: Faster migration, lower costs
  - Cons: Higher risk, harder to rollback

**Decision**: _______________

### 3. Retention Policy

**Question**: Are the proposed retention settings acceptable?

**Proposed**:
- Keep last 7 snapshots
- Keep daily for 30 days
- Keep weekly for 12 weeks (3 months)
- Keep monthly for 12 months (1 year)

**Alternatives**:
- More aggressive: Keep daily for 14 days (lower storage)
- More conservative: Keep daily for 60 days (higher storage)

**Decision**: _______________

### 4. Staging PVC

**Question**: After migration, can we reduce/remove the 20Gi staging PVC?

**Options**:
- **Option A** (Recommended): Remove entirely (Restic backs up directly to S3)
  - Pros: Cost savings, simpler infrastructure
  - Cons: No fallback for legacy backups
- **Option B**: Keep but reduce to 5Gi (for migration/testing)
  - Pros: Safety net during migration
  - Cons: Still some cost/complexity

**Decision**: _______________

### 5. Legacy Backup Cleanup

**Question**: When should we delete old tar.gz backups from S3?

**Options**:
- **Option A**: After 30 days of Restic validation
- **Option B**: After 90 days (extra safety)
- **Option C**: Keep forever (archive to Glacier)

**Decision**: _______________

---

## Implementation Checklist

### Phase 1: Core Implementation

- [ ] Add Restic image configuration to `values.yaml`
- [ ] Add Restic configuration section to `values.yaml`
- [ ] Create `templates/jobs/restic-init.yaml`
- [ ] Create `scripts/restic-backup.sh`
- [ ] Create `scripts/restic-restore.sh`
- [ ] Create `scripts/restic-forget.sh`
- [ ] Create Restic backup task in `templates/tasks.yaml`
- [ ] Create Restic pipeline in `templates/pipelines.yaml`
- [ ] Create cleanup CronJob in `templates/cronjob/restic-cleanup-cron.yaml`
- [ ] Update `templates/triggers/triggertemplates.yaml`
- [ ] Bump Chart version to `0.2.0`

### Phase 2: Secret Management

- [ ] Create Restic password secret:
  ```bash
  kubectl create secret generic restic-password \
    --from-literal=password=$(openssl rand -base64 32) \
    -n wazuh
  ```
- [ ] Verify S3 credentials secret exists
- [ ] Update ExternalSecrets if using AWS Secrets Manager
- [ ] Backup Restic password to password manager

### Phase 3: Testing & Validation

- [ ] Deploy Restic-enabled chart to K3s test environment
- [ ] Verify repository initialization successful
- [ ] Trigger manual backup
- [ ] Verify snapshot created: `restic snapshots`
- [ ] Test restore procedure
- [ ] Compare backup duration (legacy vs Restic)
- [ ] Validate S3 storage usage
- [ ] Run backup multiple times, verify incremental behavior

### Phase 4: Production Rollout

- [ ] Enable Restic for master component only
- [ ] Monitor for 1 week, compare with legacy backups
- [ ] Validate restore from Restic snapshot
- [ ] Enable Restic for worker components
- [ ] Monitor for 1 week
- [ ] Compare S3 costs (should be decreasing)
- [ ] Disable legacy backups
- [ ] Schedule cleanup of old S3 tarball backups

### Phase 5: Monitoring & Documentation

- [ ] Deploy ServiceMonitor for Prometheus metrics (optional)
- [ ] Create Grafana dashboard for backup metrics
- [ ] Set up alerting for backup failures
- [ ] Document restore procedures in runbook
- [ ] Update `README.md` with Restic usage
- [ ] Train team on Restic restore procedures

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **Restic repository corruption** | Low | High | Run `restic check` weekly, keep legacy backups during migration |
| **S3 credential issues** | Low | High | Reuse existing secret, test before rollout |
| **Increased backup duration (first run)** | High | Low | Initial backup slower (~20 min), document expectation |
| **Restore complexity** | Medium | Medium | Document restore procedures, test before production |
| **Password loss** | Low | Critical | Store password in K8s Secret + password manager |
| **Incompatibility with future Wazuh versions** | Low | Medium | Restic is version-agnostic (backs up files, not apps) |

---

## Success Criteria

### Functional Requirements

✅ Incremental backups reduce storage by 90%+
✅ Backup duration reduced from 25 min → 2-5 min (after initial)
✅ Retention policy automatically cleans up old snapshots
✅ Restore procedures validated and documented
✅ Monitoring/alerting configured for backup failures

### Non-Functional Requirements

✅ No data loss during migration
✅ Rollback possible at any time
✅ Backwards compatible (legacy backups still work during migration)
✅ Clear documentation for operators
✅ Production-tested before full rollout

---

## Additional Resources

- **Restic Documentation**: https://restic.readthedocs.io/
- **Restic GitHub**: https://github.com/restic/restic
- **Restic S3 Backend**: https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html#amazon-s3
- **Backup Best Practices**: https://restic.readthedocs.io/en/stable/075_scripting.html

---

## Next Steps

1. **Review this plan** with the team
2. **Answer decision questions** (S3 bucket, migration strategy, etc.)
3. **Create implementation branch**: `feature/incremental-backup-restic`
4. **Start Phase 1**: Implement core Restic integration
5. **Test in K3s**: Validate functionality before production
6. **Gradual rollout**: Master → Workers → Full deployment

---

**Document Version**: 1.0
**Created**: 2025-12-19
**Last Updated**: 2025-12-19
**Status**: Planning Phase
