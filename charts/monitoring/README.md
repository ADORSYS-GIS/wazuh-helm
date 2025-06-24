# Wazuh Monitoring Stack

A production-grade monitoring solution for Kubernetes clusters that integrates Prometheus, Grafana, Loki, and Grafana Alloy. This Helm chart is designed to work across multiple environments with specific optimizations for EKS, K3s, and Docker Desktop.

## Architecture

### Core Components

1. **Prometheus Stack**

   - Prometheus Server (metrics collection and storage)
   - AlertManager (alerting and notification system)
   - Grafana (visualization platform)
   - Node Exporter (host metrics collection)
   - kube-state-metrics (Kubernetes metrics collection)

2. **Logging Stack**

   - Loki (log aggregation system)
   - Grafana Alloy (log processing and forwarding)

3. **Authentication**
   - Keycloak integration for SSO
   - OIDC-based authentication

## Prerequisites

- Kubernetes 1.16+
- Helm 3.0+
- Minimum resource requirements:
  - CPU: 4 cores
  - Memory: 8Gi RAM
  - Storage: 50Gi+ available space
- For EKS deployments:
  - AWS ALB Controller
  - External DNS (optional but recommended)

## Installation

### Quick Start

```bash
# Add required Helm repositories
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Install the chart
helm upgrade -i --create-namespace monitoring ./monitoring -n monitoring
```

### Environment-Specific Deployments

#### AWS EKS

```bash
helm upgrade -i --create-namespace monitoring ./monitoring -n monitoring \
  -f values.yaml \
  -f values-eks.yaml \
  --set global.domain=your-domain.com
```

#### Docker Desktop

```bash
helm upgrade -i --create-namespace monitoring ./monitoring -n monitoring \
  -f values.yaml \
  -f values-docker-desktop.yaml
```

#### K3s

```bash
helm upgrade -i --create-namespace monitoring ./monitoring -n monitoring \
  -f values.yaml \
  -f values-k3s.yaml
```

## Configuration

### Essential Parameters

```yaml
global:
  domain: "grafana.example.team" # Your domain for ingress
  storageClassName: null # Storage class for PVCs

keycloak:
  enabled: true
  client_id: "grafana"
  client_secret: "your-secret" # Change this
  url: "https://keycloak.example.me"
  realm: "your-realm"
```

### Storage Configuration

The chart supports various storage options:

1. **Default Storage**

   - 10Gi for Prometheus
   - 10Gi for AlertManager
   - Configurable through `global.storageClassName`

2. **EKS-specific Storage**
   - Uses EBS storage by default
   - Increased to 50Gi for production workloads

### Authentication

The stack uses Keycloak for authentication with the following features:

- SSO integration
- Role-based access control
- Auto-login capability
- Refresh token support
- PKCE authentication

### Ingress Configuration

#### EKS (AWS ALB)

```yaml
ingress:
  enabled: true
  ingressClassName: alb
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
```

## Component Access

### Default URLs

- Grafana: `https://grafana.your-domain.com`
- Prometheus: `https://prometheus-grafana.your-domain.com`
- AlertManager: `https://alertmanager-grafana.your-domain.com`
- Loki: `https://loki-grafana.your-domain.com`

### Default Ports

- Grafana: 3000
- Prometheus: 9090
- AlertManager: 9093
- Loki: 3100

## Monitoring Stack Features

### Prometheus

- 10-day retention period by default
- Configurable storage (default 10Gi, EKS 50Gi)
- Automatic service discovery
- Pre-configured alerts

### Grafana

- Pre-installed plugins:
  - grafana-piechart-panel
  - grafana-clock-panel
- Automatic datasource provisioning
- Keycloak SSO integration
- GZIP compression enabled

### Loki

- Single binary mode for small deployments
- S3 compatible storage (MinIO included)
- Structured metadata support
- 24h index periods

### Grafana Alloy

- Kubernetes service discovery
- Automatic log forwarding to Loki
- Pod, node, and service monitoring
- Ingress monitoring capability

## Maintenance

### Backup Recommendations

1. Prometheus data: Regular PVC snapshots
2. Grafana dashboards: Export as JSON
3. Loki logs: S3 bucket backups
4. Configuration: Version control for values files

### Scaling Guidelines

- Prometheus: Adjust retention and storage based on metrics volume
- Loki: Configure retention and chunk size for log volume
- Grafana: Adjust resource requests/limits based on user count

## Troubleshooting

### Common Issues

1. **Storage Issues**

   ```bash
   kubectl get pvc -n monitoring  # Check PVC status
   kubectl describe pvc -n monitoring  # Debug PVC issues
   ```

2. **Ingress Problems**

   ```bash
   kubectl get ingress -n monitoring
   kubectl describe ingress -n monitoring
   ```

3. **Pod Health**
   ```bash
   kubectl get pods -n monitoring
   kubectl describe pod [pod-name] -n monitoring
   ```

## Version Information

- Chart Version: 0.1.0-rc.15
- Application Version: 1.0.0
- Tested Kubernetes Versions: 1.16+

## Support

For issues and feature requests, please contact:

- GitHub Issues: [Create an issue](https://github.com/your-repo/issues)
- Email: [your-support-email]

## License

Copyright (c) 2024

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
