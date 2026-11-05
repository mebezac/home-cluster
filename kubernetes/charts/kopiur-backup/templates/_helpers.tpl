{{- define "kopiur-backup.validate" -}}
{{- if not .Values.pvc -}}{{- fail "kopiur-backup: set .Values.pvc" -}}{{- end -}}
{{- if not (has .Values.tier (list "critical" "standard")) -}}
{{- fail (printf "kopiur-backup: tier must be critical or standard, not %q" .Values.tier) -}}
{{- end -}}
{{- if not (has .Values.copyMethod (list "Snapshot" "Direct")) -}}
{{- fail (printf "kopiur-backup: copyMethod must be Snapshot or Direct, not %q" .Values.copyMethod) -}}
{{- end -}}
{{- if and .Values.mover.privileged .Values.mover.runAsUser -}}
{{- fail "kopiur-backup: set mover.privileged or mover.runAsUser, not both" -}}
{{- end -}}
{{- if and .Values.verification.deep.enabled (not .Values.verification.deep.capacity) -}}
{{- fail "kopiur-backup: verification.deep needs verification.deep.capacity" -}}
{{- end -}}
{{- end -}}

{{- define "kopiur-backup.labels" -}}
app.kubernetes.io/name: kopiur-backup
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
kopiur-backup/pvc: {{ .Values.pvc | quote }}
kopiur-backup/tier: {{ .Values.tier | quote }}
{{- end -}}

{{- define "kopiur-backup.annotations" -}}
# The Kopiur CRDs come from the kopiur Application. On a new cluster this lets
# the app sync before they exist; Argo retries.
argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
{{- end -}}

{{/* Explicit mover identity, shared by the policy and the Restore. Empty in inherit mode. */}}
{{- define "kopiur-backup.explicitMover" -}}
{{- $m := .Values.mover -}}
{{- $gid := default $m.runAsUser $m.runAsGroup -}}
{{- $fsg := default $gid $m.fsGroup -}}
{{- if $m.privileged -}}
privilegedMode: true
securityContext:
  runAsUser: 0
  runAsGroup: 0
  runAsNonRoot: false
podSecurityContext:
  fsGroup: 0
{{- else if $m.runAsUser -}}
securityContext:
  runAsUser: {{ int $m.runAsUser }}
  runAsGroup: {{ int $gid }}
podSecurityContext:
  fsGroup: {{ int $fsg }}
{{- end -}}
{{- end -}}

{{- define "kopiur-backup.explicit" -}}
{{- if or .Values.mover.privileged .Values.mover.runAsUser -}}true{{- end -}}
{{- end -}}
