#!/usr/bin/env bash
# One-node talmac upgrade to topf.yaml talosVersion + topf config (proven on all 3 talmacs, 2026-10-01).
# Run from inside the repo (mise shims). Renders first; never prints rendered configs (plaintext secrets).
# Usage: talmac-upgrade.sh <host> <ip>. Every wait is bounded and logs each iteration;
# any unexpected state prints ABORT and exits non-zero, leaving the node cordoned.
set -u
H=$1; N=$2; EP=10.25.30.45
REPO=/Users/zac/projects/lab_casa/home-cluster
export TALOSCONFIG=$REPO/kubernetes/bootstrap/talos/talosconfig
export TOPFCONFIG=$REPO/kubernetes/bootstrap/talos/topf.yaml
export SOPS_AGE_KEY_FILE=$REPO/age.key
cd $REPO/kubernetes/bootstrap/talos
mise exec -- topf render --output ./rendered --confirm=false >/dev/null 2>&1 || { echo "render failed"; exit 1; }
TARGET=$(yq '.talosVersion' topf.yaml)
IMG=$(yq 'select(.kind=="UnattendedInstallConfig") | .installer.image' rendered/$H.yaml)
[ -n "$IMG" ] && [ -n "$TARGET" ] || { echo "could not resolve image/version"; exit 1; }
log() { echo "[$(date +%H:%M:%S)] $H: $*"; }
abort() { log "ABORT: $*"; exit 1; }
tver() { timeout 10 talosctl -e $EP -n $N version 2>/dev/null | grep -A2 Server | grep Tag | awk '{print $2}'; }
uptime_s() { timeout 10 talosctl -e $EP -n $N read /proc/uptime 2>/dev/null | awk '{print int($1)}'; }
kubelet_state() { timeout 10 talosctl -e $EP -n $N service kubelet 2>/dev/null | awk '/^STATE/{print $2}'; }

# Powercycle and wait until the node has really rebooted (uptime reset) with kubelet Running.
powercycle_wait() {
  local before; before=$(uptime_s); log "powercycle (uptime before=${before}s)"
  timeout 30 talosctl -e $EP -n $N reboot --mode=powercycle --wait=false >/dev/null 2>&1
  local down=0
  for i in $(seq 1 60); do
    sleep 10; local u k; u=$(uptime_s); k=$(kubelet_state)
    log "  t=$((i*10))s uptime=${u:-unreachable} kubelet=${k:-?}"
    [ -z "$u" ] && down=1
    if [ -n "$u" ] && { [ $down = 1 ] || [ "$u" -lt "$before" ]; } && [ "$k" = Running ]; then return 0; fi
  done
  abort "node did not come back within 10 min after powercycle"
}

log "target $TARGET image $IMG"
log "== 1. cordon + Longhorn no-schedule (no eviction) + drain"
kubectl cordon $H >/dev/null || abort cordon
kubectl -n longhorn-system patch nodes.longhorn.io $H --type=merge -p '{"spec":{"allowScheduling":false,"evictionRequested":false}}' >/dev/null || abort "longhorn patch"
kubectl drain $H --ignore-daemonsets --delete-emptydir-data --timeout=15m >/dev/null 2>&1 || abort "drain failed"
log "drained"

log "== 2. upgrade (BootFFFF exit expected)"
UL=$(mktemp); talosctl -e $EP -n $N upgrade --image $IMG --drain=false --reboot-mode powercycle --progress plain --timeout 20m >$UL 2>&1; rc=$?
grep -q "Talos-$TARGET.efi" $UL || { tail -20 $UL; abort "new UKI was not written (rc=$rc)"; }
if [ $rc -ne 0 ]; then
  grep -q "BootFFFF" $UL || { tail -20 $UL; abort "upgrade failed for a reason other than BootFFFF (rc=$rc)"; }
  log "BootFFFF abort as expected; UKI on disk"
  powercycle_wait
fi
[ "$(tver)" = "$TARGET" ] || abort "not on $TARGET after boot (got $(tver))"
log "booted $TARGET"

log "== 3. wait Ready, staged topf apply, powercycle"
for i in $(seq 1 30); do [ "$(timeout 10 talosctl -e $EP -n $N get machinestatus -o jsonpath='{.spec.status.ready}' 2>/dev/null)" = true ] && break; sleep 10; done
UUID_PATCH=$(grep -o 'volume.uuid == "[^"]*"' node/$H/00-longhorn-usb.yaml | cut -d'"' -f2)
UUID_DISK=$(timeout 10 talosctl -e $EP -n $N get discoveredvolumes sda1 -o jsonpath='{.spec.uuid}' 2>/dev/null | head -1)
[ -n "$UUID_PATCH" ] && [ "$UUID_PATCH" = "$UUID_DISK" ] || abort "USB XFS UUID mismatch: patch=$UUID_PATCH disk=$UUID_DISK"
log "USB UUID matches patch ($UUID_DISK)"
DISKUUID_BEFORE=$(kubectl -n longhorn-system get nodes.longhorn.io $H -o jsonpath='{.status.diskStatus.sabrent-usb-ssd.diskUUID}')
mise exec -- topf apply --nodes-filter "^$H\$" --mode staged --skip-post-apply-checks --confirm=false --colored never 2>&1 | grep -q 'mode=STAGED' || abort "staged apply failed"
log "config staged"
powercycle_wait

log "== 4. verify Talos side"
timeout 10 talosctl -e $EP -n $N get volumestatus e-longhorn-usb 2>/dev/null | grep -q ' ready ' || abort "e-longhorn-usb volume not ready"
timeout 10 talosctl -e $EP -n $N read /proc/mounts | grep -q ' /var/mnt/longhorn-usb ' || abort "/var/mnt/longhorn-usb not mounted"
timeout 10 talosctl -e $EP -n $N read /proc/mounts | awk '$2=="/var"' | grep -q 'nosuid,nodev' || abort "/var not secure-mounted"
for i in $(seq 1 18); do mise exec -- topf apply --nodes-filter "^$H\$" --dry-run --colored never >/dev/null 2>&1; d=$?; [ $d = 0 ] && break; sleep 10; done
[ $d = 0 ] || abort "config drift after apply (dry-run exit $d)"
log "volume ready, mounted, /var secure, no drift"

log "== 5. Longhorn disks Ready + diskUUID unchanged"
for i in $(seq 1 30); do
  R=$(kubectl -n longhorn-system get nodes.longhorn.io $H -o json | python3 -c "
import sys,json;d=json.load(sys.stdin)['status']['diskStatus']
print('ok' if all({c['type']:c['status'] for c in s.get('conditions',[])}.get('Ready')=='True' for s in d.values()) else 'wait')")
  log "  t=$((i*10))s longhorn disks: $R"; [ "$R" = ok ] && break; sleep 10
done
[ "$R" = ok ] || abort "Longhorn disks not Ready"
DISKUUID_AFTER=$(kubectl -n longhorn-system get nodes.longhorn.io $H -o jsonpath='{.status.diskStatus.sabrent-usb-ssd.diskUUID}')
[ "$DISKUUID_BEFORE" = "$DISKUUID_AFTER" ] || abort "USB diskUUID changed: $DISKUUID_BEFORE -> $DISKUUID_AFTER"
log "Longhorn disks Ready, USB diskUUID unchanged ($DISKUUID_AFTER)"

log "== 6. restore scheduling + uncordon"
kubectl -n longhorn-system patch nodes.longhorn.io $H --type=merge -p '{"spec":{"allowScheduling":true,"evictionRequested":false}}' >/dev/null
kubectl uncordon $H >/dev/null

log "== 7. health gate"
for i in $(seq 1 60); do
  V=$(kubectl -n longhorn-system get volumes.longhorn.io -o json | python3 -c "
import sys,json;from collections import Counter;c=Counter(v['status'].get('robustness') for v in json.load(sys.stdin)['items']);print(' '.join(f'{k}={v}' for k,v in sorted(c.items())))")
  P=$(kubectl get pods -A -o json | python3 -c "
import sys,json;d=json.load(sys.stdin);print(sum(1 for p in d['items'] if p['status']['phase'] not in ('Running','Succeeded') or (p['status']['phase']=='Running' and not any(c['type']=='Ready' and c['status']=='True' for c in p['status'].get('conditions',[])))))")
  C=$(kubectl -n database get clusters.postgresql.cnpg.io postgres-17-cluster -o jsonpath='{.status.readyInstances}')
  [ $((i % 3)) = 1 ] && log "  t=$((i*20))s volumes[$V] nonready_pods=$P cnpg=$C/3"
  if ! echo "$V" | grep -q -E 'degraded|faulted' && [ "$P" = 0 ] && [ "$C" = 3 ]; then log "GATE_PASS volumes[$V]"; log DONE; exit 0; fi
  sleep 20
done
abort "health gate not reached in 20 min"
