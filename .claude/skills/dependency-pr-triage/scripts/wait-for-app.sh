#!/usr/bin/env bash
# Wait for an ArgoCD Application to finish deploying a merged bump, then print
# one status line. Read-only: only `kubectl get`.
#
# Usage: wait-for-app.sh <app> [--rev <sha>] [--chart <name> <version>] [--ds <ns>/<name>] [--timeout <sec>]
#   app       Application name (NOT always the file name - argo-cd's app is `argo`)
#   --rev     require the synced git revision to start with this sha (your merge
#             commit). Without it, an app that hasn't polled yet reads
#             Synced/Healthy at the OLD revision and passes immediately.
#   --chart   also require that source's targetRevision == version (chart bumps
#             propagate in two hops: `apps` first, then the app itself)
#   --ds      also require the DaemonSet to be fully rolled (updated == available == desired)
#   --timeout give up after N seconds (default 600)
#
# Exit: 0 done+healthy, 1 failed/degraded, 2 timed out. Prints a status line
# every 30s so a stalled rollout is visible, not silent.
#
# Keep this a bash script: the Claude Code Bash tool runs zsh, which does NOT
# word-split unquoted variables, so hand-rolled `set -- $x` loops never match.
set -uo pipefail

app=$1; shift
chart="" version="" ds="" rev="" timeout=600
while [[ $# -gt 0 ]]; do
  case $1 in
    --chart) chart=$2 version=$3; shift 3 ;;
    --ds) ds=$2; shift 2 ;;
    --rev) rev=$2; shift 2 ;;
    --timeout) timeout=$2; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

k() { kubectl --request-timeout=15s "$@"; }
deadline=$((SECONDS + timeout)) last_print=-30

while :; do
  st=$(k get application "$app" -n argo-system -o json 2>/dev/null | jq -r --arg c "$chart" '
    [.status.sync.status, .status.health.status, (.status.operationState.phase // "none"),
     (if $c == "" then "-" else ([.spec.sources[]? | select(.chart == $c) | .targetRevision] | first // "?") end),
     ([(.status.sync.revisions // [.status.sync.revision])[]? | select(test("^[0-9a-f]{40}$"))] | first // "?")]
    | join(" ")')
  read -r sync health phase crev synced <<<"${st:-? ? ? ? ?}"

  ds_ok=1 ds_msg=""
  if [[ -n $ds ]]; then
    read -r want upd avail < <(k get ds "${ds#*/}" -n "${ds%/*}" \
      -o jsonpath='{.status.desiredNumberScheduled} {.status.updatedNumberScheduled} {.status.numberAvailable}' 2>/dev/null)
    ds_msg=" ds=${upd:-?}/${avail:-?}/${want:-?}"
    [[ -n ${want:-} && $want == "${upd:-}" && $want == "${avail:-}" ]] || ds_ok=0
  fi

  line="$app: $sync $health op=$phase rev=${synced:0:8}${chart:+ $chart=$crev}$ds_msg"
  if [[ $phase == Failed || $phase == Error || $health == Degraded ]]; then
    echo "FAILED  $line"; exit 1
  fi
  if [[ $sync == Synced && $health == Healthy && $phase != Running \
        && ( -z $chart || $crev == "$version" ) && ( -z $rev || $synced == "$rev"* ) && $ds_ok == 1 ]]; then
    echo "DONE    $line"; exit 0
  fi
  if (( SECONDS >= deadline )); then echo "TIMEOUT $line"; exit 2; fi
  if (( SECONDS - last_print >= 30 )); then echo "waiting $line"; last_print=$SECONDS; fi
  sleep 10
done
