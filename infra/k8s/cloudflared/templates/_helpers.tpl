# infra/k8s/cloudflared/templates/_helpers.tpl
{{/*
Common labels for cloudflared.
*/}}
{{- define "cloudflared.labels" -}}
app.kubernetes.io/name: cloudflared
app.kubernetes.io/component: tunnel
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels for pods.
*/}}
{{- define "cloudflared.selectorLabels" -}}
app.kubernetes.io/name: cloudflared
app.kubernetes.io/component: tunnel
{{- end }}
