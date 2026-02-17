# Wazuh Backup and Restore Runbook

Complete backup and restore procedures for the Wazuh Helm deployment on Kubernetes.

[[_TOC_]]

## Overview

<details open>
<summary>Expand/Collapse</summary>

```
┌──────────────────────────────────────────────────────────────┐
│               BACKUP/RESTORE ARCHITECTURE                    │
└──────────────────────────────────────────────────────────────┘

    ┌─────────────────────────────────────────────────────┐
    │                  WAZUH COMPONENTS                   │
    │                                                     │
    │  ┌──────────────┐  ┌──────────────┐  ┌────────────┐│
    │  │   Indexer    │  │   Manager    │  │  Secrets   ││
    │  │   Data       │  │   Config     │  │  & Certs   ││
    │  └──────┬───────┘  └──────┬───────┘  └──────┬─────┘│
    └─────────┼─────────────────┼─────────────────┼──────┘
              │                 │                 │
              ▼                 ▼                 ▼
    ┌─────────────────────────────────────────────────────┐
    │                  BACKUP METHODS                      │
    │                                                      │
    │  ┌──────────────┐  ┌──────────────┐  ┌────────────┐│
    │  │  OpenSearch  │  │   tar/gz     │  │  kubectl   ││
    │  │  Snapshots   │  │   Archives   │  │   export   ││
    │  └──────────────┘  └──────────────┘  └────────────┘│
    └─────────────────────────────────────────────────────┘
              │                 │                 │
              ▼                 ▼                 ▼
    ┌─────────────────────────────────────────────────────┐
    │                  STORAGE TARGETS                     │
    │                                                      │
    │  ┌──────────────┐  ┌──────────────┐  ┌────────────┐│
    │  │    S3/       │  │    NFS/      │  │   Local    ││
    │  │   MinIO      │  │   Shared     │  │   Volume   ││
    │  └──────────────┘  └──────────────┘  └────────────┘│
    └─────────────────────────────────────────────────────┘
```

### Backup Components

| Component | Data Type | Backup Method | Priority |
|-----------|-----------|---------------|----------|
| **Indexer Data** | Alerts, archives | OpenSearch Snapshots | Critical |
| **Manager Config** | ossec.conf, rules | tar archive | Critical |
| **Agent Keys** | client.keys | File copy | Critical |
| **Custom Rules** | rules/, decoders/ | tar archive | High |
| **Certificates** | TLS certs, CA | kubectl export | Critical |
| **Secrets** | Passwords, tokens | kubectl export | Critical |

</details>

---

## Backup Procedures

<details open>
<summary>Expand/Collapse</summary>

### B01 - Indexer Backup (OpenSearch Snapshots)

<details>
<summary>Snapshot Repository Setup</summary>

**Set credentials:**
```bash
export INDEXER_PASS=$(kubectl get secret -n wazuh wazuh-wazuh-helm-indexer-cred \
  -o jsonpath='{.data.INDEXER_PASSWORD}' | base64 -d)
```

**Option A: Filesystem Repository (requires shared storage)**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  -X PUT "https://localhost:9200/_snapshot/wazuh_backup" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "fs",
    "settings": {
      "location": "/mnt/snapshots",
      "compress": true
    }
  }'
```

**Option B: S3 Repository**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  -X PUT "https://localhost:9200/_snapshot/wazuh_s3_backup" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "s3",
    "settings": {
      "bucket": "wazuh-backups",
      "region": "us-east-1",
      "base_path": "snapshots"
    }
  }'
```

**Verify repository:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_snapshot/wazuh_backup/_verify"
```

</details>

### B02 - Create Indexer Snapshot

<details>
<summary>Manual Snapshot Creation</summary>

**Create snapshot of all Wazuh indices:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  -X PUT "https://localhost:9200/_snapshot/wazuh_backup/snapshot_$(date +%Y%m%d_%H%M)" \
  -H "Content-Type: application/json" \
  -d '{
    "indices": "wazuh-*",
    "ignore_unavailable": true,
    "include_global_state": false,
    "metadata": {
      "taken_by": "manual",
      "reason": "scheduled backup"
    }
  }'
```

**Check snapshot status:**
```bash
# Check specific snapshot
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_snapshot/wazuh_backup/snapshot_$(date +%Y%m%d)*" | jq

# List all snapshots
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_snapshot/wazuh_backup/_all" | jq '.snapshots[] | {name: .snapshot, state: .state, indices: .indices | length}'
```

**Expected output:**
```json
{
  "name": "snapshot_20240215_1430",
  "state": "SUCCESS",
  "indices": 15
}
```

</details>

### B03 - Manager Backup

<details>
<summary>Configuration and Keys Backup</summary>

**Create backup directory:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- mkdir -p /tmp/backup
```

**Backup all manager configuration:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  tar -czf /tmp/backup/manager-config-$(date +%Y%m%d).tar.gz \
    /var/ossec/etc/ossec.conf \
    /var/ossec/etc/client.keys \
    /var/ossec/etc/rules/ \
    /var/ossec/etc/decoders/ \
    /var/ossec/etc/lists/ \
    /var/ossec/etc/shared/ \
    2>/dev/null

# Copy to local machine
kubectl cp wazuh/wazuh-wazuh-helm-manager-master-0:/tmp/backup/manager-config-$(date +%Y%m%d).tar.gz \
  ./backups/manager-config-$(date +%Y%m%d).tar.gz
```

**Backup agent keys separately (critical):**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  cat /var/ossec/etc/client.keys > ./backups/client.keys.$(date +%Y%m%d)
```

**Verify backup contents:**
```bash
tar -tzf ./backups/manager-config-$(date +%Y%m%d).tar.gz
```

</details>

### B04 - Secrets Backup

<details>
<summary>Kubernetes Secrets Backup</summary>

**Export all Wazuh secrets:**
```bash
# All secrets (encrypted at rest recommended)
kubectl get secrets -n wazuh -o yaml > ./backups/wazuh-secrets-$(date +%Y%m%d).yaml

# Critical secrets individually
kubectl get secret wazuh-root-ca -n wazuh -o yaml > ./backups/root-ca-$(date +%Y%m%d).yaml
kubectl get secret wazuh-wazuh-helm-indexer-cred -n wazuh -o yaml > ./backups/indexer-cred-$(date +%Y%m%d).yaml
kubectl get secret wazuh-wazuh-helm-api-cred -n wazuh -o yaml > ./backups/api-cred-$(date +%Y%m%d).yaml
kubectl get secret wazuh-wazuh-helm-indexer-certs -n wazuh -o yaml > ./backups/indexer-certs-$(date +%Y%m%d).yaml
```

**Export Helm values:**
```bash
helm get values wazuh -n wazuh > ./backups/helm-values-$(date +%Y%m%d).yaml
helm get values wazuh -n wazuh --all > ./backups/helm-values-all-$(date +%Y%m%d).yaml
```

**Encrypt backups (recommended):**
```bash
# Encrypt with GPG
gpg --symmetric --cipher-algo AES256 ./backups/wazuh-secrets-$(date +%Y%m%d).yaml

# Or with age
age -p -o ./backups/wazuh-secrets-$(date +%Y%m%d).yaml.age \
  ./backups/wazuh-secrets-$(date +%Y%m%d).yaml
```

</details>

### B05 - Automated Backup CronJob

<details>
<summary>Kubernetes CronJob Configuration</summary>

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: wazuh-backup
  namespace: wazuh
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: wazuh-backup-sa
          containers:
          - name: backup
            image: curlimages/curl:latest
            command:
            - /bin/sh
            - -c
            - |
              # Create snapshot
              curl -sk -u admin:$INDEXER_PASSWORD \
                -X PUT "https://wazuh-wazuh-helm-indexer:9200/_snapshot/wazuh_backup/snapshot_$(date +%Y%m%d_%H%M)" \
                -H "Content-Type: application/json" \
                -d '{
                  "indices": "wazuh-*",
                  "ignore_unavailable": true,
                  "include_global_state": false
                }'

              # Verify snapshot started
              sleep 10
              curl -sk -u admin:$INDEXER_PASSWORD \
                "https://wazuh-wazuh-helm-indexer:9200/_snapshot/wazuh_backup/_current"
            env:
            - name: INDEXER_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: wazuh-wazuh-helm-indexer-cred
                  key: INDEXER_PASSWORD
          restartPolicy: OnFailure
```

**Apply CronJob:**
```bash
kubectl apply -f wazuh-backup-cronjob.yaml
```

**Monitor backup jobs:**
```bash
# List jobs
kubectl get jobs -n wazuh

# Check latest job logs
kubectl logs -n wazuh job/wazuh-backup-<timestamp>
```

</details>

</details>

---

## Restore Procedures

<details open>
<summary>Expand/Collapse</summary>

### R01 - Restore Indexer Data

<details>
<summary>Snapshot Restoration</summary>

**List available snapshots:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_snapshot/wazuh_backup/_all" | jq '.snapshots[].snapshot'
```

**Close indices before restore:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  -X POST "https://localhost:9200/wazuh-*/_close"
```

**Restore from snapshot:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  -X POST "https://localhost:9200/_snapshot/wazuh_backup/snapshot_YYYYMMDD_HHMM/_restore" \
  -H "Content-Type: application/json" \
  -d '{
    "indices": "wazuh-*",
    "ignore_unavailable": true,
    "include_global_state": false
  }'
```

**Monitor restore progress:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_recovery?active_only=true" | jq
```

**Reopen indices:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  -X POST "https://localhost:9200/wazuh-*/_open"
```

</details>

### R02 - Restore Manager Configuration

<details>
<summary>Configuration Restoration</summary>

**Copy backup to pod:**
```bash
kubectl cp ./backups/manager-config-YYYYMMDD.tar.gz \
  wazuh/wazuh-wazuh-helm-manager-master-0:/tmp/
```

**Extract configuration:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  tar -xzf /tmp/manager-config-YYYYMMDD.tar.gz -C /
```

**Restart manager:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/wazuh-control restart
```

**Verify restoration:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/wazuh-control status

# Check agent keys restored
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/agent_control -l | wc -l
```

</details>

### R03 - Restore Secrets

<details>
<summary>Kubernetes Secrets Restoration</summary>

**Restore from backup:**
```bash
# Decrypt if encrypted
gpg -d ./backups/wazuh-secrets-YYYYMMDD.yaml.gpg > ./backups/wazuh-secrets-YYYYMMDD.yaml

# Apply secrets
kubectl apply -f ./backups/wazuh-secrets-YYYYMMDD.yaml

# Or restore individual secrets
kubectl apply -f ./backups/root-ca-YYYYMMDD.yaml
kubectl apply -f ./backups/indexer-cred-YYYYMMDD.yaml
kubectl apply -f ./backups/api-cred-YYYYMMDD.yaml
```

**Restart pods to pick up new secrets:**
```bash
kubectl rollout restart statefulset/wazuh-wazuh-helm-indexer -n wazuh
kubectl rollout restart statefulset/wazuh-wazuh-helm-manager-master -n wazuh
kubectl rollout restart statefulset/wazuh-wazuh-helm-manager-worker -n wazuh
```

</details>

</details>

---

## Disaster Recovery

<details open>
<summary>Expand/Collapse</summary>

### DR01 - Full Disaster Recovery

<details>
<summary>Complete System Recovery</summary>

**Prerequisites:**
- [ ] Backup files available
- [ ] Clean Kubernetes cluster
- [ ] Helm chart access
- [ ] Storage provisioner working

**Step 1: Create namespace and restore secrets**
```bash
kubectl create namespace wazuh

# Restore root CA first (critical for TLS)
kubectl apply -f ./backups/root-ca-YYYYMMDD.yaml -n wazuh

# Restore other secrets
kubectl apply -f ./backups/wazuh-secrets-YYYYMMDD.yaml
```

**Step 2: Deploy Wazuh with Helm**
```bash
helm upgrade --install wazuh ./charts/wazuh \
  --namespace wazuh \
  -f ./backups/helm-values-YYYYMMDD.yaml \
  --wait \
  --timeout 15m
```

**Step 3: Wait for pods to be ready**
```bash
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/instance=wazuh \
  -n wazuh \
  --timeout=600s
```

**Step 4: Register snapshot repository**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  -X PUT "https://localhost:9200/_snapshot/wazuh_backup" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "fs",
    "settings": {"location": "/mnt/snapshots"}
  }'
```

**Step 5: Restore indexer data**
```bash
# List available snapshots
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_snapshot/wazuh_backup/_all" | jq '.snapshots[].snapshot'

# Restore latest snapshot
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  -X POST "https://localhost:9200/_snapshot/wazuh_backup/snapshot_YYYYMMDD_HHMM/_restore" \
  -H "Content-Type: application/json" \
  -d '{"indices": "wazuh-*"}'
```

**Step 6: Restore manager configuration**
```bash
kubectl cp ./backups/manager-config-YYYYMMDD.tar.gz \
  wazuh/wazuh-wazuh-helm-manager-master-0:/tmp/

kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  tar -xzf /tmp/manager-config-YYYYMMDD.tar.gz -C /

kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/wazuh-control restart
```

**Step 7: Verify recovery**
```bash
# Indexer health
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS https://localhost:9200/_cluster/health | jq

# Agent count
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/agent_control -l | wc -l

# Index count
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS "https://localhost:9200/_cat/indices/wazuh-*?v"
```

</details>

### DR02 - Recovery Checklist

<details>
<summary>Verification Checklist</summary>

| Check | Command | Expected |
|-------|---------|----------|
| Namespace exists | `kubectl get ns wazuh` | Active |
| Secrets restored | `kubectl get secrets -n wazuh` | All present |
| Pods running | `kubectl get pods -n wazuh` | All Running |
| Indexer health | `_cluster/health` | green |
| Indices restored | `_cat/indices/wazuh-*` | Data present |
| Manager running | `wazuh-control status` | All running |
| Agents registered | `agent_control -l` | Count matches backup |

</details>

</details>

---

## Retention Policy

<details open>
<summary>Expand/Collapse</summary>

### Retention Schedule

<details>
<summary>Data Retention Guidelines</summary>

| Data Type | Retention | Backup Frequency | Storage Location |
|-----------|-----------|------------------|------------------|
| Alerts | 90 days | Daily | S3/Shared storage |
| Archives | 30 days | Weekly | S3/Shared storage |
| Snapshots | 30 days | Daily (keep 30) | Snapshot repo |
| Manager Config | Forever | Before changes | Git/Secure storage |
| Secrets | Forever | Before changes | Encrypted backup |
| Helm values | Forever | Before changes | Git |

</details>

### Snapshot Cleanup

<details>
<summary>Automated Cleanup</summary>

**Delete old snapshots (keep last 30):**
```bash
# List snapshots older than 30 days
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_snapshot/wazuh_backup/_all" | \
  jq -r '.snapshots[] | select(.start_time_in_millis < (now - 30*24*60*60*1000)*1000) | .snapshot'

# Delete specific snapshot
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  -X DELETE "https://localhost:9200/_snapshot/wazuh_backup/snapshot_YYYYMMDD_HHMM"
```

**Cleanup CronJob:**
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: wazuh-backup-cleanup
  namespace: wazuh
spec:
  schedule: "0 4 * * 0"  # Weekly on Sunday at 4 AM
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: cleanup
            image: curlimages/curl:latest
            command:
            - /bin/sh
            - -c
            - |
              # Get snapshots older than 30 days and delete
              OLD_SNAPSHOTS=$(curl -sk -u admin:$INDEXER_PASSWORD \
                "https://wazuh-wazuh-helm-indexer:9200/_snapshot/wazuh_backup/_all" | \
                jq -r '.snapshots | sort_by(.start_time_in_millis) | .[:-30] | .[].snapshot')

              for snapshot in $OLD_SNAPSHOTS; do
                curl -sk -u admin:$INDEXER_PASSWORD \
                  -X DELETE "https://wazuh-wazuh-helm-indexer:9200/_snapshot/wazuh_backup/$snapshot"
                echo "Deleted snapshot: $snapshot"
              done
            env:
            - name: INDEXER_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: wazuh-wazuh-helm-indexer-cred
                  key: INDEXER_PASSWORD
          restartPolicy: OnFailure
```

</details>

</details>

---

## Troubleshooting

<details>
<summary>Expand/Collapse</summary>

### TS1 - Backup Issues

<details>
<summary>Common Backup Problems</summary>

| Issue | Cause | Solution |
|-------|-------|----------|
| Snapshot failed | Insufficient space | Clear old snapshots |
| Repository not found | Not registered | Re-register repository |
| Partial snapshot | Index locked | Retry after unlock |
| Slow backup | Large indices | Schedule during off-hours |

**Debug commands:**
```bash
# Check repository status
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_snapshot/wazuh_backup/_status"

# Check disk space
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- df -h /mnt/snapshots
```

</details>

### TS2 - Restore Issues

<details>
<summary>Common Restore Problems</summary>

| Issue | Cause | Solution |
|-------|-------|----------|
| Restore blocked | Index exists | Close or delete index first |
| Version mismatch | Incompatible version | Use compatible cluster version |
| Missing shards | Incomplete snapshot | Use different snapshot |
| Permission denied | Security plugin | Check user permissions |

**Debug commands:**
```bash
# Check restore status
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_recovery?detailed=true" | jq

# Force close stuck index
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  -X POST "https://localhost:9200/wazuh-alerts-*/_close?wait_for_active_shards=0"
```

</details>

</details>

---

## Appendix

<details>
<summary>Expand/Collapse</summary>

### A. Related Documentation

| Document | Description |
|----------|-------------|
| [Deployment Runbook](deployment.md) | Fresh deployment |
| [Upgrade Runbook](upgrade.md) | Upgrade procedures |
| [Troubleshooting](../troubleshooting/common-issues.md) | Common issues |

### B. Backup Checklist

**Daily backup verification:**
- [ ] Snapshot completed successfully
- [ ] Snapshot state is SUCCESS
- [ ] Storage space adequate

**Weekly tasks:**
- [ ] Verify backup restoration (test)
- [ ] Clean old snapshots
- [ ] Review backup logs

**Monthly tasks:**
- [ ] Full disaster recovery test
- [ ] Update backup documentation
- [ ] Review retention policy

### C. Revision History

| Date | Version | Author | Changes |
|------|---------|--------|---------|
| 2024-02 | 1.0 | Platform Team | Initial version |
| 2024-02 | 2.0 | Platform Team | SOCFortress format |

</details>
