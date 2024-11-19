#!/bin/bash

set -e

# Check if folder argument is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <output-folder>"
  exit 1
fi

OUTPUT_FOLDER="$1"

# Create the folder if it doesn't exist
mkdir -p "$OUTPUT_FOLDER"

# Generate Root CA
echo "Generating Root CA"
openssl genrsa -out "$OUTPUT_FOLDER/root-ca-key.pem" 2048
openssl req -days 3650 -new -x509 -sha256 \
  -key "$OUTPUT_FOLDER/root-ca-key.pem" \
  -out "$OUTPUT_FOLDER/root-ca.pem" \
  -subj "/C=DE/L=Bayern/O=Adorsys/CN=root-ca"

# Function to generate certificates for different contexts
generate_cert() {
  local CONTEXT=$1
  local DOMAINS_FILE="$2"

  echo "* Generating certificate for context: $CONTEXT"

  # Read domains from file or command-line arguments
  if [ -f "$DOMAINS_FILE" ]; then
    DOMAINS=$(cat "$DOMAINS_FILE")
  else
    DOMAINS="$2"
  fi

  # Split domains into an array
  IFS=',' read -ra DOMAINS_ARRAY <<< "$DOMAINS"

  # Generate a private key
  openssl genrsa -out "$OUTPUT_FOLDER/${CONTEXT}-key.pem" 2048

  # Create an OpenSSL configuration file for SAN
  CERT_CONFIG="$OUTPUT_FOLDER/openssl-san.${CONTEXT}.cnf"
  cat > "$CERT_CONFIG" <<EOL
[req]
default_bits = 2048
x509_extensions = v3_ca
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
C = DE
L = Bayern
O = Adorsys
CN = ${DOMAINS_ARRAY[0]}

[req_ext]
subjectAltName = @alt_names

[alt_names]
EOL

  # Append SAN entries
  for i in "${!DOMAINS_ARRAY[@]}"; do
    echo "DNS.$((i + 1)) = ${DOMAINS_ARRAY[$i]}" >> "$CERT_CONFIG"
  done

  # Generate the CSR
  openssl req -new -days 3650 -key "$OUTPUT_FOLDER/${CONTEXT}-key.pem" -out "$OUTPUT_FOLDER/${CONTEXT}.csr" -config "$CERT_CONFIG"

  # Sign the CSR
  openssl x509 -req -days 3650 \
    -in "$OUTPUT_FOLDER/${CONTEXT}.csr" \
    -CA "$OUTPUT_FOLDER/root-ca.pem" \
    -CAkey "$OUTPUT_FOLDER/root-ca-key.pem" \
    -CAcreateserial -sha256 \
    -out "$OUTPUT_FOLDER/${CONTEXT}.pem"

  echo "Certificate for '$OUTPUT_FOLDER/${CONTEXT}' created: '$OUTPUT_FOLDER/${CONTEXT}.pem'"

  rm "$OUTPUT_FOLDER/${CONTEXT}.csr"
  rm "$CERT_CONFIG"
}