# Prometheus

Prometheus is a robust metrics collection and monitoring system that is part of the Wazuh Monitoring Stack. It collects and stores metrics, providing insights into the performance and health of your Kubernetes cluster.

## Features

- **Automatic Service Discovery**: Automatically discovers services and endpoints within your cluster.
- **Pre-configured Alerts**: Comes with a set of pre-configured alerts to monitor cluster health.
- **10-day Retention**: Default retention period for metrics, configurable based on your needs.

## Configuration

To configure Prometheus, modify the `values.yaml` file:

```yaml
prom-stack:
  prometheus:
    ingress:
      enabled: false
      ingressClassName: traefik
      hosts:
        - "prometheus-{{ .Values.global.domain }}"
```

## Usage

Prometheus integrates with Grafana for visualization. Ensure that Grafana is configured to use Prometheus as a data source.

## Troubleshooting

- **Metrics Collection**: Verify that Prometheus is scraping metrics from the correct endpoints.
- **Alerting**: Check AlertManager configuration to ensure alerts are being sent correctly.
