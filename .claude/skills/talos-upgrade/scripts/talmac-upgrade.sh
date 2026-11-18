#!/usr/bin/env bash
# One talmac: upgrade to topf.yaml talosVersion + topf config. Proven 2026-10-01 (1.14.2 migration,
# BootFFFF every time) and 2026-11-17 (1.14.4 -> 1.14.6: no BootFFFF, Talos powercycled by itself).
# Usage: [DRAIN_FORCE=1] mise exec -- bash talmac-upgrade.sh <host> <ip>   (backgrounded, logged)
# First move the CNPG primary off this node (SKILL.md). Every wait is bounded and logs each pass;
# any unexpected state prints ABORT and exits non-zero, leaving the node cordoned.
set -u
H=$1; N=$2; EP=10.25.30.45
source "$(dirname "$0")/lib.sh"
render_target
uptime_s() { timeout 10 talosctl -e $EP -n "$N" read /proc/uptime 2>/dev/null | awk '{print int($1)}'; }

# Powercycle and wait until the node has really rebooted (uptime reset) with kubelet Running.
# Never gate on "node unreachable": a talmac can come back between two probes.
powercycle_wait() {
  local before down=0 u k; before=$(uptime_s); log "powercycle (uptime before=${before}s)"
  timeout 30 talosctl -e $EP -n "$N" reboot --mode=powercycle --wait=false >/dev/null 2>&1
  for i in $(seq 1 60); do
    sleep 10; u=$(uptime_s); k=$(kubelet_state)
    log "  t=$((i*10))s uptime=${u:-unreachable} kubelet=${k:-?}"
    [ -z "$u" ] && down=1
    if [ -n "$u" ] && { [ $down = 1 ] || [ "$u" -lt "$before" ]; } && [ "$k" = Running ]; then return 0; fi
  done
  abort "node did not come back within 10 min after powercycle"
}

log "target $TARGET image $IMG"
log "== 1. cordon + drain"
cordon_drain

log "== 2. upgrade (exit 0 = Talos powercycled itself; BootFFFF exit = we powercycle)"
UL=$(mktemp); talosctl -e $EP -n "$N" upgrade --image "$IMG" --drain=false --reboot-mode powercycle --progress plain --timeout 20m >"$UL" 2>&1; rc=$?
if [ $rc -ne 0 ]; then
  grep -q "Talos-$TARGET.efi" "$UL" || { tail -20 "$UL"; abort "new UKI was not written (rc=$rc)"; }
  grep -q "BootFFFF" "$UL" || { tail -20 "$UL"; abort "upgrade failed for a reason other than BootFFFF (rc=$rc)"; }
  log "BootFFFF abort; UKI on disk"
  powercycle_wait
fi
wait_version 30 || abort "not on $TARGET after boot (got $(tver))"
log "booted $TARGET"

log "== 3. wait Ready, topf apply"
wait_machine_ready || abort "machine not ready"
UUID_PATCH=$(grep -o 'volume.uuid == "[^"]*"' "node/$H/00-longhorn-usb.yaml" | cut -d'"' -f2)
UUID_DISK=$(timeout 10 talosctl -e $EP -n "$N" get discoveredvolumes sda1 -o jsonpath='{.spec.uuid}' 2>/dev/null | head -1)
[ -n "$UUID_PATCH" ] && [ "$UUID_PATCH" = "$UUID_DISK" ] || abort "USB XFS UUID mismatch: patch=$UUID_PATCH disk=$UUID_DISK"
log "USB UUID matches patch ($UUID_DISK)"
DISKUUID_BEFORE=$(kubectl -n longhorn-system get nodes.longhorn.io "$H" -o jsonpath='{.status.diskStatus.sabrent-usb-ssd.diskUUID}')
if installer_only_diff; then
  log "diff is the installer line only: live apply (no reboot)"
else
  # Anything more (a volume or kernel change, the 1.14 migration) is staged, then a powercycle.
  topf apply --nodes-filter "^$H\$" --mode staged --skip-post-apply-checks --confirm=false --colored never 2>&1 | grep -q 'mode=STAGED' || abort "staged apply failed"
  log "config staged"
  powercycle_wait
  wait_machine_ready || abort "machine not ready after powercycle"
fi
topf_apply_live

log "== 4. verify Talos side"
timeout 10 talosctl -e $EP -n "$N" get volumestatus e-longhorn-usb 2>/dev/null | grep -q ' ready ' || abort "e-longhorn-usb volume not ready"
timeout 10 talosctl -e $EP -n "$N" read /proc/mounts | grep -q ' /var/mnt/longhorn-usb ' || abort "/var/mnt/longhorn-usb not mounted"
timeout 10 talosctl -e $EP -n "$N" read /proc/mounts | awk '$2=="/var"' | grep -q 'nosuid,nodev' || abort "/var not secure-mounted"
log "volume ready, mounted, /var secure, no drift"

log "== 5. Longhorn disks Ready + diskUUID unchanged"
longhorn_disks_ready
DISKUUID_AFTER=$(kubectl -n longhorn-system get nodes.longhorn.io "$H" -o jsonpath='{.status.diskStatus.sabrent-usb-ssd.diskUUID}')
[ "$DISKUUID_BEFORE" = "$DISKUUID_AFTER" ] || abort "USB diskUUID changed: $DISKUUID_BEFORE -> $DISKUUID_AFTER"
log "Longhorn disks Ready, USB diskUUID unchanged ($DISKUUID_AFTER)"

log "== 6. restore scheduling + uncordon"
restore_scheduling

log "== 7. health gate"
health_gate && log DONE
