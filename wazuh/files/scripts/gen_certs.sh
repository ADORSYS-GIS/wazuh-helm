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
  openssl genrsa -out "$OUTPUT_FOLDER/${CONTEXT}-key-temp.pem" 2048

  echo "create: ${CONTEXT}-key.pem"
  openssl pkcs8 -inform PEM -outform PEM \
    -in "$OUTPUT_FOLDER/${CONTEXT}-key-temp.pem" \
    -topk8 -nocrypt -v1 PBE-SHA1-3DES \
    -out "$OUTPUT_FOLDER/${CONTEXT}-key.pem"

  echo "create: $OUTPUT_FOLDER/${CONTEXT}.csr"
  CERT_CONFIG="$OUTPUT_FOLDER/openssl-san.${CONTEXT}.cnf"

  # Create an OpenSSL configuration file for SAN
  echo "Creating configuration file: '$CERT_CONFIG'"
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
CN = ${DOMAINS[0]}

[req_ext]
subjectAltName = @alt_names

[alt_names]
EOL

  # Append SAN entries
  for i in "${!DOMAINS[@]}"; do
    echo "DNS.$((i + 1)) = ${DOMAINS[$i]}" >> "$CERT_CONFIG"
  done

  # Use the configuration file to generate the CSR
  openssl req -new -days 3650 -key "$OUTPUT_FOLDER/${CONTEXT}-key.pem" -out "$OUTPUT_FOLDER/${CONTEXT}.csr" -config "$CERT_CONFIG"

  echo "create: $OUTPUT_FOLDER/${CONTEXT}.pem"
  openssl x509 -req -days 3650 \
    -in "$OUTPUT_FOLDER/${CONTEXT}.csr" \
    -CA "$OUTPUT_FOLDER/root-ca.pem" \
    -CAkey "$OUTPUT_FOLDER/root-ca-key.pem" \
    -CAcreateserial -sha256 \
    -out "$OUTPUT_FOLDER/${CONTEXT}.pem"

  echo "Certificate for '$OUTPUT_FOLDER/${CONTEXT}' created: '$OUTPUT_FOLDER/${CONTEXT}.pem'"

  rm "$OUTPUT_FOLDER/${CONTEXT}-key-temp.pem"
  rm "$OUTPUT_FOLDER/${CONTEXT}.csr"
}