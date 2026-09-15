{{- define "open-observe-minimal.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "open-observe-minimal.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "open-observe-minimal.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "open-observe-minimal.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: observability
{{- end }}

{{- define "open-observe-minimal.selectorLabels" -}}
app.kubernetes.io/name: {{ include "open-observe-minimal.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "open-observe-minimal.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "open-observe-minimal.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "open-observe-minimal.image" -}}
{{- printf "%s/%s@%s" .Values.image.registry .Values.image.repository .Values.image.digest -}}
{{- end }}
