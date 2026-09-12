{{- define "tenant-queue.labels" -}}
app.kubernetes.io/name: tenant-queue
app.kubernetes.io/managed-by: {{ .Release.Service }}
platform.component: governance
platform.tenant: {{ .Values.tenant }}
platform.cluster: {{ .Values.clusterName }}
{{- end }}

{{/*
Render one ClusterQueue's resourceGroups block from a {cpu: ..., memory: ..., pods: ...} map of
nominal quota, optionally with a matching borrowingLimit map. Keeping this in one place is what
keeps the high and low queues structurally identical - they differ only in their numbers and
their preemption stance, which is exactly the claim the design makes.

Context: dict "quota" <map> "borrowingLimit" <map> "flavor" <string>
*/}}
{{- define "tenant-queue.resourceGroups" -}}
- coveredResources:
    {{- range $resource, $_ := .quota }}
    - {{ $resource }}
    {{- end }}
  flavors:
    - name: {{ .flavor }}
      resources:
        {{- range $resource, $quantity := .quota }}
        - name: {{ $resource }}
          nominalQuota: {{ $quantity | quote }}
          {{- $limit := index $.borrowingLimit $resource }}
          {{- if $limit }}
          borrowingLimit: {{ $limit | quote }}
          {{- end }}
        {{- end }}
{{- end }}
