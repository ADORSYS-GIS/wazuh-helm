cp etc/filebeat/filebeat.reference.yml /etc/filebeat/
cp etc/filebeat/fields.yml /etc/filebeat/
cp -r etc/filebeat/modules.d/* /etc/filebeat/modules.d/
cp -r etc/postfix/* /etc/postfix/
cp var/ossec/etc/client.keys /var/ossec/etc/
chown root:wazuh /var/ossec/etc/client.keys
cp -r var/ossec/etc/sslmanager* /var/ossec/etc/
cp var/ossec/etc/ossec.conf /var/ossec/etc/
chown root:wazuh /var/ossec/etc/ossec.conf
cp var/ossec/etc/internal_options.conf /var/ossec/etc/
chown root:wazuh /var/ossec/etc/internal_options.conf
cp var/ossec/etc/local_internal_options.conf /var/ossec/etc/
chown root:wazuh /var/ossec/etc/local_internal_options.conf
cp -r var/ossec/etc/rules/* /var/ossec/etc/rules/
chown -R wazuh:wazuh /var/ossec/etc/rules/
cp -r var/ossec/etc/decoders/* /var/ossec/etc/decoders
chown -R wazuh:wazuh /var/ossec/etc/decoders/
cp -r var/ossec/etc/shared/* /var/ossec/etc/shared/
chown -R wazuh:wazuh /var/ossec/etc/shared/
chown root:wazuh /var/ossec/etc/shared/ar.conf
cp -r var/ossec/logs/* /var/ossec/logs/
chown -R wazuh:wazuh /var/ossec/logs/
cp -r var/ossec/queue/agentless/*  /var/ossec/queue/agentless/
chown -R wazuh:wazuh /var/ossec/queue/agentless/
cp var/ossec/queue/agents-timestamp /var/ossec/queue/
chown root:wazuh /var/ossec/queue/agents-timestamp
cp -r var/ossec/queue/fts/* /var/ossec/queue/fts/
chown -R wazuh:wazuh /var/ossec/queue/fts/
cp -r var/ossec/queue/rids/* /var/ossec/queue/rids/
chown -R wazuh:wazuh /var/ossec/queue/rids/
cp -r var/ossec/stats/* /var/ossec/stats/
chown -R wazuh:wazuh /var/ossec/stats/
cp -r var/ossec/var/multigroups/* /var/ossec/var/multigroups/
chown -R wazuh:wazuh /var/ossec/var/multigroups/