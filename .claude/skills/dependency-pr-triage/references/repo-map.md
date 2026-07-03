# Repo map — where dependencies live & how to judge impact

Read this when scanning for required changes (phase 3) and classifying danger
(phase 5). It maps a Renovate PR to the files it touches and tells you which
components are platform-critical (so a *minor* bump still lands in the 🛑 tier).

## Dependency kind → where it's referenced

Renovate's manager label tells you the kind; the package name in the title is
your grep key across `kubernetes/`.

| PR kind (label) | What the title names | Where we set it |
|-|-|-|
| `renovate/container` | image repo, e.g. `ghcr.io/mealie-recipes/mealie` | `kubernetes/apps/<ns>/<app>/values.yaml` → `image.repository` + `tag` (pinned `tag@sha256:...`) |
| `renovate/helm` | chart name, e.g. `cert-manager`, `cloudnative-pg` | `targetRevision` in `kubernetes/argo/apps/<ns>/<app>.yaml`; chart config in that app's `values.yaml` |
| `renovate/github-release` | tool, e.g. `getsops/sops`, `siderolabs/talos`, `helmfile/helmfile` | `kubernetes/bootstrap/` (talos), `helmfile.yaml`, `.github/workflows/*` |

Structure recap (`kubernetes/`):

- `apps/<namespace>/<app>/` — per-app `values.yaml` (+ `kustomization.yaml`,
  `*.sops.yaml` when secrets exist). Namespace usually == app name.
- `argo/apps/<namespace>/<app>.yaml` — the ArgoCD Application; holds chart
  `targetRevision` and the app-template version.
- `bootstrap/` — `helmfile.yaml` and `talos/`; the pre-ArgoCD layer.

The image tag / chart version Renovate updates is the exact line to scan and the
line to put a `# changelog:` breadcrumb above.

## Blast-radius tiers

Impact = **semver × blast radius**. Semver comes off the PR title (see SKILL.md).
Blast radius comes from *what the component is*:

### Platform-critical → 🛑 even for minors, and majors get maximum care

These underpin everything else. A regression here can take down the whole
cluster, break GitOps reconciliation, or corrupt data.

- **argo-system / argo-cd** — the GitOps engine itself. If this breaks, nothing
  else syncs. Grouped bumps common here (Argo Operator group in renovate.json5).
- **database** — central Postgres (CloudNativePG). Many apps init a DB against
  it via `postgres-init` init-containers. Major bumps can imply data migrations;
  check running version via the k8s MCP before adopting.
- **valkey** — central Redis-equivalent shared by multiple apps.
- **cert-manager** — TLS for all ingress. CRD-bearing; majors may drop old API
  versions — verify served CRDs in-cluster first.
- **network** — Cilium / CNI / external-dns / ingress. Networking outage =
  everything unreachable.
- **storage / longhorn-system / openebs-system** — persistent volumes. Risky to
  bump carelessly; data lives here.
- **observability** — victoria-metrics-k8s-stack, prometheus-operator-crds.
  CRD-bearing; a CRD major (e.g. prometheus-operator-crds) can break every
  ServiceMonitor/PrometheusRule if an API version is removed.
- **kube-system**, **security** (authelia — auth for protected ingress),
  **bootstrap/talos**, **sops/ksops** (secret decryption — break this and
  ArgoCD can't render secrets).

For these: read the changelog fully, check the live cluster (phase 4), and never
merge a major without an explicit, informed go from the user.

### Leaf apps → tier by semver alone

Everything else is a single self-contained app (mealie, jellyfin, immich,
audiobookshelf, lubelog, shlink, romm, lastglance, esphome, zwave-js-ui, …). A
break affects only that app, and rollback is a one-line revert. So:

- digest / patch → ✅
- minor → ✅–⚠️ (⚠️ if the changelog shows behavior/config changes)
- major → ⚠️ (🛑 only if it carries a DB/schema migration or needs a config edit)

Immich is a notable leaf that ships DB migrations on some releases — treat its
majors as 🛑 and read release notes carefully.

## Repo conventions that affect "does this need a change?"

Grounded in `CLAUDE.md` and `AGENTS.md`:

- **Images are pinned `tag@sha256:...`.** Renovate updates both. No `latest`.
- **app-template chart** (`ghcr.io/bjw-s-labs/helm`, currently `4.6.2`) backs
  most apps — a *chart-structure* change in an app-template bump can ripple
  across every app that uses it; scan broadly for those.
- **Central Postgres + init-container** pattern: apps needing a DB use a
  `ghcr.io/home-operations/postgres-init` init-container against the central
  `database` Postgres (example: `kubernetes/apps/lubelog/lubelog/`). A Postgres
  major is high blast-radius for this reason.
- **Central Valkey** as the shared Redis.
- **Ingress**: `internal` vs `external` classNames, domain `laboratory.casa`,
  TLS handled by cert-manager (so cert-manager majors matter for all ingress).
- **GitOps**: merging = deploying. Cluster is read-only to you (k8s MCP for
  inspection only); all changes go through the repo.

## Quick impact heuristics

- Changelog says "renamed value `x` → `y`" → grep our `values.yaml`; only a
  problem if we set `x`.
- Changelog says "new required setting" → always a required repo change before
  merge.
- Changelog says "changed default" → matters only if we relied on the old
  default (i.e. we *didn't* set it explicitly).
- CRD chart major that "removes v1beta1 X" → check in-cluster whether anything
  still uses v1beta1 X before merging.
- Empty/cosmetic changelog + no config overlap → safe, batch-mergeable.
