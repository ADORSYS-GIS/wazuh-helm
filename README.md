# Wazuh Helm chart

To use this chart, you need to have first a root CA.
To create one you can use the following commands:
```shell
OUTPUT_FOLDER="wazuh-certs" # Modify this to your needs
echo "Generating Root CA"
openssl genrsa -out "$OUTPUT_FOLDER/root-ca-key.pem" 2048
openssl req -days 3650 -new -x509 -sha256 \
    -key "$OUTPUT_FOLDER/root-ca-key.pem" \
    -out "$OUTPUT_FOLDER/root-ca.pem" \
    -subj "/C=DE/L=Bayern/O=Adorsys/CN=root-ca"
```

This will generate a root CA that you can use to sign
the certificates for the Wazuh components.

Then create a secret with the root CA:
```shell
NAMESPACE="wazuh" # Modify this to your needs
ROOT_SECRET_NAME="wazuh-root-ca" # Modify this to your needs
kubectl -n $NAMESPACE create secret generic $ROOT_SECRET_NAME \
    --from-file="root-ca.pem"="$OUTPUT_FOLDER/root-ca.pem" \
    --from-file="root-ca-key.pem"="$OUTPUT_FOLDER/root-ca-key.pem"
```