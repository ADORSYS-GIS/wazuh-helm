{{/*
Common secret
*/}}
{{- define "secret.common" -}}
{{- if $.Values.cluster.secret.enabled -}}
{{ include "common.names.fullname" $ }}-common-config
{{- else -}}
{{- $.Values.cluster.secretName -}}
{{- end -}}
{{- end -}}

{{/*
Inxeder credentials
*/}}
{{- define "secret.indexer-auth" -}}
{{- if $.Values.indexer.auth -}}
{{ include "common.names.fullname" $ }}-indexer-cred
{{- else -}}
{{- $.Values.indexer.authSecret -}}
{{- end -}}
{{- end -}}

{{/*
API credentials
*/}}
{{- define "secret.api-auth" -}}
{{- if $.Values.apiCred.auth -}}
{{ include "common.names.fullname" $ }}-api-cred
{{- else -}}
{{- $.Values.apiCred.authSecret -}}
{{- end -}}
{{- end -}}

{{/*
Dashboard credentials
*/}}
{{- define "secret.dashboard-auth" -}}
{{- if $.Values.dashboard.auth -}}
{{ include "common.names.fullname" $ }}-dashboard-cred
{{- else -}}
{{- $.Values.dashboard.authSecret -}}
{{- end -}}
{{- end -}}

{{/*
Slack notification credentials
*/}}
{{- define "secret.notification-slack" -}}
{{- if not $.Values.notification.slack.externalSecret -}}
{{ include "common.names.fullname" $ }}-slack-cred
{{- else -}}
{{- $.Values.notification.slack.externalSecret -}}
{{- end -}}
{{- end -}}

{{/*
Jira integration credentials
*/}}
{{- define "secret.integration-jira" -}}
{{- if not $.Values.integration.jira.externalSecret -}}
{{ include "common.names.fullname" $ }}-jira-cred
{{- else -}}
{{- $.Values.integration.jira.externalSecret -}}
{{- end -}}
{{- end -}}