# Recovering / upgrading a talmac node to Talos v1.13+ (T2 Intel Mac)

## Background

Stock Talos v1.13 **hangs at cold boot** on the 2018 T2 Mac mini: its kernel uses a
Clang+LLD EFI stub that Apple's Intel firmware refuses to hand off to
(siderolabs/talos#13579). An in-place `talosctl upgrade` *appears* to work because it
kexecs the new kernel — but the box never survives a real power cycle.

**The earlier GRUB-ladder idea in this doc's history was wrong** (Talos GRUB 2.14 also
uses EFI hand-off, so it hangs too). The working fix is a **custom installer** built
with the kernel linked by GNU ld instead of LLD:

- Repo: `github.com/mebezac/talos-mac-installer` (builds via GitHub Actions on tag push)
- Installer image: `ghcr.io/mebezac/talos-mac/installer:<talos-version>`
- USB ISO: attached to the matching GitHub Release (`metal-amd64.iso`)

A GCC-linked kernel cold-boots fine under UKI/systemd-boot, so **no GRUB, no version
ladder** — the Mac upgrades like any other node once it's on the custom image.

`talconfig.yaml` already points **talmac-02** at `ghcr.io/mebezac/talos-mac/installer`
(talhelper appends `:${talosVersion}`). talmac-01/03 remain on their v1.12.4 pins until
migrated the same way.

## Recover talmac-02 (10.25.30.43) — currently down on a non-booting stock v1.13.5

Run from repo root unless noted. Env:

```bash
export SOPS_AGE_KEY_FILE=/Users/zac/projects/lab_casa/home-cluster/age.key
N=10.25.30.43 ; H=talmac-02
cd kubernetes/bootstrap/talos
export TALOSCONFIG="$PWD/clusterconfig/talosconfig"
```

### 1. Flash the custom ISO to USB (macOS)

```bash
gh release download v1.13.5 -R mebezac/talos-mac-installer -p 'metal-amd64.iso' -O /tmp/talmac.iso
diskutil list                                   # find the USB, e.g. /dev/disk4
diskutil unmountDisk /dev/diskN
sudo dd if=/tmp/talmac.iso of=/dev/rdiskN bs=4m status=progress
sync ; diskutil eject /dev/diskN
```

### 2. Boot it — this is the real cold-boot test

Power on holding **⌥ (Option)** → pick **EFI Boot**. T2 Startup Security must already
allow external + reduced security (set during the original install; if it won't boot the
USB, fix in recoveryOS → Startup Security Utility).

- **Reaches Talos maintenance mode** → the GCC kernel cold-boots. The whole fix is proven.
- **Folder-with-`?` / hang** → firmware still rejects it; stop and re-check the build,
  don't proceed.

Keep the **USB Longhorn enclosure plugged in** (machine-disks.yaml references it; Talos
volume teardown blocks if a referenced disk is absent). Node comes up on its DHCP
reservation `10.25.30.43` in maintenance mode.

### 3. Install the custom image

```bash
talhelper genconfig --config-file talconfig.yaml --secret-file talsecret.sops.yaml \
  --out-dir clusterconfig
# sanity: install image should be the custom installer, not factory.talos.dev
grep -A2 'install:' clusterconfig/kubernetes-talmac-02.yaml | grep image   # ghcr.io/mebezac/...:v1.13.5

talosctl apply-config --insecure -n $N --file clusterconfig/kubernetes-talmac-02.yaml
```

The node writes v1.13.5 (UKI, custom kernel) to `/dev/nvme0n1`, reboots, cold-boots
cleanly, and rejoins as a worker (kubelet v1.35.6). Verify:

```bash
talosctl -n $N version                                  # Talos v1.13.5
talosctl -n $N get extensions | grep -E 'i915|thunderbolt|intel-ucode'   # present
kubectl get node $H -o wide                              # Ready, v1.35.6
```

### 4. Prove it survives a cold boot

```bash
talosctl -n $N reboot        # comes back on its own = firmware boots the custom kernel
```

### 5. Restore workloads

```bash
kubectl uncordon $H
kubectl -n longhorn-system patch nodes.longhorn.io $H --type=merge \
  -p '{"spec":{"allowScheduling":true,"evictionRequested":false}}'
kubectl -n longhorn-system get volumes.longhorn.io -o wide | grep -iv healthy   # -> empty
```

## Roll out to talmac-01 / talmac-03 (in-place upgrade — no USB needed)

A working node (e.g. on v1.12.4) can be upgraded **in place** — no USB, no wipe, no
Longhorn disk re-adoption (`--preserve` keeps the disks, so replicas survive the
reboot):

```bash
N=<ip> ; H=talmac-0X
kubectl cordon $H
kubectl -n longhorn-system patch nodes.longhorn.io $H --type=merge \
  -p '{"spec":{"allowScheduling":false,"evictionRequested":false}}'   # NO eviction — preserve keeps replicas
kubectl drain $H --ignore-daemonsets --delete-emptydir-data --timeout=15m
talosctl -n $N upgrade --image ghcr.io/mebezac/talos-mac/installer:v1.13.5 --preserve
```

**Expect a non-fatal error.** The upgrade reports:
`failed to install bootloader: failed to create boot entry: ... BootFFFF: declared
length of FilePath (166) overruns available data (165)` and exits 1 — Apple's EFI NVRAM
has a malformed `BootFFFF` variable that Talos's boot-entry enumeration can't parse.
This is **cosmetic**: the new v1.13.5 UKI is written to the ESP and systemd-boot (already
the installed boot manager) boots it. Verify the node actually came up on v1.13.5
(`talosctl -n $N version` → v1.13.5, kernel `6.18.36-talos`) — it will have, despite the
error — then `kubectl uncordon $H` + restore Longhorn scheduling.

Then in `talconfig.yaml`: set that node's `talosImageURL` to the custom installer and
delete its `patches/talmac-0X/machine-install.yaml` pin.

- **talmac-01** — migrated 2026-07-04 via this in-place path (Ready on v1.13.5).
- **talmac-03** — its USB Longhorn enclosure was physically unplugged for a while; plug
  it back before upgrading so the `machine-disks.yaml` mount resolves.
- A full **USB ISO reinstall** (Phase 1-3 above) is only needed to recover a node that's
  already bricked on a non-booting stock v1.13.x (as talmac-02 was) — not for a normal
  migration off a working v1.12.x.

Evacuate before touching a node:

```bash
kubectl cordon $H
kubectl -n longhorn-system patch nodes.longhorn.io $H --type=merge \
  -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}'
# wait until 0 replicas remain on the node, all volumes still Healthy, then:
kubectl drain $H --ignore-daemonsets --delete-emptydir-data --timeout=15m
```

## New Talos releases

Tag `github.com/mebezac/talos-mac-installer` with the talos version (e.g. `v1.13.6`) to
build a matching custom installer, bump `talosVersion` in `talconfig.yaml`, then
`upgrade --image ghcr.io/mebezac/talos-mac/installer:v1.13.6 --preserve` per node. Never
point a talmac at `factory.talos.dev` for v1.13+ — that's the hanging stock kernel.

## Notes / gotchas

- Never wrap `talosctl reset`/`upgrade` in `timeout` — an interrupt leaves the node in a
  half-reset LOCKED state. Background it instead.
- Correct wipe flag is `--wipe-mode system-disk` (not `--system-disk-wipe-spec`).
- factory DNS (node resolver 10.25.30.38) is flaky; a failed image pull is a safe no-op —
  retry. (Less relevant now that installs pull from ghcr, not factory.)
- The cluster k8s/API stays at v1.35; a talmac worker's kubelet may lag up to 3 minors,
  so no cluster-wide downgrade is ever needed.
