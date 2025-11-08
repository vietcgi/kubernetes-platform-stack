{{/*
Standard pod security context
Usage: {{ include "platform-library.podSecurityContext" .Values.podSecurityContext }}
*/}}
{{- define "platform-library.podSecurityContext" -}}
runAsNonRoot: {{ .runAsNonRoot | default true }}
runAsUser: {{ .runAsUser | default 1000 }}
{{- if .fsGroup }}
fsGroup: {{ .fsGroup }}
{{- end }}
{{- end }}

{{/*
Standard container security context
Usage: {{ include "platform-library.containerSecurityContext" .Values.securityContext }}
*/}}
{{- define "platform-library.containerSecurityContext" -}}
allowPrivilegeEscalation: {{ .allowPrivilegeEscalation | default false }}
capabilities:
  drop:
    {{- range .capabilities.drop | default (list "ALL") }}
    - {{ . }}
    {{- end }}
{{- if .readOnlyRootFilesystem }}
readOnlyRootFilesystem: {{ .readOnlyRootFilesystem }}
{{- end }}
{{- end }}

{{/*
RBAC configuration
Usage: {{ include "platform-library.rbacConfig" .Values.rbac }}
*/}}
{{- define "platform-library.rbacConfig" -}}
create: {{ .create | default true }}
{{- if .name }}
name: {{ .name }}
{{- end }}
{{- end }}

{{/*
Service account configuration
Usage: {{ include "platform-library.serviceAccount" (dict "create" true "name" "my-sa" "automount" true) }}
*/}}
{{- define "platform-library.serviceAccount" -}}
create: {{ .create | default true }}
{{- if .name }}
name: {{ .name }}
{{- end }}
automountServiceAccountToken: {{ .automountServiceAccountToken | default true }}
{{- end }}
