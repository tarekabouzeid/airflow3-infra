{{- define "cluster-governance.labels" -}}
app.kubernetes.io/name: cluster-governance
app.kubernetes.io/managed-by: {{ .Release.Service }}
platform.component: governance
platform.cluster: {{ .Values.clusterName }}
{{- end }}

{{/*
The namespaceSelector every tenant-facing Kyverno rule matches on. Keyed off the label
charts/tenant-project stamps on every namespace it creates, so a namespace that is not a
tenant namespace (kube-system, argocd, kueue-system, kyverno, vault, spark-operator, ...) is
never matched by any rule in this chart - policy that cannot reach platform components cannot
deadlock the platform.
*/}}
{{- define "cluster-governance.tenantNamespaceSelector" -}}
matchLabels:
  platform.tenant-namespace: "true"
{{- end }}

{{/*
Narrower selector: only the namespaces where tenant TASKS land ("<tenant>-workloads"), not the
namespaces holding a tenant's Airflow control plane. Rules that assume a pod is a queued unit of
batch work (queue membership, tenant-workload-* priority classes) use this, never the broad one.
*/}}
{{- define "cluster-governance.workloadNamespaceSelector" -}}
matchLabels:
  platform.namespace-role: workloads
{{- end }}

{{/*
The exclude block every rule in this chart carries. Strictly redundant with the tenant-namespace
selector above (a platform namespace does not carry platform.tenant-namespace, so it cannot match
in the first place) - carried anyway so that a namespace accidentally labelled as a tenant's still
cannot pull a platform component into a tenant-shaped policy.
*/}}
{{- define "cluster-governance.excludeBlock" -}}
any:
  - resources:
      namespaces:
        {{- range .Values.policy.excludedNamespaces }}
        - {{ . | quote }}
        {{- end }}
{{- end }}
