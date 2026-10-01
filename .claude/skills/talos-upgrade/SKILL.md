---
name: talos-upgrade
description: >-
  Upgrade the Talos version on this home-cluster's nodes safely, one at a time,
  draining Longhorn + workloads first and verifying full health before moving on.
  Use whenever the user wants to bump Talos (e.g. "get the cluster on v1.13.5",
  "upgrade talos", "roll out the new talos version", "update <node> to <version>",
  "do the talos nodes"), reinstall/recover a node, or migrate a node between
  installer schematics. Handles the whole node loop: pick a safe order
  (workers → control-plane, non-leaders → etcd-leader last), cordon, drain past
  the Longhorn instance-manager PDB, evacuate single-replica volumes that would
  otherwise go offline, run `talosctl upgrade --preserve`, ride out the T2 Mac
  BootFFFF non-fatal error, apply the topf-rendered machine config per node,
  re-enable scheduling, and confirm every volume / pod / etcd member is healthy
  before the next node. Knows this repo's topf layout (talhelper is gone),
  the talmac T2 Mac constraints (>= v1.14.2 only), and the Longhorn
  gotchas (stale USB mounts, diskUUID mismatch, data-locality PVs, CNPG
  switchover). Reach for this any time a Talos node needs upgrading, reinstalling,
  or migrating.
---

# Talos node upgrade (safe, one node at a time)

Upgrade Talos on cluster nodes so **nothing loses data and no volume goes
unavailable unexpectedly**. The loop for every node: evacuate → `talosctl
upgrade --preserve` → verify → restore → confirm cluster fully healthy → only
then touch the next node. Never two nodes at once.

**This is the bootstrap/Talos layer — ArgoCD does NOT manage it.** Config lives
in `kubernetes/bootstrap/talos/` (topf: `topf.yaml` + `all/` `control-plane/` `worker/`
`node/<host>/` patches, `schematics/*.yaml`, `secrets.sops.yaml`), applied manually. Config
edits are committed to the repo normally (no attribution trailer per repo convention).

**talhelper is gone** (archived upstream; replaced by [topf](https://postfinance.github.io/topf/)
in 8010c9cc). There is no `talconfig.yaml`, `talsecret.sops.yaml`, `patches/` or
`clusterconfig/` any more — never run `talhelper genconfig` or apply an old
`clusterconfig/*.yaml`. topf and talosctl are pinned in `.mise.toml`; run from inside the
repo (mise shims fail outside it) or prefix with `mise exec --`. `task --list` shows the
`talos:*` wrappers (`render`, `diff`, `apply-node`, `nodes`, `upgrade-node`, `talosconfig`).

## Setup (run first, every session)

```bash
cd /Users/zac/projects/lab_casa/home-cluster/kubernetes/bootstrap/talos
export SOPS_AGE_KEY_FILE=/Users/zac/projects/lab_casa/home-cluster/age.key
export TALOSCONFIG=/Users/zac/projects/lab_casa/home-cluster/kubernetes/bootstrap/talos/talosconfig
export TOPFCONFIG=/Users/zac/projects/lab_casa/home-cluster/kubernetes/bootstrap/talos/topf.yaml
[ -s "$TALOSCONFIG" ] || topf talosconfig   # regenerate from the secrets bundle if missing
# render (gitignored ./rendered - PLAINTEXT SECRETS, never print whole files) + validate:
topf render --output ./rendered --confirm=false
for f in rendered/*.yaml; do talosctl validate --mode metal --config "$f"; done
topf nodes               # live stage / ready / schematic / version per node (retry once on i/o timeout)
topf upgrade --dry-run   # read-only plan: per node version_actual→desired, schematic_actual→desired, installer
```

`topf upgrade --dry-run` is the quickest "who still needs upgrading, and to what image"
view. The talmacs report `schematic_actual=37656798…` until their first 1.14.2 upgrade:
that's the empty-schematic ID the retired custom installer reported, not a drift problem.

`topf.yaml` carries `talosVersion:` (and optionally a per-node `talosVersion:` override) —
the version everything targets. Renovate bumps it (github-releases siderolabs/talos)
alongside `aqua:siderolabs/talos` in `.mise.toml`; keep talosctl on the same version. To
upgrade the whole cluster to a new patch, bump `talosVersion` first (and
`kubernetesVersion` if desired — that's `task talos:upgrade-k8s`, separate from this
skill), re-render, then loop. For a same-version rollout (nodes lagging the pinned
version) no edit is needed — just loop.

**Confirm the factory has built every installer before touching a node**
(`crane digest factory.talos.dev/metal-installer/<schematic>:<version>` for each distinct
image). A schematic the factory has never seen needs one `topf render --submit-to-factory`
first; otherwise the upgrade's image pull fails.

### Node inventory & upgrade image

Each node's upgrade image = the `UnattendedInstallConfig.installer.image` topf renders
(`factory.talos.dev/metal-installer/<schematic>:<talosVersion>`, schematic hashed locally
from `schematics/<hw>.yaml`):

```bash
for f in rendered/*.yaml; do
  echo "$f -> $(yq 'select(.kind=="UnattendedInstallConfig") | .installer.image' "$f")"
done
```

`topf upgrade` exists (pre-pull, cordon+drain with a 5m timeout, kexec reboot, uncordon;
etcd health is validated server-side on ≥1.13 nodes) but this skill drives
`talosctl upgrade --image <that image> --preserve` by hand because of the Longhorn
evacuation (the instance-manager PDB outlasts topf's drain timeout) and the talmac
BootFFFF/powercycle steps below. Don't use `task talos:upgrade-node` on a talmac.
Either way, **the machine config is a separate step**: an upgrade keeps the node's
current config.

### First upgrade to 1.14 (one-time topf migration)

Nodes upgraded from 1.13 still run the old talhelper-era legacy v1alpha1 config (1.14
still accepts it). The topf render uses 1.14-only document kinds, so it can ONLY be
applied **after** a node is on 1.14 — never before. Per node, right after its upgrade is
verified (step 5) and while it's still cordoned:

```bash
topf apply --nodes-filter '^<host>$' --dry-run   # review the diff (secrets redacted); exit 2 = "changes found", not an error
topf apply --nodes-filter '^<host>$'             # asks to confirm; mode auto; waits 30s stabilization
```

- **Never run an unfiltered `topf apply` / `task talos:apply` while any node is still on
  1.13.** It walks every node. `task talos:diff` (dry-run) is harmless but noisy until
  the migration is done.
- topf's pre-flight aborts if the node has unmet conditions. Fix the node rather than
  reaching for `--allow-not-ready`.
- The apply restarts kubelet, so kubelet's image GC ages reset (expected).
- **VIP:** wyse-5070-03 becomes a `10.25.30.116` Layer2 VIP candidate only once its topf
  config is applied; until then only the elitebooks can hold the VIP. Do wyse-03 first
  among the control planes (unless it is the etcd leader) so there are always two
  candidates while the elitebooks reboot. The VIP moving makes kubectl blip for a few
  seconds; talosctl talks to node IPs, so it's unaffected.

Expect control-plane static pods to re-render. **talmacs**: their patch swaps legacy
`machine.disks` for `ExistingVolumeConfig` (USB SSD by XFS UUID, same
`/var/mnt/longhorn-usb` path) - apply with `--mode staged`, then
`talosctl reboot --mode powercycle` while the node is still drained, then confirm
`talosctl get volumestatus` shows `e-longhorn-usb` ready, `get mountstatus` shows
`/var/mnt/longhorn-usb`, and the Longhorn disk `sabrent-usb-ssd` is Ready with its
unchanged diskUUID before uncordoning. If the selector matches nothing the volume just
waits (no data touched) - restore the old mount by reverting that patch.

Current nodes (verify live, don't trust this list blindly):

| Node | IP | Role | Longhorn? | Installer |
|-|-|-|-|-|
| elitebook-01 | 10.25.30.45 | control-plane | no | factory `249d9135…` |
| elitebook-02 | 10.25.30.46 | control-plane | no | factory `249d9135…` |
| wyse-5070-03 | 10.25.30.35 | control-plane | no | factory `9ba0b24a…` |
| wyse-5070-01 | 10.25.30.33 | worker | yes | factory `9ba0b24a…` |
| wyse-5070-02 | 10.25.30.34 | worker | yes | factory `9ba0b24a…` |
| talmac-01 | 10.25.30.42 | worker | yes | factory `2385c7da…` |
| talmac-02 | 10.25.30.43 | worker | yes | factory `2385c7da…` |
| talmac-03 | 10.25.30.44 | worker | yes | factory `2385c7da…` |

The **talmac** nodes are 2018 T2 Intel Macs. Stock Talos v1.13.0–v1.14.1 hangs at
cold boot on them (Apple EFI-stub bug, siderolabs/talos#13579); **v1.14.2+ carries the
fix** (siderolabs/pkgs@6c312e4), so they use the stock factory schematic `2385c7da…`
(i915, intel-ucode, iscsi-tools, thunderbolt, util-linux-tools + `intel_iommu=on
iommu=pt pcie_ports=compat`). **Never put a talmac on anything between v1.13.0 and
v1.14.1.** The old custom GCC installer (`ghcr.io/mebezac/talos-mac/installer`,
sibling repo `talos-mac-installer`) is archived — don't use it.

## Choose the order

1. **Workers first, control-plane last.** Workers are lower-risk; get the
   procedure warm on them.
2. **Control-plane: non-leaders first, the etcd leader LAST.** Find the leader:
   ```bash
   talosctl -e 10.25.30.45 -n 10.25.30.45,10.25.30.46,10.25.30.35 etcd status
   # LEADER column shows the member ID that is leader; upgrade that node last.
   ```
   With 3 CP nodes, quorum is 2 — rebooting one keeps the cluster up. Verify all
   3 etcd members are healthy & converged **before each** CP node and again after.
3. Do talmacs whenever; they're workers. In-place upgrade works (they don't need
   the USB unless already bricked on a non-booting stock 1.13.x — see "Mac notes").

## The per-node loop

For each node, `N=<ip>` and `H=<hostname>`.

### 1. Baseline + pick the endpoint

```bash
# all volumes healthy before we start? (must be — don't upgrade onto a degraded cluster)
kubectl -n longhorn-system get volumes.longhorn.io -o json | python3 -c "
import sys,json;d=json.load(sys.stdin)
bad=[v['metadata']['name'] for v in d['items'] if v['status'].get('robustness') in ('degraded','faulted')]
print('degraded/faulted:', bad or '(none)')"
```

**When the node you're upgrading is also a talosctl endpoint** (the 3 CP IPs are
endpoints), drive its `talosctl` calls through a *different* endpoint with `-e`
(e.g. upgrade `.46` via `-e 10.25.30.45`), or the command dies mid-reboot.

### 2. Longhorn: analyse redundancy, then evacuate correctly

Only relevant for Longhorn nodes (wyse-01/02, talmacs). **The critical question:
does this node hold the LAST healthy replica of any volume?** If yes, a reboot
takes that volume offline — you must move the replica off first.

```bash
kubectl -n longhorn-system get replicas.longhorn.io -o json | python3 -c "
import sys,json
d=json.load(sys.stdin); NODE='$H'
from collections import defaultdict
by=defaultdict(list)
for r in d['items']:
    if r['spec']['volumeName'] in {x['spec']['volumeName'] for x in d['items'] if x['spec'].get('nodeID')==NODE}:
        by[r['spec']['volumeName']].append((r['spec'].get('nodeID'),r.get('status',{}).get('currentState'),r['spec'].get('healthyAt','')!=''))
lastonly=[]
for vn,reps in by.items():
    he=sum(1 for n,st,h in reps if n!=NODE and h and st=='running')
    if any(n==NODE for n,_,_ in reps) and he==0: lastonly.append(vn)
print('volumes whose LAST healthy replica is on',NODE,':', lastonly or 'NONE')"
```

- **NONE (all volumes redundant elsewhere)** → `--preserve` is safe. Disable
  scheduling *without* eviction (keeps the local replicas; they reattach after
  reboot, much faster than a rebuild):
  ```bash
  kubectl cordon $H
  kubectl -n longhorn-system patch nodes.longhorn.io $H --type=merge \
    -p '{"spec":{"allowScheduling":false,"evictionRequested":false}}'
  ```
- **Some volumes have their last replica here** (typically single-replica
  volumes: numberOfReplicas=1, or data-locality-pinned) → you MUST evacuate them
  or they go offline during the reboot. Request full node eviction and wait for
  **0 replicas** before upgrading:
  ```bash
  kubectl cordon $H
  kubectl -n longhorn-system patch nodes.longhorn.io $H --type=merge \
    -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}'
  # wait until 0 replicas remain on the node (Longhorn rebuilds them elsewhere):
  until [ "$(kubectl -n longhorn-system get replicas.longhorn.io -o json | python3 -c "
  import sys,json;print(sum(1 for r in json.load(sys.stdin)['items'] if r['spec'].get('nodeID')=='$H'))")" = 0 ]; do sleep 6; done
  ```
  **Remember to set `evictionRequested:false` again after the node is back**, or
  Longhorn keeps refusing to schedule replicas there.

Identify what the single-replica volumes actually are so you know the blast radius:
```bash
kubectl get pv -o json | python3 -c "
import sys,json
for p in json.load(sys.stdin)['items']:
    c=p['spec'].get('claimRef',{}); print(p['metadata']['name'][:20],'->',c.get('namespace'),'/',c.get('name'))"
```
Common ones on this cluster: observability (victoria-logs/metrics/alertmanager),
and CNPG postgres instances (single Longhorn replica each — CNPG does its own
app-level HA across instances).

### 3. Drain

```bash
kubectl drain $H --ignore-daemonsets --delete-emptydir-data --timeout=15m
```
Run it **backgrounded** (drains exceed the 2-min foreground cap). Expected residue:
- **Static control-plane pods** (`kube-apiserver/controller-manager/scheduler-<node>`)
  never drain — that's fine, they cycle with the node.
- **Longhorn `instance-manager-…`** may block on its PDB
  (`node-drain-policy: block-if-contains-last-replica`) while replicas are still
  running. If you evacuated to 0 replicas in step 2, the PDB clears and drain
  finishes. If you used `--preserve`, the instance-manager stays blocked until the
  volumes detach (workloads evicted) — that's OK, the upgrade's own reboot handles
  it; you can stop waiting on the drain once all *real* workloads are off.
- **CNPG**: draining the node running the **primary** triggers an automatic clean
  switchover to another instance (a few seconds' write blip). Confirm:
  `kubectl -n database get cluster <name> -o jsonpath='{.status.currentPrimary}'`.
- **Data-locality PVs** (e.g. jellyfin) node-pin their pod — the pod goes
  `Pending` until this node returns. Expected; it reschedules post-upgrade.

### 4. Upgrade — `--preserve`, backgrounded, never timeout-wrapped

```bash
talosctl -e <other-endpoint-or-$N> -n $N upgrade \
  --image <installer image from "Node inventory" — it already ends in :<talosVersion>> --preserve
```
**Never wrap `talosctl upgrade` (or `reset`) in `timeout`** — an interrupted
upgrade leaves the node in a half-reset LOCKED state. Background it and poll.

`--preserve` keeps EPHEMERAL/etcd data across the reboot. Talos cordons/drains,
reboots into the new UKI, then auto-uncordons the k8s node itself.

**Watch the logs while it pulls — the image pull is the flaky part.** The first
thing the upgrade does is pull the installer image, and the on-node DNS resolver
(`10.25.30.38`) flakes intermittently. A failed pull is a **safe no-op** — the
node hasn't touched its disk yet — so it's always safe to just re-run the same
`upgrade` command. Tail the node while the upgrade runs so you can see the pull
succeed (or fail on DNS) instead of guessing:

```bash
# in a backgrounded shell, follow the node's kernel/service log during the upgrade:
talosctl -e <endpoint> -n $N dmesg --follow &          # or: talosctl -e <endpoint> -n $N logs machined -f
```
What you're looking for:
- `failed to pull image ... lookup ... server misbehaving` / `i/o timeout` /
  `no such host` → **DNS flake. Re-run the exact same `upgrade` command.** Nothing
  was changed on disk; retry is free. It usually succeeds on the 2nd or 3rd try.
- Pull succeeds → you'll see it unpack, write the new UKI, and reboot. From here
  it's committed; move to step 5 and wait for it back.
- A burst of DNS/NTP timeouts in the log *after* the reboot (first boot) is also
  normal and self-recovers in 1-2 min — don't panic-reinstall over it.

### 5. Wait for it back, then verify

```bash
# NOTE: the `Tag:` line sits TWO lines below `Server:` (Server → NODE → Tag), so the
# match must span at least `-A2` AND grep the Tag line — `grep -A1 Server | grep -q <version>`
# never matches and loops until timeout (looks like the node is stuck when it's actually fine).
until talosctl -e <endpoint> -n $N version 2>/dev/null | grep -A2 Server | grep Tag | grep -q <version>; do sleep 6; done
talosctl -e <endpoint> -n $N version | grep -A2 Server | grep Tag   # <version>
kubectl get node $H -o wide                                         # Ready, Talos (<version>), kernel 6.18.x
```

> When wrapping this wait in a `Monitor`/background poll, use the **same** `grep -A2 Server | grep Tag | grep -q <version>` predicate — a too-narrow `-A1` context is the classic "stuck waiting for NODE_BACK" bug.

**Control-plane extra check — etcd must be fully healthy before the next CP:**
```bash
talosctl -e 10.25.30.45 -n 10.25.30.45,10.25.30.46,10.25.30.35 etcd status
# 3 members, no LEARNER, ERRORS column empty, RAFT INDEX within a few of each other, same TERM
talosctl -e 10.25.30.45 -n 10.25.30.45 etcd members   # 3 members, LEARNER=false
kubectl -n kube-system get pods --field-selector spec.nodeName=$H | grep -E 'apiserver|controller|scheduler'  # 1/1
```
(Mixed etcd patch versions across members mid-rollout is fine; a leader
re-election when you upgrade the leader is expected — TERM bumps by 1.)

### 6. Restore Longhorn scheduling (Longhorn nodes only)

```bash
kubectl -n longhorn-system patch nodes.longhorn.io $H --type=merge \
  -p '{"spec":{"allowScheduling":true,"evictionRequested":false}}'   # evictionRequested:false is mandatory if you evicted in step 2
kubectl -n longhorn-system get nodes.longhorn.io $H -o json | python3 -c "
import sys,json;d=json.load(sys.stdin)
for n,st in d['status']['diskStatus'].items():
    print(n,{c['type']:c['status'] for c in st.get('conditions',[])})"   # Ready:True Schedulable:True
```
Talos already uncordoned the k8s node **on the normal path** (where Talos itself
drove the reboot). It does NOT on a **talmac you powercycled yourself** after the
BootFFFF abort — that node returns `Ready,SchedulingDisabled`. Always check and
uncordon explicitly:
```bash
kubectl get node $H --no-headers   # if it says Ready,SchedulingDisabled:
kubectl uncordon $H
```

### 7. Confirm cluster fully healthy — GATE before the next node

Do NOT start the next node until all of these pass:
```bash
# all volumes healthy (detached volumes show robustness=unknown — that's fine, not degraded/faulted)
kubectl -n longhorn-system get volumes.longhorn.io -o json | python3 -c "
import sys,json;d=json.load(sys.stdin)
from collections import Counter
print(dict(Counter(v['status'].get('robustness') for v in d['items'])))
print('degraded/faulted:',[v['metadata']['name'] for v in d['items'] if v['status'].get('robustness') in ('degraded','faulted')] or '(none)')"
# zero non-ready pods
kubectl get pods -A -o json | python3 -c "
import sys,json;d=json.load(sys.stdin)
bad=[(p['metadata']['namespace'],p['metadata']['name']) for p in d['items']
     if p['status']['phase'] not in ('Running','Succeeded')
     or (p['status']['phase']=='Running' and not any(c['type']=='Ready' and c['status']=='True' for c in p['status'].get('conditions',[])))]
print('non-ready:',len(bad)); [print(' ',*b) for b in bad[:20]]"
```
Wait for replica rebuilds to finish (evacuated volumes rebuild back onto the node
once scheduling is restored). Only when volumes are all healthy and pods all ready
do you move on.

## Mac (talmac) notes

- **The BootFFFF "failure" is cosmetic — but the node does NOT reboot itself, you
  must powercycle it.** In-place upgrade of a talmac reports `failed to create boot
  entry: BootFFFF: declared length of FilePath … overruns available data` and exits
  1 — Apple's EFI NVRAM has a malformed variable Talos can't parse. Crucially, the
  installer fails at the *last* step (writing the EFI boot-entry variable), so the
  upgrade sequence **aborts before rebooting** — unlike a GRUB node, it does NOT
  cordon/reboot on its own. The new `Talos-v<ver>.efi` UKI and `BOOTX64.efi` ARE
  written to disk (confirm the `copying … Talos-v<ver>.efi` line in the log), so the
  fix is simply to reboot through firmware yourself:
  ```bash
  # after the BootFFFF exit-1, the node is still on the OLD version, drained/cordoned.
  # force a full firmware reboot (NOT a kexec, which would re-boot the old kernel):
  talosctl -e <endpoint> -n $N reboot --mode=powercycle
  ```
  systemd-boot then boots the newest on-disk UKI = the new version. The hardware
  reset takes ~15-20s to actually trigger, so a version read in that window returns
  the *old* version from the still-running node. **Do NOT handle that with a
  "wait for UNREACHABLE" phase** — see the trap below. Just sleep past the reset
  window, then poll for the target version with a single bounded, always-verbose
  loop:
  ```bash
  TARGET=v1.14.2; EP=10.25.30.45; N=10.25.30.43   # TARGET = topf.yaml talosVersion
  probe() { timeout 10 talosctl -e $EP -n $N version 2>/dev/null \
              | grep -A2 Server | grep Tag | awk '{print $2}'; }
  talosctl -e $EP -n $N reboot --mode=powercycle
  sleep 45                      # ride out the 15-20s reset trigger + early boot
  for i in $(seq 1 40); do      # hard bound: ~7 min
    V=$(probe); echo "t=$((45+i*10))s version=${V:-unreachable}"   # print EVERY pass
    [ "$V" = "$TARGET" ] && echo BOOTED_NEW && break
    sleep 10
  done
  ```
  Longhorn disks come back `Ready:False` for ~10-50s post-boot while
  instance-manager restarts, then flip to Ready — normal, not the diskUUID gotcha.
- **Never gate on "wait for the node to go UNREACHABLE".** A talmac powercycle can
  come and go faster than the probe interval, so the unreachable window is often
  missed entirely and that loop never breaks. Worse, the usual shape
  (`for …; do sleep 5; [ -z "$(probe)" ] && break; done`) prints **nothing** while
  it spins, so it burns its full bound — 40 iterations × (5s sleep + up to 10s
  probe) ≈ 10 minutes of dead silence — and looks exactly like a hung node when the
  machine is already up and healthy. Poll for the *target version* instead, sleep
  past the reset window rather than trying to detect it, and **echo on every
  iteration** so a stall is always distinguishable from a slow boot.
- **`talosctl version` has NO `--timeout` flag.** Passing one makes the command
  exit 1 with `unknown flag: --timeout` and print NOTHING to stdout — so a poll
  loop that greps its output reads every iteration as "unreachable" and spins
  until the loop bound while the node is actually up and healthy. This is the
  classic fake-stuck-talmac bug; it also produces a bogus instant "UNREACHABLE at
  t=5s" in the wait-for-unreachable phase. Wrap the whole call in the shell's
  `timeout` instead (safe for a read-only `version`; still NEVER for
  `upgrade`/`reset`):
  ```bash
  # reachability probe — note `timeout N talosctl`, NOT `talosctl --timeout`
  probe() { timeout 10 talosctl -e <endpoint> -n $N version 2>/dev/null \
              | grep -A2 Server | grep Tag | awk '{print $2}'; }
  until [ -z "$(probe)" ]; do sleep 5; done          # gone down
  until [ "$(probe)" = "<version>" ]; do sleep 10; done   # back up on the new version
  ```
  If a poll loop ever reports "unreachable" for more than ~3 min, STOP and run the
  bare command by hand — confirm it's a real outage and not a bad flag swallowing
  the output.
- **A powercycled talmac does NOT get auto-uncordoned.** Talos only uncordons the
  k8s node when *it* drove the reboot (the normal GRUB-node upgrade path). Because
  the BootFFFF abort means you rebooted the node yourself, it comes back
  `Ready,SchedulingDisabled` and stays there — you must `kubectl uncordon $H`
  explicitly in step 6 alongside the Longhorn patch, or the node sits idle and
  nothing reschedules onto it.
- **USB ISO reinstall is only for a talmac already bricked** on a non-booting
  stock 1.13.x–1.14.1. Flash the factory `metal-amd64.iso` for schematic `2385c7da…`
  at **v1.14.2+**, boot holding ⌥ → EFI Boot, then
  `topf apply --nodes-filter '^<host>$'` (topf detects maintenance mode and applies
  insecurely; its dry-run diff won't be meaningful there). A normal migration off a
  working version is just an in-place `upgrade --preserve`.
- **Stale USB Longhorn mount after replug.** If a USB enclosure was unplugged and
  replugged, the old mount goes stale (`/var/mnt/longhorn-usb` → dead `/dev/sdX1`,
  `input/output error` on `longhorn-disk.cfg`, disk `Ready:False`). A **reboot fixes
  it**: Talos re-discovers the disk (legacy `machine.disks` by-id before the topf apply;
  `ExistingVolumeConfig longhorn-usb` by XFS UUID after it, from
  `node/talmac-0N/00-longhorn-usb.yaml`), and Longhorn re-adopts automatically **if the
  on-disk diskUUID still matches** the node CR. No manual dance needed for that case.
  Check with `talosctl -n $N get volumestatus e-longhorn-usb`.
- **Longhorn diskUUID mismatch** ("record diskUUID doesn't match the one on the
  disk"): happens when `/var/lib/longhorn/` got reset (fresh install, or a
  `--preserve` upgrade that reset EPHEMERAL) so the on-disk cfg has a *new* UUID.
  Fix only if the disk holds **0 replicas** (check first!). The webhook blocks a
  plain remove — you must **disable, remove, re-add**, one disk at a time:
  ```bash
  kubectl -n longhorn-system patch nodes.longhorn.io $H --type=json \
    -p '[{"op":"replace","path":"/spec/disks/<disk-name>/allowScheduling","value":false}]'
  kubectl -n longhorn-system patch nodes.longhorn.io $H --type=json \
    -p '[{"op":"remove","path":"/spec/disks/<disk-name>"}]'
  # wait for it to leave status.diskStatus, then re-add with the SAME spec
  # (path, storageReserved, tags — copy from a healthy peer node like talmac-03):
  kubectl -n longhorn-system patch nodes.longhorn.io $H --type=json \
    -p '[{"op":"add","path":"/spec/disks/<disk-name>","value":{"allowScheduling":true,"diskDriver":"","diskType":"filesystem","evictionRequested":false,"path":"/var/lib/longhorn/","storageReserved":32212254720,"tags":[]}}]'
  # Longhorn adopts the on-disk UUID → Ready:True Schedulable:True
  ```
  Removing/re-adding a shared Longhorn disk CR is a shared-cluster mutation — the
  auto-approver will ask for explicit user confirmation. Get it before running.

## Repo cleanup after migrating a node onto a new installer

If you moved a node onto a different schematic or version pin, edit its entry in
`topf.yaml` (`schematicId: "@schematics/<hw>.yaml"`, or a per-node `talosVersion`),
re-render to confirm the installer image resolved, and commit (conventional-commit message, no
attribution trailer).

## Gotchas learned (quick reference)

- **One node at a time. Always.** Gate on full cluster health between nodes.
- **Single-replica / last-replica-on-node volumes must be evicted, not just
  `--preserve`d** — otherwise they go offline during the reboot. Analyse
  redundancy first (step 2).
- **Longhorn instance-manager PDB blocks drain** while replicas run; `block-if-
  contains-last-replica` allows it once volumes are redundant/detached. Evacuating
  to 0 replicas is the deterministic unblock.
- **`evictionRequested:true` must be reset to `false`** after the node returns.
- **Never `timeout`-wrap `talosctl upgrade`/`reset`.** Background it. A killed
  upgrade LOCKS the node.
- **Detached volume `robustness=unknown` is normal** (no attached workload) — not
  a fault. Only `degraded`/`faulted` are real problems.
- **CNPG primary drain = automatic switchover.** Safe and expected.
- **Talmac BootFFFF error is non-fatal.** Verify version, don't reinstall. It does
  mean you must `reboot --mode=powercycle` yourself AND `kubectl uncordon` after —
  neither happens automatically on that path.
- **Never pass `--timeout` to `talosctl version`** — the flag doesn't exist, the
  command prints nothing, and version poll loops hang forever on a healthy node.
  Use `timeout 10 talosctl … version` instead. Any "unreachable" streak longer
  than ~3 min should be re-checked by hand before believing it.
- **Every wait loop must echo on every iteration and carry a hard bound.** A
  silent loop is indistinguishable from a hung node; a loop whose only exit is the
  success condition will spin its whole budget when that condition never trips.
  Never gate a reboot wait on "node goes unreachable" — poll for the target
  version and sleep past the reset window instead.
- **`talosctl` needs an absolute `$TALOSCONFIG`.** Exporting
  `TALOSCONFIG="$PWD/talosconfig"` breaks the moment anything `cd`s
  elsewhere (editing this skill file will do it), and the failure reads as
  `talos config file is empty`. Use the full
  `/Users/zac/projects/lab_casa/home-cluster/kubernetes/bootstrap/talos/talosconfig`
  path in every command. That failure is a safe no-op — the upgrade never reached
  the node — so just re-run it.
- **etcd: leader last, verify 3 healthy converged members between CP nodes**, use
  a different `-e` endpoint when the node being rebooted is itself an endpoint.
- **Node DNS resolver (10.25.30.38) is flaky — watch the upgrade's image pull and
  retry on DNS failure.** The pull is the failure-prone step; a failed pull hasn't
  touched disk, so re-running the same `upgrade` is a safe no-op (see step 4).
  First boot after the reboot can also log a burst of DNS/NTP timeouts and look
  stalled for 1-2 min, then self-recovers; don't reinstall over it.
- **This layer isn't ArgoCD-managed** — topf/bootstrap, applied by hand.
- **talosctl ≥1.14 `upgrade` = install → its own drain (`--drain-timeout` 5m) → reboot →
  uncordon.** The install takes seconds; the node then sits on the old version while
  talosctl waits out pod grace periods (ingress-nginx-external has 300s), so ~2-4 min at
  "still old version" is normal. `--preserve` is gone (always preserved). Check
  `talosctl logs machined | grep "upgrade progress"` for "installation of vX complete".
- **Check for node-pinned local PVs before draining** (`kubectl get pv` with `.spec.local`
  / nodeAffinity): their pods stay Pending until that node returns. As of 2026-09-30 there
  are none (garage vfs-cache and jellyfin transcodes moved to emptyDir).
- **After the 1.14 upgrade but before the topf apply, `/var` loses `nosuid,nodev`**
  (legacy config under the 1.14 contract). The topf render's `VolumeConfig EPHEMERAL
  mount.secure: true` restores them on the next reboot. Expected, not a regression.
- **`topf apply --dry-run` exits 1 while the node is NotReady** (pre-flight). Wait for
  kubelet Ready (~1 min after boot), then dry-run again: exit 2 = diff, 0 = in sync.
  Re-run the dry-run after the apply and require exit 0.
- **Elitebooks: never kexec. Always `--reboot-mode powercycle` / `reboot --mode powercycle`.**
  On 2026-09-30 elitebook-02 hung after the kexec into v1.14.2: it answered ping, but all
  service ports were closed and apid never started. About 75 minutes later it rebooted
  and GRUB fell back to slot A (the old version). A retry of the same kexec worked.
  Firmware reboots took 70-100s and were clean on both elitebooks. If a node answers ping
  but 50000 stays refused for more than 5 minutes, it is hung: ask the user to check the
  screen. A hard power-off falls back to the old slot.
- **Apply config to control-plane nodes as `--mode staged --skip-post-apply-checks` and then
  `talosctl reboot --drain --mode powercycle`. Don't use a live no-reboot apply.** On
  wyse-03 the live apply restarted kubelet, the old kubelet ignored SIGTERM, and Talos
  marked the service Failed ("cannot delete running task kubelet"). `service kubelet
  restart` couldn't fix it; only a reboot did. The workers' live applies were fine. The
  reboot also brings back the `/var` `nosuid,nodev` flags in the same step.
- **etcd 3.6 → 3.7 happens on control-plane upgrade** (the image is not pinned). It's one-way,
  so take `talosctl etcd snapshot` into the scratchpad first. The STORAGE column flips to
  3.7.0 once all members run 3.7.1.
- **The control-plane topf diff adds `KubeEtcdEncryptionConfig` without the `identity: {}`
  fallback** (the upstream 1.14 default). Before applying, confirm by hash that the
  secretbox key matches the live one. `KubeAuthenticationConfig` allows anonymous access
  to `/livez`, `/readyz` and `/healthz` only; the old setting was `--anonymous-auth=false`.
  Both are expected.
- **topf, not talhelper.** Render/validate with topf, take the upgrade image from the
  rendered `UnattendedInstallConfig`, apply config with `topf apply --nodes-filter
  '^<host>$'` (dry-run first) only once that node is on 1.14. Never unfiltered mid-rollout.
- **Rendered configs and `talosconfig` hold plaintext secrets** — gitignored; `yq` out
  the field you need, never `cat` a whole file.
