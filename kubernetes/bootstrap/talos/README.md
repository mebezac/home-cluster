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

Everything uses the Talos 1.14 multi-document kinds except `all/30-kubelet.yaml.tpl`, which
has to stay on legacy `.machine.kubelet` because 1.14 has no multi-doc equivalent for kubelet
`extraMounts` (see the note in that file).
