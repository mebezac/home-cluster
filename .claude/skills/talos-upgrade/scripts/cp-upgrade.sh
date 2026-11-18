#!/usr/bin/env bash
# One CONTROL-PLANE node: upgrade to topf.yaml talosVersion with a powercycle reboot (never kexec:
# an elitebook hung after a kexec on 2026-09-30), then topf apply. Do the etcd leader LAST, and
# take `talosctl etcd snapshot` into the scratchpad before the first one.
# Usage: mise exec -- bash cp-upgrade.sh <host> <ip> <endpoint-ip>   (endpoint = ANOTHER control plane)
# A live apply is used only when the diff is the installer line alone (no kubelet restart). Any
# other diff is staged + powercycled: a live apply that restarts kubelet once left wyse-03's
# kubelet Failed until a reboot.
set -u
H=$1; N=$2; EP=$3
CPS=10.25.30.45,10.25.30.46,10.25.30.35
[ "$EP" != "$N" ] || { echo "endpoint must be another control plane"; exit 1; }
source "$(dirname "$0")/lib.sh"
render_target

etcd_ok() {  # 3 voters, no errors, one leader, one term
  timeout 20 talosctl -e "$EP" -n $CPS etcd status 2>/dev/null | python3 -c "
import sys
rows=[l.split() for l in sys.stdin.read().splitlines()[1:] if l.strip()]
# columns: node member db(2 words) in-use(3) leader idx term applied learner proto storage [errors] = 14 without errors
ok=len(rows)==3 and all(len(r)==14 and r[11]=='false' for r in rows) and len({r[7] for r in rows})==1 and len({r[9] for r in rows})==1
print('ok' if ok else 'bad', 'leader=%s term=%s' % ({r[7] for r in rows}, {r[9] for r in rows}) if rows else 'no-rows')"
}
powercycle_back() {
  local before u
  before=$(timeout 10 talosctl -e "$EP" -n "$N" read /proc/uptime 2>/dev/null | awk '{print int($1)}')
  timeout 30 talosctl -e "$EP" -n "$N" reboot --drain --mode powercycle --wait=false >/dev/null 2>&1
  for i in $(seq 1 60); do
    sleep 10; u=$(timeout 10 talosctl -e "$EP" -n "$N" read /proc/uptime 2>/dev/null | awk '{print int($1)}')
    log "  t=$((i*10))s uptime=${u:-unreachable} kubelet=$(kubelet_state)"
    [ -n "$u" ] && [ "$u" -lt "${before:-999999}" ] && [ "$(kubelet_state)" = Running ] && return 0
  done
  abort "node not back 10 min after powercycle (ping but no :50000 for >5 min = hung: ask the user to check the screen)"
}

log "target $TARGET image $IMG endpoint $EP"
E=$(etcd_ok); log "== 0. etcd before: $E"
[ "${E%% *}" = ok ] || abort "etcd not healthy before"

log "== 1. upgrade (Talos drains, powercycles, uncordons)"
UL=$(mktemp)
for try in 1 2 3; do
  talosctl -e "$EP" -n "$N" upgrade --image "$IMG" --reboot-mode powercycle --progress plain --timeout 25m >"$UL" 2>&1; rc=$?
  log "upgrade try $try rc=$rc"
  [ $rc = 0 ] && break
  grep -qiE 'pull|lookup|i/o timeout|no such host' "$UL" && ! grep -q "installation of $TARGET complete" "$UL" \
    && { tail -5 "$UL"; log "image pull failed; retry"; sleep 20; continue; }
  tail -20 "$UL"; break
done
wait_version 48 || { tail -20 "$UL"; abort "not on $TARGET (got $(tver))"; }
log "booted $TARGET"

log "== 2. Ready + etcd + static pods"
wait_machine_ready || abort "machine not ready"
for i in $(seq 1 30); do E=$(etcd_ok); log "  t=$((i*10))s etcd $E"; [ "${E%% *}" = ok ] && break; sleep 10; done
[ "${E%% *}" = ok ] || abort "etcd not converged"
for _ in $(seq 1 30); do
  S=$(kubectl -n kube-system get pods --field-selector spec.nodeName="$H" --no-headers 2>/dev/null | grep -E 'apiserver|controller-manager|scheduler' | awk '$2=="1/1"' | wc -l)
  [ "$S" = 3 ] && break; sleep 10
done
[ "$S" = 3 ] || abort "static control-plane pods not 3x 1/1 (got $S)"
log "etcd ok, static pods 3/3"

log "== 3. topf apply"
for _ in $(seq 1 18); do topf_dry >/dev/null; d=$?; [ $d != 1 ] && break; sleep 10; done
if [ "$d" = 2 ] && ! installer_only_diff; then
  log "diff is more than the installer line: staged apply + powercycle"
  topf apply --nodes-filter "^$H\$" --mode staged --skip-post-apply-checks --confirm=false --colored never 2>&1 | grep -q 'mode=STAGED' || abort "staged apply failed"
  powercycle_back
  wait_machine_ready || abort "machine not ready after powercycle"
fi
topf_apply_live
[ "$(kubelet_state)" = Running ] || abort "kubelet not Running after apply"
log "no drift, kubelet Running"

log "== 4. uncordon check + health gate"
kubectl get node "$H" --no-headers | grep -q SchedulingDisabled && { log "still cordoned: uncordon"; kubectl uncordon "$H" >/dev/null; }
health_gate && log "etcd $(etcd_ok)" && log DONE
