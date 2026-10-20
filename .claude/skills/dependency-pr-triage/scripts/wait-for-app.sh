#!/usr/bin/env bash
# Wait for an ArgoCD Application to finish deploying a merged bump, then print
# one status line. Read-only: only `kubectl get`.
#
# Usage: wait-for-app.sh <app> [--rev <sha>] [--repo <path>] [--chart <name> <version>] [--ds <ns>/<name>] [--timeout <sec>]
#   app       Application name (NOT always the file name - argo-cd's app is `argo`)
#   --rev     require the synced git revision to be this sha (your merge commit)
#             OR A LATER COMMIT that contains it. Without it, an app that hasn't
#             polled yet reads Synced/Healthy at the OLD revision and passes
#             immediately. "Later" matters when several PRs merge while you wait:
#             Argo syncs HEAD, so the app may never sit at your exact sha.
#             Uses `git merge-base --is-ancestor` in this repo (fetches if the
#             commit isn't local), so it works for concurrent waits. A commit
#             that renders no change for this app (comments only) passes as soon
#             as the app is Synced at it - Argo runs no sync op for a no-op.
#   --repo    git checkout that --rev belongs to. Default: the first of the
#             current directory's repo, then this script's repo (home-cluster),
#             that has the commit after a fetch - so running it from
#             home-cluster-private for a private-repo merge just works.
#   --chart   also require that source's targetRevision == version (chart bumps
#             propagate in two hops: `apps` first, then the app itself)
#   --ds      also require the DaemonSet to be fully rolled (updated == available == desired).
#             An OPERATOR-managed DaemonSet (e.g. intel-gpu) can roll a second time
#             after the operator itself restarts - re-check with `kubectl rollout status`.
#   --timeout give up after N seconds (default 600)
#
# --chart/--rev are also checked against the LAST SYNC OPERATION's revisions, not
# only spec/status: right after `apps` bumps a chart, the app can read
# Synced/Healthy op=Succeeded from the PREVIOUS operation before its own sync
# starts (seen on the self-managed `argo` app).
#
# Exit: 0 done+healthy, 1 failed/degraded AT the target (a Degraded state from
# before --rev/--chart lands keeps waiting), 2 timed out. Prints a status line
# every 30s so a stalled rollout is visible, not silent.
#
# Keep this a bash script: the Claude Code Bash tool runs zsh, which does NOT
# word-split unquoted variables, so hand-rolled `set -- $x` loops never match.
set -uo pipefail

app=$1; shift
chart="" version="" ds="" rev="" repo="" timeout=600
while [[ $# -gt 0 ]]; do
  case $1 in
    --chart) chart=$2 version=$3; shift 3 ;;
    --ds) ds=$2; shift 2 ;;
    --rev) rev=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    --timeout) timeout=$2; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

k() { kubectl --request-timeout=15s "$@"; }

# True if commit $1 is $rev or descends from it.
reached() {
  local c=$1
  [[ $c =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ $c == "$rev"* ]] && return 0
  git -C "$repo" cat-file -e "$c^{commit}" 2>/dev/null || git -C "$repo" fetch -q origin 2>/dev/null
  git -C "$repo" merge-base --is-ancestor "$rev" "$c" 2>/dev/null
}

# Pick the checkout --rev lives in: --repo if given, else the cwd's repo, then
# this script's repo. Each Argo app tracks one repo, and a private-repo sha is
# never in home-cluster, so don't assume the script's own checkout.
has_rev() {
  git -C "$1" cat-file -e "$rev^{commit}" 2>/dev/null && return 0
  git -C "$1" fetch -q origin 2>/dev/null
  git -C "$1" cat-file -e "$rev^{commit}" 2>/dev/null
}
if [[ -n $rev ]]; then
  if [[ -n $repo ]]; then
    cands=("$repo")
  else
    cands=()
    t=$(git rev-parse --show-toplevel 2>/dev/null) && cands+=("$t")
    cands+=("$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)")
  fi
  found=""
  for c in "${cands[@]}"; do has_rev "$c" && { found=$c; break; }; done
  [[ -n $found ]] || { echo "unknown --rev $rev (not in ${cands[*]} after fetch)" >&2; exit 64; }
  repo=$found
fi
deadline=$((SECONDS + timeout)) last_print=-30

while :; do
  st=$(k get application "$app" -n argo-system -o json 2>/dev/null | jq -r --arg c "$chart" '
    [.status.sync.status, .status.health.status, (.status.operationState.phase // "none"),
     (if $c == "" then "-" else ([.spec.sources[]? | select(.chart == $c) | .targetRevision] | first // "?") end),
     ([(.status.sync.revisions // [.status.sync.revision])[]? | select(test("^[0-9a-f]{40}$"))] | first // "?"),
     ((.status.operationState.syncResult.revisions // [.status.operationState.syncResult.revision // "?"]) | map(. // "?") | join(","))]
    | join(" ")')
  read -r sync health phase crev synced oprevs <<<"${st:-? ? ? ? ? ?}"

  # The finished operation must itself have deployed the wanted chart / commit.
  op_ok=1
  if [[ -n $chart ]] && [[ ",$oprevs," != *",$version,"* ]]; then op_ok=0; fi
  rev_ok=1
  if [[ -n $rev ]]; then
    reached "$synced" || rev_ok=0
    op_rev_ok=0
    IFS=, read -ra ops <<<"$oprevs"
    for o in "${ops[@]}"; do reached "$o" && { op_rev_ok=1; break; }; done
    # A commit that doesn't change this app's rendered manifests (a comment, or
    # another app's file) never gets a sync operation: Argo compares, finds
    # nothing to apply, and marks it Synced at the new revision. Live == desired
    # at the target then, so that counts too.
    [[ $sync == Synced ]] && (( rev_ok )) && op_rev_ok=1
    (( op_rev_ok )) || op_ok=0
  fi

  ds_ok=1 ds_msg=""
  if [[ -n $ds ]]; then
    read -r want upd avail < <(k get ds "${ds#*/}" -n "${ds%/*}" \
      -o jsonpath='{.status.desiredNumberScheduled} {.status.updatedNumberScheduled} {.status.numberAvailable}' 2>/dev/null)
    ds_msg=" ds=${upd:-?}/${avail:-?}/${want:-?}"
    [[ -n ${want:-} && $want == "${upd:-}" && $want == "${avail:-}" ]] || ds_ok=0
  fi

  line="$app: $sync $health op=$phase rev=${synced:0:8}${chart:+ $chart=$crev}$ds_msg"
  (( op_ok )) || line+=" (last sync op not yet at target)"
  # Only fail on the target's own state: an app that is already Degraded (the
  # bump you are fixing) reads Degraded at the OLD revision until Argo polls.
  if (( op_ok && rev_ok )) && [[ $phase == Failed || $phase == Error || $health == Degraded ]]; then
    echo "FAILED  $line"; exit 1
  fi
  if [[ $sync == Synced && $health == Healthy && $phase != Running \
        && ( -z $chart || $crev == "$version" ) && $rev_ok == 1 && $ds_ok == 1 && $op_ok == 1 ]]; then
    echo "DONE    $line"; exit 0
  fi
  if (( SECONDS >= deadline )); then echo "TIMEOUT $line"; exit 2; fi
  if (( SECONDS - last_print >= 30 )); then echo "waiting $line"; last_print=$SECONDS; fi
  sleep 10
done
