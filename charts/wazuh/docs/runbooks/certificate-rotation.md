# Wazuh Certificate Rotation Runbook

Complete certificate rotation procedures for the Wazuh Helm deployment on Kubernetes.

[[_TOC_]]

## Overview

<details open>
<summary>Expand/Collapse</summary>

```
┌──────────────────────────────────────────────────────────────┐
│               CERTIFICATE ARCHITECTURE                        │
└──────────────────────────────────────────────────────────────┘

    ┌─────────────────────────────────────────────────────┐
    │                    ROOT CA                           │
    │              (wazuh-root-ca secret)                  │
    │                                                      │
    │  root-ca.pem           root-ca-key.pem              │
    └──────────────────────┬──────────────────────────────┘
                           │
           ┌───────────────┼───────────────┐
           │               │               │
           ▼               ▼               ▼
    ┌────────────┐  ┌────────────┐  ┌────────────┐
    │  Indexer   │  │  Manager   │  │ Dashboard  │
    │   Certs    │  │   Certs    │  │   Certs    │
    │            │  │            │  │            │
    │ - node     │  │ - server   │  │ - server   │
    │ - admin    │  │ - filebeat │  │            │
    │ - transport│  │            │  │            │
    └────────────┘  └────────────┘  └────────────┘
```

### Certificate Types

| Certificate | Purpose | Location | Validity |
|-------------|---------|----------|----------|
| **Root CA** | Trust anchor | Secret: wazuh-root-ca | 10 years |
| **Indexer Node** | TLS for indexer | Secret: indexer-certs | 1 year |
| **Indexer Admin** | Admin operations | Secret: indexer-certs | 1 year |
| **Indexer Transport** | Node-to-node | Secret: indexer-certs | 1 year |
| **Manager** | Filebeat to indexer | Secret: manager-certs | 1 year |
| **Dashboard** | HTTPS UI | Secret: dashboard-certs | 1 year |

</details>

---

## Pre-Rotation Checks

<details open>
<summary>Expand/Collapse</summary>

### C01 - Check Certificate Expiry

<details>
<summary>View Current Certificates</summary>

**Check indexer certificates:**
```bash
# Get certificate from pod
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  openssl x509 -in /usr/share/wazuh-indexer/certs/node.pem -noout -dates

# Expected output:
# notBefore=Feb 15 00:00:00 2024 GMT
# notAfter=Feb 15 00:00:00 2025 GMT
```

**Check all certificate expiry dates:**
```bash
# Indexer node cert
echo "=== Indexer Node Cert ==="
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  openssl x509 -in /usr/share/wazuh-indexer/certs/node.pem -noout -enddate

# Indexer admin cert
echo "=== Indexer Admin Cert ==="
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  openssl x509 -in /usr/share/wazuh-indexer/certs/admin.pem -noout -enddate

# Root CA
echo "=== Root CA ==="
kubectl get secret wazuh-root-ca -n wazuh -o jsonpath='{.data.root-ca\.pem}' | \
  base64 -d | openssl x509 -noout -enddate
```

**Check days until expiry:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  openssl x509 -in /usr/share/wazuh-indexer/certs/node.pem -noout -checkend 2592000

# Exit code 0 = valid for more than 30 days
# Exit code 1 = expires within 30 days
```

</details>

### C02 - Pre-Rotation Backup

<details>
<summary>Backup Current Certificates</summary>

**CRITICAL: Always backup before rotation**

```bash
# Create backup directory
mkdir -p ./cert-backups/$(date +%Y%m%d)

# Backup all certificate secrets
kubectl get secret wazuh-root-ca -n wazuh -o yaml > \
  ./cert-backups/$(date +%Y%m%d)/wazuh-root-ca.yaml

kubectl get secret wazuh-wazuh-helm-indexer-certs -n wazuh -o yaml > \
  ./cert-backups/$(date +%Y%m%d)/indexer-certs.yaml

kubectl get secret wazuh-wazuh-helm-manager-certs -n wazuh -o yaml > \
  ./cert-backups/$(date +%Y%m%d)/manager-certs.yaml

kubectl get secret wazuh-wazuh-helm-dashboard-certs -n wazuh -o yaml > \
  ./cert-backups/$(date +%Y%m%d)/dashboard-certs.yaml

# Encrypt backup
tar -czf cert-backup-$(date +%Y%m%d).tar.gz ./cert-backups/$(date +%Y%m%d)
gpg --symmetric --cipher-algo AES256 cert-backup-$(date +%Y%m%d).tar.gz
```

</details>

### C03 - Verify Cluster Health

<details>
<summary>Pre-Rotation Health Check</summary>

**Ensure cluster is healthy before rotation:**

```bash
# Indexer cluster health
INDEXER_PASS=$(kubectl get secret -n wazuh wazuh-wazuh-helm-indexer-cred \
  -o jsonpath='{.data.INDEXER_PASSWORD}' | base64 -d)

kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS https://localhost:9200/_cluster/health | jq

# All pods running
kubectl get pods -n wazuh

# No pending operations
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  "https://localhost:9200/_cluster/pending_tasks" | jq
```

**Pre-rotation checklist:**
- [ ] Cluster status: GREEN
- [ ] All pods: Running
- [ ] Backups: Completed
- [ ] Maintenance window: Scheduled

</details>

</details>

---

## Certificate Rotation Methods

<details open>
<summary>Expand/Collapse</summary>

### C04 - Method 1: Helm Chart Regeneration

<details>
<summary>Let Helm Regenerate Certificates</summary>

**This is the simplest method if using Helm-managed certificates.**

**Step 1: Delete existing certificate secrets**
```bash
# Delete leaf certificates (NOT the root CA)
kubectl delete secret wazuh-wazuh-helm-indexer-certs -n wazuh
kubectl delete secret wazuh-wazuh-helm-manager-certs -n wazuh
kubectl delete secret wazuh-wazuh-helm-dashboard-certs -n wazuh
```

**Step 2: Upgrade Helm release**
```bash
helm upgrade wazuh ./charts/wazuh \
  --namespace wazuh \
  -f values.yaml \
  --set indexer.certs.enabled=true \
  --wait
```

**Step 3: Rolling restart all components**
```bash
kubectl rollout restart statefulset/wazuh-wazuh-helm-indexer -n wazuh
kubectl rollout restart statefulset/wazuh-wazuh-helm-manager-master -n wazuh
kubectl rollout restart statefulset/wazuh-wazuh-helm-manager-worker -n wazuh
kubectl rollout restart deployment/wazuh-wazuh-helm-dashboard -n wazuh
```

**Step 4: Verify new certificates**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  openssl x509 -in /usr/share/wazuh-indexer/certs/node.pem -noout -dates
```

</details>

### C05 - Method 2: Manual Certificate Generation

<details>
<summary>Generate Certificates Manually</summary>

**Use when you need custom SANs or specific certificate attributes.**

**Step 1: Generate new certificates using OpenSSL**
```bash
# Create working directory
mkdir -p ./new-certs && cd ./new-certs

# Extract existing Root CA (or generate new one)
kubectl get secret wazuh-root-ca -n wazuh -o jsonpath='{.data.root-ca\.pem}' | \
  base64 -d > root-ca.pem
kubectl get secret wazuh-root-ca -n wazuh -o jsonpath='{.data.root-ca-key\.pem}' | \
  base64 -d > root-ca-key.pem

# Generate indexer node certificate
openssl genrsa -out indexer-key.pem 2048

openssl req -new -key indexer-key.pem -out indexer.csr \
  -subj "/C=US/ST=CA/L=SF/O=Wazuh/OU=Indexer/CN=wazuh-indexer"

cat > indexer-ext.cnf << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=@alt_names

[alt_names]
DNS.1=wazuh-wazuh-helm-indexer
DNS.2=wazuh-wazuh-helm-indexer.wazuh.svc.cluster.local
DNS.3=*.wazuh-wazuh-helm-indexer-headless.wazuh.svc.cluster.local
DNS.4=localhost
IP.1=127.0.0.1
EOF

openssl x509 -req -in indexer.csr -CA root-ca.pem -CAkey root-ca-key.pem \
  -CAcreateserial -out indexer.pem -days 365 -extfile indexer-ext.cnf
```

**Step 2: Create Kubernetes secret**
```bash
kubectl create secret generic wazuh-wazuh-helm-indexer-certs \
  --from-file=node.pem=indexer.pem \
  --from-file=node-key.pem=indexer-key.pem \
  --from-file=root-ca.pem=root-ca.pem \
  --from-file=admin.pem=admin.pem \
  --from-file=admin-key.pem=admin-key.pem \
  -n wazuh \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Step 3: Restart components**
```bash
kubectl rollout restart statefulset/wazuh-wazuh-helm-indexer -n wazuh
kubectl rollout status statefulset/wazuh-wazuh-helm-indexer -n wazuh
```

</details>

### C06 - Method 3: cert-manager Integration

<details>
<summary>Use cert-manager for Automatic Rotation</summary>

**Best for automated certificate lifecycle management.**

**Step 1: Create Issuer**
```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: wazuh-ca-issuer
  namespace: wazuh
spec:
  ca:
    secretName: wazuh-root-ca
```

**Step 2: Create Certificate resources**
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wazuh-indexer-cert
  namespace: wazuh
spec:
  secretName: wazuh-wazuh-helm-indexer-certs
  duration: 8760h  # 1 year
  renewBefore: 720h  # Renew 30 days before expiry
  subject:
    organizations:
      - Wazuh
  isCA: false
  privateKey:
    algorithm: RSA
    size: 2048
  usages:
    - server auth
    - client auth
  dnsNames:
    - wazuh-wazuh-helm-indexer
    - wazuh-wazuh-helm-indexer.wazuh.svc.cluster.local
    - "*.wazuh-wazuh-helm-indexer-headless.wazuh.svc.cluster.local"
    - localhost
  ipAddresses:
    - 127.0.0.1
  issuerRef:
    name: wazuh-ca-issuer
    kind: Issuer
```

**Step 3: Apply and verify**
```bash
kubectl apply -f wazuh-certificates.yaml

# Check certificate status
kubectl get certificates -n wazuh
kubectl describe certificate wazuh-indexer-cert -n wazuh
```

**cert-manager will automatically:**
- Renew certificates before expiry
- Update secrets with new certificates
- Trigger pod restarts (with reloader)

</details>

</details>

---

## Rotation Procedures

<details open>
<summary>Expand/Collapse</summary>

### C07 - Indexer Certificate Rotation

<details>
<summary>Step-by-Step Indexer Rotation</summary>

**IMPORTANT: Indexer requires special handling for cluster stability**

**Step 1: Put cluster in maintenance mode**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  -X PUT "https://localhost:9200/_cluster/settings" \
  -H "Content-Type: application/json" \
  -d '{
    "transient": {
      "cluster.routing.allocation.enable": "primaries"
    }
  }'
```

**Step 2: Update certificate secret**
```bash
# Using method from C04 or C05
kubectl delete secret wazuh-wazuh-helm-indexer-certs -n wazuh

# Helm will regenerate on upgrade
helm upgrade wazuh ./charts/wazuh -n wazuh -f values.yaml --wait
```

**Step 3: Rolling restart (one node at a time)**
```bash
# Restart each indexer node sequentially
for i in 0 1 2; do
  echo "Restarting indexer-$i..."
  kubectl delete pod wazuh-wazuh-helm-indexer-$i -n wazuh

  # Wait for pod to be ready
  kubectl wait --for=condition=ready pod/wazuh-wazuh-helm-indexer-$i \
    -n wazuh --timeout=300s

  # Wait for cluster to stabilize
  kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
    curl -sk -u admin:$INDEXER_PASS \
    "https://localhost:9200/_cluster/health?wait_for_status=green&timeout=2m"

  echo "Indexer-$i ready"
  sleep 30
done
```

**Step 4: Re-enable allocation**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS \
  -X PUT "https://localhost:9200/_cluster/settings" \
  -H "Content-Type: application/json" \
  -d '{
    "transient": {
      "cluster.routing.allocation.enable": null
    }
  }'
```

**Step 5: Verify**
```bash
# Check cluster health
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS https://localhost:9200/_cluster/health | jq

# Verify new certificate
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  openssl x509 -in /usr/share/wazuh-indexer/certs/node.pem -noout -dates
```

</details>

### C08 - Manager Certificate Rotation

<details>
<summary>Manager Certificate Rotation</summary>

**Step 1: Update secret**
```bash
kubectl delete secret wazuh-wazuh-helm-manager-certs -n wazuh
helm upgrade wazuh ./charts/wazuh -n wazuh -f values.yaml --wait
```

**Step 2: Restart manager pods**
```bash
kubectl rollout restart statefulset/wazuh-wazuh-helm-manager-master -n wazuh
kubectl rollout restart statefulset/wazuh-wazuh-helm-manager-worker -n wazuh

# Wait for rollout
kubectl rollout status statefulset/wazuh-wazuh-helm-manager-master -n wazuh
kubectl rollout status statefulset/wazuh-wazuh-helm-manager-worker -n wazuh
```

**Step 3: Verify Filebeat connection**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/filebeat test output

# Should show "talk to server... OK"
```

</details>

### C09 - Dashboard Certificate Rotation

<details>
<summary>Dashboard Certificate Rotation</summary>

**Step 1: Update secret**
```bash
kubectl delete secret wazuh-wazuh-helm-dashboard-certs -n wazuh
helm upgrade wazuh ./charts/wazuh -n wazuh -f values.yaml --wait
```

**Step 2: Restart dashboard**
```bash
kubectl rollout restart deployment/wazuh-wazuh-helm-dashboard -n wazuh
kubectl rollout status deployment/wazuh-wazuh-helm-dashboard -n wazuh
```

**Step 3: Verify HTTPS**
```bash
# Port forward and test
kubectl port-forward -n wazuh svc/wazuh-wazuh-helm-dashboard 5601:5601 &
curl -sk https://localhost:5601/api/status | jq '.status.overall.state'
```

</details>

### C10 - Root CA Rotation

<details>
<summary>Root CA Rotation (Major Operation)</summary>

**WARNING: Root CA rotation requires regenerating ALL certificates**

**This is a significant operation. Plan carefully.**

**Step 1: Generate new Root CA**
```bash
openssl genrsa -out new-root-ca-key.pem 4096

openssl req -x509 -new -nodes -key new-root-ca-key.pem \
  -sha256 -days 3650 -out new-root-ca.pem \
  -subj "/C=US/ST=CA/L=SF/O=Wazuh/OU=Security/CN=Wazuh Root CA"
```

**Step 2: Create transitional trust bundle**
```bash
# Combine old and new CA for transition period
cat root-ca.pem new-root-ca.pem > combined-ca.pem
```

**Step 3: Update Root CA secret**
```bash
kubectl create secret generic wazuh-root-ca \
  --from-file=root-ca.pem=new-root-ca.pem \
  --from-file=root-ca-key.pem=new-root-ca-key.pem \
  -n wazuh \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Step 4: Regenerate all leaf certificates**
```bash
# Delete all certificate secrets
kubectl delete secret wazuh-wazuh-helm-indexer-certs -n wazuh
kubectl delete secret wazuh-wazuh-helm-manager-certs -n wazuh
kubectl delete secret wazuh-wazuh-helm-dashboard-certs -n wazuh

# Helm upgrade to regenerate
helm upgrade wazuh ./charts/wazuh -n wazuh -f values.yaml --wait
```

**Step 5: Rolling restart ALL components**
```bash
kubectl rollout restart statefulset/wazuh-wazuh-helm-indexer -n wazuh
kubectl rollout restart statefulset/wazuh-wazuh-helm-manager-master -n wazuh
kubectl rollout restart statefulset/wazuh-wazuh-helm-manager-worker -n wazuh
kubectl rollout restart deployment/wazuh-wazuh-helm-dashboard -n wazuh
```

**Step 6: Update agents with new CA**
```bash
# Agents need the new Root CA to trust the manager
# Distribute new-root-ca.pem to all agents
# Location: /var/ossec/etc/rootCA.pem (Linux)
```

</details>

</details>

---

## Post-Rotation Verification

<details open>
<summary>Expand/Collapse</summary>

### C11 - Verification Checklist

<details>
<summary>Post-Rotation Checks</summary>

**Certificate verification:**
```bash
# Check all new certificates
echo "=== Indexer Node ===" && \
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  openssl x509 -in /usr/share/wazuh-indexer/certs/node.pem -noout -dates

echo "=== Manager ===" && \
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  openssl x509 -in /var/ossec/etc/sslmanager.cert -noout -dates 2>/dev/null || echo "Using default"
```

**Service connectivity:**
```bash
# Indexer API
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS https://localhost:9200/_cluster/health | jq '.status'

# Wazuh API
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS https://localhost:55000/ | jq '.data.title'

# Dashboard
kubectl exec -n wazuh deploy/wazuh-wazuh-helm-dashboard -- \
  curl -sk https://localhost:5601/api/status | jq '.status.overall.state'
```

**Agent connectivity:**
```bash
# Check agent count (should be same as before)
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/agent_control -l | grep -c "Active"
```

</details>

</details>

---

## Troubleshooting

<details>
<summary>Expand/Collapse</summary>

### TS1 - Certificate Issues

<details>
<summary>Common Certificate Problems</summary>

| Issue | Cause | Solution |
|-------|-------|----------|
| SSL handshake failed | Certificate mismatch | Verify CA chain |
| Certificate expired | Rotation overdue | Regenerate immediately |
| SAN mismatch | Wrong DNS/IP in cert | Regenerate with correct SANs |
| Permission denied | Wrong file permissions | Fix permissions (600 for keys) |

**Debug SSL issues:**
```bash
# Check certificate chain
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  openssl s_client -connect localhost:9200 -showcerts < /dev/null

# Verify certificate matches key
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- bash -c '
  openssl x509 -noout -modulus -in /usr/share/wazuh-indexer/certs/node.pem | md5sum
  openssl rsa -noout -modulus -in /usr/share/wazuh-indexer/certs/node-key.pem | md5sum
'
# Both should match
```

</details>

### TS2 - Rollback Procedure

<details>
<summary>Emergency Rollback</summary>

**If rotation fails, restore from backup:**

```bash
# Restore certificate secrets
kubectl apply -f ./cert-backups/YYYYMMDD/indexer-certs.yaml
kubectl apply -f ./cert-backups/YYYYMMDD/manager-certs.yaml
kubectl apply -f ./cert-backups/YYYYMMDD/dashboard-certs.yaml

# Restart all components
kubectl rollout restart statefulset/wazuh-wazuh-helm-indexer -n wazuh
kubectl rollout restart statefulset/wazuh-wazuh-helm-manager-master -n wazuh
kubectl rollout restart statefulset/wazuh-wazuh-helm-manager-worker -n wazuh
kubectl rollout restart deployment/wazuh-wazuh-helm-dashboard -n wazuh

# Verify restoration
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:$INDEXER_PASS https://localhost:9200/_cluster/health | jq
```

</details>

</details>

---

## Appendix

<details>
<summary>Expand/Collapse</summary>

### A. Certificate Paths Reference

| Component | Certificate Path | Key Path |
|-----------|------------------|----------|
| Indexer Node | /usr/share/wazuh-indexer/certs/node.pem | node-key.pem |
| Indexer Admin | /usr/share/wazuh-indexer/certs/admin.pem | admin-key.pem |
| Indexer Transport | /usr/share/wazuh-indexer/certs/transport.pem | transport-key.pem |
| Manager | /var/ossec/etc/sslmanager.cert | sslmanager.key |
| Filebeat | /etc/filebeat/certs/ | |
| Dashboard | /usr/share/wazuh-dashboard/certs/ | |

### B. Related Documentation

| Document | Description |
|----------|-------------|
| [Deployment Runbook](deployment.md) | Initial certificate setup |
| [Backup/Restore](backup-restore.md) | Certificate backup |
| [Troubleshooting](../troubleshooting/common-issues.md) | Common issues |

### C. Rotation Schedule

| Certificate | Validity | Rotation Schedule | Alert Threshold |
|-------------|----------|-------------------|-----------------|
| Root CA | 10 years | 8-9 years | 1 year before |
| Leaf certs | 1 year | 10-11 months | 30 days before |

### D. Revision History

| Date | Version | Author | Changes |
|------|---------|--------|---------|
| 2024-02 | 1.0 | Platform Team | Initial version |

</details>
