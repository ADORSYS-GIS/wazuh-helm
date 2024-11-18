#!/usr/bin/env bash

set -ex

# Generate Root CA
echo "Root CA"
openssl genrsa -out root-ca-key.pem 2048
openssl req -days 3650 -new -x509 -sha256 -key root-ca-key.pem -out root-ca.pem -subj "/C=DE/L=Bayern/O=Adorsys/CN=root-ca"

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
  openssl pkcs8 -inform PEM -outform PEM -in "${CONTEXT}-key-temp.pem" -topk8 -nocrypt -v1 PBE-SHA1-3DES -out "${CONTEXT}-key.pem"

  echo "create: ${CONTEXT}.csr"

  # Use OpenSSL to generate the CSR directly from stdin
  openssl req -new -days 3650 -key "${CONTEXT}-key.pem" -out "${CONTEXT}.csr" -config <(
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

  echo "create: ${CONTEXT}.pem"
  openssl x509 -req -days 3650 -in "${CONTEXT}.csr" -CA root-ca.pem -CAkey root-ca-key.pem -CAcreateserial -sha256 -out "${CONTEXT}.pem"

  echo "Certificate for ${CONTEXT} created: ${CONTEXT}.pem"
}