# Wazuh Indexer with S3 Snapshot Repository Support

Custom Docker image extending `wazuh/wazuh-indexer` with the OpenSearch `repository-s3` plugin pre-installed, enabling Amazon S3 as a snapshot repository backend.

## Overview

By default, the Wazuh Indexer (based on OpenSearch) only supports local filesystem snapshot repositories. This custom image adds the `repository-s3` plugin so you can use an S3 bucket for storing and restoring index snapshots.

The Helm chart includes a conditional init container (`setup-s3-keystore`) that injects AWS credentials into the OpenSearch keystore at pod startup, keeping secrets out of the Docker image.

## Architecture

```
Pod Startup Flow:
  1. [init] volume-mount-hack        - Fix volume permissions
  2. [init] increase-vm-max-map-count - Set kernel parameters
  3. [init] config-init               - Generate auth credentials
  4. [init] setup-s3-keystore         - Inject AWS creds into keystore (conditional)
  5. [main] wazuh-indexer             - Start OpenSearch with S3 plugin + keystore
```

## Building the Image

### Prerequisites

- Docker (or compatible builder like Podman/Buildah)

### Build

```bash
docker build --build-arg WAZUH_VERSION=4.14.2 \
  -t wazuh-indexer-s3:4.14.2 \
  utils/packages/wazuh-indexer-s3/
```

The `WAZUH_VERSION` build arg defaults to `4.14.2` and should match your deployment's Wazuh version.

### For K3s (containerd)

K3s uses containerd, not Docker. After building, import the image:

```bash
docker save wazuh-indexer-s3:4.14.2 | sudo k3s ctr images import -
```

### Push to a Registry (Production)

```bash
docker tag wazuh-indexer-s3:4.14.2 ghcr.io/<your-org>/wazuh-indexer-s3:4.14.2
docker push ghcr.io/<your-org>/wazuh-indexer-s3:4.14.2
```

## Helm Chart Configuration

### 1. Create the AWS Credentials Secret

```bash
kubectl -n wazuh create secret generic aws-s3-credentials \
  --from-literal=AWS_ACCESS_KEY_ID=<your-access-key> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<your-secret-key>
```

For production with External-Secrets Operator, create an `ExternalSecret` resource that syncs credentials from AWS Secrets Manager into this secret.

### 2. Configure values

**Local development (K3s with locally imported image):**

```yaml
indexer:
  image:
    registry: ""
    repository: wazuh-indexer-s3
    tag: "4.14.2"
    pullPolicy: Never
  s3Snapshot:
    enabled: true
    credentialsSecret: aws-s3-credentials
```

**Production (EKS with GHCR-hosted image):**

```yaml
indexer:
  image:
    registry: ghcr.io
    repository: <your-org>/wazuh-indexer-s3
    tag: "4.14.2"
  s3Snapshot:
    enabled: true
    credentialsSecret: ext-wazuh-aws-s3-snapshot-credentials
```

### 3. Deploy

```bash
helm upgrade wazuh charts/wazuh -n wazuh -f charts/wazuh/values-local.yaml -f my-s3-values.yaml
```

## Registering the S3 Snapshot Repository

After the indexer pods are running with the S3 plugin, register the S3 bucket as a snapshot repository via the OpenSearch API:

```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:<password> \
  -X PUT "https://localhost:9200/_snapshot/s3-repo" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "s3",
    "settings": {
      "bucket": "your-bucket-name",
      "region": "eu-central-1",
      "base_path": "snapshots"
    }
  }'
```

### Verify the Repository

```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:<password> \
  "https://localhost:9200/_snapshot/s3-repo"
```

## Taking and Restoring Snapshots

### Create a Snapshot

```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:<password> \
  -X PUT "https://localhost:9200/_snapshot/s3-repo/snapshot-1?wait_for_completion=true"
```

### List Snapshots

```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:<password> \
  "https://localhost:9200/_snapshot/s3-repo/_all"
```

### Restore a Snapshot

```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:<password> \
  -X POST "https://localhost:9200/_snapshot/s3-repo/snapshot-1/_restore"
```

### Delete the Snapshot Repository (Unregister)

```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  curl -sk -u admin:<password> \
  -X DELETE "https://localhost:9200/_snapshot/s3-repo"
```

This only unregisters the repository from OpenSearch. It does **not** delete snapshots or data in the S3 bucket.

## Files Modified/Created

| File | Description |
|------|-------------|
| `utils/packages/wazuh-indexer-s3/Dockerfile` | Custom image with `repository-s3` plugin |
| `charts/wazuh/values.yaml` | Added `indexer.s3Snapshot` config section (`enabled`, `credentialsSecret`) |
| `charts/wazuh/templates/indexer/sts.indexer.yaml` | Added conditional keystore init container, emptyDir volume, and volume mount |

## Dockerfile Details

The Dockerfile handles two quirks of the `wazuh/wazuh-indexer` base image:

1. **Missing `/etc/sysconfig/wazuh-indexer`** — The `opensearch-env` script sources this file, which doesn't exist in the container. We create it with `touch`.
2. **Missing `OPENSEARCH_PATH_CONF`** — The plugin installer requires this environment variable pointing to the OpenSearch config directory.

```dockerfile
ARG WAZUH_VERSION=4.14.2
FROM wazuh/wazuh-indexer:${WAZUH_VERSION}

USER root
ENV OPENSEARCH_PATH_CONF=/usr/share/wazuh-indexer/config

RUN touch /etc/sysconfig/wazuh-indexer && \
    /usr/share/wazuh-indexer/bin/opensearch-plugin install --batch repository-s3

USER wazuh-indexer
```

## Troubleshooting

### Init container `setup-s3-keystore` fails

Check the init container logs:
```bash
kubectl logs -n wazuh wazuh-wazuh-helm-indexer-0 -c setup-s3-keystore
```

Common causes:
- The credentials secret doesn't exist or has wrong key names (must be `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`)
- The secret is in a different namespace

### Plugin not loaded

Verify the plugin is installed:
```bash
kubectl exec -n wazuh wazuh-wazuh-helm-indexer-0 -- \
  /usr/share/wazuh-indexer/bin/opensearch-plugin list
```

Should include `repository-s3` in the output. If not, check that the custom image is being used:
```bash
kubectl get pod -n wazuh wazuh-wazuh-helm-indexer-0 -o jsonpath='{.spec.containers[0].image}'
```

### StorageClass error on `helm upgrade`

If you see `StorageClass is invalid: updates to provisioner are forbidden`, delete the existing StorageClass first:
```bash
kubectl delete storageclass wazuh-wazuh-helm
```
This is safe — it doesn't affect existing PVCs or PVs.
