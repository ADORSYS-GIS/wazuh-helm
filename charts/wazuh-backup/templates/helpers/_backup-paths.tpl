{{/*
Convert backup paths from values.yaml to comma-separated strings for the pipeline.
Supports both simple mode (sourcePvcPath) and advanced mode (backupPaths.include/exclude).
*/}}

{{- define "backup.includePaths" -}}
{{- $component := . -}}
{{- if $component.backupPaths -}}
{{- if $component.backupPaths.include -}}
{{- $component.backupPaths.include | join "," -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "backup.excludePatterns" -}}
{{- $component := . -}}
{{- if $component.backupPaths -}}
{{- if $component.backupPaths.exclude -}}
{{- $component.backupPaths.exclude | join "," -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "backup.sourcePath" -}}
{{- $component := . -}}
{{- if $component.sourcePvcPath -}}
{{- $component.sourcePvcPath -}}
{{- end -}}
{{- end -}}
