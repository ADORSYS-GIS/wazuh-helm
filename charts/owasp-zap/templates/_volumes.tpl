{{/*
Volume name. Choose externalPvcName if set, otherwise use the default PVC name
*/}}
{{- define "owasp-zap.volumeName" -}}
{{- if .Values.externalPvcName }}
{{- .Values.externalPvcName }}
{{- else }}
{{- $fullName := (include "common.names.fullname" .) }}
{{- printf "%s-%s" $fullName "pvc" }}
{{- end }}
{{- end }}