# Wazuh Deployment Runbook

Complete deployment procedures for the Wazuh Helm chart on Kubernetes.

[[_TOC_]]

## Overview

<details open>
<summary>Expand/Collapse</summary>

```
┌──────────────────────────────────────────────────────────────┐
│                  DEPLOYMENT WORKFLOW                          │
└──────────────────────────────────────────────────────────────┘

    ┌─────────────────┐
    │ D01 - PRE-REQS  │
    │ Check Prereqs   │
    └────────┬────────┘
             │
             ▼
    ┌─────────────────┐
    │ D02 - PREPARE   │
    │ Namespace/Certs │
    └────────┬────────┘
             │
             ▼
    ┌─────────────────┐
    │ D03 - VALUES    │
    │ Configure       │
    └────────┬────────┘
             │
             ▼
    ┌─────────────────┐
    │ D04 - DEPLOY    │
    │ Helm Install    │
    └────────┬────────┘
             │
             ▼
    ┌─────────────────┐
    │ D05 - VERIFY    │
    │ Health Checks   │
    └────────┬────────┘
             │
             ▼
    ┌─────────────────┐
    │ D06 - POST      │
    │ Configuration   │
    └─────────────────┘
```

### Deployment Types

| Type | Use Case | Complexity |
|------|----------|------------|
| **Single-node** | Development, testing | Low |
| **Multi-node** | Production, HA | Medium |
| **Distributed** | Large scale, geo-distributed | High |

</details>

---

## Prerequisites

<details open>
<summary>Expand/Collapse</summary>

### D01 - Check Prerequisites

<details>
<summary>Requirements Checklist</summary>

**Kubernetes Cluster:**
- [ ] Kubernetes 1.23+
- [ ] kubectl configured
- [ ] Helm 3.10+
- [ ] Cluster admin access

**Resources:**
| Component | Min CPU | Min Memory | Storage |
|-----------|---------|------------|---------|
| Indexer (per node) | 2 cores | 4Gi | 50Gi |
| Manager Master | 1 core | 2Gi | 10Gi |
| Manager Worker | 1 core | 2Gi | 10Gi |
| Dashboard | 1 core | 2Gi | - |

**Storage:**
- [ ] StorageClass available
- [ ] PV provisioner configured
- [ ] Sufficient storage capacity

**Network:**
- [ ] Ingress controller (optional)
- [ ] LoadBalancer support (optional)
- [ ] DNS configured (optional)

**Verification commands:**
```bash
# Check Kubernetes version
kubectl version --short

# Check Helm version
helm version --short

# Check StorageClass
kubectl get storageclass

# Check cluster resources
kubectl top nodes
```

</details>

### D01.1 - Resource Verification

<details>
<summary>Verify Cluster Capacity</summary>

```bash
# Check available resources
kubectl describe nodes | grep -A 5 "Allocated resources"

# Check namespace resource quotas
kubectl describe resourcequota -n wazuh 2>/dev/null || echo "No quota set"

# Verify storage provisioner
kubectl get pods -n kube-system | grep -E "(csi|provisioner|storage)"
```

**Minimum cluster requirements:**
- 8 CPU cores total
- 16GB RAM total
- 100GB storage

</details>

</details>

---

## Preparation

<details open>
<summary>Expand/Collapse</summary>

### D02 - Prepare Environment

<details>
<summary>Namespace and Secrets</summary>

**Create namespace:**
```bash
kubectl create namespace wazuh
kubectl label namespace wazuh app=wazuh
```

**Create pull secret (if using private registry):**
```bash
kubectl create secret docker-registry wazuh-registry \
  --docker-server=registry.example.com \
  --docker-username=<user> \
  --docker-password=<password> \
  -n wazuh
```

</details>

### D02.1 - Certificate Preparation

<details>
<summary>TLS Certificates</summary>

**Option A: Let Helm generate certificates (default)**
```yaml
# values.yaml - certificates will be auto-generated
indexer:
  certs:
    enabled: true
```

**Option B: Provide existing certificates**
```bash
# Create secret with existing CA
kubectl create secret generic wazuh-root-ca \
  --from-file=root-ca.pem=./certs/root-ca.pem \
  --from-file=root-ca-key.pem=./certs/root-ca-key.pem \
  -n wazuh

# Reference in values.yaml
indexer:
  certs:
    existingSecret: wazuh-root-ca
```

**Option C: Use cert-manager**
```yaml
# ClusterIssuer for Wazuh
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: wazuh-ca-issuer
spec:
  selfSigned: {}
```

</details>

### D03 - Configure Values

<details>
<summary>values.yaml Configuration</summary>

**Minimal production values:**
```yaml
# values-production.yaml
global:
  storageClass: "ceph-block"  # Your StorageClass

indexer:
  replicas: 3
  resources:
    requests:
      memory: "4Gi"
      cpu: "2"
    limits:
      memory: "8Gi"
      cpu: "4"
  persistence:
    size: 100Gi

manager:
  master:
    replicas: 1
    resources:
      requests:
        memory: "2Gi"
        cpu: "1"
  worker:
    replicas: 2
    resources:
      requests:
        memory: "2Gi"
        cpu: "1"

dashboard:
  replicas: 1
  ingress:
    enabled: true
    hostname: wazuh.example.com
```

**Key configuration areas:**

| Section | Description |
|---------|-------------|
| `global` | Storage class, image settings |
| `indexer` | OpenSearch cluster config |
| `manager` | Wazuh manager settings |
| `dashboard` | UI and ingress |
| `notification` | Alert channels |

</details>

</details>

---

## Deployment

<details open>
<summary>Expand/Collapse</summary>

### D04 - Deploy with Helm

<details>
<summary>Installation Commands</summary>

**Add Helm repository:**
```bash
# If using remote repo
helm repo add wazuh https://your-repo.example.com
helm repo update
```

**Install from local chart:**
```bash
# Navigate to chart directory
cd charts/wazuh

# Install with custom values
helm upgrade --install wazuh . \
  --namespace wazuh \
  --create-namespace \
  -f values.yaml \
  -f values-production.yaml \
  --wait \
  --timeout 15m
```

**Monitor installation:**
```bash
# Watch pod creation
kubectl get pods -n wazuh -w

# View Helm release status
helm status wazuh -n wazuh
```

</details>

### D04.1 - Installation Options

<details>
<summary>Deployment Variations</summary>

**Development deployment:**
```bash
helm upgrade --install wazuh . \
  --namespace wazuh-dev \
  --set indexer.replicas=1 \
  --set manager.worker.replicas=0 \
  --set dashboard.replicas=1
```

**HA deployment:**
```bash
helm upgrade --install wazuh . \
  --namespace wazuh \
  -f values.yaml \
  -f values-ha.yaml \
  --set indexer.replicas=3 \
  --set manager.worker.replicas=2
```

**Air-gapped deployment:**
```bash
# Pre-pull images
helm template wazuh . | grep "image:" | sort -u

# Install with local registry
helm upgrade --install wazuh . \
  --namespace wazuh \
  --set global.imageRegistry=registry.internal.com
```

</details>

### D05 - Verify Deployment

<details>
<summary>Health Checks</summary>

**Check all pods are running:**
```bash
kubectl get pods -n wazuh -o wide

# Expected output (3-node indexer, 1 master, 2 workers):
# NAME                                    READY   STATUS
# wazuh-wazuh-helm-dashboard-xxx          1/1     Running
# wazuh-wazuh-helm-indexer-0              1/1     Running
# wazuh-wazuh-helm-indexer-1              1/1     Running
# wazuh-wazuh-helm-indexer-2              1/1     Running
# wazuh-wazuh-helm-manager-master-0       1/1     Running
# wazuh-wazuh-helm-manager-worker-0       1/1     Running
# wazuh-wazuh-helm-manager-worker-1       1/1     Running
```

**Check services:**
```bash
kubectl get svc -n wazuh

# Key services:
# wazuh-wazuh-helm-indexer      - OpenSearch (9200)
# wazuh-wazuh-helm-manager      - Agent registration (1514, 1515)
# wazuh-wazuh-helm-dashboard    - Web UI (5601)
```

**Check PVCs:**
```bash
kubectl get pvc -n wazuh

# All should be "Bound"
```

</details>

### D05.1 - Component Health

<details>
<summary>Verify Each Component</summary>

**Indexer cluster health:**
```bash
INDEXER_PASS=$(kubectl get secret -n wazuh wazuh-wazuh-helm-indexer-cred \
  -o jsonpath='{.data.INDEXER_PASSWORD}' | base64 -d)

kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS https://localhost:9200/_cluster/health | jq

# Expected: "status": "green", "number_of_nodes": 3
```

**Manager status:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/wazuh-control status

# All services should be "running"
```

**Dashboard access:**
```bash
# Port-forward for testing
kubectl port-forward -n wazuh svc/wazuh-wazuh-helm-dashboard 5601:5601

# Access: https://localhost:5601
# Default: admin / SecretPassword (from indexer secret)
```

**API health:**
```bash
API_PASS=$(kubectl get secret -n wazuh wazuh-wazuh-helm-api-cred \
  -o jsonpath='{.data.password}' | base64 -d)

kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS https://localhost:55000/ | jq
```

</details>

</details>

---

## Post-Deployment

<details open>
<summary>Expand/Collapse</summary>

### D06 - Post-Deployment Configuration

<details>
<summary>Initial Setup Tasks</summary>

**Configure index patterns:**
```bash
# Verify wazuh-alerts index exists
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS https://localhost:9200/_cat/indices/wazuh-*
```

**Enable alerting (if configured):**
```bash
# Check notification channels
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  https://localhost:9200/_plugins/_notifications/configs | jq '.config_list[].config.name'
```

**Test agent registration:**
```bash
# Get manager service IP
MANAGER_IP=$(kubectl get svc -n wazuh wazuh-wazuh-helm-manager -o jsonpath='{.spec.clusterIP}')

# Or external IP/hostname for external agents
kubectl get svc -n wazuh wazuh-wazuh-helm-manager
```

</details>

### D06.1 - Security Hardening

<details>
<summary>Post-Install Security</summary>

**Change default passwords:**
```bash
# Change indexer admin password
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -p 'NewPassword123!'

# Update secret
kubectl patch secret wazuh-wazuh-helm-indexer-cred -n wazuh \
  -p '{"data":{"INDEXER_PASSWORD":"'$(echo -n 'NewPassword123!' | base64)'"}}'
```

**Enable network policies:**
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: wazuh-default-deny
  namespace: wazuh
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

**Configure pod security:**
```bash
# Label namespace for pod security
kubectl label namespace wazuh pod-security.kubernetes.io/enforce=restricted
```

</details>

</details>

---

## Troubleshooting

<details>
<summary>Expand/Collapse</summary>

### TS1 - Common Deployment Issues

<details>
<summary>Issue Resolution</summary>

| Issue | Cause | Solution |
|-------|-------|----------|
| Pods stuck in Pending | Insufficient resources | Check node resources, PVC status |
| Indexer not forming cluster | Network/DNS issues | Check headless service, DNS |
| Manager can't connect to indexer | Certificate mismatch | Verify certs, check logs |
| Dashboard 502 errors | Indexer not ready | Wait for indexer green status |

**Debug commands:**
```bash
# Check pod events
kubectl describe pod <pod-name> -n wazuh

# Check logs
kubectl logs <pod-name> -n wazuh --tail=100

# Check PVC issues
kubectl describe pvc <pvc-name> -n wazuh
```

</details>

### TS2 - Rollback Procedure

<details>
<summary>How to Rollback</summary>

```bash
# List release history
helm history wazuh -n wazuh

# Rollback to previous version
helm rollback wazuh <revision> -n wazuh

# Verify rollback
kubectl get pods -n wazuh
helm status wazuh -n wazuh
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
| [Upgrade Runbook](upgrade.md) | Upgrade procedures |
| [Backup/Restore](backup-restore.md) | Backup procedures |
| [Scaling](scaling.md) | Scaling procedures |
| [Troubleshooting](../troubleshooting/common-issues.md) | Common issues |

### B. Checklist Summary

- [ ] Prerequisites verified
- [ ] Namespace created
- [ ] Certificates prepared
- [ ] values.yaml configured
- [ ] Helm install completed
- [ ] All pods running
- [ ] Cluster health green
- [ ] Dashboard accessible
- [ ] Security hardening applied

### C. Revision History

| Date | Version | Author | Changes |
|------|---------|--------|---------|
| 2024-02 | 1.0 | Platform Team | Initial version |

</details>
