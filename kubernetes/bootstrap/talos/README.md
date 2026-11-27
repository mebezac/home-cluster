# Talos

Machine configs are assembled by [topf](https://postfinance.github.io/topf/) from `topf.yaml`
plus the strategic-merge patches in this directory. Run `task --list` from the repo root for
the render / diff / apply / upgrade tasks.

- `topf.yaml`: cluster, versions (Renovate-tracked), nodes and per-node `data`
- `schematics/<hardware>.yaml`: Image Factory schematics; topf hashes them locally into the
  installer image (`factory.talos.dev/metal-installer/<id>:<talosVersion>`). A schematic the
  factory has never seen needs one `topf render --submit-to-factory` first.
- `secrets.sops.yaml`: the Talos secrets bundle (SOPS-encrypted)
- `talosconfig`, `rendered/`: generated, plaintext secrets, gitignored

## Patch directories

Merged in this order, alphabetically within each directory; later patches win:

- `all/`: every node
- `control-plane/`: control-plane nodes
- `worker/`: worker nodes
- `node/<host>/`: one node

Files ending in `.yaml.tpl` are Go-templated per node (`.Node.Host`, `.Node.IP`,
`.Node.Data.*`, `.Data.*`, `.KubernetesVersion`); see the
[topf configuration model](https://postfinance.github.io/topf/main/configuration-model/).

Everything uses the Talos 1.14 multi-document kinds except two legacy v1alpha1 blocks that 1.14
has no multi-doc equivalent for: `all/30-kubelet.yaml.tpl` (`.machine.kubelet` extraMounts) and
`all/80-logging.yaml` (`.machine.logging` service log destinations). See the notes in those files.

- `all/60-watchdog.yaml.tpl`: hardware watchdog, rendered only for nodes with `data.watchdog`
  in `topf.yaml` (today the elitebooks; wyse and talmac have no usable device, see the file).
- `all/80-logging.yaml`: service and kernel logs to VictoriaLogs via the `talos-logs` DaemonSet.

`TOPFCONFIG` (from `.mise.human.toml`) points at the main checkout. In a git worktree, pass
`--topfconfig $PWD/topf.yaml`, or topf renders the main checkout's patches.

## Upgrades

One node at a time, with a health gate between nodes. The procedure, the gotchas and the
per-node-type scripts (`worker-upgrade.sh`, `talmac-upgrade.sh`, `cp-upgrade.sh`) are in
`.claude/skills/talos-upgrade/`. When `kubernetesVersion` moved too, run
`task talos:upgrade-k8s` (dry-run first) BEFORE any node: every config apply pushes the
rendered kubelet version.
