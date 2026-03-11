{{/*
Common secret
*/}}
{{- define "secret.common" -}}
{{- if $.Values.cluster.auth.existingSecret -}}
{{- $.Values.cluster.auth.existingSecret -}}
{{- else if $.Values.cluster.secret.enabled -}}
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
{{- if $.Values.integration.jira.existingSecret -}}
{{- $.Values.integration.jira.existingSecret -}}
{{- else if $.Values.integration.jira.externalSecret -}}
{{- $.Values.integration.jira.externalSecret -}}
{{- else -}}
{{ include "common.names.fullname" $ }}-jira-cred
{{- end -}}
{{- end -}}

{{/*
OIDC/Keycloak credentials
*/}}
{{- define "secret.oidc" -}}
{{- if $.Values.indexer.keycloak.existingSecret -}}
{{- $.Values.indexer.keycloak.existingSecret -}}
{{- else -}}
{{ include "common.names.fullname" $ }}-keycloak-credentials
{{- end -}}
{{- end -}}

{{/*
Azure integration credentials
*/}}
{{- define "secret.integration-azure" -}}
{{- if $.Values.integration.azure.secrets.existingSecret -}}
{{- $.Values.integration.azure.secrets.existingSecret -}}
{{- else -}}
{{ include "common.names.fullname" $ }}-azure-cred
{{- end -}}
{{- end -}}