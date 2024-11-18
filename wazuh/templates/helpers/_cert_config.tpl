{{/**
Config file for the Wazuh Certificates genrator
*/}}
{{- define "wazuh.cert_config" -}}
nodes:
  # Wazuh indexer server nodes
  indexer:
    {{- range $i := until ((.Values.secretjob.maxIndexer | default 1) | int) }}
    - name: {{ include "common.names.fullname" $ }}-indexer-{{ $i }}.{{ include "common.names.fullname" $ }}-indexer
      ip: {{ include "common.names.fullname" $ }}-indexer-{{ $i }}.{{ include "common.names.fullname" $ }}-indexer
    {{- end }}

  # Wazuh server nodes
  # Use node_type only with more than one Wazuh manager
  server:
    {{- range $i := until ((.Values.secretjob.maxMaster | default 1) | int) }}
    - name: {{ include "common.names.fullname" $ }}-manager-master-{{ $i }}.{{ include "common.names.fullname" $ }}-cluster
      ip: {{ include "common.names.fullname" $ }}-manager-master-{{ $i }}.{{ include "common.names.fullname" $ }}-cluster
      node_type: master
    {{- end }}
    {{- range $i := until ((.Values.secretjob.maxWorker | default 1) | int) }}
    - name: {{ include "common.names.fullname" $ }}-manager-worker-{{ $i }}.{{ include "common.names.fullname" $ }}-cluster
      ip: {{ include "common.names.fullname" $ }}-manager-worker-{{ $i }}.{{ include "common.names.fullname" $ }}-cluster
      node_type: worker
    {{- end }}

  # Wazuh dashboard node
  dashboard:
    - name: {{ include "common.names.fullname" $ }}-dashboard
      ip: {{ include "common.names.fullname" $ }}-dashboard
{{- end -}}