{{/*
Default Storage class
*/}}
{{- define "wazuh.storageClassName" -}}
    {{- if .Values.global.storageClassName -}}
        {{- .Values.global.storageClassName -}}
    {{- else -}}
        {{- include "common.names.fullname" $ -}}
    {{- end -}}
{{- end -}}