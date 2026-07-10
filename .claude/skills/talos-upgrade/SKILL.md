---
name: talos-upgrade
description: >-
  Upgrade the Talos version on this home-cluster's nodes safely, one at a time,
  draining Longhorn + workloads first and verifying full health before moving on.
  Use whenever the user wants to bump Talos (e.g. "get the cluster on v1.13.5",
  "upgrade talos", "roll out the new talos version", "update <node> to <version>",
  "do the talos nodes"), reinstall/recover a node, or migrate a node onto the
  custom Mac installer. Handles the whole node loop: pick a safe order
  (workers → control-plane, non-leaders → etcd-leader last), cordon, drain past
  the Longhorn instance-manager PDB, evacuate single-replica volumes that would
  otherwise go offline, run `talosctl upgrade --preserve`, ride out the T2 Mac
  BootFFFF non-fatal error, re-enable scheduling, and confirm every volume /
  pod / etcd member is healthy before the next node. Knows this repo's talhelper
  layout, the custom GCC installer for the talmac nodes, and the Longhorn
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
in `kubernetes/bootstrap/talos/` (talhelper), applied manually. Config edits are
committed to the repo normally (no attribution trailer per repo convention).

## Setup (run first, every session)

```bash
cd kubernetes/bootstrap/talos
export SOPS_AGE_KEY_FILE=/Users/zac/projects/lab_casa/home-cluster/age.key
export TALOSCONFIG="$PWD/clusterconfig/talosconfig"
# regenerate configs so the install image reflects the target talosVersion:
talhelper genconfig --config-file talconfig.yaml --secret-file talsecret.sops.yaml --out-dir clusterconfig
```

`talconfig.yaml` already carries `talosVersion:` — the version everything targets.
To upgrade the whole cluster to a new patch, bump `talosVersion` there first (and
`kubernetesVersion` if desired), regen, then loop. For a same-version rollout
(nodes lagging the pinned version) no edit is needed — just loop.

### Node inventory & upgrade image

Each node's upgrade image = its **install image** from the generated config
(factory schematic + `:version`, or the custom installer for talmacs):

```bash
for f in clusterconfig/kubernetes-*.yaml; do
  echo "$f -> $(grep -A3 'install:' "$f" | grep image: | head -1 | awk '{print $2}')"
done
```

Current nodes (verify live, don't trust this list blindly):

| Node | IP | Role | Longhorn? | Installer |
|-|-|-|-|-|
| elitebook-01 | 10.25.30.45 | control-plane | no | factory `249d9135…` |
| elitebook-02 | 10.25.30.46 | control-plane | no | factory `249d9135…` |
| wyse-5070-03 | 10.25.30.35 | control-plane | no | factory `9ba0b24a…` |
| wyse-5070-01 | 10.25.30.33 | worker | yes | factory `9ba0b24a…` |
| wyse-5070-02 | 10.25.30.34 | worker | yes | factory `9ba0b24a…` |
| talmac-01 | 10.25.30.42 | worker | yes | **`ghcr.io/mebezac/talos-mac/installer`** |
| talmac-02 | 10.25.30.43 | worker | yes | **custom** |
| talmac-03 | 10.25.30.44 | worker | yes | **custom** |

The **talmac** nodes are 2018 T2 Intel Macs and MUST use the custom GCC-linked
installer (`ghcr.io/mebezac/talos-mac/installer:<ver>`) — stock Talos 1.13+ hangs
at cold boot (siderolabs/talos#13579). Never point a talmac at `factory.talos.dev`
for 1.13+. See the `talos-mac-installer` sibling repo + the memory of the same name.

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
  --image <install-image-from-step-'Node inventory'>:<version> --preserve
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
Talos already uncordoned the k8s node. If you manually `kubectl cordon`'d and it
didn't auto-uncordon, `kubectl uncordon $H`.

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

- **The BootFFFF "failure" is cosmetic.** In-place upgrade of a talmac reports
  `failed to create boot entry: BootFFFF: declared length of FilePath … overruns
  available data` and exits 1 — Apple's EFI NVRAM has a malformed variable Talos
  can't parse. The new UKI IS written and systemd-boot boots it. Always re-check
  `talosctl -n $N version` → it upgraded despite the error.
- **USB ISO reinstall is only for a talmac already bricked** on a non-booting
  stock 1.13.x. Flash `metal-amd64.iso` from the matching
  `mebezac/talos-mac-installer` GitHub release, boot holding ⌥ → EFI Boot,
  `talosctl apply-config --insecure`. A normal migration off a working version is
  just an in-place `upgrade --preserve`.
- **Stale USB Longhorn mount after replug.** If a USB enclosure was unplugged and
  replugged, the old bind mount goes stale (`/var/mnt/longhorn-usb` → dead
  `/dev/sda1`, `input/output error` on `longhorn-disk.cfg`, disk `Ready:False`).
  The upgrade's **reboot fixes it** — Talos re-resolves the `by-id` mount and
  Longhorn re-adopts automatically **if the on-disk diskUUID still matches** the
  node CR. No manual dance needed for that case.
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

If you moved a node onto the custom installer or off a version pin, edit
`talconfig.yaml` (set its `talosImageURL`, delete its
`patches/<node>/machine-install.yaml` pin + the reference line), keep
`machine-disks.yaml`, `talhelper genconfig` to confirm the install image resolved,
update `docs/talmac-1.13-upgrade.md`, and commit (conventional-commit message, no
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
- **Talmac BootFFFF error is non-fatal.** Verify version, don't reinstall.
- **etcd: leader last, verify 3 healthy converged members between CP nodes**, use
  a different `-e` endpoint when the node being rebooted is itself an endpoint.
- **Node DNS resolver (10.25.30.38) is flaky — watch the upgrade's image pull and
  retry on DNS failure.** The pull is the failure-prone step; a failed pull hasn't
  touched disk, so re-running the same `upgrade` is a safe no-op (see step 4).
  First boot after the reboot can also log a burst of DNS/NTP timeouts and look
  stalled for 1-2 min, then self-recovers; don't reinstall over it.
- **This layer isn't ArgoCD-managed** — talhelper/bootstrap, applied by hand.
