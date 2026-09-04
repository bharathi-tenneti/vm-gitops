{{- define "vm-images.imageRef" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repo }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repo }}:{{ .Values.image.tag }}
{{- end -}}
{{- end -}}
