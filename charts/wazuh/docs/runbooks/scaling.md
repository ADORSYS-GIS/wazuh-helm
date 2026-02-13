# Wazuh Scaling Runbook

Complete scaling procedures for the Wazuh Helm deployment on Kubernetes.

[[_TOC_]]

## Overview

<details open>
<summary>Expand/Collapse</summary>

```
┌──────────────────────────────────────────────────────────────┐
│                    SCALING ARCHITECTURE                       │
└──────────────────────────────────────────────────────────────┘

    ┌─────────────────────────────────────────────────────┐
    │                  SCALABLE COMPONENTS                 │
    │                                                      │
    │  ┌──────────────┐  ┌──────────────┐  ┌────────────┐│
    │  │   Indexer    │  │   Manager    │  │ Dashboard  ││
    │  │   Cluster    │  │   Workers    │  │  Replicas  ││
    │  │   (3→5→7)    │  │   (2→4→N)    │  │   (1→3)    ││
    │  └──────────────┘  └──────────────┘  └────────────┘│
    └─────────────────────────────────────────────────────┘
                           │
                           ▼
    ┌─────────────────────────────────────────────────────┐
    │                  SCALING TRIGGERS                    │
    │                                                      │
    │  • Agent count increase                              │
    │  • EPS (events per second) threshold                 │
    │  • Storage utilization                               │
    │  • CPU/Memory pressure                               │
    │  • Query latency increase                            │
    └─────────────────────────────────────────────────────┘
```

### Scaling Types

| Type | Description | Complexity | Downtime |
|------|-------------|------------|----------|
| **Vertical** | Increase resources (CPU/RAM) | Low | Pod restart |
| **Horizontal** | Add more replicas | Medium | None |
| **Storage** | Expand PVCs | Medium | None* |

*Depends on storage class support

</details>

---

## Capacity Planning

<details open>
<summary>Expand/Collapse</summary>

### S01 - Sizing Guidelines

<details>
<summary>Resource Sizing Reference</summary>

**Indexer sizing by agent count:**

| Agents | Indexer Nodes | CPU/Node | RAM/Node | Storage/Node |
|--------|---------------|----------|----------|--------------|
| 1-100 | 1 | 2 cores | 4GB | 50GB |
| 100-500 | 3 | 2 cores | 4GB | 100GB |
| 500-1000 | 3 | 4 cores | 8GB | 200GB |
| 1000-5000 | 5 | 4 cores | 16GB | 500GB |
| 5000+ | 7+ | 8 cores | 32GB | 1TB |

**Manager sizing by agent count:**

| Agents | Master | Workers | CPU/Worker | RAM/Worker |
|--------|--------|---------|------------|------------|
| 1-100 | 1 | 0 | - | - |
| 100-500 | 1 | 1 | 2 cores | 2GB |
| 500-1000 | 1 | 2 | 2 cores | 4GB |
| 1000-5000 | 1 | 4 | 4 cores | 4GB |
| 5000+ | 1 | 8+ | 4 cores | 8GB |

**Dashboard sizing:**

| Concurrent Users | Replicas | CPU | RAM |
|------------------|----------|-----|-----|
| 1-10 | 1 | 1 core | 2GB |
| 10-50 | 2 | 2 cores | 4GB |
| 50+ | 3 | 2 cores | 4GB |

</details>

### S01.1 - Monitoring Metrics

<details>
<summary>When to Scale</summary>

**Indexer scaling triggers:**
| Metric | Threshold | Action |
|--------|-----------|--------|
| CPU usage | > 70% sustained | Add nodes or increase CPU |
| Heap usage | > 75% | Increase RAM |
| Disk usage | > 80% | Expand storage or add nodes |
| Query latency | > 5s p95 | Add nodes |
| Indexing rate | Falling behind | Add nodes |

**Manager scaling triggers:**
| Metric | Threshold | Action |
|--------|-----------|--------|
| Agent queue | > 1000 queued | Add workers |
| CPU usage | > 80% sustained | Increase resources |
| Event processing delay | > 30s | Add workers |

**Check current metrics:**
```bash
# Indexer cluster stats
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_cluster/stats?human=true" | jq

# Node-level metrics
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_nodes/stats?human=true" | jq

# Manager agent stats
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/agent_control -l | wc -l
```

</details>

</details>

---

## Horizontal Scaling

<details open>
<summary>Expand/Collapse</summary>

### S02 - Scale Indexer Cluster

<details>
<summary>Add Indexer Nodes</summary>

**Prerequisites:**
- [ ] Indexer cluster healthy (green)
- [ ] Sufficient cluster resources
- [ ] Storage available

**Scale from 3 to 5 nodes:**
```bash
# Update values and upgrade
helm upgrade wazuh ./charts/wazuh \
  --namespace wazuh \
  -f values.yaml \
  --set indexer.replicas=5 \
  --wait
```

**Or update values.yaml:**
```yaml
indexer:
  replicas: 5
```

**Apply:**
```bash
helm upgrade wazuh ./charts/wazuh -n wazuh -f values.yaml --wait
```

**Monitor scaling:**
```bash
# Watch new pods
kubectl get pods -n wazuh -l app=wazuh-indexer -w

# Monitor cluster health
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_cluster/health?wait_for_nodes=5&timeout=5m" | jq
```

**Verify new nodes joined:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_cat/nodes?v"
```

</details>

### S02.1 - Scale Down Indexer

<details>
<summary>Remove Indexer Nodes</summary>

**CAUTION: Ensure data is replicated before scaling down**

**Pre-scale checks:**
```bash
# Ensure green status
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_cluster/health" | jq '.status'

# Check shard distribution
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_cat/shards?v" | grep -c "wazuh-wazuh-helm-indexer-4"
```

**Exclude node from allocation:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  -X PUT "https://localhost:9200/_cluster/settings" \
  -H "Content-Type: application/json" \
  -d '{
    "transient": {
      "cluster.routing.allocation.exclude._name": "wazuh-wazuh-helm-indexer-4"
    }
  }'
```

**Wait for shards to relocate:**
```bash
# Monitor shard relocation
watch -n 5 'kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_cat/shards?v" | grep -c "wazuh-wazuh-helm-indexer-4"'

# Should return 0 when complete
```

**Scale down:**
```bash
helm upgrade wazuh ./charts/wazuh \
  --namespace wazuh \
  -f values.yaml \
  --set indexer.replicas=3 \
  --wait
```

**Clear exclusion:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  -X PUT "https://localhost:9200/_cluster/settings" \
  -H "Content-Type: application/json" \
  -d '{
    "transient": {
      "cluster.routing.allocation.exclude._name": null
    }
  }'
```

</details>

### S03 - Scale Manager Workers

<details>
<summary>Add/Remove Workers</summary>

**Scale workers from 2 to 4:**
```bash
helm upgrade wazuh ./charts/wazuh \
  --namespace wazuh \
  -f values.yaml \
  --set manager.worker.replicas=4 \
  --wait
```

**Monitor worker scaling:**
```bash
# Watch pods
kubectl get pods -n wazuh -l app=wazuh-manager-worker -w

# Check cluster status
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/cluster_control -l
```

**Verify agent distribution:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/cluster_control -a | head -20
```

**Scale down workers:**
```bash
# Graceful - agents will reconnect to remaining workers
helm upgrade wazuh ./charts/wazuh \
  --namespace wazuh \
  -f values.yaml \
  --set manager.worker.replicas=2 \
  --wait
```

</details>

### S04 - Scale Dashboard

<details>
<summary>Dashboard Replicas</summary>

**Scale dashboard for HA:**
```bash
helm upgrade wazuh ./charts/wazuh \
  --namespace wazuh \
  -f values.yaml \
  --set dashboard.replicas=3 \
  --wait
```

**Verify load balancing:**
```bash
# Check all replicas
kubectl get pods -n wazuh -l app=wazuh-dashboard

# Check endpoints
kubectl get endpoints -n wazuh wazuh-wazuh-helm-dashboard
```

</details>

</details>

---

## Vertical Scaling

<details open>
<summary>Expand/Collapse</summary>

### S05 - Increase Resources

<details>
<summary>CPU and Memory Scaling</summary>

**Update indexer resources:**
```yaml
# values.yaml
indexer:
  resources:
    requests:
      cpu: "4"
      memory: "8Gi"
    limits:
      cpu: "8"
      memory: "16Gi"
  heapSize: "8g"  # Should be ~50% of memory limit
```

**Update manager resources:**
```yaml
# values.yaml
manager:
  master:
    resources:
      requests:
        cpu: "2"
        memory: "4Gi"
  worker:
    resources:
      requests:
        cpu: "2"
        memory: "4Gi"
```

**Apply changes:**
```bash
helm upgrade wazuh ./charts/wazuh \
  --namespace wazuh \
  -f values.yaml \
  --wait
```

**Note:** Vertical scaling requires pod restart. Pods will be restarted one at a time (rolling update).

</details>

### S05.1 - JVM Heap Tuning

<details>
<summary>Indexer Heap Configuration</summary>

**Heap sizing guidelines:**
- Heap should be ~50% of container memory
- Max heap: 32GB (pointer compression limit)
- Leave room for OS cache

**Update heap size:**
```yaml
indexer:
  heapSize: "8g"
  resources:
    limits:
      memory: "16Gi"
```

**Verify heap settings:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_nodes/stats/jvm" | jq '.nodes[].jvm.mem'
```

</details>

</details>

---

## Storage Scaling

<details open>
<summary>Expand/Collapse</summary>

### S06 - Expand PVCs

<details>
<summary>Online Volume Expansion</summary>

**Prerequisites:**
- StorageClass must support volume expansion
- `allowVolumeExpansion: true`

**Check StorageClass:**
```bash
kubectl get storageclass -o jsonpath='{.items[*].allowVolumeExpansion}'
```

**Expand indexer PVC:**
```bash
# Edit PVC directly
kubectl patch pvc wazuh-indexer-data-wazuh-wazuh-helm-indexer-0 -n wazuh \
  -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'

# Or update all indexer PVCs
for i in 0 1 2; do
  kubectl patch pvc wazuh-indexer-data-wazuh-wazuh-helm-indexer-$i -n wazuh \
    -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'
done
```

**Verify expansion:**
```bash
kubectl get pvc -n wazuh

# Check actual size in pod
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- df -h /usr/share/wazuh-indexer/data
```

**Note:** Some storage providers require pod restart for expansion to take effect.

</details>

### S06.1 - Add Data Nodes for Storage

<details>
<summary>Scale Out for Storage</summary>

If volume expansion isn't supported, add more indexer nodes:

```yaml
indexer:
  replicas: 5  # Add 2 more nodes
  persistence:
    size: 100Gi  # New nodes get this size
```

**Apply and rebalance:**
```bash
helm upgrade wazuh ./charts/wazuh -n wazuh -f values.yaml --wait

# Trigger shard rebalancing
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  -X POST "https://localhost:9200/_cluster/reroute?retry_failed=true"
```

</details>

</details>

---

## Auto-Scaling

<details open>
<summary>Expand/Collapse</summary>

### S07 - Horizontal Pod Autoscaler

<details>
<summary>HPA Configuration</summary>

**Dashboard HPA (recommended for variable user load):**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: wazuh-dashboard-hpa
  namespace: wazuh
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: wazuh-wazuh-helm-dashboard
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
```

**Apply HPA:**
```bash
kubectl apply -f wazuh-dashboard-hpa.yaml

# Monitor HPA
kubectl get hpa -n wazuh -w
```

**Note:** StatefulSets (indexer, manager) are not recommended for HPA due to complexity of cluster coordination.

</details>

### S07.1 - KEDA for Event-Driven Scaling

<details>
<summary>Advanced Auto-Scaling</summary>

**KEDA ScaledObject for manager workers:**
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: wazuh-manager-worker-scaler
  namespace: wazuh
spec:
  scaleTargetRef:
    name: wazuh-wazuh-helm-manager-worker
  minReplicaCount: 2
  maxReplicaCount: 8
  triggers:
  - type: prometheus
    metadata:
      serverAddress: http://prometheus.monitoring:9090
      metricName: wazuh_agent_count
      threshold: "500"  # Scale when agents per worker > 500
      query: |
        sum(wazuh_agents_total) / count(kube_pod_info{pod=~"wazuh.*manager-worker.*"})
```

</details>

</details>

---

## Troubleshooting

<details>
<summary>Expand/Collapse</summary>

### TS1 - Scaling Issues

<details>
<summary>Common Problems</summary>

| Issue | Cause | Solution |
|-------|-------|----------|
| Pods stuck pending | Insufficient resources | Check node capacity |
| Cluster not green after scale | Shard allocation | Wait or adjust settings |
| New workers not receiving agents | Service discovery | Check headless service |
| Storage not expanding | StorageClass limitation | Use volume expansion or add nodes |

**Debug commands:**
```bash
# Check pod scheduling issues
kubectl describe pod <pending-pod> -n wazuh

# Check cluster allocation issues
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_cluster/allocation/explain" | jq

# Check node resources
kubectl top nodes
kubectl describe nodes | grep -A 5 "Allocated resources"
```

</details>

### TS2 - Post-Scaling Verification

<details>
<summary>Verification Checklist</summary>

**After scaling indexer:**
```bash
# Verify node count
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_cat/nodes?v"

# Verify cluster health
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_cluster/health" | jq
```

**After scaling manager:**
```bash
# Verify cluster membership
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/cluster_control -l

# Verify agent distribution
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/cluster_control -a | head -20
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
| [Deployment Runbook](deployment.md) | Initial deployment |
| [Upgrade Runbook](upgrade.md) | Upgrade procedures |
| [Backup/Restore](backup-restore.md) | Backup before scaling |

### B. Scaling Checklist

**Before scaling:**
- [ ] Backup current state
- [ ] Check cluster health
- [ ] Verify resource availability
- [ ] Plan maintenance window (if needed)

**After scaling:**
- [ ] Verify component health
- [ ] Check data distribution
- [ ] Monitor metrics
- [ ] Update documentation

### C. Revision History

| Date | Version | Author | Changes |
|------|---------|--------|---------|
| 2024-02 | 1.0 | Platform Team | Initial version |

</details>
