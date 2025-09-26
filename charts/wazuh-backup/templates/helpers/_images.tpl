{{- define "image.ref" -}}
{{- $img := . -}}
{{- if $img.digest -}}
{{ printf "%s/%s@%s" $img.registry $img.repository $img.digest }}
{{- else -}}
{{ printf "%s/%s:%s" $img.registry $img.repository $img.tag }}
{{- end -}}
{{- end -}}
