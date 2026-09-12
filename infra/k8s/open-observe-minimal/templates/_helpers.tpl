{{/*
Chart name (overridable).
*/}}
{{- define "open-observe-minimal.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. Defaults to the release name so resources are
named `openobserve`, `openobserve-data`, etc. when installed as
`helm install openobserve`.
*/}}
{{- define "open-observe-minimal.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels applied to every resource.
*/}}
{{- define "open-observe-minimal.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "open-observe-minimal.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: observability
{{- end }}

{{/*
Selector labels. These are used by the Deployment selector and the
Service selector. They must remain stable across upgrades.
*/}}
{{- define "open-observe-minimal.selectorLabels" -}}
app.kubernetes.io/name: {{ include "open-observe-minimal.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}


{{/*
ServiceAccount name.
*/}}
{{- define "open-observe-minimal.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "open-observe-minimal.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference. Prefers digest over tag when set.
*/}}
{{- define "open-observe-minimal.image" -}}
{{- $registry := .Values.image.registry -}}
{{- $repository := .Values.image.repository -}}
{{- if .Values.image.digest -}}
{{- printf "%s/%s@%s" $registry $repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry $repository .Values.image.tag -}}
{{- end -}}
{{- end }}
