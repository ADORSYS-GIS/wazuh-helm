## Initialize the backup folder
bkp_folder=/tmp/wazuh_files_backup
mkdir -p $bkp_folder

## Backup the host information
cat /etc/*release* > $bkp_folder/host-info.txt

## Install rsync
yum install -y rsync

## Backup the Wazuh files
rsync -aREz \
  --ignore-missing-args \
  /etc/wazuh-indexer/certs/ \
  /etc/wazuh-indexer/jvm.options \
  /etc/wazuh-indexer/jvm.options.d \
  /etc/wazuh-indexer/log4j2.properties \
  /etc/wazuh-indexer/opensearch.yml \
  /etc/wazuh-indexer/opensearch.keystore \
  /etc/wazuh-indexer/opensearch-observability/ \
  /etc/wazuh-indexer/opensearch-reports-scheduler/ \
  /etc/wazuh-indexer/opensearch-security/ \
  /usr/lib/sysctl.d/wazuh-indexer.conf $bkp_folder