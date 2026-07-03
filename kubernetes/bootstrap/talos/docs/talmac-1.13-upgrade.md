# Runbook: Migrating an Intel Mac mini node onto Talos v1.13.x

Getting a `talmac-*` node (Intel `Macmini8,1`, 2018 T2) from its pinned **Talos
v1.12.4** up to **v1.13.x** without hitting the Intel-Mac boot hang.

Worked example targets **talmac-02** (`10.25.30.43`); the procedure is parameterized
(`$N` / `$H`) so it also applies to talmac-01 (`10.25.30.42`) and talmac-03
(`10.25.30.44`). Do one node at a time.

---

## Why this is not a normal upgrade

Talos **v1.13.x hangs at the TALOS splash on Intel Macs**. Root cause: the v1.13
kernel's Clang+LLD/ThinLTO EFI stub, which Apple's Intel EFI firmware cannot hand off
to during a cold UEFI boot (siderolabs/talos#13579 — affects Ubuntu/Debian too, not
Talos-specific).

The UKI/systemd-boot default landed in **Talos 1.10**. The talmacs were installed fresh
at v1.12.4, so they boot via **UKI/sd-boot** (`bootedWithUKI: true`; partition layout
`EFI/META/STATE/EPHEMERAL`, no BIOS/BOOT). **Talos upgrades preserve the existing
bootloader**, so a UKI node upgraded in place to v1.13.x stays on UKI and hangs.

The fix: reinstall from **v1.9.6** — the last GRUB-defaulting release — then ladder the
Talos version up one minor at a time. GRUB uses the legacy x86 boot protocol that boots
fine on Mac firmware, and it is preserved across every upgrade, so it rides all the way
to v1.13.x and dodges the hang.

### Kubernetes version — no cluster downgrade

The cluster's k8s version is the **control-plane/API-server** version (1.35) and does
not change. A worker only runs a **kubelet**, and the k8s skew policy (≥1.28) allows a
kubelet up to **3 minors older** than the API server — so kubelet 1.32 (Talos 1.9.6's
max) is fully supported against a 1.35 API server. Kubelet walks up with Talos, reaching
1.35.6 at the end. Only this one worker runs an older kubelet, transiently.

---

## Node facts (talmac-02, verified live)

- IP `10.25.30.43`, hostname `talmac-02`, install disk `/dev/nvme0n1` (Apple SSD).
- Also has a USB Longhorn disk mounted at `/var/mnt/longhorn-usb`.
- Factory schematic `2385c7daef21b71bfd59f74b96cdccfebe5003bcef3cee5b56b1add17a8f4817`
  = extensions `i915, intel-ucode, iscsi-tools, thunderbolt, util-linux-tools`
  + kernel args `intel_iommu=on iommu=pt pcie_ports=compat`.
  `pcie_ports=compat` is what makes the Apple NVMe usable — it must be present at every
  step. Using the same schematic for every install/upgrade image keeps it consistent.

## Version ladder (sequential — do not skip minors)

| Step | Talos | kubelet (worker) | Bootloader |
|-|-|-|-|
| Fresh install | v1.9.6 | v1.32.x | **GRUB** (last GRUB-default release) |
| Upgrade 1 | v1.10.9 | v1.33.x | GRUB (preserved) |
| Upgrade 2 | v1.11.6 | v1.34.x | GRUB (preserved) |
| Upgrade 3 | v1.12.9 | v1.35.6 | GRUB (preserved) |
| Upgrade 4 | v1.13.5 | v1.35.6 | GRUB (preserved) — **no hang** |

Rule per rung: **upgrade Talos first, then bump kubelet** to that release's max
(kubelet ≤ Talos-supported k8s max, and ≤ API server 1.35). Pick the newest patch of
each k8s minor; check the target Talos release notes' supported-k8s range.

All installer/upgrade images use the same schematic:
`factory.talos.dev/installer/2385c7daef21b71bfd59f74b96cdccfebe5003bcef3cee5b56b1add17a8f4817:<version>`

---

## Procedure

### Phase 0 — Pre-flight & evacuate (graceful)

```bash
N=10.25.30.43 ; H=talmac-02
talosctl -n $N version                            # expect Talos v1.12.4
talosctl -n $N get securitystate | grep -i uki    # bootedWithUKI: true (why we reinstall)
kubectl get node $H -o wide                        # note current kubelet

# Cordon + stop Longhorn scheduling and request replica eviction off this node
kubectl cordon $H
kubectl -n longhorn-system patch nodes.longhorn.io $H --type=merge \
  -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}'

# Wait until NO replicas remain on the node (rebuilt elsewhere), all volumes still Healthy
watch "kubectl -n longhorn-system get replicas.longhorn.io -o wide | grep -c $H"   # -> 0

# Drain workloads
kubectl drain $H --ignore-daemonsets --delete-emptydir-data --timeout=15m
```

Step 2 covers replicas on both the internal NVMe and the USB Longhorn disk.

### Phase 1 — Build the v1.9.6 GRUB USB

```bash
curl -LO "https://factory.talos.dev/image/2385c7daef21b71bfd59f74b96cdccfebe5003bcef3cee5b56b1add17a8f4817/v1.9.6/metal-amd64.iso"

# Write to USB (macOS): identify, unmount, dd to the RAW device
diskutil list
diskutil unmountDisk /dev/diskN
sudo dd if=metal-amd64.iso of=/dev/rdiskN bs=4m status=progress
sync ; diskutil eject /dev/diskN
```

T2 Startup Security (should already be set from the original install; verify if boot
fails): **Reduced Security + Allow booting from external media** (recoveryOS → Startup
Security Utility). Secure Boot stays off — the schematic is `secureboot: false`.

### Phase 2 — Wipe the UKI install & boot v1.9.6

```bash
# Wipe the existing v1.12.4 UKI system so the Mac can't boot back into it
talosctl -n $N reset --system-labels-to-wipe STATE,EPHEMERAL --reboot --graceful=false
# (or full wipe: --system-disk-wipe-spec all)
```

Boot the USB: power on holding **Option (⌥)** → pick **EFI Boot**. The node comes up in
**maintenance mode** and DHCPs. Find its address (DHCP lease / console) and call it
`$M`.

### Phase 3 — Install v1.9.6 with kubelet 1.32 (via talhelper)

Use a **temporary talconfig override** so all global patches (Cilium `cni: none`,
network, sysctls, disks, longhorn label) are preserved:

```bash
cd kubernetes/bootstrap/talos
cp talconfig.yaml /tmp/talconfig.step.yaml
# In /tmp/talconfig.step.yaml set:
#   talosVersion: v1.9.6
#   kubernetesVersion: v1.32.x         # newest 1.32 patch Talos 1.9.6 supports
# (leave the talmac-02 talosImageURL = the schematic; talhelper appends :v1.9.6)

talhelper genconfig -c /tmp/talconfig.step.yaml   # -> clusterconfig/kubernetes-talmac-02.yaml
talosctl apply-config --insecure -n $M --file clusterconfig/kubernetes-talmac-02.yaml
```

The node installs v1.9.6 to `/dev/nvme0n1` with **GRUB**, reboots onto the static
`10.25.30.43`, and joins the cluster (kubelet 1.32). Verify:

```bash
talosctl -n $N version                              # Talos v1.9.6
talosctl -n $N get securitystate | grep -i uki      # bootedWithUKI: FALSE  <-- GRUB
talosctl -n $N get discoveredvolumes | grep -Ei 'BIOS|BOOT'   # BIOS + BOOT partitions present
kubectl get node $H                                  # Ready, kubelet v1.32.x
```

> If `securitystate` still shows `bootedWithUKI: true`, STOP — the node booted the old
> UKI install, not the USB. Re-check the wipe (Phase 2) and the boot source.

### Phase 4 — Ladder up (GRUB preserved at every step)

Repeat for **v1.10.9**, then **v1.11.6**, then **v1.12.9**:

```bash
VER=v1.10.9          # then v1.11.6, then v1.12.9
talosctl -n $N upgrade \
  --image factory.talos.dev/installer/2385c7daef21b71bfd59f74b96cdccfebe5003bcef3cee5b56b1add17a8f4817:$VER \
  --preserve
# wait for reboot + rejoin
talosctl -n $N version && kubectl get node $H
talosctl -n $N get securitystate | grep -i uki       # MUST stay bootedWithUKI: false

# bump kubelet to this release's max: edit kubernetesVersion in /tmp/talconfig.step.yaml
# (keep talosVersion == the rung just installed), then:
talhelper genconfig -c /tmp/talconfig.step.yaml
talosctl -n $N apply-config --file clusterconfig/kubernetes-talmac-02.yaml
kubectl get node $H                                   # kubelet -> v1.33 / v1.34 / v1.35.6
```

kubelet targets per rung: v1.10.9→**v1.33.x**, v1.11.6→**v1.34.x**, v1.12.9→**v1.35.6**.

### Phase 5 — Final rung: v1.13.5 (the one that used to hang)

The node is now on v1.12.9, kubelet 1.35.6, still GRUB. Switch back to the **real,
unmodified `talconfig.yaml`** (Talos v1.13.5 / k8s v1.35.6) — first remove talmac-02's
version pin (Phase 7) so it tracks the global version — then:

```bash
cd kubernetes/bootstrap/talos
talhelper genconfig                                  # real talconfig -> v1.13.5 / v1.35.6
talosctl -n $N apply-config --file clusterconfig/kubernetes-talmac-02.yaml
talosctl -n $N upgrade \
  --image factory.talos.dev/installer/2385c7daef21b71bfd59f74b96cdccfebe5003bcef3cee5b56b1add17a8f4817:v1.13.5 \
  --preserve
```

Because the bootloader is still GRUB, the v1.13.5 kernel boots via the legacy x86 path
and **does not hang**. Verify:

```bash
talosctl -n $N version                               # Talos v1.13.5
talosctl -n $N get securitystate | grep -i uki       # bootedWithUKI: false (GRUB)
kubectl get node $H                                   # Ready, v1.35.6
```

### Phase 6 — Restore workloads & Longhorn

```bash
kubectl uncordon $H
kubectl -n longhorn-system patch nodes.longhorn.io $H --type=merge \
  -p '{"spec":{"allowScheduling":true,"evictionRequested":false}}'
kubectl -n longhorn-system get volumes.longhorn.io -o wide | grep -iv healthy   # expect empty
```

### Phase 7 — Repo cleanup (talhelper)

Once the node is confirmed healthy on v1.13.5:

- Delete `patches/talmac-02/machine-install.yaml` and remove its
  `- "@./patches/talmac-02/machine-install.yaml"` line from `talconfig.yaml`, so the node
  tracks the global `talosVersion`. Keep `machine-disks.yaml`.
- Update the `# Pinned to v1.12.4 …` comment on the talmac-02 node.
- Leave talmac-01 and talmac-03 pinned until they are migrated the same way.
- Commit normally. **ArgoCD does not manage the Talos layer** — this is
  talhelper/bootstrap, applied manually.

---

## End-to-end verification

1. `talosctl -n 10.25.30.43 version` → **Talos v1.13.5**.
2. `talosctl -n 10.25.30.43 get securitystate` → **`bootedWithUKI: false`** (GRUB — the
   whole point; if this ever flipped to `true` mid-ladder, a step re-UKI'd the node).
3. `talosctl -n 10.25.30.43 get discoveredvolumes` → BIOS + BOOT partitions present.
4. `kubectl get node talmac-02` → `Ready`, kubelet **v1.35.6**.
5. `talosctl -n 10.25.30.43 get extensions` → i915 / intel-ucode / iscsi-tools /
   thunderbolt / util-linux-tools present (schematic preserved).
6. `kubectl -n longhorn-system get volumes.longhorn.io` → all **Healthy**.
7. Reboot test: `talosctl -n 10.25.30.43 reboot` → node returns cleanly (proves the
   v1.13.5 kernel boots via GRUB on the Mac firmware without hanging).

## Rollback / safety

- If an **upgrade** rung fails to return: it is a drained worker, so the cluster is
  unaffected. Reboot to the previous GRUB A/B entry, or re-run the USB reinstall.
- If the **v1.13.5** step hangs at the splash: the node was on UKI, not GRUB — restart
  from Phase 2 (wipe → v1.9.6 USB).
- Do **not** skip minors; sequential rungs keep config-schema migrations and the GRUB
  bootloader intact.

## Follow-up

- Repeat for **talmac-01** (`10.25.30.42` — remove/account for its smarthome USB adapter
  first) and **talmac-03** (`10.25.30.44`), one at a time.
- Track siderolabs/talos#13579 — if Talos ships a non-LTO/fixed EFI-stub kernel, fresh
  UKI installs may become viable and this GRUB dance can be retired.
