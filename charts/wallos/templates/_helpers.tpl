{{/*
Expand the name of the chart.
*/}}
{{- define "wallos.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. If the release name already contains the chart name
it is used as-is, so `helm install wallos wallos/wallos` yields plain `wallos`.
*/}}
{{- define "wallos.fullname" -}}
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

{{- define "wallos.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "wallos.labels" -}}
helm.sh/chart: {{ include "wallos.chart" . }}
{{ include "wallos.selectorLabels" . }}
app.kubernetes.io/version: {{ include "wallos.imageTag" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "wallos.selectorLabels" -}}
app.kubernetes.io/name: {{ include "wallos.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "wallos.imageTag" -}}
{{- .Values.image.tag | default .Chart.AppVersion }}
{{- end }}

{{- define "wallos.image" -}}
{{- printf "%s:%s" .Values.image.repository (include "wallos.imageTag" .) }}
{{- end }}

{{/*
Name of the PVC holding the database and the uploaded logos.
*/}}
{{- define "wallos.claimName" -}}
{{- .Values.persistence.existingClaim | default (printf "%s-data" (include "wallos.fullname" .)) }}
{{- end }}

{{/*
The data volume, shared by the app and the backup job. Without persistence it
is an emptyDir and everything is lost with the pod -- NOTES.txt says so.
*/}}
{{- define "wallos.dataVolume" -}}
- name: data
{{- if .Values.persistence.enabled }}
  persistentVolumeClaim:
    claimName: {{ include "wallos.claimName" . }}
{{- else }}
  emptyDir: {}
{{- end }}
{{- end }}
