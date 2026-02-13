# Wazuh Agent Management Runbook

Complete agent management procedures for the Wazuh Helm deployment on Kubernetes.

[[_TOC_]]

## Overview

<details open>
<summary>Expand/Collapse</summary>

```
┌──────────────────────────────────────────────────────────────┐
│                AGENT MANAGEMENT ARCHITECTURE                  │
└──────────────────────────────────────────────────────────────┘

    ┌─────────────────────────────────────────────────────┐
    │                    AGENTS                            │
    │                                                      │
    │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌─────────┐│
    │  │  Linux   │ │ Windows  │ │  macOS   │ │ Docker  ││
    │  │  Agents  │ │  Agents  │ │  Agents  │ │ Agents  ││
    │  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬────┘│
    └───────┼────────────┼────────────┼────────────┼─────┘
            │            │            │            │
            └────────────┴─────┬──────┴────────────┘
                               │
                               ▼
    ┌─────────────────────────────────────────────────────┐
    │              WAZUH MANAGER CLUSTER                   │
    │                                                      │
    │  ┌──────────────────────────────────────────────┐  │
    │  │              Load Balancer                    │  │
    │  │           (1514, 1515 ports)                  │  │
    │  └──────────────────────────────────────────────┘  │
    │           │                    │                    │
    │           ▼                    ▼                    │
    │  ┌──────────────┐    ┌──────────────────────────┐  │
    │  │   Master     │    │       Workers            │  │
    │  │   (config)   │    │  (agent connections)     │  │
    │  └──────────────┘    └──────────────────────────┘  │
    └─────────────────────────────────────────────────────┘
```

### Agent Lifecycle

| Phase | Description | Actions |
|-------|-------------|---------|
| **Registration** | Agent joins cluster | Auto or manual registration |
| **Active** | Agent sending events | Monitor, configure groups |
| **Disconnected** | Agent offline | Investigate, remediate |
| **Removed** | Agent deleted | Cleanup, re-register if needed |

</details>

---

## Agent Registration

<details open>
<summary>Expand/Collapse</summary>

### A01 - Get Manager Connection Info

<details>
<summary>Connection Details</summary>

**Get manager service endpoint:**
```bash
# Internal (within cluster)
MANAGER_SVC="wazuh-wazuh-helm-manager.wazuh.svc.cluster.local"

# External (LoadBalancer)
MANAGER_IP=$(kubectl get svc -n wazuh wazuh-wazuh-helm-manager \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Or NodePort
MANAGER_PORT=$(kubectl get svc -n wazuh wazuh-wazuh-helm-manager \
  -o jsonpath='{.spec.ports[?(@.name=="registration")].nodePort}')
```

**Get registration password:**
```bash
# Default registration password (if configured)
REGISTRATION_PASS=$(kubectl get secret -n wazuh wazuh-wazuh-helm-authd-pass \
  -o jsonpath='{.data.authd.pass}' | base64 -d 2>/dev/null || echo "not configured")
```

**Ports reference:**

| Port | Protocol | Purpose |
|------|----------|---------|
| 1514 | TCP | Agent event communication |
| 1515 | TCP | Agent registration (authd) |
| 1516 | TCP | Cluster communication |
| 55000 | TCP | Wazuh API |

</details>

### A02 - Auto Registration

<details>
<summary>Automatic Agent Registration</summary>

**Linux agent installation with auto-registration:**
```bash
# Download and install agent
curl -s https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.9.0-1_amd64.deb \
  -o wazuh-agent.deb

WAZUH_MANAGER="<MANAGER_IP>" \
WAZUH_REGISTRATION_SERVER="<MANAGER_IP>" \
WAZUH_AGENT_GROUP="default" \
WAZUH_AGENT_NAME="$(hostname)" \
dpkg -i wazuh-agent.deb

# Start agent
systemctl daemon-reload
systemctl enable wazuh-agent
systemctl start wazuh-agent
```

**Windows agent (PowerShell):**
```powershell
# Download agent
Invoke-WebRequest -Uri https://packages.wazuh.com/4.x/windows/wazuh-agent-4.9.0-1.msi `
  -OutFile wazuh-agent.msi

# Install with auto-registration
msiexec.exe /i wazuh-agent.msi /q `
  WAZUH_MANAGER="<MANAGER_IP>" `
  WAZUH_REGISTRATION_SERVER="<MANAGER_IP>" `
  WAZUH_AGENT_GROUP="windows" `
  WAZUH_AGENT_NAME="$env:COMPUTERNAME"

# Start service
NET START Wazuh
```

**Docker agent:**
```bash
docker run -d --name wazuh-agent \
  -e WAZUH_MANAGER="<MANAGER_IP>" \
  -e WAZUH_AGENT_GROUP="docker" \
  -e WAZUH_AGENT_NAME="docker-$(hostname)" \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  wazuh/wazuh-agent:4.9.0
```

</details>

### A03 - Manual Registration

<details>
<summary>Manual Agent Registration</summary>

**On the manager - add agent:**
```bash
kubectl exec -it -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/manage_agents -a <AGENT_NAME> -i <AGENT_IP>

# Or interactive mode
kubectl exec -it -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/manage_agents
```

**Extract agent key:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/manage_agents -e <AGENT_ID>
```

**On the agent - import key:**
```bash
# Linux
/var/ossec/bin/manage_agents -i <KEY_FROM_MANAGER>

# Then configure manager IP in ossec.conf
sed -i 's/<address>.*<\/address>/<address><MANAGER_IP><\/address>/' \
  /var/ossec/etc/ossec.conf

# Restart agent
systemctl restart wazuh-agent
```

</details>

### A04 - Kubernetes DaemonSet Agent

<details>
<summary>Deploy Agent as DaemonSet</summary>

**Agent DaemonSet manifest:**
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: wazuh-agent
  namespace: wazuh
spec:
  selector:
    matchLabels:
      app: wazuh-agent
  template:
    metadata:
      labels:
        app: wazuh-agent
    spec:
      containers:
      - name: wazuh-agent
        image: wazuh/wazuh-agent:4.9.0
        env:
        - name: WAZUH_MANAGER
          value: "wazuh-wazuh-helm-manager.wazuh.svc.cluster.local"
        - name: WAZUH_AGENT_GROUP
          value: "kubernetes"
        - name: WAZUH_AGENT_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        securityContext:
          privileged: true
        volumeMounts:
        - name: var-log
          mountPath: /var/log
          readOnly: true
        - name: etc-os-release
          mountPath: /etc/os-release
          readOnly: true
      volumes:
      - name: var-log
        hostPath:
          path: /var/log
      - name: etc-os-release
        hostPath:
          path: /etc/os-release
      tolerations:
      - operator: Exists
```

**Deploy DaemonSet:**
```bash
kubectl apply -f wazuh-agent-daemonset.yaml

# Verify agents registered
kubectl get pods -n wazuh -l app=wazuh-agent
```

</details>

</details>

---

## Agent Monitoring

<details open>
<summary>Expand/Collapse</summary>

### A05 - List Agents

<details>
<summary>View Agent Status</summary>

**List all agents:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/agent_control -l
```

**List with status:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/agent_control -l | head -50

# Output format:
# ID: 001, Name: web-server-01, IP: 192.168.1.10, Active
# ID: 002, Name: db-server-01, IP: 192.168.1.20, Disconnected
```

**Via API:**
```bash
API_PASS=$(kubectl get secret -n wazuh wazuh-wazuh-helm-api-cred \
  -o jsonpath='{.data.password}' | base64 -d)

kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  "https://localhost:55000/agents?select=id,name,status,ip&limit=50" | jq
```

**Agent count by status:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  "https://localhost:55000/agents/summary/status" | jq
```

</details>

### A06 - Agent Details

<details>
<summary>View Specific Agent</summary>

**Get agent details:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  "https://localhost:55000/agents/<AGENT_ID>" | jq
```

**Get agent configuration:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  "https://localhost:55000/agents/<AGENT_ID>/config/client/client" | jq
```

**Get agent OS info:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  "https://localhost:55000/syscollector/<AGENT_ID>/os" | jq
```

</details>

### A07 - Disconnected Agents

<details>
<summary>Handle Disconnected Agents</summary>

**List disconnected agents:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  "https://localhost:55000/agents?status=disconnected" | jq '.data.affected_items[] | {id, name, ip, disconnection_time}'
```

**Agents disconnected > 24 hours:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  "https://localhost:55000/agents?status=disconnected&older_than=1d" | jq
```

**Troubleshoot disconnected agent:**

| Check | Command on Agent |
|-------|------------------|
| Service status | `systemctl status wazuh-agent` |
| Agent logs | `tail -f /var/ossec/logs/ossec.log` |
| Network connectivity | `nc -zv <MANAGER_IP> 1514` |
| DNS resolution | `nslookup <MANAGER_HOSTNAME>` |
| Time sync | `timedatectl status` |

</details>

</details>

---

## Agent Groups

<details open>
<summary>Expand/Collapse</summary>

### A08 - Manage Groups

<details>
<summary>Group Operations</summary>

**List groups:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  "https://localhost:55000/groups" | jq '.data.affected_items[].name'
```

**Create group:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  -X POST "https://localhost:55000/groups" \
  -H "Content-Type: application/json" \
  -d '{"group_id": "webservers"}'
```

**Delete group:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  -X DELETE "https://localhost:55000/groups?groups_list=webservers"
```

</details>

### A09 - Assign Agents to Groups

<details>
<summary>Group Assignment</summary>

**Assign agent to group:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  -X PUT "https://localhost:55000/agents/<AGENT_ID>/group/webservers"
```

**Assign multiple agents:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  -X PUT "https://localhost:55000/agents/group" \
  -H "Content-Type: application/json" \
  -d '{
    "group_id": "webservers",
    "agents_list": ["001", "002", "003"]
  }'
```

**List agents in group:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  "https://localhost:55000/groups/webservers/agents" | jq '.data.affected_items[] | {id, name}'
```

**Remove agent from group:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  -X DELETE "https://localhost:55000/agents/<AGENT_ID>/group/webservers"
```

</details>

### A10 - Group Configuration

<details>
<summary>Configure Group Settings</summary>

**View group configuration:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  cat /var/ossec/etc/shared/webservers/agent.conf
```

**Update group configuration:**
```bash
# Create/update agent.conf for the group
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- bash -c 'cat > /var/ossec/etc/shared/webservers/agent.conf << EOF
<agent_config>
  <localfile>
    <log_format>apache</log_format>
    <location>/var/log/apache2/access.log</location>
  </localfile>
  <localfile>
    <log_format>apache</log_format>
    <location>/var/log/apache2/error.log</location>
  </localfile>
  <syscheck>
    <directories check_all="yes">/var/www/html</directories>
  </syscheck>
</agent_config>
EOF'

# Push configuration to agents
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/agent_groups -S -g webservers
```

</details>

</details>

---

## Agent Maintenance

<details open>
<summary>Expand/Collapse</summary>

### A11 - Restart Agents

<details>
<summary>Remote Agent Restart</summary>

**Restart single agent:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  -X PUT "https://localhost:55000/agents/<AGENT_ID>/restart"
```

**Restart multiple agents:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  -X PUT "https://localhost:55000/agents/restart" \
  -H "Content-Type: application/json" \
  -d '{"agents_list": ["001", "002", "003"]}'
```

**Restart all agents in group:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  -X PUT "https://localhost:55000/agents/group/webservers/restart"
```

</details>

### A12 - Remove Agents

<details>
<summary>Agent Removal</summary>

**Remove single agent:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  -X DELETE "https://localhost:55000/agents?agents_list=<AGENT_ID>&status=all"
```

**Remove disconnected agents older than 7 days:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  -X DELETE "https://localhost:55000/agents?older_than=7d&status=disconnected"
```

**Remove agents by CLI:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/manage_agents -r <AGENT_ID>
```

**Bulk remove (interactive):**
```bash
kubectl exec -it -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/manage_agents
# Select (R) to remove agents
```

</details>

### A13 - Agent Upgrade

<details>
<summary>Upgrade Agent Versions</summary>

**Check agent version:**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  "https://localhost:55000/agents?select=id,name,version" | jq '.data.affected_items[] | {id, name, version}'
```

**Upgrade single agent (via API):**
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  -X PUT "https://localhost:55000/agents/<AGENT_ID>/upgrade"
```

**Upgrade all outdated agents:**
```bash
# First, list outdated agents
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  "https://localhost:55000/agents/outdated" | jq

# Upgrade all
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  curl -sk -u wazuh-wui:$API_PASS \
  -X PUT "https://localhost:55000/agents/upgrade"
```

**Manual upgrade on agent:**
```bash
# Linux
apt-get update && apt-get install wazuh-agent -y
systemctl restart wazuh-agent

# Windows (PowerShell)
Invoke-WebRequest -Uri https://packages.wazuh.com/4.x/windows/wazuh-agent-4.9.0-1.msi -OutFile wazuh-agent.msi
msiexec.exe /i wazuh-agent.msi /q
NET STOP Wazuh && NET START Wazuh
```

</details>

</details>

---

## Troubleshooting

<details>
<summary>Expand/Collapse</summary>

### TS1 - Registration Issues

<details>
<summary>Common Registration Problems</summary>

| Issue | Cause | Solution |
|-------|-------|----------|
| Connection refused | Firewall | Open ports 1514, 1515 |
| Authentication error | Wrong password | Verify authd password |
| Certificate error | TLS mismatch | Verify CA certificate |
| Timeout | Network issue | Check routing/DNS |
| Agent already exists | Duplicate name | Remove old agent first |

**Debug registration:**
```bash
# On agent - check connectivity
nc -zv <MANAGER_IP> 1514
nc -zv <MANAGER_IP> 1515

# On manager - check authd
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  cat /var/ossec/logs/ossec.log | grep authd

# Test registration manually
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/agent-auth -m localhost -A test-agent
```

</details>

### TS2 - Connection Issues

<details>
<summary>Agent Connectivity Problems</summary>

**Check agent logs:**
```bash
# On agent
tail -f /var/ossec/logs/ossec.log
```

**Common errors and solutions:**

| Error | Cause | Solution |
|-------|-------|----------|
| "Disconnected from manager" | Network interruption | Check network path |
| "Invalid key" | Key mismatch | Re-register agent |
| "SSL error" | Certificate issue | Update CA on agent |
| "Queue full" | Events backing up | Check disk space |

**Manager-side diagnostics:**
```bash
# Check agent connection on manager
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  /var/ossec/bin/agent_control -i <AGENT_ID>

# Check manager logs for agent
kubectl exec -n wazuh wazuh-wazuh-helm-manager-master-0 -- \
  grep <AGENT_ID> /var/ossec/logs/ossec.log | tail -20
```

</details>

### TS3 - Performance Issues

<details>
<summary>Agent Performance Problems</summary>

**High CPU on agent:**
```bash
# Check what's running
top -p $(pgrep -d',' wazuh)

# Check log volume
ls -la /var/ossec/queue/ossec/

# Reduce log collection temporarily
# Edit /var/ossec/etc/ossec.conf
```

**Event backlog:**
```bash
# Check queue status
ls -la /var/ossec/queue/ossec/queue

# Clear old events (if necessary)
rm /var/ossec/queue/ossec/queue/*
systemctl restart wazuh-agent
```

</details>

</details>

---

## Appendix

<details>
<summary>Expand/Collapse</summary>

### A. Agent Ports Reference

| Port | Direction | Protocol | Purpose |
|------|-----------|----------|---------|
| 1514 | Agent → Manager | TCP | Event forwarding |
| 1515 | Agent → Manager | TCP | Registration |
| 514 | Systems → Agent | UDP | Syslog collection |

### B. Related Documentation

| Document | Description |
|----------|-------------|
| [Deployment Runbook](deployment.md) | Initial deployment |
| [Scaling Runbook](scaling.md) | Scale manager workers |
| [Troubleshooting](../troubleshooting/common-issues.md) | Common issues |

### C. Agent Management Checklist

**New agent deployment:**
- [ ] Manager connectivity verified
- [ ] Registration successful
- [ ] Agent appears in dashboard
- [ ] Events being received
- [ ] Assigned to correct group

**Regular maintenance:**
- [ ] Check for disconnected agents
- [ ] Review agent versions
- [ ] Clean up removed systems
- [ ] Verify group configurations

### D. Revision History

| Date | Version | Author | Changes |
|------|---------|--------|---------|
| 2024-02 | 1.0 | Platform Team | Initial version |

</details>
