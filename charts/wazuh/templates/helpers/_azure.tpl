{{- define "integration.azure.conf" -}}
<wodle name="azure-logs">
    <disabled>no</disabled>
    <run_on_start>yes</run_on_start>

    {{ if (eq (include "integration.azure.exists.log" $) "true") -}}
    <log_analytics>
        <auth_path>/var/ossec/wodles/credentials/log_analytics_credentials</auth_path>
        <tenantdomain>{{- include "common.tplvalues.render" (dict "value" $.Values.integration.azure.domain "context" $) -}}</tenantdomain>
        <request>
            <query>AzureActivity</query>
            {{ if $.Values.integration.azure.workspace -}}
            <workspace>{{- include "common.tplvalues.render" (dict "value" $.Values.integration.azure.workspace "context" $) -}}</workspace>
            {{- end }}
            <time_offset>1d</time_offset>
        </request>
    </log_analytics>
    {{- end }}

    {{ if (eq (include "integration.azure.exists.graph" $) "true") -}}
    <graph>
        <auth_path>/var/ossec/wodles/credentials/graph_credentials</auth_path>
        <tenantdomain>{{- include "common.tplvalues.render" (dict "value" $.Values.integration.azure.domain "context" $) -}}</tenantdomain>
        <request>
            <query>auditLogs/directoryAudits</query>
            <time_offset>1d</time_offset>
        </request>
    </graph>
    {{- end }}

    {{ if (eq (include "integration.azure.exists.storage" $) "true") -}}
    <storage>
        <auth_path>/var/ossec/wodles/credentials/storage_credentials</auth_path>
        <container name="insights-activity-logs">
            <blobs>.json</blobs>
            <content_type>json_inline</content_type>
            <time_offset>24h</time_offset>
        </container>
    </storage>
    {{- end }}
</wodle>
{{- end -}}

{{- define "integration.azure.exists" -}}
{{- if or (eq (include "integration.azure.exists.log" $) "true") (eq (include "integration.azure.exists.graph" $) "true") (eq (include "integration.azure.exists.storage" $) "true") -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{- define "integration.azure.exists.log" -}}
{{- if and .Values.integration .Values.integration.azure .Values.integration.azure.auth .Values.integration.azure.auth.log .Values.integration.azure.auth.log.application_key .Values.integration.azure.auth.log.application_id -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{- define "integration.azure.exists.graph" -}}
{{- if and .Values.integration .Values.integration.azure .Values.integration.azure.auth .Values.integration.azure.auth.graph .Values.integration.azure.auth.graph.application_key .Values.integration.azure.auth.graph.application_id -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{- define "integration.azure.exists.storage" -}}
{{- if and .Values.integration .Values.integration.azure .Values.integration.azure.auth .Values.integration.azure.auth.storage .Values.integration.azure.auth.storage.account_name .Values.integration.azure.auth.storage.account_key -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}