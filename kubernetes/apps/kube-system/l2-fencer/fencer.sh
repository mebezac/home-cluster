#!/bin/sh
# l2-fencer: drop a NotReady node from the Cilium L2 announcement policy so a
# half-alive cilium-agent releases its LoadBalancer IP leases (audit 2026-11-26 #101).
set -u
LABEL=l2.laboratory.casa/fenced
FENCE_AFTER=${FENCE_AFTER:-120}      # seconds NotReady before fencing
UNFENCE_AFTER=${UNFENCE_AFTER:-300}  # seconds Ready before unfencing
INTERVAL=${INTERVAL:-15}
DRY_RUN=${DRY_RUN:-false}
ONCE=${ONCE:-false}
K="kubectl --request-timeout=10s"
TPL='{{range .items}}{{.metadata.name}} {{range .status.conditions}}{{if eq .type "Ready"}}{{.status}} {{.lastTransitionTime}}{{end}}{{end}} {{with index .metadata.labels "l2.laboratory.casa/fenced"}}{{.}}{{else}}-{{end}}{{"\n"}}{{end}}'
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
ts() { date -u -d "$1" +%s 2>/dev/null || date -u -D '%Y-%m-%dT%H:%M:%SZ' -d "$1" +%s; }
act() { # $1 node, $2 fence|unfence
  [ "$2" = fence ] && v="$LABEL=true" || v="$LABEL-"
  if [ "$DRY_RUN" = true ]; then log "dry-run: would $2 $1"; return 0; fi
  # Node label: durable (the agent copies Node labels into its CiliumNode).
  # CiliumNode label: reaches the L2 announcer directly, even if the agent's
  # Node->CiliumNode sync is stuck.
  if $K label node "$1" "$v" --overwrite >/dev/null && $K label ciliumnode "$1" "$v" --overwrite >/dev/null
  then log "$2 $1"; else log "ERROR: $2 $1 failed"; fi
}
while :; do
  [ "$ONCE" = true ] || sleep "$INTERVAL"
  if ! $K get --raw /readyz >/dev/null 2>&1; then log "skip: apiserver /readyz failed"; [ "$ONCE" = true ] && exit 0; continue; fi
  if ! nodes=$($K get nodes -o go-template="$TPL"); then log "skip: list nodes failed"; [ "$ONCE" = true ] && exit 0; continue; fi
  now=$(date -u +%s); notready=0; cand=""; fenced=""; unfence=""
  while read -r n st ltt f; do
    [ -n "$n" ] && [ -n "$ltt" ] || continue
    age=$(( now - $(ts "$ltt") ))
    if [ "$st" != True ]; then
      notready=$((notready + 1)); [ "$age" -ge "$FENCE_AFTER" ] && cand="$n ${age}s"
    fi
    if [ "$f" = true ]; then
      if [ "$st" = True ] && [ "$age" -ge "$UNFENCE_AFTER" ]; then unfence="$unfence $n"; else fenced="$n"; fi
    fi
  done <<EOT
$nodes
EOT
  for n in $unfence; do act "$n" unfence; done      # always safe: a Ready node may announce again
  if [ "$notready" -ge 2 ]; then
    log "skip: $notready nodes NotReady (control-plane trouble?), no fencing"
  elif [ -n "$cand" ] && [ -z "$fenced" ]; then
    log "node ${cand% *} NotReady for ${cand#* }"; act "${cand% *}" fence
  elif [ -n "$cand" ]; then
    log "hold: $fenced already fenced, ${cand% *} NotReady"
  fi
  [ "$ONCE" = true ] && { log "ok: notready=$notready fenced=${fenced:-none}"; exit 0; }
done
