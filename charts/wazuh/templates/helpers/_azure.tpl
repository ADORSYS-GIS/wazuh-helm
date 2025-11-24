{{- define "integration.azure.exists" -}}
{{- $azure := .Values.integration.azure -}}
{{- if and $azure $azure.auth -}}
{{- if or (and $azure.auth.log $azure.logAnalytics $azure.logAnalytics.enabled) (and $azure.auth.graph $azure.graph $azure.graph.enabled) (and $azure.auth.storage $azure.storage $azure.storage.enabled) -}}
true
{{- else -}}
false
{{- end -}}
{{- else -}}
false
{{- end -}}
{{- end -}}

{{- define "integration.azure.conf" -}}
{{- $azure := .Values.integration.azure -}}
{{- if $azure -}}
{{- if or (and $azure.logAnalytics $azure.logAnalytics.enabled) (and $azure.graph $azure.graph.enabled) (and $azure.storage $azure.storage.enabled) -}}
<wodle name="azure-logs">
    <disabled>no</disabled>
    <run_on_start>yes</run_on_start>
{{- if and $azure.logAnalytics $azure.logAnalytics.enabled }}
    <log_analytics>
        <auth_path>/var/ossec/wodles/credentials/log_analytics_credentials</auth_path>
{{- if $azure.tenantDomain }}
        <tenantdomain>{{ include "common.tplvalues.render" (dict "value" $azure.tenantDomain "context" $) }}</tenantdomain>
{{- end }}
{{- if $azure.logAnalytics.queries }}
{{- range $query := $azure.logAnalytics.queries }}
        <request>
            <query>{{ $query.query }}</query>
            <workspace>{{ default $azure.logAnalytics.workspace $query.workspace }}</workspace>
{{- if $query.timeOffset }}
            <time_offset>{{ $query.timeOffset }}</time_offset>
{{- else }}
            <time_offset>1d</time_offset>
{{- end }}
        </request>
{{- end }}
{{- else }}
        <request>
            <query>AzureActivity</query>
            <workspace>{{ include "common.tplvalues.render" (dict "value" $azure.logAnalytics.workspace "context" $) }}</workspace>
            <time_offset>1d</time_offset>
        </request>
{{- end }}
    </log_analytics>
{{- end }}
{{- if and $azure.graph $azure.graph.enabled }}
    <graph>
        <auth_path>/var/ossec/wodles/credentials/graph_credentials</auth_path>
{{- if $azure.tenantDomain }}
        <tenantdomain>{{ include "common.tplvalues.render" (dict "value" $azure.tenantDomain "context" $) }}</tenantdomain>
{{- end }}
{{- if $azure.graph.queries }}
{{- range $query := $azure.graph.queries }}
        <request>
            <query>{{ $query.query }}</query>
{{- if $query.timeOffset }}
            <time_offset>{{ $query.timeOffset }}</time_offset>
{{- else }}
            <time_offset>1d</time_offset>
{{- end }}
        </request>
{{- end }}
{{- else }}
        <request>
            <query>auditLogs/directoryAudits</query>
            <time_offset>1d</time_offset>
        </request>
{{- end }}
    </graph>
{{- end }}
{{- if and $azure.storage $azure.storage.enabled }}
    <storage>
        <auth_path>/var/ossec/wodles/credentials/storage_credentials</auth_path>
{{- if $azure.storage.containers }}
{{- range $container := $azure.storage.containers }}
        <container name="{{ $container.name }}">
{{- if $container.blobs }}
            <blobs>{{ $container.blobs }}</blobs>
{{- else }}
            <blobs>.json</blobs>
{{- end }}
{{- if $container.contentType }}
            <content_type>{{ $container.contentType }}</content_type>
{{- else }}
            <content_type>json_inline</content_type>
{{- end }}
{{- if $container.timeOffset }}
            <time_offset>{{ $container.timeOffset }}</time_offset>
{{- else }}
            <time_offset>24h</time_offset>
{{- end }}
        </container>
{{- end }}
{{- else }}
        <container name="insights-activity-logs">
            <blobs>.json</blobs>
            <content_type>json_inline</content_type>
            <time_offset>24h</time_offset>
        </container>
{{- end }}
    </storage>
{{- end }}
</wodle>
{{- end -}}
{{- end -}}
{{- end }}

{{- define "integration.azure.exists.log" -}}
{{- $azure := .Values.integration.azure -}}
{{- if and $azure $azure.auth $azure.auth.log -}}
{{- if and $azure.logAnalytics $azure.logAnalytics.enabled -}}
true
{{- else -}}
false
{{- end -}}
{{- else -}}
false
{{- end -}}
{{- end -}}

{{- define "integration.azure.exists.graph" -}}
{{- $azure := .Values.integration.azure -}}
{{- if and $azure $azure.auth $azure.auth.graph -}}
{{- if and $azure.graph $azure.graph.enabled -}}
true
{{- else -}}
false
{{- end -}}
{{- else -}}
false
{{- end -}}
{{- end -}}

{{- define "integration.azure.exists.storage" -}}
{{- $azure := .Values.integration.azure -}}
{{- if and $azure $azure.auth $azure.auth.storage -}}
{{- if and $azure.storage $azure.storage.enabled -}}
true
{{- else -}}
false
{{- end -}}
{{- else -}}
false
{{- end -}}
{{- end -}}