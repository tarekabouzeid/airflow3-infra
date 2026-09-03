{{- define "postgres-lite.fullname" -}}
{{ .Release.Name }}-{{ .Values.nameOverride }}
{{- end -}}
