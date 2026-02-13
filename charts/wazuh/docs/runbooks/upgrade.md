# Wazuh Upgrade Runbook

Complete upgrade procedures for the Wazuh Helm deployment on Kubernetes.

[[_TOC_]]

## Overview

<details open>
<summary>Expand/Collapse</summary>

```
┌──────────────────────────────────────────────────────────────┐
│                    UPGRADE WORKFLOW                           │
└──────────────────────────────────────────────────────────────┘

    ┌─────────────────┐
    │ U01 - PLAN      │
    │ Review Changes  │
    └────────┬────────┘
             │
             ▼
    ┌─────────────────┐
    │ U02 - BACKUP    │
    │ Full Backup     │
    └────────┬────────┘
             │
             ▼
    ┌─────────────────┐
    │ U03 - PRE-CHECK │
    │ Health Verify   │
    └────────┬────────┘
             │
             ▼
    ┌─────────────────┐     Fail     ┌─────────────────┐
    │ U04 - UPGRADE   ├─────────────►│ U06 - ROLLBACK  │
    │ Helm Upgrade    │              └─────────────────┘
    └────────┬────────┘
             │ Success
             ▼
    ┌─────────────────┐
    │ U05 - VERIFY    │
    │ Post-Upgrade    │
    └─────────────────┘
```

### Upgrade Types

| Type | Description | Risk Level | Downtime |
|------|-------------|------------|----------|
| **Patch** | Bug fixes, security patches | Low | None |
| **Minor** | New features, improvements | Medium | Minimal |
| **Major** | Breaking changes, migrations | High | Planned |
| **Chart-only** | Helm chart updates | Low | None |

</details>

---

## Planning

<details open>
<summary>Expand/Collapse</summary>

### U01 - Review Changes

<details>
<summary>Pre-Upgrade Planning</summary>

**Review release notes:**
- [ ] Read CHANGELOG for target version
- [ ] Check for breaking changes
- [ ] Review migration guides
- [ ] Check compatibility matrix

**Version compatibility matrix:**

| Wazuh Manager | Wazuh Indexer | Dashboard | Agents |
|---------------|---------------|-----------|--------|
| 4.7.x | 2.11.x | 4.7.x | 4.7.x, 4.6.x |
| 4.8.x | 2.12.x | 4.8.x | 4.8.x, 4.7.x |
| 4.9.x | 2.13.x | 4.9.x | 4.9.x, 4.8.x |

**Diff current vs new values:**
```bash
# Get current values
helm get values wazuh -n wazuh > current-values.yaml

# Compare with new defaults
helm show values ./charts/wazuh > new-defaults.yaml
diff current-values.yaml new-defaults.yaml
```

</details>

### U01.1 - Change Assessment

<details>
<summary>Impact Analysis</summary>

| Change Type | Impact | Action Required |
|-------------|--------|-----------------|
| Image version | Pod restart | Schedule maintenance |
| Resource limits | Pod restart | Verify node capacity |
| Replicas | Scaling | Check cluster resources |
| Config changes | Service reload | May require restart |
| CRD changes | Cluster-wide | Admin approval |

**Checklist:**
- [ ] Backup completed
- [ ] Maintenance window scheduled
- [ ] Stakeholders notified
- [ ] Rollback plan documented
- [ ] Team available for support

</details>

</details>

---

## Pre-Upgrade

<details open>
<summary>Expand/Collapse</summary>

### U02 - Create Backup

<details>
<summary>Full System Backup</summary>

**CRITICAL: Always backup before upgrade**

See [Backup/Restore Runbook](backup-restore.md) for detailed procedures.

**Quick backup commands:**
```bash
# Set credentials
INDEXER_PASS=$(kubectl get secret -n wazuh wazuh-wazuh-helm-indexer-cred \
  -o jsonpath='{.data.INDEXER_PASSWORD}' | base64 -d)

# Create indexer snapshot
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  -X PUT "https://localhost:9200/_snapshot/wazuh_backup/pre_upgrade_$(date +%Y%m%d_%H%M)" \
  -H "Content-Type: application/json" \
  -d '{
    "indices": "wazuh-*",
    "ignore_unavailable": true,
    "include_global_state": false
  }'

# Backup manager config
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  tar -czf /tmp/manager-backup.tar.gz /var/ossec/etc/
kubectl cp wazuh/wazuh-wazuh-helm-manager-master-0:/tmp/manager-backup.tar.gz ./manager-backup-$(date +%Y%m%d).tar.gz

# Backup secrets
kubectl get secrets -n wazuh -o yaml > wazuh-secrets-backup-$(date +%Y%m%d).yaml

# Backup Helm values
helm get values wazuh -n wazuh > values-backup-$(date +%Y%m%d).yaml
```

**Verify backup:**
```bash
# Check snapshot status
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_snapshot/wazuh_backup/_all" | jq '.snapshots[-1].state'

# Should return: "SUCCESS"
```

</details>

### U03 - Pre-Upgrade Health Check

<details>
<summary>System Health Verification</summary>

**Indexer cluster health:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS https://localhost:9200/_cluster/health | jq

# Required: "status": "green"
# Acceptable: "status": "yellow" (with justification)
# STOP if: "status": "red"
```

**All pods running:**
```bash
kubectl get pods -n wazuh -o wide

# All pods should be Running and Ready
# Check for any restarts
kubectl get pods -n wazuh -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}'
```

**Manager cluster status:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/cluster_control -l

# All nodes should be "connected"
```

**Agent connectivity:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/agent_control -l | head -20

# Note current connected agent count
```

**Pre-upgrade checklist:**
- [ ] Indexer cluster: GREEN
- [ ] All pods: Running
- [ ] Manager cluster: Connected
- [ ] Agents: Connected
- [ ] Backup: Verified

</details>

</details>

---

## Upgrade Execution

<details open>
<summary>Expand/Collapse</summary>

### U04 - Perform Upgrade

<details>
<summary>Helm Upgrade Commands</summary>

**Standard upgrade:**
```bash
# Pull latest chart (if from repo)
helm repo update

# Dry-run first
helm upgrade wazuh ./charts/wazuh \
  --namespace wazuh \
  -f values.yaml \
  -f values-production.yaml \
  --dry-run

# If dry-run looks good, execute
helm upgrade wazuh ./charts/wazuh \
  --namespace wazuh \
  -f values.yaml \
  -f values-production.yaml \
  --wait \
  --timeout 15m
```

**Upgrade with specific version:**
```bash
helm upgrade wazuh ./charts/wazuh \
  --namespace wazuh \
  -f values.yaml \
  --set global.imageTag=4.9.0 \
  --wait
```

**Monitor upgrade progress:**
```bash
# In separate terminal
watch -n 2 kubectl get pods -n wazuh

# Watch events
kubectl get events -n wazuh --watch
```

</details>

### U04.1 - Component-Specific Upgrades

<details>
<summary>Rolling Update Strategy</summary>

**Indexer upgrade (StatefulSet):**
- Updates one pod at a time
- Waits for pod to be ready before next
- Maintains quorum throughout

```bash
# Monitor indexer rolling update
kubectl rollout status statefulset/wazuh-wazuh-helm-indexer -n wazuh
```

**Manager upgrade:**
- Master updated first
- Workers updated after master is ready

```bash
# Monitor manager updates
kubectl rollout status statefulset/wazuh-wazuh-helm-manager-master -n wazuh
kubectl rollout status statefulset/wazuh-wazuh-helm-manager-worker -n wazuh
```

**Dashboard upgrade (Deployment):**
- Zero-downtime with multiple replicas
- RollingUpdate strategy

```bash
kubectl rollout status deployment/wazuh-wazuh-helm-dashboard -n wazuh
```

</details>

### U04.2 - Handling Long Upgrades

<details>
<summary>Extended Upgrade Scenarios</summary>

**If upgrade takes longer than expected:**
```bash
# Check what's happening
kubectl describe pod -n wazuh -l app.kubernetes.io/instance=wazuh | grep -A 10 Events

# Check logs of updating pods
kubectl logs -n wazuh <pod-name> --tail=50

# Check if indexer is rebalancing
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_cluster/health?wait_for_status=green&timeout=5m"
```

**Data migration scenarios:**
```bash
# Check index migration status
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_cat/recovery?v&active_only=true"
```

</details>

</details>

---

## Post-Upgrade

<details open>
<summary>Expand/Collapse</summary>

### U05 - Verify Upgrade

<details>
<summary>Post-Upgrade Validation</summary>

**Version verification:**
```bash
# Check image versions
kubectl get pods -n wazuh -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

# Check Wazuh version
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/wazuh-control info | grep VERSION
```

**Cluster health:**
```bash
# Indexer health
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS https://localhost:9200/_cluster/health | jq

# Manager status
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/wazuh-control status
```

**Functional tests:**
```bash
# Test API
API_PASS=$(kubectl get secret -n wazuh wazuh-wazuh-helm-api-cred \
  -o jsonpath='{.data.password}' | base64 -d)

kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS https://localhost:55000/agents/summary/status | jq

# Test dashboard
kubectl port-forward -n wazuh svc/wazuh-wazuh-helm-dashboard 5601:5601 &
curl -sk https://localhost:5601/api/status | jq '.status.overall.state'
```

**Agent connectivity verification:**
```bash
# Compare agent count with pre-upgrade
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/agent_control -l | grep -c "Active"
```

</details>

### U05.1 - Post-Upgrade Checklist

<details>
<summary>Verification Checklist</summary>

| Check | Command | Expected |
|-------|---------|----------|
| All pods running | `kubectl get pods -n wazuh` | All Running |
| Indexer health | `_cluster/health` | green |
| Manager services | `wazuh-control status` | All running |
| Agent count | `agent_control -l \| wc -l` | Same as before |
| Dashboard access | Browser test | Login works |
| Alerts flowing | Check recent alerts | New alerts appear |

**Sign-off checklist:**
- [ ] All pods running without restarts
- [ ] Indexer cluster green
- [ ] Manager cluster connected
- [ ] Agent count matches pre-upgrade
- [ ] Dashboard accessible
- [ ] Alerts being received
- [ ] Backup verified accessible

</details>

</details>

---

## Rollback

<details open>
<summary>Expand/Collapse</summary>

### U06 - Rollback Procedure

<details>
<summary>Emergency Rollback</summary>

**When to rollback:**
- Upgrade fails to complete
- Critical functionality broken
- Data corruption detected
- Agents can't connect

**Helm rollback:**
```bash
# List release history
helm history wazuh -n wazuh

# REVISION  STATUS      DESCRIPTION
# 1         superseded  Install complete
# 2         superseded  Upgrade complete
# 3         deployed    Upgrade complete  <- current

# Rollback to previous revision
helm rollback wazuh 2 -n wazuh --wait

# Verify rollback
helm status wazuh -n wazuh
kubectl get pods -n wazuh
```

**If Helm rollback fails:**
```bash
# Force pod restart with previous image
kubectl set image statefulset/wazuh-wazuh-helm-indexer \
  indexer=wazuh/wazuh-indexer:4.7.5 -n wazuh

kubectl set image statefulset/wazuh-wazuh-helm-manager-master \
  manager=wazuh/wazuh-manager:4.7.5 -n wazuh
```

</details>

### U06.1 - Data Restore

<details>
<summary>Restore from Backup</summary>

**If data corruption occurred:**

See [Backup/Restore Runbook](backup-restore.md) for full restore procedures.

**Quick restore steps:**
```bash
# Restore indexer snapshot
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  -X POST "https://localhost:9200/_snapshot/wazuh_backup/pre_upgrade_YYYYMMDD_HHMM/_restore" \
  -H "Content-Type: application/json" \
  -d '{
    "indices": "wazuh-*",
    "ignore_unavailable": true
  }'

# Restore manager config
kubectl cp manager-backup-YYYYMMDD.tar.gz wazuh/wazuh-wazuh-helm-manager-master-0:/tmp/
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  tar -xzf /tmp/manager-backup-YYYYMMDD.tar.gz -C /
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/wazuh-control restart
```

</details>

</details>

---

## Troubleshooting

<details>
<summary>Expand/Collapse</summary>

### TS1 - Common Upgrade Issues

<details>
<summary>Issue Resolution</summary>

| Issue | Cause | Solution |
|-------|-------|----------|
| Pods stuck terminating | PVC issues, finalizers | Force delete, check PVC |
| Indexer won't form cluster | Certificate mismatch | Regenerate certs |
| Manager can't start | Config incompatibility | Check ossec.conf syntax |
| Dashboard 502 | Indexer not ready | Wait for indexer health |
| Agents disconnecting | Version mismatch | Upgrade agents |

**Debug commands:**
```bash
# Check pod issues
kubectl describe pod <pod-name> -n wazuh
kubectl logs <pod-name> -n wazuh --previous

# Check events
kubectl get events -n wazuh --sort-by='.lastTimestamp'

# Force delete stuck pod
kubectl delete pod <pod-name> -n wazuh --force --grace-period=0
```

</details>

### TS2 - Partial Upgrade Recovery

<details>
<summary>Stuck Upgrade Recovery</summary>

**If upgrade is stuck:**
```bash
# Check Helm release status
helm status wazuh -n wazuh

# If stuck in "pending-upgrade"
helm rollback wazuh 0 -n wazuh  # Rollback to current

# Or force upgrade
helm upgrade wazuh ./charts/wazuh \
  --namespace wazuh \
  -f values.yaml \
  --force \
  --wait
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
| [Backup/Restore](backup-restore.md) | Backup procedures |
| [Scaling](scaling.md) | Scaling procedures |

### B. Upgrade Checklist Summary

**Pre-upgrade:**
- [ ] Review release notes
- [ ] Full backup completed
- [ ] Health check passed
- [ ] Maintenance window scheduled

**Upgrade:**
- [ ] Dry-run successful
- [ ] Helm upgrade executed
- [ ] Pods rolling correctly

**Post-upgrade:**
- [ ] All pods running
- [ ] Cluster health green
- [ ] Agents connected
- [ ] Functional tests passed

### C. Revision History

| Date | Version | Author | Changes |
|------|---------|--------|---------|
| 2024-02 | 1.0 | Platform Team | Initial version |

</details>
