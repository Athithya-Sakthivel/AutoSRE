{{- define "externalsecrets.name" -}}
{{- default "externalsecrets" .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "externalsecrets.labels" -}}
app.kubernetes.io/name: {{ include "externalsecrets.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: autosre
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}
