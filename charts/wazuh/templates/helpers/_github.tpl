{{- define "integration.github.conf" -}}
{{ range $k, $v := .Values.integration.github }}
<github>
    <enabled>yes</enabled>
    <interval>30s</interval>
    <time_delay>30s</time_delay>
    <curl_max_size>1M</curl_max_size>
    <only_future_events>no</only_future_events>

    {{ range $v.orgs -}}
    <api_auth>
        <org_name>{{ include "common.tplvalues.render" (dict "value" . "context" $) }}</org_name>
        <api_token>{{ include "common.tplvalues.render" (dict "value" $v.secret "context" $) }}</api_token>
    </api_auth>
    {{ end }}

    <api_parameters>
        <event_type>all</event_type>
    </api_parameters>
</github>
{{- end }}
{{- end -}}