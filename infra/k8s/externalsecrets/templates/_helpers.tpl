{{- define "externalsecrets.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "externalsecrets.storeNamespace" -}}
{{- default .Release.Namespace .Values.namespace -}}
{{- end }}
