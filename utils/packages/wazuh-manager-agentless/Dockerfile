FROM wazuh/wazuh-manager:4.13.1

RUN yum install -y expect openssh-clients \
 && yum clean all \
 && rm -rf /var/cache/yum

# Copy the classical
RUN \
    cp /var/ossec/agentless/ssh_integrity_check_linux /var/ossec/agentless/ssh_integrity_check_linux_legacy \
    && cp /var/ossec/agentless/ssh_integrity_check_bsd /var/ossec/agentless/ssh_integrity_check_bsd_legacy \
    && cp /var/ossec/agentless/ssh_pixconfig_diff /var/ossec/agentless/ssh_pixconfig_diff_legacy \
    && cp /var/ossec/agentless/ssh_generic_diff /var/ossec/agentless/ssh_generic_diff_legacy \
    && for f in /var/ossec/agentless/*_legacy; do \
         sed -i 's|spawn ssh \$hostname|spawn ssh \\\n  -o KexAlgorithms=diffie-hellman-group1-sha1,diffie-hellman-group14-sha1 \\\n  -o HostKeyAlgorithms=ssh-rsa \\\n  -o PubkeyAcceptedAlgorithms=ssh-rsa \\\n  -o Ciphers=aes128-cbc \\\n  -o MACs=hmac-sha1 \\\n  \$hostname|g' "$f"; \
       done
