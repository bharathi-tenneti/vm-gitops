{{- define "vm.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: vm-gitops
{{- with .Values.labels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "vm.cloudInitUserData" -}}
#cloud-config
user: {{ .Values.cloudInit.user }}
{{- with .Values.cloudInit.sshAuthorizedKeys }}
ssh_authorized_keys:
{{- range . }}
  - {{ . | quote }}
{{- end }}
{{- end }}
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
{{- with .Values.cloudInit.extraUserData }}
{{ . }}
{{- end }}
{{- end -}}
