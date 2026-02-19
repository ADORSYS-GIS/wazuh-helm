ARG WAZUH_VERSION=4.14.2
FROM wazuh/wazuh-indexer:${WAZUH_VERSION}

USER root

ENV OPENSEARCH_PATH_CONF=/usr/share/wazuh-indexer/config

# Create missing sysconfig file that opensearch-env expects, then install the S3 repository plugin
RUN touch /etc/sysconfig/wazuh-indexer && \
    /usr/share/wazuh-indexer/bin/opensearch-plugin install --batch repository-s3

USER wazuh-indexer
