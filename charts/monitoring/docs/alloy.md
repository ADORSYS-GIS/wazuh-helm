# Role of Alloy (with Links)

# Grafana Alloy

Grafana Alloy is a powerful tool for log processing and forwarding within the Wazuh Monitoring Stack. It enhances the capabilities of Grafana by providing additional visualization and monitoring features.

## Features

- **Kubernetes Service Discovery**: Automatically discovers services, pods, nodes, and endpoints within your Kubernetes cluster.
- **Log Forwarding**: Seamlessly forwards logs to Loki for aggregation and analysis.
- **Ingress Monitoring**: Monitors ingress traffic and provides insights into ingress performance and health.

## Configuration

To configure Grafana Alloy, modify the `values.yaml` file:

```yaml
alloy:
  enabled: true
  ingress:
    enabled: false
    ingressClassName: traefik
    hosts:
      - "alloy-{{ .Values.global.domain }}"
```

## Usage

Grafana Alloy integrates with Loki to provide a comprehensive logging solution. Ensure that Loki is enabled and properly configured to receive logs from Alloy.

## Troubleshooting

- **Ingress Issues**: Verify ingress configuration and ensure that the ingress controller is properly set up.
- **Log Forwarding**: Check Alloy's configuration to ensure logs are being forwarded to the correct Loki endpoint.
