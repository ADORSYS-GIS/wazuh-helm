#!/bin/bash
#
# Wazuh Agent Registration Script
# Registers an agent and syncs keys to all worker nodes
#
# Usage: ./register-agent.sh <agent-name> [namespace]
#
set -e

AGENT_NAME=$1
NAMESPACE=${2:-wazuh}

if [ -z "$AGENT_NAME" ]; then
    echo "Usage: $0 <agent-name> [namespace]"
    echo ""
    echo "Examples:"
    echo "  $0 MyWindowsPC"
    echo "  $0 LinuxServer wazuh"
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== Wazuh Agent Registration ===${NC}"
echo "Agent Name: $AGENT_NAME"
echo "Namespace: $NAMESPACE"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}ERROR: kubectl is not installed${NC}"
    exit 1
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo -e "${RED}ERROR: jq is not installed. Please install it first.${NC}"
    exit 1
fi

# Check if namespace exists
if ! kubectl get namespace $NAMESPACE &> /dev/null; then
    echo -e "${RED}ERROR: Namespace '$NAMESPACE' does not exist${NC}"
    exit 1
fi

# Get API credentials
echo -e "${YELLOW}Fetching API credentials...${NC}"
API_USER=$(kubectl get secret wazuh-wazuh-helm-api-cred -n $NAMESPACE -o jsonpath='{.data.API_USERNAME}' | base64 -d)
API_PASS=$(kubectl get secret wazuh-wazuh-helm-api-cred -n $NAMESPACE -o jsonpath='{.data.API_PASSWORD}' | base64 -d)

if [ -z "$API_USER" ] || [ -z "$API_PASS" ]; then
    echo -e "${RED}ERROR: Could not retrieve API credentials${NC}"
    exit 1
fi

echo -e "${GREEN}API credentials retrieved${NC}"
echo ""

# Register agent via API
echo -e "${YELLOW}Registering agent: $AGENT_NAME${NC}"
RESULT=$(kubectl exec -n $NAMESPACE wazuh-wazuh-helm-manager-master-0 -- bash -c "
  TOKEN=\$(curl -s -u $API_USER:$API_PASS -k -X POST 'https://localhost:55000/security/user/authenticate?raw=true')
  curl -s -k -X POST 'https://localhost:55000/agents' \
    -H \"Authorization: Bearer \$TOKEN\" \
    -H 'Content-Type: application/json' \
    -d '{\"name\":\"$AGENT_NAME\",\"ip\":\"any\"}'
" 2>/dev/null)

# Check for errors
ERROR=$(echo "$RESULT" | jq -r '.error // empty')
if [ "$ERROR" != "0" ] && [ -n "$ERROR" ]; then
    echo -e "${RED}ERROR: Failed to register agent${NC}"
    echo "$RESULT" | jq .
    exit 1
fi

AGENT_ID=$(echo "$RESULT" | jq -r '.data.id')
AGENT_KEY=$(echo "$RESULT" | jq -r '.data.key')

if [ "$AGENT_ID" == "null" ] || [ -z "$AGENT_ID" ]; then
    echo -e "${RED}ERROR: Failed to register agent${NC}"
    echo "$RESULT" | jq .
    exit 1
fi

echo -e "${GREEN}Agent registered successfully${NC}"
echo "  ID: $AGENT_ID"
echo ""

# Assign to default group
echo -e "${YELLOW}Assigning agent to default group...${NC}"
GROUP_RESULT=$(kubectl exec -n $NAMESPACE wazuh-wazuh-helm-manager-master-0 -- bash -c "
  TOKEN=\$(curl -s -u $API_USER:$API_PASS -k -X POST 'https://localhost:55000/security/user/authenticate?raw=true')
  curl -s -k -X PUT 'https://localhost:55000/agents/$AGENT_ID/group/default' \
    -H \"Authorization: Bearer \$TOKEN\"
" 2>/dev/null)

echo -e "${GREEN}Agent assigned to default group${NC}"
echo ""

# Sync keys to workers
echo -e "${YELLOW}Syncing keys to worker nodes...${NC}"
KEYS=$(kubectl exec -n $NAMESPACE wazuh-wazuh-helm-manager-master-0 -- cat /var/ossec/etc/client.keys 2>/dev/null)

# Get list of worker pods
WORKERS=$(kubectl get pods -n $NAMESPACE -l node-type=worker -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

if [ -z "$WORKERS" ]; then
    echo -e "${YELLOW}No worker pods found, checking for worker-0 and worker-1...${NC}"
    WORKERS="wazuh-wazuh-helm-manager-worker-0 wazuh-wazuh-helm-manager-worker-1"
fi

for WORKER in $WORKERS; do
    echo "  Syncing to $WORKER..."
    kubectl exec -n $NAMESPACE $WORKER -i -- bash -c "cat > /var/ossec/etc/client.keys" <<< "$KEYS" 2>/dev/null || echo "    Warning: Could not sync to $WORKER"
done

echo -e "${GREEN}Keys synced to all workers${NC}"
echo ""

# Get worker service IP
WORKER_IP=$(kubectl get svc -n $NAMESPACE wazuh-wazuh-helm-worker -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [ -z "$WORKER_IP" ]; then
    WORKER_IP=$(kubectl get svc -n $NAMESPACE wazuh-wazuh-helm-worker -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
fi

# Decode the key
DECODED_KEY=$(echo "$AGENT_KEY" | base64 -d 2>/dev/null || echo "$AGENT_KEY" | base64 -D 2>/dev/null)

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}       REGISTRATION COMPLETE           ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Agent ID:   ${YELLOW}$AGENT_ID${NC}"
echo -e "Agent Name: ${YELLOW}$AGENT_NAME${NC}"
echo -e "Manager IP: ${YELLOW}$WORKER_IP${NC}"
echo ""
echo -e "${YELLOW}Base64 Key:${NC}"
echo "$AGENT_KEY"
echo ""
echo -e "${YELLOW}Decoded Key:${NC}"
echo "$DECODED_KEY"
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}       INSTALLATION COMMANDS           ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Windows (PowerShell as Admin):${NC}"
echo "----------------------------------------"
cat << EOF
# Option 1: MSI with parameters
msiexec.exe /i wazuh-agent-4.13.1-1.msi /q WAZUH_MANAGER="$WORKER_IP" WAZUH_AGENT_NAME="$AGENT_NAME" WAZUH_AGENT_KEY="$AGENT_KEY"

# Option 2: Manual configuration after installation
Stop-Service WazuhSvc
Set-Content -Path "C:\Program Files (x86)\ossec-agent\client.keys" -Value "$DECODED_KEY"
\$config = Get-Content "C:\Program Files (x86)\ossec-agent\ossec.conf" -Raw
\$config = \$config -replace '<address>[^<]+</address>', '<address>$WORKER_IP</address>'
\$config = \$config -replace '<auto_enrollment>[^<]*</auto_enrollment>', '<auto_enrollment>no</auto_enrollment>'
Set-Content -Path "C:\Program Files (x86)\ossec-agent\ossec.conf" -Value \$config
Start-Service WazuhSvc
EOF
echo ""
echo -e "${YELLOW}Linux:${NC}"
echo "----------------------------------------"
cat << EOF
# After installing wazuh-agent package:
systemctl stop wazuh-agent
echo "$DECODED_KEY" > /var/ossec/etc/client.keys
chmod 640 /var/ossec/etc/client.keys
chown root:wazuh /var/ossec/etc/client.keys
sed -i 's/<address>.*<\/address>/<address>$WORKER_IP<\/address>/' /var/ossec/etc/ossec.conf
sed -i 's/<auto_enrollment>yes<\/auto_enrollment>/<auto_enrollment>no<\/auto_enrollment>/' /var/ossec/etc/ossec.conf
systemctl start wazuh-agent
EOF
echo ""
