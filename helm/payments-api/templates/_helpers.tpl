{{/*
_helpers.tpl — Named templates for the payments-api Helm chart.
All helpers follow Helm community conventions and are prefixed with
"payments-api." to avoid collisions with any parent chart.
*/}}

{{/*
Expand the name of the chart.
Uses .Values.nameOverride if set, otherwise falls back to .Chart.Name.
The result is truncated to 63 characters to comply with DNS label limits.
*/}}
{{- define "payments-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
Priority:
  1. .Values.fullnameOverride  (explicit override)
  2. <release-name>-<chart-name>  (standard composition)
Truncated to 63 chars and any trailing dash removed.
*/}}
{{- define "payments-api.fullname" -}}
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
Create chart label value in the form <chart-name>-<chart-version>.
Used by the "helm.sh/chart" label.
*/}}
{{- define "payments-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource managed by this chart.
Includes both immutable selector labels and informational labels.
*/}}
{{- define "payments-api.labels" -}}
helm.sh/chart: {{ include "payments-api.chart" . }}
{{ include "payments-api.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels — used in matchLabels (must remain stable across upgrades).
Only name and instance are included here; do NOT add mutable labels.
*/}}
{{- define "payments-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "payments-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Return the ServiceAccount name to use.
Logic:
  - If serviceAccount.create=true and a custom name is provided → use custom name.
  - If serviceAccount.create=true and no name is provided → use fullname.
  - If serviceAccount.create=false → use "default" (or provided name if any).
*/}}
{{- define "payments-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
  {{- default (include "payments-api.fullname" .) .Values.serviceAccount.name }}
{{- else }}
  {{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
