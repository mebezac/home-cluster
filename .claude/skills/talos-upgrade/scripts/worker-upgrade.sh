#!/usr/bin/env bash
# One non-talmac WORKER (wyse-5070-01/02): upgrade to topf.yaml talosVersion, then a live topf
# apply. Proven on both Wyses, 2026-11-17 (1.14.4 -> 1.14.6, ~4-8 min each with the gate).
# Usage: [DRAIN_FORCE=1] mise exec -- bash worker-upgrade.sh <host> <ip>   (backgrounded, logged)
# Bounded waits that log every pass; ABORT exits non-zero and leaves the node cordoned.
set -u
H=$1; N=$2; EP=10.25.30.45
source "$(dirname "$0")/lib.sh"
render_target
log "target $TARGET image $IMG"

log "== 0. last-replica check"
# A volume whose only healthy replica is here goes offline during the reboot (lib.sh).
ATT=$(attached_last_replica)
[ -z "$ATT" ] || abort "attached volumes whose last healthy replica is here: $ATT (evict first, SKILL.md step 2)"
log "no attached volume depends on this node alone"

log "== 1. cordon + drain"
cordon_drain

log "== 2. upgrade (talosctl drains nothing here, reboots, waits)"
UL=$(mktemp)
for try in 1 2 3; do
  talosctl -e $EP -n $N upgrade --image "$IMG" --drain=false --progress plain --timeout 20m >"$UL" 2>&1; rc=$?
  log "upgrade try $try rc=$rc"
  [ $rc = 0 ] && break
  # A failed image pull (flaky node DNS) has not touched the disk: re-running is a safe no-op.
  grep -qiE 'pull|lookup|i/o timeout|no such host' "$UL" && ! grep -q "installation of $TARGET complete" "$UL" \
    && { tail -5 "$UL"; log "image pull failed; retry"; sleep 20; continue; }
  tail -20 "$UL"; break
done
wait_version 40 || { tail -20 "$UL"; abort "not on $TARGET (got $(tver))"; }
log "booted $TARGET"

log "== 3. live topf apply"
wait_machine_ready || abort "machine not ready"
topf_apply_live
timeout 10 talosctl -e $EP -n $N read /proc/mounts | awk '$2=="/var"' | grep -q 'nosuid,nodev' || abort "/var not secure-mounted"
log "no drift, /var secure"

log "== 4. Longhorn disks Ready"
longhorn_disks_ready

log "== 5. restore scheduling + uncordon"
restore_scheduling

log "== 6. health gate"
health_gate && log DONE
