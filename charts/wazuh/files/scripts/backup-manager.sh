## Initialize the backup folder
bkp_folder=/tmp/wazuh_files_backup
mkdir -p $bkp_folder

## Backup the host information
cat /etc/*release* > $bkp_folder/host-info.txt

## Install rsync
yum install -y rsync

## Backup the Wazuh files
rsync -aREz -v --stats --progress \
  --ignore-missing-args \
  /etc/filebeat/ \
  /etc/postfix/ \
  /var/ossec/api/configuration/ \
  /var/ossec/etc/client.keys \
  /var/ossec/etc/sslmanager* \
  /var/ossec/etc/ossec.conf \
  /var/ossec/etc/internal_options.conf \
  /var/ossec/etc/local_internal_options.conf \
  /var/ossec/etc/rules/local_rules.xml \
  /var/ossec/etc/decoders/local_decoder.xml \
  /var/ossec/etc/shared/ \
  /var/ossec/queue/agentless/ \
  /var/ossec/queue/agents-timestamp \
  /var/ossec/queue/fts/ \
  /var/ossec/queue/rids/ \
  /var/ossec/stats/ \
  /var/ossec/var/multigroups/ \
  $bkp_folder

## Backup the Wazuh files
rsync -aREz -v --stats --progress \
  /var/ossec/queue/db/ \
  $bkp_folder


# Merge the two for loops
for i in {1..20} ; do
  if [ $i -lt 10 ]; then
    echo "Copying 012.db to 0$i.db"
    rsync -aREz -v --stats --progress --ignore-missing-args "/var/ossec/queue/db/00$i.db" $bkp_folder
  else
    echo "Copying 012.db to $i.db"
    rsync -aREz -v --stats --progress --ignore-missing-args "/var/ossec/queue/db/0$i.db" $bkp_folder
  fi
done