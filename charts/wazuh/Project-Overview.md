# ADORSYS-GIS Wazuh Repository Documentation

This document provides an overview and links to the various Wazuh-related repositories maintained within the ADORSYS-GIS GitHub organization.

The repositories listed here are filtered by the term "wazuh" within the organization.

**Source Link:** [https://github.com/orgs/ADORSYS-GIS/repositories?language=&q=wazuh&sort=&type=all](https://github.com/orgs/ADORSYS-GIS/repositories?language=&q=wazuh&sort=&type=all)

## Repository List

Below is a list of the relevant repositories with their direct links and a brief description based on the provided README content.

| Repository Name         | GitHub Link                                                              | Description                                                                                                                                 | Purpose / Notes                                                 |
| :---------------------- | :----------------------------------------------------------------------- | :------------------------------------------------------------------------------------------------------------------------------------------ | :-------------------------------------------------------------- |
| **wazuh-helm**          | [https://github.com/ADORSYS-GIS/wazuh-helm](https://github.com/ADORSYS-GIS/wazuh-helm)       | Helm chart for deploying Wazuh.                                                                                                             | Helm deployment for Wazuh infrastructure.                     |
| **wazuh**               | [https://github.com/ADORSYS-GIS/wazuh](https://github.com/ADORSYS-GIS/wazuh)           |                                                                                      | The main Wazuh server/manager core components. |
| **wazuh-playbook**      | [https://github.com/ADORSYS-GIS/wazuh-playbook](https://github.com/ADORSYS-GIS/wazuh-playbook) | Contains playbooks designed to assist in remediating security incidents detected by Wazuh.                                                  | Remediation playbooks for security incidents.                   |
| **wazuh-yara**          | [https://github.com/ADORSYS-GIS/wazuh-yara](https://github.com/ADORSYS-GIS/wazuh-yara)       | Integrates YARA rules with Wazuh to improve malware detection and file integrity monitoring.                                                | YARA integration for malware scanning and FIM.                |
| **wazuh-snort**         | [https://github.com/ADORSYS-GIS/wazuh-snort](https://github.com/ADORSYS-GIS/wazuh-snort)     | Project focused on integrating Snort with Wazuh to improve network security monitoring and threat detection.                                | Snort integration for network intrusion detection (NIDS).       |
| **wazuh-suricata**      | [https://github.com/ADORSYS-GIS/wazuh-suricata](https://github.com/ADORSYS-GIS/wazuh-suricata) | Integrates the Wazuh agent with Suricata, a high-performance network intrusion detection system (NIDS).                                     | Suricata integration for network intrusion detection (NIDS).    |
| **wazuh-cert-oauth2**   | [https://github.com/ADORSYS-GIS/wazuh-cert-oauth2](https://github.com/ADORSYS-GIS/wazuh-cert-oauth2) | Demonstrates by example how to authenticate with Keycloak and submit a certificate to the end use for Wazuh server communication.           | Authentication and certificate issuance via OAuth2/Keycloak.  |
| **wazuh-agent**         | [https://github.com/ADORSYS-GIS/wazuh-agent](https://github.com/ADORSYS-GIS/wazuh-agent)     | Provides an automated setup script for installing the Wazuh Agent along with essential security tools, Yara and Snort.                      | Automated agent setup scripts (includes Yara/Snort setup).      |
| **wazuh-agent-status**  | [https://github.com/ADORSYS-GIS/wazuh-agent-status](https://github.com/ADORSYS-GIS/wazuh-agent-status) | An application designed to monitor the state of Wazuh agents, providing real-time insights into operational status via a system tray tool. | Desktop application for monitoring agent status.                |
| **wazuh-trivy**         | [https://github.com/ADORSYS-GIS/wazuh-trivy](https://github.com/ADORSYS-GIS/wazuh-trivy)     | Wazuh and Trivy integration to scan Docker image vulnerabilities.                                                                           | Trivy integration for container vulnerability scanning.       |
