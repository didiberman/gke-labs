{{/*
_helpers.tpl — Helm template helpers for the Temporal wrapper chart.
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "temporal-wrapper.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this.
*/}}
{{- define "temporal-wrapper.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart label (chart name + version).
*/}}
{{- define "temporal-wrapper.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to all resources in this chart.
*/}}
{{- define "temporal-wrapper.labels" -}}
helm.sh/chart: {{ include "temporal-wrapper.chart" . }}
{{ include "temporal-wrapper.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels (subset of common labels; used in matchLabels).
*/}}
{{- define "temporal-wrapper.selectorLabels" -}}
app.kubernetes.io/name: {{ include "temporal-wrapper.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
