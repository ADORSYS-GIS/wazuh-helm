{{- define "integration.aws.exists" -}}
{{- $aws := .Values.integration.aws -}}
{{- if $aws -}}
{{- if or (and $aws.cloudtrail $aws.cloudtrail.enabled) (and $aws.config $aws.config.enabled) (and $aws.securityHub $aws.securityHub.enabled) -}}
true
{{- else -}}
false
{{- end -}}
{{- else -}}
false
{{- end -}}
{{- end -}}

{{- define "integration.aws.conf" -}}
{{- $aws := .Values.integration.aws -}}
{{- if $aws -}}
{{- if or (and $aws.cloudtrail $aws.cloudtrail.enabled) (and $aws.config $aws.config.enabled) (and $aws.securityHub $aws.securityHub.enabled) -}}
<wodle name="aws-s3">
  <disabled>no</disabled>
{{- $interval := (default "1m" (or (and $aws.cloudtrail $aws.cloudtrail.interval) (and $aws.securityHub $aws.securityHub.interval))) }}
{{- if $interval }}
  <interval>{{ include "common.tplvalues.render" (dict "value" $interval "context" $) }}</interval>
{{- else }}
  <interval>1m</interval>
{{- end }}
  <run_on_start>yes</run_on_start>
  <skip_on_error>yes</skip_on_error>
{{- if and $aws.cloudtrail $aws.cloudtrail.enabled }}
  <bucket type="cloudtrail">
    <name>{{ include "common.tplvalues.render" (dict "value" $aws.cloudtrail.bucketName "context" $) }}</name>
{{- if and $aws.profile (ne $aws.profile "~") }}
    <aws_profile>{{ include "common.tplvalues.render" (dict "value" $aws.profile "context" $) }}</aws_profile>
{{- end }}
{{- if $aws.roleArn }}
    <iam_role_arn>{{ include "common.tplvalues.render" (dict "value" $aws.roleArn "context" $) }}</iam_role_arn>
{{- end }}
{{- if $aws.awsOrganizationId }}
    <aws_organization_id>{{ include "common.tplvalues.render" (dict "value" $aws.awsOrganizationId "context" $) }}</aws_organization_id>
{{- end }}
  </bucket>
{{- end }}
{{- if and $aws.config $aws.config.enabled }}
  <bucket type="config">
    <name>{{ include "common.tplvalues.render" (dict "value" $aws.config.bucketName "context" $) }}</name>
{{- if and $aws.profile (ne $aws.profile "~") }}
    <aws_profile>{{ include "common.tplvalues.render" (dict "value" $aws.profile "context" $) }}</aws_profile>
{{- end }}
{{- if $aws.roleArn }}
    <iam_role_arn>{{ include "common.tplvalues.render" (dict "value" $aws.roleArn "context" $) }}</iam_role_arn>
{{- end }}
  </bucket>
{{- end }}
{{- if and $aws.securityHub $aws.securityHub.enabled }}
  <subscriber type="security_hub">
    <sqs_name>{{ include "common.tplvalues.render" (dict "value" $aws.securityHub.sqsName "context" $) }}</sqs_name>
{{- if and $aws.profile (ne $aws.profile "~") }}
    <aws_profile>{{ include "common.tplvalues.render" (dict "value" $aws.profile "context" $) }}</aws_profile>
{{- end }}
{{- if $aws.roleArn }}
    <iam_role_arn>{{ include "common.tplvalues.render" (dict "value" $aws.roleArn "context" $) }}</iam_role_arn>
{{- end }}
  </subscriber>
{{- end }}
</wodle>
{{- end -}}
{{- end -}}
{{- end }}