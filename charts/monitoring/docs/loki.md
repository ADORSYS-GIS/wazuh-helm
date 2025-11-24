# Loki

Loki is a log aggregation system that is part of the Wazuh Monitoring Stack. It is designed to work seamlessly with Prometheus and Grafana, providing a unified monitoring and logging solution.

## Features

- **Single Binary Mode**: Ideal for small deployments, simplifying the setup and management.
- **S3 Compatible Storage**: Supports MinIO for scalable and reliable log storage.
- **Structured Metadata Support**: Allows for rich log querying and analysis.

## Configuration

To configure Loki, modify the `values.yaml` file:

```yaml
loki:
  enabled: true
  ingress:
    enabled: false
    ingressClassName: traefik
    hosts:
      - "loki-{{ .Values.global.domain }}"
```

## Usage

Loki integrates with Grafana to provide a powerful logging and visualization platform. Ensure that Grafana is configured to use Loki as a data source.

## Troubleshooting

- **Storage Issues**: Verify that the storage backend is properly configured and accessible.
- **Log Ingestion**: Check Loki's configuration to ensure logs are being ingested correctly.
