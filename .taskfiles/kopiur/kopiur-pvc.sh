#!/usr/bin/env bash
# Kopiur recovery for one PVC that kubernetes/charts/kopiur-backup backs up.
# Run it through task (task --list | grep kopiur). Usage:
#
#   kopiur-pvc.sh list     <ns> <pvc>
#   kopiur-pvc.sh snapshot <ns> <pvc>
#   kopiur-pvc.sh file     <ns> <pvc> <path-in-pvc> [dest] [offset]
#   kopiur-pvc.sh rollback <ns> <pvc> [offset|RFC3339-time]
#   kopiur-pvc.sh refill   <ns> <pvc> [snapshot-first]
#   kopiur-pvc.sh cutover  <ns> <pvc>
#
# rollback: stop the app, take a safety snapshot, make the PVC an exact copy of
#   an older snapshot (in place, extra files deleted), start the app. offset 1 =
#   the snapshot before the latest (counted BEFORE the safety snapshot). To undo
#   a rollback, roll back again with offset 1.
# refill: stop the app, delete the PVC and its populator Restore, and let Argo
#   create both again. The new PVC fills from the latest snapshot. Needs
#   restore.enabled and the PVC's dataSourceRef. snapshot-first takes a snapshot
#   of the current data first (for a cutover or a move); leave it out when the
#   current data is broken, or the refill brings the broken data back.
#
# cutover: move an existing PVC onto its populator Restore, once. First commit
#   restore.enabled and the PVC's dataSourceRef (Argo then shows a sync error,
#   because a bound PVC's dataSourceRef cannot change). Then run this: stop the
#   app, take a snapshot, keep the old volume (PV reclaim Retain), delete the
#   PVC, and let Argo create it again from that snapshot. The old PV stays
#   Released; delete it when the app looks right.
#
# A mover that copies the app pod's user cannot run while the app is stopped, so
# for those policies the extra snapshot runs just BEFORE the stop (writes in the
# few seconds after it are lost). With an explicit or privileged mover it runs
# after the stop.
#
# Both pause the Argo Application's auto-sync while they work and turn it back on
# at the end, also on failure. Argo then scales the app back up.
set -euo pipefail

cmd=${1:?command}; ns=${2:?namespace}; pvc=${3:?pvc}; shift 3
log() { printf '>> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v kubectl-kopiur >/dev/null || die "kubectl-kopiur is not on PATH (mise install)"

# --- lookups -----------------------------------------------------------------

# Succeeded Snapshot CRs of this PVC's policy, newest first: "<name> <start> <kopia-id>"
snapshots() {
  kubectl get snapshots.kopiur.home-operations.com -n "$ns" -o json | jq -r --arg p "$pvc" '
    [.items[] | select(.metadata.labels["kopiur.home-operations.com/config"] == $p)
              | select(.status.phase == "Succeeded")
              | {n: .metadata.name, t: (.status.timing.startTime // .metadata.creationTimestamp),
                 id: .status.snapshot.kopiaSnapshotID}]
    | sort_by(.t) | reverse | .[] | "\(.n) \(.t) \(.id)"'
}

# Pick a snapshot by offset (0 = latest) or by time (newest at or before it).
pick_snapshot() {
  local sel=${1:-0} list
  list=$(snapshots)
  [ -n "$list" ] || die "no successful snapshots for $ns/$pvc"
  if [[ $sel =~ ^[0-9]+$ ]]; then
    sed -n "$((sel + 1))p" <<<"$list" | awk '{print $1}'
  else
    local want; want=$(date -u -d "$sel" +%s) || die "cannot read time '$sel'"
    while read -r n t _; do
      [ "$(date -u -d "$t" +%s)" -le "$want" ] && { echo "$n"; return; }
    done <<<"$list"
  fi
}

argo_app() {
  kubectl get pvc -n "$ns" "$pvc" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null | cut -d: -f1
}

# Deployments/StatefulSets whose pods mount the PVC: "kind/name"
workloads() {
  local rs
  kubectl get pods -n "$ns" -o json | jq -r --arg c "$pvc" '
    .items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $c))
    | .metadata.ownerReferences[]? | "\(.kind)/\(.name)"' | sort -u | while read -r o; do
    case $o in
      ReplicaSet/*) rs=${o#ReplicaSet/}
        kubectl get rs -n "$ns" "$rs" -o jsonpath='{range .metadata.ownerReferences[*]}{.kind}/{.name}{"\n"}{end}' ;;
      StatefulSet/*|Deployment/*) echo "$o" ;;
      *) die "pod owner $o is not a Deployment or StatefulSet; stop it by hand" ;;
    esac
  done | sort -u
}

# --- stop / start ------------------------------------------------------------

APP=""; AUTOMATED=""; WORKLOADS=""
stop_app() {
  APP=$(argo_app)
  [ -n "$APP" ] || die "$ns/$pvc has no Argo tracking-id; cannot find its Application"
  AUTOMATED=$(kubectl get application -n argo-system "$APP" -o json | jq -c '.spec.syncPolicy.automated // empty')
  [ -n "$AUTOMATED" ] || die "Application $APP has no automated sync to pause (already paused?)"
  log "pausing auto-sync of Application $APP"
  kubectl patch application -n argo-system "$APP" --type=json \
    -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' >/dev/null
  trap start_app EXIT
  WORKLOADS=$(workloads)
  for w in $WORKLOADS; do log "scaling $w to 0"; kubectl scale -n "$ns" "$w" --replicas=0 >/dev/null; done
  log "waiting until no pod mounts $pvc"
  for _ in $(seq 1 60); do
    [ -z "$(kubectl get pods -n "$ns" -o json | jq -r --arg c "$pvc" \
      '.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $c)) | select(.metadata.labels["app.kubernetes.io/managed-by"] != "kopiur") | .metadata.name')" ] && return
    sleep 5
  done
  die "pods still mount $pvc after 5 minutes"
}

start_app() {
  trap - EXIT
  [ -n "$APP" ] || return 0
  log "turning auto-sync of Application $APP back on (Argo scales the app back up)"
  kubectl patch application -n argo-system "$APP" --type=merge \
    -p "{\"spec\":{\"syncPolicy\":{\"automated\":$AUTOMATED}}}" >/dev/null
  kubectl annotate application -n argo-system "$APP" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
}

# The restore mover runs as the backup's mover: explicit fields copied from the
# policy, or the identity recorded on the snapshot.
restore_mover() {
  kubectl get snapshotpolicy -n "$ns" "$pvc" -o json | jq -c '
    .spec.mover // {} | if .inheritSecurityContextFrom then
      del(.inheritSecurityContextFrom) + {inheritSecurityContextFrom: {snapshot: {}}} else . end'
}

# Kopiur 0.10.16 leaves the populator Restore's projected key copy
# (<pvc>-restore-creds-N) in the app namespace after the fill. The other mover
# paths delete theirs. Delete it once the PVC is Bound (the fill is done then).
cleanup_restore_creds() {
  local s
  for s in $(kubectl get secrets -n "$ns" -l app.kubernetes.io/component=credentials -o json | jq -r --arg p "$pvc" \
      '.items[] | select(.metadata.name | startswith($p + "-restore-creds-")) | .metadata.name'); do
    log "deleting leftover key copy $ns/$s"
    kubectl delete secret -n "$ns" "$s" >/dev/null
  done
}

inherits_user() {
  [ "$(kubectl get snapshotpolicy -n "$ns" "$pvc" -o jsonpath='{.spec.mover.inheritSecurityContextFrom}')" != "" ]
}

# Stop the app with a snapshot of its data taken at the right moment.
stop_with_snapshot() {
  if inherits_user; then
    log "snapshot of the current data (before the stop: this mover copies the pod's user)"
    kubectl kopiur snapshot now --policy "$pvc" -n "$ns" --wait >&2
    stop_app
  else
    stop_app
    log "snapshot of the current data (app stopped)"
    kubectl kopiur snapshot now --policy "$pvc" -n "$ns" --wait >&2
  fi
}

wait_restore() {
  local name=$1 phase
  for _ in $(seq 1 360); do
    phase=$(kubectl get restore -n "$ns" "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    case $phase in
      Completed|Succeeded) log "restore $name: $phase"; return 0 ;;
      Failed) kubectl get restore -n "$ns" "$name" -o json | jq '.status.conditions' >&2; die "restore $name failed" ;;
    esac
    sleep 5
  done
  die "restore $name did not finish in 30 minutes"
}

# --- commands ----------------------------------------------------------------

case $cmd in
  list)
    kubectl kopiur snapshots list -n "$ns" | awk -v p="$pvc" 'NR == 1 || $2 == p'
    ;;

  snapshot)
    kubectl kopiur snapshot now --policy "$pvc" -n "$ns" --wait
    ;;

  file)
    path=${1:?path inside the PVC, e.g. config/app.db}; dest=${2:-./$(basename "$path")}; sel=${3:-0}
    snap=$(pick_snapshot "$sel"); [ -n "$snap" ] || die "no snapshot for '$sel'"
    log "downloading $path from $snap to $dest"
    kubectl kopiur download -n "$ns" "$snap" "$path" "$dest"
    ;;

  rollback)
    sel=${1:-1}
    snap=$(pick_snapshot "$sel"); [ -n "$snap" ] || die "no snapshot for '$sel'"
    log "rolling $ns/$pvc back to $snap (undo afterwards: rollback offset 1)"
    stop_with_snapshot
    name="$pvc-rollback-$(date -u +%Y%m%d%H%M%S)"
    kubectl apply -f - >/dev/null <<EOF
apiVersion: kopiur.home-operations.com/v1alpha1
kind: Restore
metadata:
  name: $name
  namespace: $ns
spec:
  source:
    snapshotRef:
      name: $snap
  target:
    pvcRef:
      name: $pvc
  options:
    enableFileDeletion: true
    writeFilesAtomically: true
  policy:
    onMissingSnapshot: Fail
  credentialProjection:
    enabled: true
  mover: $(restore_mover)
EOF
    wait_restore "$name"
    kubectl delete restore -n "$ns" "$name" >/dev/null
    start_app
    log "done: $ns/$pvc now holds $snap"
    ;;

  refill)
    kubectl get restore -n "$ns" "$pvc" >/dev/null 2>&1 || die "no populator Restore $ns/$pvc (set restore.enabled)"
    [ "$(kubectl get pvc -n "$ns" "$pvc" -o jsonpath='{.spec.dataSourceRef.name}')" = "$pvc" ] \
      || die "PVC $ns/$pvc has no dataSourceRef to Restore $pvc; Argo would re-create it empty"
    if [ "${1:-}" = snapshot-first ]; then
      stop_with_snapshot
    else
      snapshots | head -1 | grep -q . || die "no successful snapshot to refill from"
      stop_app
    fi
    log "deleting PVC $ns/$pvc and Restore $ns/$pvc (Argo re-creates both)"
    kubectl delete pvc -n "$ns" "$pvc" --wait=true
    kubectl delete restore -n "$ns" "$pvc" --wait=true
    start_app
    log "waiting for the new PVC to fill"
    for _ in $(seq 1 120); do
      kubectl get restore -n "$ns" "$pvc" >/dev/null 2>&1 && break; sleep 5
    done
    for _ in $(seq 1 360); do
      [ "$(kubectl get pvc -n "$ns" "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null)" = Bound ] && break; sleep 5
    done
    kubectl get restore -n "$ns" "$pvc" -o json | jq '{phase: .status.phase, resolved: .status.resolved}'
    cleanup_restore_creds
    kubectl get pvc -n "$ns" "$pvc"
    ;;

  cutover)
    kubectl get restore -n "$ns" "$pvc" >/dev/null 2>&1 || die "no populator Restore $ns/$pvc (set restore.enabled and sync)"
    [ -z "$(kubectl get pvc -n "$ns" "$pvc" -o jsonpath='{.spec.dataSourceRef.name}')" ] \
      || die "PVC $ns/$pvc already has a dataSourceRef; use refill"
    [ -z "$(kubectl get restore -n "$ns" "$pvc" -o jsonpath='{.status.resolved.resolution}')" ] \
      || die "Restore $ns/$pvc already resolved a snapshot; delete it so Argo re-creates it, then retry"
    pv=$(kubectl get pvc -n "$ns" "$pvc" -o jsonpath='{.spec.volumeName}')
    stop_with_snapshot
    log "keeping the old volume: PV $pv reclaimPolicy Retain"
    kubectl patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null
    log "deleting PVC $ns/$pvc (Argo re-creates it with the dataSourceRef)"
    kubectl delete pvc -n "$ns" "$pvc" --wait=true
    start_app
    log "waiting for the new PVC to fill"
    for _ in $(seq 1 360); do
      [ "$(kubectl get pvc -n "$ns" "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null)" = Bound ] && break; sleep 5
    done
    kubectl get restore -n "$ns" "$pvc" -o json | jq '{phase: .status.phase, resolved: .status.resolved}'
    cleanup_restore_creds
    kubectl get pvc -n "$ns" "$pvc"
    log "old volume kept as Released PV $pv. When the app looks right: kubectl delete pv $pv"
    ;;

  *) die "unknown command $cmd (list, snapshot, file, rollback, refill, cutover)" ;;
esac
