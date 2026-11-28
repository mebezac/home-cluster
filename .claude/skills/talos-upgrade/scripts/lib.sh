#!/usr/bin/env bash
# Shared helpers for the talos-upgrade scripts. Source it after H (host), N (node IP) and
# EP (talosctl endpoint, never the node being rebooted when it is a control plane) are set.
# Run the scripts through `mise exec --`: a bare talosctl on PATH can be an older install
# than the .mise.toml pin (seen 2026-11-17: 1.14.5 on PATH, 1.14.6 pinned).
# NEVER edit a script while a run of it is in progress: bash reads the file as it goes.
REPO=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
export TALOSCONFIG=$REPO/kubernetes/bootstrap/talos/talosconfig
export TOPFCONFIG=$REPO/kubernetes/bootstrap/talos/topf.yaml
export SOPS_AGE_KEY_FILE=$REPO/age.key
cd "$REPO/kubernetes/bootstrap/talos" || exit 1

log() { echo "[$(TZ=America/New_York date +%H:%M:%S)] $H: $*"; }
abort() { log "ABORT: $*"; exit 1; }
# `timeout N talosctl`, never `talosctl --timeout` (no such flag on version: it prints nothing).
# Prints the running version, or "<version>-schematic-<first 8>" while the node still runs a
# schematic other than WANT_SCHEMATIC (set by render_target). So a same-version schematic change
# (2026-11-27: SELinux off via extraKernelArgs) does not read as "already on TARGET" before the
# reboot. Empty when the node is unreachable.
tver() {
  local v s
  v=$(timeout 10 talosctl -e "$EP" -n "$N" version 2>/dev/null | grep -A2 Server | grep Tag | awk '{print $2}')
  [ -n "$v" ] || return 0
  if [ -n "${WANT_SCHEMATIC:-}" ]; then
    s=$(timeout 10 talosctl -e "$EP" -n "$N" get extensions 2>/dev/null | awk '$6=="schematic"{print $7}')
    [ "$s" = "$WANT_SCHEMATIC" ] || { echo "$v-schematic-${s:0:8}"; return 0; }
  fi
  echo "$v"
}
kubelet_state() { timeout 10 talosctl -e "$EP" -n "$N" service kubelet 2>/dev/null | awk '/^STATE/{print $2}'; }
wait_machine_ready() {
  for _ in $(seq 1 30); do
    [ "$(timeout 10 talosctl -e "$EP" -n "$N" get machinestatus -o jsonpath='{.spec.status.ready}' 2>/dev/null)" = true ] && return 0
    sleep 10
  done
  return 1
}

# Render (gitignored ./rendered holds PLAINTEXT secrets; never print it) and set TARGET + IMG.
render_target() {
  topf render --output ./rendered --confirm=false >/dev/null 2>&1 || abort "render failed"
  TARGET=$(yq '.talosVersion' topf.yaml)
  IMG=$(yq 'select(.kind=="UnattendedInstallConfig") | .installer.image' "rendered/$H.yaml")
  [ -n "$IMG" ] && [ -n "$TARGET" ] || abort "could not resolve image/version"
  WANT_SCHEMATIC=$(echo "$IMG" | sed -nE 's#.*/metal-installer/([0-9a-f]+):.*#\1#p')
  [ -n "$WANT_SCHEMATIC" ] || abort "no schematic ID in $IMG"
  log "want $TARGET schematic ${WANT_SCHEMATIC:0:8}, running $(tver)"
}

# Poll for the target version: bounded, one line per pass. Never gate on "node unreachable".
wait_version() {  # $1 = passes of 10 s
  local v
  for i in $(seq 1 "${1:-40}"); do
    v=$(tver); log "  t=$((i*10))s version=${v:-unreachable}"
    [ "$v" = "$TARGET" ] && return 0
    sleep 10
  done
  return 1
}

# topf dry-run: 0 = in sync, 2 = diff, 1 = error (for example the node is NotReady: retry).
topf_dry() { topf apply --nodes-filter "^$H\$" --dry-run --colored never 2>&1; }
# True when every changed line of the diff is the installer image (a same-schematic version bump).
# That kind of diff applies live: no reboot, and kubelet does NOT restart (checked on wyse-01,
# 2026-11-17), so it is safe on control planes too.
installer_only_diff() {
  local changed
  changed=$(topf_dry | grep -E '^\s*[-+]' | grep -vE '^\s*(---|\+\+\+)')
  [ -n "$changed" ] && ! echo "$changed" | grep -qv 'metal-installer/'
}
# Live apply when there is a diff, then require exit 0.
topf_apply_live() {
  local d out
  for _ in $(seq 1 18); do topf_dry >/dev/null; d=$?; [ $d != 1 ] && break; sleep 10; done
  log "pre-apply dry-run exit $d (2 = diff, 0 = in sync)"
  if [ "$d" = 2 ]; then
    out=$(topf apply --nodes-filter "^$H\$" --confirm=false --colored never 2>&1) || { echo "$out" | tail -20; abort "apply failed"; }
    log "applied"
    for _ in $(seq 1 18); do topf_dry >/dev/null; d=$?; [ $d = 0 ] && break; sleep 10; done
  fi
  [ "$d" = 0 ] || abort "config drift after apply (dry-run exit $d)"
}

# Pods that are not Ready. A Failed pod of a Job that later completed (a retry won) is history,
# not a fault: without this filter one failed CronJob attempt holds the gate for ever.
nonready_pods() {
  kubectl get pods,jobs -A -o json | python3 -c "
import sys,json;it=json.load(sys.stdin)['items']
done={(j['metadata']['namespace'],j['metadata']['name']) for j in it if j['kind']=='Job' and any(c['type']=='Complete' and c['status']=='True' for c in j['status'].get('conditions',[]))}
old=lambda p: p['status']['phase']=='Failed' and any(o['kind']=='Job' and (p['metadata']['namespace'],o['name']) in done for o in p['metadata'].get('ownerReferences',[]))
bad=[p['metadata']['namespace']+'/'+p['metadata']['name'] for p in it if p['kind']=='Pod' and not old(p) and (p['status']['phase'] not in ('Running','Succeeded') or (p['status']['phase']=='Running' and not any(c['type']=='Ready' and c['status']=='True' for c in p['status'].get('conditions',[]))))]
print(len(bad), ' '.join(bad[:5]))"
}
# Attached volumes whose last healthy running replica is on $H: they go offline in the reboot.
# Detached volumes have no running replica anywhere, so they always match; only ATTACHED count.
attached_last_replica() {
  kubectl -n longhorn-system get replicas.longhorn.io,volumes.longhorn.io -o json | python3 -c "
import sys,json
from collections import defaultdict
it=json.load(sys.stdin)['items']; NODE='$H'; by=defaultdict(list)
state={v['metadata']['name']:v['status'].get('state') for v in it if v['kind']=='Volume'}
for r in it:
    if r['kind']=='Replica': by[r['spec']['volumeName']].append(r)
out=[]
for vn,reps in by.items():
    if not any(r['spec'].get('nodeID')==NODE for r in reps): continue
    he=sum(1 for r in reps if r['spec'].get('nodeID')!=NODE and r['spec'].get('healthyAt') and r.get('status',{}).get('currentState')=='running')
    if he==0 and state.get(vn)=='attached': out.append(vn)
print(' '.join(out))"
}
# After the drain: wait until no attached volume needs this node (single-replica volumes follow
# their pod to its new node by best-effort locality). 30 min bound, one line per pass.
wait_no_last_replica() {
  local a
  for i in $(seq 1 90); do
    a=$(attached_last_replica); log "  t=$((i*20))s attached-last-replica-here: ${a:-none}"
    [ -z "$a" ] && return 0
    sleep 20
  done
  abort "attached volumes still have their last healthy replica here: $a"
}
longhorn_summary() {
  kubectl -n longhorn-system get volumes.longhorn.io -o json | python3 -c "
import sys,json;from collections import Counter;c=Counter(v['status'].get('robustness') for v in json.load(sys.stdin)['items']);print(' '.join(f'{k}={v}' for k,v in sorted(c.items())))"
}
# GATE before the next node: no degraded/faulted volume, 0 non-ready pods, CNPG 3/3. 20 min bound.
health_gate() {
  local v p c
  for i in $(seq 1 60); do
    v=$(longhorn_summary); p=$(nonready_pods)
    c=$(kubectl -n database get clusters.postgresql.cnpg.io postgres-17-cluster -o jsonpath='{.status.readyInstances}')
    [ $((i % 3)) = 1 ] && log "  t=$((i*20))s volumes[$v] nonready_pods=$p cnpg=$c/3"
    if ! echo "$v" | grep -qE 'degraded|faulted' && [ "${p%% *}" = 0 ] && [ "$c" = 3 ]; then
      log "GATE_PASS volumes[$v]"; return 0
    fi
    sleep 20
  done
  abort "health gate not reached in 20 min (last: volumes[$v] nonready=$p cnpg=$c/3)"
}

# Cordon, Longhorn no-schedule WITHOUT eviction (local replicas re-attach after the reboot), drain.
# DRAIN_FORCE=1 also deletes bare pods (no controller), e.g. the Guildhall runners in
# guildhall-workers. Only with the user's OK: nothing re-creates them except Guildhall.
cordon_drain() {
  kubectl cordon "$H" >/dev/null || abort cordon
  kubectl -n longhorn-system patch nodes.longhorn.io "$H" --type=merge \
    -p '{"spec":{"allowScheduling":false,"evictionRequested":false}}' >/dev/null || abort "longhorn patch"
  kubectl drain "$H" --ignore-daemonsets --delete-emptydir-data --timeout=15m ${DRAIN_FORCE:+--force} >/dev/null 2>&1 \
    || { kubectl drain "$H" --ignore-daemonsets --delete-emptydir-data --dry-run=server ${DRAIN_FORCE:+--force} 2>&1 | grep -i error
         abort "drain failed (bare pods? re-run with DRAIN_FORCE=1 after the user agrees)"; }
  log "drained"
}
restore_scheduling() {
  kubectl -n longhorn-system patch nodes.longhorn.io "$H" --type=merge \
    -p '{"spec":{"allowScheduling":true,"evictionRequested":false}}' >/dev/null
  kubectl uncordon "$H" >/dev/null
}
longhorn_disks_ready() {
  local r
  for i in $(seq 1 30); do
    r=$(kubectl -n longhorn-system get nodes.longhorn.io "$H" -o json | python3 -c "
import sys,json;d=json.load(sys.stdin)['status']['diskStatus']
print('ok' if all({c['type']:c['status'] for c in s.get('conditions',[])}.get('Ready')=='True' for s in d.values()) else 'wait')")
    log "  t=$((i*10))s longhorn disks: $r"; [ "$r" = ok ] && return 0; sleep 10
  done
  abort "Longhorn disks not Ready"
}
