# Grafana

Grafana is a powerful visualization platform that is part of the Wazuh Monitoring Stack. It provides a rich set of features for creating dashboards and visualizing metrics and logs.

## Features

- **Pre-installed Plugins**: Includes plugins like grafana-piechart-panel and grafana-clock-panel.
- **Keycloak SSO Integration**: Supports single sign-on with Keycloak for secure access.
- **Automatic Datasource Provisioning**: Automatically configures data sources for Prometheus and Loki.

## Configuration

To configure Grafana, modify the `values.yaml` file:

```yaml
prom-stack:
  grafana:
    ingress:
      enabled: true
      ingressClassName: traefik
      hosts:
        - "{{ .Values.global.domain }}"
```

## Usage

Grafana is the primary interface for visualizing metrics and logs. Ensure that it is configured to connect to Prometheus and Loki.

## Troubleshooting

- **Access Issues**: Verify ingress configuration and ensure that the ingress controller is properly set up.
- **Plugin Issues**: Check Grafana logs for any errors related to plugin loading.
