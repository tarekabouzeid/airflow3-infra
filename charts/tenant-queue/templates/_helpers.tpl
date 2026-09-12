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
{{- $borrowingLimit := .borrowingLimit | default dict -}}
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
          {{- /*
            hasKey, NOT truthiness. In Kueue an ABSENT borrowingLimit means "borrow as much of the
            cohort's spare capacity as you like", while borrowingLimit: 0 means "borrow nothing" -
            opposite meanings. A `{{ if $limit }}` test treats the integer 0 as false and drops the
            field, turning the strictest possible setting into the most permissive one. Helm's
            --set coerces "0" to a number, so this is reachable from the command line as well as
            from a values file.
          */}}
          {{- if hasKey $borrowingLimit $resource }}
          borrowingLimit: {{ index $borrowingLimit $resource | quote }}
          {{- end }}
        {{- end }}
{{- end }}
