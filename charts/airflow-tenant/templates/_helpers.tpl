{{- define "airflow-tenant.labels" -}}
app.kubernetes.io/managed-by: argocd
platform.tenant: {{ .Values.tenant }}
{{- end -}}
