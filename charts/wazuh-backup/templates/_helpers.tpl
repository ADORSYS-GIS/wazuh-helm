{{/*
Expand the name of the chart.
*/}}
{{- define "wazuh-backup.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "wazuh-backup.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "wazuh-backup.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "wazuh-backup.labels" -}}
helm.sh/chart: {{ include "wazuh-backup.chart" . }}
{{ include "wazuh-backup.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "wazuh-backup.selectorLabels" -}}
app.kubernetes.io/name: {{ include "wazuh-backup.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Generate ServiceAccount name
*/}}
{{- define "wazuh-backup.serviceAccountName" -}}
{{- if .Values.serviceaccounts }}
{{- range .Values.serviceaccounts }}
{{- if .enabled | default true }}
{{ include "common.tplvalues.render" (dict "value" .name "context" $) }}
{{- break }}
{{- end }}
{{- end }}
{{- else }}
{{ include "common.names.fullname" . }}-sa
{{- end }}
{{- end }}

{{/*
Generate staging PVC name
*/}}
{{- define "wazuh-backup.stagingPvcName" -}}
{{- if .Values.pvc.staging.externalName -}}
{{ .Values.pvc.staging.externalName }}
{{- else -}}
{{ .Values.pvc.staging.name }}
{{- end -}}
{{- end -}}

{{/*
Generate EventListener service name
*/}}
{{- define "wazuh-backup.eventListenerService" -}}
{{ include "common.names.fullname" . }}-listener-svc
{{- end -}}

{{/*
Generate component-specific labels
*/}}
{{- define "wazuh-backup.componentLabels" -}}
{{- $componentName := .componentName -}}
{{- $context := .context -}}
component: {{ $componentName }}
backup.wazuh.io/component: {{ $componentName }}
{{- end -}}

{{/*
Return the appropriate pipeline name based on graceful shutdown setting
*/}}
{{- define "wazuh-backup.pipelineName" -}}
{{- if .Values.features.gracefulShutdown.enabled }}
{{ include "common.names.fullname" . }}-component-backup-graceful
{{- else }}
{{ include "common.names.fullname" . }}-component-backup
{{- end }}
{{- end }}

{{/*
Return the image reference
This helper is used for backward compatibility with existing _images.tpl
*/}}
{{- define "image.ref" -}}
{{- include "common.images.image" (dict "imageRoot" . "global" $.Values.global) -}}
{{- end -}}

{{/*
Check if any backup components are enabled
Returns "true" if at least one component is enabled, empty string otherwise
*/}}
{{- define "wazuh-backup.hasEnabledComponents" -}}
{{- $hasEnabled := false -}}
{{- range .Values.backup.components -}}
{{- if .enabled -}}
{{- $hasEnabled = true -}}
{{- end -}}
{{- end -}}
{{- if $hasEnabled -}}
true
{{- end -}}
{{- end -}}

{{/*
Generate pod name for a component replica with fallback to hardcoded value
Usage: {{ include "wazuh-backup.podName" (dict "component" .component "index" $index "context" $) }}
*/}}
{{- define "wazuh-backup.podName" -}}
{{- $component := .component -}}
{{- $index := .index -}}
{{- if $component.podName -}}
  {{- $component.podName -}}
{{- else -}}
  {{- printf "%s-%d" $component.statefulsetName $index -}}
{{- end -}}
{{- end -}}

{{/*
Generate PVC name for a component replica with fallback to hardcoded value
StatefulSet PVC naming pattern: {volumeClaimTemplate}-{statefulsetName}-{ordinal}
Usage: {{ include "wazuh-backup.pvcName" (dict "component" .component "index" $index "context" $) }}
*/}}
{{- define "wazuh-backup.pvcName" -}}
{{- $component := .component -}}
{{- $index := .index -}}
{{- if $component.pvcName -}}
  {{- $component.pvcName -}}
{{- else -}}
  {{- printf "%s-%s-%d" $component.statefulsetName $component.statefulsetName $index -}}
{{- end -}}
{{- end -}}

{{/*
Generate replica-specific backup subdirectory
Usage: {{ include "wazuh-backup.replicaSubdir" (dict "component" .component "index" $index "context" $) }}
*/}}
{{- define "wazuh-backup.replicaSubdir" -}}
{{- $component := .component -}}
{{- $index := .index -}}
{{- printf "%s-%d" $component.backupSubdir $index -}}
{{- end -}}
