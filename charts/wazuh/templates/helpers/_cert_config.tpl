{{/*
Cert generation script
*/}}
{{- define "wazuh.cert_script" -}}
{{ $.Files.Get "files/scripts/gen_certs.sh" }}

# Generate certificates
generate_cert "indexer" \
    "{{ include "common.names.fullname" $ }}-indexer-api,*.{{ include "common.names.fullname" $ }}-indexer"

generate_cert "server" \
    "{{ include "common.names.fullname" $ }}-manager,*.{{ include "common.names.fullname" $ }}-cluster,{{ include "common.names.fullname" $ }}-cluster,{{ include "common.names.fullname" $ }},*.{{ include "common.names.fullname" $ }}"

generate_cert "dashboard" \
    "{{ include "common.names.fullname" $ }}-dashboard,*.{{ include "common.names.fullname" $ }}-dashboard"

generate_cert "admin" "admin"
{{- end -}}

{{/*
Cert secret name
*/}}
{{- define "wazuh.cert_secret_name" -}}
{{ include "common.names.fullname" $ }}-certificates
{{- end -}}

{{/*
Root-CA Secret name
*/}}
{{- define "wazuh.cert_root_name" -}}
{{ $.Values.cluster.rootCaSecretName }}
{{- end -}}