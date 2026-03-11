# Wazuh Helm Chart

Deploy Wazuh SIEM on Kubernetes with OpenSearch, alerting, and anomaly detection.

## Quick Start

1. [Getting Started Guide](./GETTING_STARTED.md) - Deploy on k3s, minikube, or microk8s
2. [Project Overview](./Project-Overview.md) - Architecture and components

## Documentation

Comprehensive documentation is available in the [docs/](./docs/) folder:

### For SOC Analysts
- [Alerting Monitors Reference](./docs/alerting/monitors.md) - All 13 alerting monitors
- [Malware Incident Response](./docs/playbooks/IRP-Malware.md)
- [Brute Force Attack Response](./docs/playbooks/IRP-BruteForce.md)
- [Playbook Template](./docs/playbooks/IRP-Template.md)

### For Operations Teams
- [Backup & Restore](./docs/runbooks/backup-restore.md)
- [Troubleshooting Guide](./docs/troubleshooting/common-issues.md)

## Features

- **Wazuh Manager** - Master/Worker cluster with auto-scaling
- **OpenSearch Indexer** - 3-node cluster with ISM lifecycle policies
- **Wazuh Dashboard** - Kibana-based UI with Wazuh plugin
- **13 Alerting Monitors** - Real-time security alerts and scheduled reports
- **10 Anomaly Detectors** - ML-based anomaly detection
- **Multi-channel Notifications** - Email, Slack, GitHub Issues

## Alerting Monitors

| Monitor | Schedule | Description |
|---------|----------|-------------|
| Critical Severity Alert | 1 min | High severity events (level >= 12) |
| Rootkit/Malware Detection | 1 min | Malware and rootkit alerts |
| Brute Force Attack | 5 min | Multiple failed auth attempts |
| Unauthorized Application | 5 min | Blacklisted software detection |
| Daily Security Summary | 8:00 AM | Daily event overview |
| Deprecated OS Report | 8:01 AM | EOL operating system check |
| Weekly Compliance Report | Monday 8:00 AM | SCA compliance summary |

## Installation

```bash
# Create namespace and root CA secret
kubectl create namespace wazuh
kubectl create secret generic wazuh-root-ca -n wazuh \
  --from-file=root-ca.pem --from-file=root-ca-key.pem

# Install with Helm
helm upgrade --install wazuh ./charts/wazuh -n wazuh \
  -f values.yaml -f values-<platform>.yaml
```

## Configuration

See [values.yaml](./values.yaml) for all configuration options.

## License

Apache 2.0
