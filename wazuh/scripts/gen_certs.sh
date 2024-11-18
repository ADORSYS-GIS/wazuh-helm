#!/bin/bash

set -ex

# Check if folder argument is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <output-folder>"
  exit 1
fi

OUTPUT_FOLDER="\$1"

# Create the folder if it doesn't exist
mkdir -p "$OUTPUT_FOLDER"

# Generate Root CA
echo "Root CA"
openssl genrsa -out "$OUTPUT_FOLDER/root-ca-key.pem" 2048
openssl req -days 3650 -new -x509 -sha256 \
  -key "$OUTPUT_FOLDER/root-ca-key.pem" \
  -out "$OUTPUT_FOLDER/root-ca.pem" \
  -subj "/C=DE/L=Bayern/O=Adorsys/CN=root-ca"

# Function to generate certificates for different contexts
generate_cert() {
  local CONTEXT=$1
  shift
  local DOMAINS=("$@")

  echo "* Generating certificate for context: $CONTEXT"

  # Generate a private key
  echo "create: ${CONTEXT}-key-temp.pem"
  openssl genrsa -out "${CONTEXT}-key-temp.pem" 2048

  echo "create: ${CONTEXT}-key.pem"
  openssl pkcs8 -inform PEM -outform PEM \
    -in "$OUTPUT_FOLDER/${CONTEXT}-key-temp.pem" \
    -topk8 -nocrypt -v1 PBE-SHA1-3DES \
    -out "$OUTPUT_FOLDER/${CONTEXT}-key.pem"

  echo "create: $OUTPUT_FOLDER/${CONTEXT}.csr"

  # Use OpenSSL to generate the CSR directly from stdin
  openssl req -new -days 3650 -key "$OUTPUT_FOLDER/${CONTEXT}-key.pem" -out "$OUTPUT_FOLDER/${CONTEXT}.csr" -config <(
    cat <<EOL
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
C = DE
L = Bayern
O = Adorsys
CN = ${DOMAINS[0]}

[req_ext]
subjectAltName = @alt_names

[alt_names]
EOL
    for i in "${!DOMAINS[@]}"; do
      echo "DNS.$((i + 1)) = ${DOMAINS[$i]}"
    done
  )

  echo "create: $OUTPUT_FOLDER/${CONTEXT}.pem"
  openssl x509 -req -days 3650 \
    -in "$OUTPUT_FOLDER/${CONTEXT}.csr" \
    -CA "$OUTPUT_FOLDER/root-ca.pem" \
    -CAkey "$OUTPUT_FOLDER/root-ca-key.pem" \
    -CAcreateserial -sha256 \
    -out "$OUTPUT_FOLDER/${CONTEXT}.pem"

  echo "Certificate for '$OUTPUT_FOLDER/${CONTEXT}' created: '$OUTPUT_FOLDER/${CONTEXT}.pem'"
}