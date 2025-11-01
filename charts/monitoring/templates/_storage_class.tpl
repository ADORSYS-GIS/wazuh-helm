{{/*
Default Storage class
*/}}
{{- define "common.storage-className" -}}
    {{- if $.Values.global.storageClassName -}}
        {{- $.Values.global.storageClassName -}}
    {{- else -}}
        {{- "wazuh-monitoring-sc" -}}
    {{- end -}}
{{- end -}}