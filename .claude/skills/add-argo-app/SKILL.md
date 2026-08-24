---
name: add-argo-app
description: >-
  Add a NEW application to this home-cluster repo as an ArgoCD Application using
  the bjw-s app-template Helm chart. Use whenever the user wants to add, create,
  onboard, deploy, "set up", or "stand up" a new app, point at a GitHub repo /
  README / project URL to "run this in the cluster", or translate a Flux
  HelmRelease / docker-compose / plain manifests into this repo's GitOps layout,
  or says "add <app> to argo" / "deploy <app>" / "I want to run <app>" / "make
  an app for <x>". Spawns subagents to deep-read the upstream project's FULL
  README/docs (installation, every env/config knob, and optional add-ons that
  fit this repo's style), presents the optional choices via the question tool
  for a fully-fleshed-out — not bare-bones — deploy, then scaffolds the full
  directory (values.yaml + Argo Application,
  plus ksops secret files when needed), wires the house patterns (internal
  ingress on laboratory.casa, Longhorn persistence, runAs 3000 security context,
  central Postgres init-container, central valkey), pins images to tag@sha256,
  commits GitOps-first, and verifies the app synced Healthy via the argocd +
  kubernetes MCP. Reach for this any time a new workload needs to exist in the
  cluster.
---

# Add a new ArgoCD app (bjw-s app-template, GitOps-first)

Scaffold a new application so ArgoCD deploys it: an app directory with
`values.yaml` (+ ksops secret files if needed) and an Argo `Application`
manifest. **Never** `kubectl apply` / `helm install` — edit files, commit, push;
the app-of-apps parent picks it up and ArgoCD reconciles. Use the kubernetes +
argocd MCP only to *verify* the result.

`AGENTS.md` at the repo root is the exhaustive values.yaml cookbook (every
persistence/ingress/security/probe/sidecar/cronjob pattern). This skill is the
workflow + the facts that drift; open `AGENTS.md` for any pattern not covered
here.

## Resolving unknowns — the escalation ladder

You will hit things you're unsure how to express in this repo's conventions (an
odd env var, a chart quirk, where a mount goes, how another app handled a DB).
**Do not guess and do not jump straight to asking the user.** Climb this ladder
in order, stopping at the first rung that answers it:

1. **Search this repo first.** Almost every pattern already exists here. `grep`
   / `ls` for a similar app (`grep -rl "<thing>" kubernetes/apps/`), read its
   `values.yaml` and Argo manifest, and copy the shape. Consult `AGENTS.md`.
   This repo is the source of truth — match it over any external "best practice".
2. **Only if it's genuinely novel here**, research externally:
   - **context7 MCP** — for the upstream app's / Helm chart's / library's own
     docs (config keys, required env, ports).
   - **tavily-search skill** — for the general web (the project's README,
     docker-hub page, GitHub issues, "how to run X in kubernetes").
   - **git-grep MCP** (`mcp__git-grep__searchGitHub`) — to see how *other people*
     run the same image (search their compose files / Helm values / k8s manifests).
3. **Still lost → ask the user.** Only after the repo and research come up empty.
   Ask a specific, narrow question (the one fact you're missing), not an open one.

Note in your reasoning which rung answered each unknown, so the user can see
what was derived vs. what was assumed.

## Phase 0a — Deep-read the source (ALWAYS via subagents)

The goal is a **fully fleshed-out** app on the first go, not a bare-bones one.
Bare-minimum installs that miss the optional-but-obvious config (SSO, metrics,
a second volume the app really wants) are a failure of this skill.

Assume a **container image exists** (this repo only runs containers) — if you
truly can't find one, that's a stop-and-ask.

**Always spawn subagents** to read the FULL documentation — not just the first
screen of the README. Fan out (single message, parallel `Agent` calls) with
**three research tracks**; give each the project URL/repo and this repo's house
patterns (`AGENTS.md` + the Repo-facts table above) so they know what "fits our
style" means:

1. **Installation** — the complete run story: official image(s) + registry, all
   exposed **ports**, every **volume/path** that must persist, required
   **backing services** (Postgres/redis/etc.), health endpoint, run-as-user /
   capability requirements, and any first-run/bootstrap steps. Read the README
   end-to-end plus `docker-compose.yml` / `Dockerfile` / `helm/` / `docs/`.
2. **Env vars / config** — the EXHAUSTIVE list of configuration knobs (env vars,
   config-file keys, CLI flags). For each: name, purpose, default, required vs
   optional, and secret vs non-secret. Chase the dedicated config/reference doc,
   not just the quickstart.
3. **Optional configs / add-ons that fit THIS repo** — features worth enabling
   given our conventions: Authelia/OIDC SSO, Prometheus metrics + ServiceMonitor,
   external-vs-internal ingress, central Postgres/valkey instead of bundled,
   extra persistence, sidecars, cron/maintenance jobs, backups. The subagent
   should return each as a concrete "we could also enable X (needs Y)" option
   with the config it requires.

Tell each subagent: read the FULL docs (follow links into `docs/`), and return a
compact structured brief — **outcomes not process, under ~2000 chars**. Cite
where each fact came from. If a subagent hits an unknown, it climbs the
escalation ladder (repo → context7/tavily/git-grep) before giving up.

Then resolve the **image version → sha256 digest** yourself (subagents may not
have registry access) and merge the three briefs into one derived shape:
image, ports, env (secret vs not), volumes, backing services, plus the menu of
optional add-ons.

## Phase 0a.1 — Present options, get the user's call

Do NOT silently pick the fleshed-out config — surface the choices. Use the
**AskUserQuestion** tool to let the user opt into the add-ons track #3 surfaced
(and any genuine forks: which optional datastore, SSO or not, expose externally
or keep internal, which optional volumes). Group related toggles; offer a
sensible default per the Repo-facts patterns. Anything the docs left ambiguous
that research couldn't settle goes here too.

Bare essentials (image/ports/required env/required volumes/required DB) don't
need a question — they're mandatory. Ask only about the **optional** dimensions,
so the user shapes how fleshed-out it gets. Then carry their answers into
Phase 0b.

## Repo facts (verify before trusting — some drift)

| Fact | Value |
|-|-|
| App dir | `kubernetes/apps/<namespace>/<app>/` |
| Argo Application | `kubernetes/argo/apps/<namespace>/<app>.yaml` |
| Chart repo | `ghcr.io/bjw-s-labs/helm` (NOT the github.io URL) |
| app-template version | **5.0.1** (dominant in-repo; confirm with `grep -rh 'chart: app-template' -A1 kubernetes/argo/apps/`) |
| Git repoURL | `https://github.com/mebezac/home-cluster.git` |
| Argo app namespace / project | `argo-system` / `kubernetes` |
| Domain | `laboratory.casa` (no TLS block — cert-manager handles it) |
| Central Postgres (CNPG) | host `postgres-17-cluster-rw.database.svc.cluster.local` |
| postgres-init image | `ghcr.io/home-operations/postgres-init` (tag `18.4` at last check) |
| Central valkey (redis) | `valkey.valkey.svc.cluster.local:6379` |
| Default run-as user | `3000` |

The app-of-apps parent (`kubernetes/argo/apps.yaml`, app `apps`) directory-
recurses `kubernetes/argo/apps/**` and auto-syncs — dropping a new
`Application` file there is all it takes to register the app.

## Phase 0b — Settle the deployment decisions

With the runtime shape from 0a and the user's add-on choices from 0a.1 in hand,
pin down the repo-side choices:

1. **App name + namespace.** Namespace = app name unless it belongs to an
   existing functional group (e.g. `observability/`, `security/`, `media/`,
   `database/`). Check `ls kubernetes/apps/` for an existing group.
2. **Chart.** Default is bjw-s `app-template` (a single container/workload). If
   the app ships its own upstream Helm chart the user prefers, note its
   repoURL + chart + version (see the multi-source note below) — but most apps
   here use app-template even for third-party images.
3. **Image pin.** ALWAYS an explicit released version — **never `latest`** (or
   any moving tag) if it can be avoided. Where possible **pin the digest too**:
   `tag: X.Y.Z@sha256:...`. Only fall back to `latest@sha256:` if the image
   publishes no versioned tags at all. Resolve the digest yourself.
4. **Ingress?** internal (default) vs external vs external+authelia; pick a
   subdomain by function. Map 0a's port to the service/ingress.
5. **Persistence.** Turn 0a's volume paths into `persistence` entries. Almost
   always **Longhorn** (`storageClass: longhorn`, `ReadWriteOnce`) — reach for
   anything else only with a specific reason (see the storage-class table in
   `AGENTS.md`: `longhorn-single-replica` for throwaway data, `openebs-hostpath`
   for hot local scratch, NFS for bulk media).
   **Size small — smaller than you think.** Expanding a Longhorn PVC later is
   trivial; shrinking is not. Plenty of apps here live happily on 128Mi. Size by
   what's actually stored:
   - config / SQLite / small state → `128Mi`–`1Gi`
   - app data that grows slowly (docs, uploads) → a few Gi
   - media / recordings / backups → tens of Gi+, and consider NFS instead of
     Longhorn for genuinely large bulk data.
   When unsure, pick the smaller number.
6. **Secrets.** 0a's secret env → ksops (Phase 2); non-secret env → `env:`.
7. **Database.** 0a's Postgres dep → **central PG init pattern** (Phase 3), not
   a bundled DB. redis → central valkey. Any other datastore → confirm with user.

If translating from Flux/compose/manifests, this is where their values land.
(`.agents/workflows/translate-flux-to-argo.md` has the Flux-specific mapping.)

## Phase 1 — Scaffold the files

Create `kubernetes/apps/<namespace>/<app>/values.yaml`:

```yaml
defaultPodOptions:
  securityContext:
    runAsNonRoot: true
    runAsUser: 3000
    runAsGroup: 3000
    fsGroup: 3000
    fsGroupChangePolicy: OnRootMismatch
    seccompProfile: { type: RuntimeDefault }

controllers:
  <app>:                                   # controller name = app name
    annotations:
      reloader.stakater.com/auto: "true"   # restart on secret/configmap change
    containers:
      app:
        image:
          repository: <registry>/<image>
          tag: <X.Y.Z>@sha256:<digest>
        env:
          TZ: America/New_York
        # envFrom: [{ secretRef: { name: <app>-secret } }]   # if secrets
        resources:
          requests: { cpu: 10m, memory: 128Mi }
          limits: { memory: 512Mi }

service:
  app:
    controller: <app>
    ports:
      http:
        port: <container-port>

ingress:                                   # omit whole block if no ingress
  app:
    className: internal                    # or external (+ authelia) — see AGENTS.md
    hosts:
      - host: <subdomain>.laboratory.casa
        paths:
          - path: /
            service:
              identifier: app              # must match the service key above
              port: http

persistence:                              # omit if stateless
  data:
    type: persistentVolumeClaim
    storageClass: longhorn
    accessMode: ReadWriteOnce
    size: 1Gi                              # right-size DOWN; easy to expand, not shrink (128Mi is common)
    globalMounts:
      - path: /data
```

Create the Argo Application at
`kubernetes/argo/apps/<namespace>/<app>.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app>
  namespace: argo-system
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: kubernetes
  sources:
    - repoURL: https://github.com/mebezac/home-cluster.git
      path: kubernetes/apps/<namespace>/<app>
      targetRevision: main
      ref: <app>-repo
    - repoURL: ghcr.io/bjw-s-labs/helm
      chart: app-template
      targetRevision: 5.0.1
      helm:
        releaseName: <app>
        valueFiles:
          - $<app>-repo/kubernetes/apps/<namespace>/<app>/values.yaml
  destination:
    name: in-cluster
    namespace: <namespace>
  syncPolicy:
    automated:
      allowEmpty: true
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- The `ref:` name must match `<app>-repo` and be consumed by the
  `$<app>-repo/...` valueFiles path. **Only include `ref:` when a second source
  actually uses `$<app>-repo`** — a single-source Application with an unconsumed
  `ref` nil-panics the app-controller.
- **Different upstream chart** (not app-template): swap the 2nd source's
  `repoURL`/`chart`/`targetRevision`. **Multi-component app** (e.g. app +
  worker): add another repo source (its own `ref`) + chart source per component,
  each with its own `releaseName` — mirror an existing multi-source app like
  `kubernetes/argo/apps/immich/`.

## Phase 2 — Secrets (ksops, only if needed)

Three files in the app dir. Never invent a `type:` — use bare `stringData`.

`secret-generator.yaml`:
```yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: <app>-secret-generator
  annotations:
    config.kubernetes.io/function: |
      exec:
        path: ksops
files:
  - ./<app>-secret.sops.yaml
```

`kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
generators:
  - secret-generator.yaml
```

`<app>-secret.sops.yaml` — write the real values in **plaintext** first, then
**encrypt it yourself in place** (you have SOPS access now):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: <app>-secret
  namespace: <namespace>
stringData:
  API_KEY: <real-value>
```
```bash
sops --encrypt --in-place kubernetes/apps/<namespace>/<app>/<app>-secret.sops.yaml
```
`.sops.yaml`'s creation rules auto-match `kubernetes/**/*.sops.yaml` (age
recipient + `encrypted_regex: ^(data|stringData)$`), and `SOPS_AGE_KEY_FILE` is
already exported via mise — so no flags/keys needed. **Never commit the
plaintext**: encrypt before `git add`, and verify with
`grep -q ENC\\[ <file>` (or eyeball that `stringData` values show `ENC[...]`).
**NEVER commit or push the age PRIVATE key** (`age.key`, `*.agekey`, `*.key`) or
any decrypted key material — they're gitignored; keep it that way. Only the
public age *recipient* belongs in a tracked file (`.sops.yaml`).

Editing an existing secret: `sops <file>` opens the decrypted buffer, or
`sops set <file> '["stringData"]["KEY"]' '"value"'` for a one-shot change;
read a value with `sops decrypt <file>`. Re-encryption is automatic on save.

Wire it into the container with `envFrom: [{ secretRef: { name: <app>-secret } }]`
(a YAML anchor `&envFrom` / `*envFrom` lets an init-container reuse it — see
below). For non-secret config files use a kustomize `configMapGenerator`
(AGENTS.md → ConfigMaps).

## Phase 3 — Central Postgres (only if the app needs a DB)

Don't bundle a per-app Postgres. Provision a database on the central CNPG
cluster with a `postgres-init` init-container. Put the DB creds in the app's
ksops secret (`INIT_POSTGRES_*`), then reference the same secret from both the
init-container and the app. Model = `kubernetes/apps/lubelog/lubelog/`.

```yaml
controllers:
  <app>:
    annotations:
      reloader.stakater.com/auto: "true"
    initContainers:
      init-db:
        image:
          repository: ghcr.io/home-operations/postgres-init
          tag: 18.4
        envFrom: &envFrom
          - secretRef:
              name: <app>-secret
    containers:
      app:
        envFrom: *envFrom
        # ...
```

Secret keys the init-container consumes:
`INIT_POSTGRES_HOST` (=`postgres-17-cluster-rw.database.svc.cluster.local`),
`INIT_POSTGRES_DBNAME`, `INIT_POSTGRES_USER`, `INIT_POSTGRES_PASS`,
`INIT_POSTGRES_SUPER_PASS`. Add any app-specific connection string the app
itself reads (e.g. `POSTGRES_CONNECTION`) as another key in the same secret.

For redis, don't deploy one — point the app at
`valkey.valkey.svc.cluster.local:6379`.

## Phase 4 — Commit, push, verify

1. Sanity-check the YAML renders (`kustomize build kubernetes/apps/<ns>/<app>`
   if a kustomization.yaml exists; otherwise eyeball indentation).
2. Commit (conventional, e.g. `feat(<app>): add ...`) and **push straight to
   `main`** — that's the default here (single-user homelab, no PR/branch dance);
   pushing is what triggers the live deploy. Omit any Claude/co-author trailer.
3. Verify via MCP (the parent `apps` auto-syncs; nudge it if impatient):
   - `mcp__argocd-mcp__get_application` on `<app>` → `sync=Synced`,
     `health=Healthy`.
   - `kubectl get pods -n <namespace>` → running; if a DB init-container,
     confirm `init-db` completed (check logs on CrashLoop).
   - Hit the ingress host if applicable.
4. If it doesn't appear at all: the parent may not have reconciled — sync `apps`
   in `argo-system`, and re-check the file path is under
   `kubernetes/argo/apps/**`.

## Gotchas

- **Stale version in AGENTS.md.** It says app-template `4.6.2`; the repo is on
  `5.0.1`. Always grep the actual current version rather than copying a doc.
- **Chart repo.** `ghcr.io/bjw-s-labs/helm`, never `https://bjw-s.github.io/helm-charts/`.
- **`identifier` must match the service key** (both `app`), or the ingress 500s
  with no backend.
- **No TLS block** for `laboratory.casa` — cert-manager owns it. External apps
  add the `external-dns` target annotation + `className: external` instead.
- **No Flux-isms.** No `${TIMEZONE}` / `${VOLSYNC_CLAIM}` substitution, no
  `existingClaim` templating — use literal values.
- **Pin images** to an explicit version, digest too where possible
  (`tag: X.Y.Z@sha256:...`) — bare `latest`/moving tags break Renovate + rollbacks.
- **Right-size PVCs DOWN.** Longhorn by default; start small (128Mi is common),
  grow later. Expanding is easy, shrinking isn't — never over-provision "to be
  safe". Size by content: config = tiny, media/recordings = big (or NFS).
- **Unconsumed `ref:` panics the app-controller** — only include it when a
  second source references `$<app>-repo`.
- **Encrypt secrets before committing.** You have SOPS access
  (`sops --encrypt --in-place` on the `*.sops.yaml`); never `git add` a
  plaintext secret — verify `ENC[...]` first.
