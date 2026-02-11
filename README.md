# Wazuh Helm chart

[![Helm Publish](https://github.com/ADORSYS-GIS/wazuh-helm/actions/workflows/helm-publish.yml/badge.svg)](https://github.com/ADORSYS-GIS/wazuh-helm/actions/workflows/helm-publish.yml) [![Build Docker image](https://github.com/ADORSYS-GIS/wazuh-helm/actions/workflows/build-envsubst.yml/badge.svg)](https://github.com/ADORSYS-GIS/wazuh-helm/actions/workflows/build-envsubst.yml)

## Cloud Integrations

This Helm chart supports comprehensive cloud security monitoring:

### AWS Integration
- CloudTrail logs
- AWS Config
- Security Hub alerts
- VPC Flow Logs
- GuardDuty findings

See [AWS integration guide](DEPLOY_AWS.md) for setup instructions.

### Azure Integration
- Azure Activity Logs
- Azure AD Audit Logs
- Microsoft Defender for Cloud alerts
- Application Insights
- AKS audit logs
- Azure SQL audit logs
- NSG flow logs

See [Azure deployment guide](DEPLOY_AZURE.md) and [Azure data sources guide](AZURE_DATA_SOURCES.md) for detailed setup instructions.

Use the interactive script to enable additional Azure data sources:
```bash
./enable-azure-datasources.sh
```

---

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

To create the namespace, use the following command:
```shell
NAMESPACE="wazuh" # Modify this to your needs
kubectl create namespace $NAMESPACE
```

```shell
kubectl create secret generic wazuh-wazuh-helm-github-cred \
    --namespace wazuh \
    --from-literal=GITHUB_ORG="skyengpro" \
    --from-literal=GITHUB_REPO="wazuh-alerts" \
    --from-literal=GITHUB_TOKEN=""
```