{{/*
Template helpers for the OpenSPP chart: resource naming, common labels, per-component selector
labels, the Secret name, the PostGIS service name, and the shared database-connection env block.
*/}}

{{- define "openspp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "openspp.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "openspp.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Common labels applied to every object. */}}
{{- define "openspp.labels" -}}
app.kubernetes.io/name: {{ include "openspp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: openspp
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* Per-component selector labels. */}}
{{- define "openspp.odoo.selectorLabels" -}}
app: openspp-odoo
tier: backend
{{- end -}}

{{- define "openspp.postgis.selectorLabels" -}}
app: openspp-postgis
tier: database
{{- end -}}

{{/* Name of the Secret to use (created here, or a pre-existing one). */}}
{{- define "openspp.secretName" -}}
{{- if .Values.secrets.existingSecret -}}
{{- .Values.secrets.existingSecret -}}
{{- else -}}
{{- printf "%s-secrets" (include "openspp.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* PostGIS headless service name (also the StatefulSet serviceName). */}}
{{- define "openspp.postgis.serviceName" -}}
{{- printf "%s-postgis" (include "openspp.fullname" .) -}}
{{- end -}}

{{/* Shared DB-connection env block (OpenSPP2 vars), used by the Odoo and jobworker Deployments.
The entrypoint aborts if any of these is missing. */}}
{{- define "openspp.odoo.dbEnv" -}}
- name: DB_HOST
  value: {{ include "openspp.postgis.serviceName" . | quote }}
- name: DB_PORT
  value: {{ .Values.postgis.port | quote }}
- name: DB_NAME
  value: {{ .Values.postgis.database | quote }}
- name: DB_USER
  value: {{ .Values.postgis.user | quote }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "openspp.secretName" . }}
      key: db-password
- name: ODOO_ADMIN_PASSWD
  valueFrom:
    secretKeyRef:
      name: {{ include "openspp.secretName" . }}
      key: odoo-admin-password
{{- end -}}
