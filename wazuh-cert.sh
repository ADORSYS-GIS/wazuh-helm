#!/bin/bash
set -euo pipefail

# Usage: ./generate-wazuh-cert.sh <output-folder> <agent-name>
# Example: ./generate-wazuh-cert.sh /var/ossec/etc desmond-agent-02

OUTPUT_FOLDER="$1"
AGENT_NAME="$2"

# Check CA folder
if [ -z "${ROOT_CA_FOLDER:-}" ]; then
  echo "Please set ROOT_CA_FOLDER environment variable pointing to your root CA folder"
  exit 1
fi

mkdir -p "$OUTPUT_FOLDER"

echo "* Generating Wazuh agent certificate for: $AGENT_NAME"

# Generate private key (4096 bits)
openssl genrsa -out "$OUTPUT_FOLDER/sslagent.key" 4096

# Generate CSR
openssl req -new -key "$OUTPUT_FOLDER/sslagent.key" \
  -subj "/C=DE/L=Bayern/O=Adorsys/CN=$AGENT_NAME" \
  -out "$OUTPUT_FOLDER/sslagent.csr"

# Sign CSR with root CA and include clientAuth usage
openssl x509 -req -days 3650 \
  -in "$OUTPUT_FOLDER/sslagent.csr" \
  -CA "$ROOT_CA_FOLDER/root-ca.pem" \
  -CAkey "$ROOT_CA_FOLDER/root-ca-key.pem" \
  -CAcreateserial -sha256 \
  -extfile <(printf "extendedKeyUsage=clientAuth\nsubjectAltName=DNS:$AGENT_NAME") \
  -out "$OUTPUT_FOLDER/sslagent.cert"

# Secure permissions
chown root:wazuh "$OUTPUT_FOLDER/sslagent."*
chmod 640 "$OUTPUT_FOLDER/sslagent."*

echo "✅ Certificate and key created in $OUTPUT_FOLDER"
echo "   - sslagent.key"
echo "   - sslagent.cert"
echo "   - sslagent.csr (safe to delete after enrollment)"
