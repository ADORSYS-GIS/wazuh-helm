FROM wazuh/wazuh-manager:4.14.3

RUN yum install -y expect openssh-clients \
 && yum clean all \
 && rm -rf /var/cache/yum

ADD config/etc/cont-init.d/3-agentless-legacy-ssh.sh /etc/cont-init.d
