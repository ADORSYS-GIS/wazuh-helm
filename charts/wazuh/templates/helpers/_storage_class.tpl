{{/*
Name of the Storage class
*/}}
{{- define "wazuh.storageClassName" -}}
    {{- if not .Values.global.storageClassName  }}
        {{- if and .Values.storageClass .Values.storageClass.enabled }}
            {{- $prefix := (include "common.names.fullname" $)}}
            {{- if .Values.storageClass.name }}
                {{- $suffix := .Values.storageClass.name }}
                {{- printf "%s-%s" $prefix $suffix | trunc 63 | trimSuffix "-" }}
            {{- else }}
                {{- $prefix }}
            {{- end }}
        {{- else }}
            {{- $.Values.global.externalStorageClassName }}
        {{- end }}
    {{- else }}
        {{- .Values.global.storageClassName }}
    {{- end }}
{{- end }}