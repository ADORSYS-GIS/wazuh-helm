{{- define "integration.aws.conf" -}}
{{- $aws := .Values.integration.aws -}}
{{- if $aws -}}
{{- if $aws.enable -}}
{{- if and $aws.cloudtrail $aws.cloudtrail.enabled -}}
<wodle name="aws-s3">
    <disabled>no</disabled>
    <interval>{{- include "common.tplvalues.render" (dict "value" (default "1m" $aws.cloudtrail.interval) "context" $) -}}</interval>
    <run_on_start>yes</run_on_start>
    <skip_on_error>yes</skip_on_error>

    <bucket type="cloudtrail">
        <name>{{- include "common.tplvalues.render" (dict "value" $aws.cloudtrail.bucketName "context" $) -}}</name>
        {{- if $aws.profile }}
        <aws_profile>{{- include "common.tplvalues.render" (dict "value" $aws.profile "context" $) -}}</aws_profile>
        {{- end }}
        {{- if $aws.roleArn }}
        <iam_role_arn>{{- include "common.tplvalues.render" (dict "value" $aws.roleArn "context" $) -}}</iam_role_arn>
        {{- end }}
    </bucket>
</wodle>
{{- end -}}

{{- if and $aws.securityHub $aws.securityHub.enabled -}}
<wodle name="aws-s3">
    <disabled>no</disabled>
    <interval>{{- include "common.tplvalues.render" (dict "value" (default "1h" $aws.securityHub.interval) "context" $) -}}</interval>
    <run_on_start>yes</run_on_start>

    <subscriber type="security_hub">
        <sqs_name>{{- include "common.tplvalues.render" (dict "value" $aws.securityHub.sqsName "context" $) -}}</sqs_name>
        {{- if $aws.profile }}
        <aws_profile>{{- include "common.tplvalues.render" (dict "value" $aws.profile "context" $) -}}</aws_profile>
        {{- end }}
        {{- if $aws.roleArn }}
        <iam_role_arn>{{- include "common.tplvalues.render" (dict "value" $aws.roleArn "context" $) -}}</iam_role_arn>
        {{- end }}
    </subscriber>
</wodle>
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
