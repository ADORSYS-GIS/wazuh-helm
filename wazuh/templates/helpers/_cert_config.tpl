{{/*
Cert generation script
*/}}
{{- define "wazuh.cert_script" -}}
{{ $.Files.Get "scripts/gen_certs.sh" }}

# Generate certificates
generate_cert "indexer" \
    "*.{{ include "common.names.fullname" $ }}-indexer" \
    "{{ include "common.names.fullname" $ }}-indexer" \
    "*.{{ include "common.names.fullname" $ }}-indexer-api" \
    "{{ include "common.names.fullname" $ }}-indexer-api"

generate_cert "server" \
    "*.{{ include "common.names.fullname" $ }}-manager" \
    "{{ include "common.names.fullname" $ }}-manager" \
    "*.{{ include "common.names.fullname" $ }}" \
    "{{ include "common.names.fullname" $ }}"

generate_cert "dashboard" \
    "*.{{ include "common.names.fullname" $ }}-dashboard" \
    "{{ include "common.names.fullname" $ }}-dashboard"

generate_cert "admin" "admin"

rm "$OUTPUT_FOLDER/*.temp.pem"
{{- end -}}