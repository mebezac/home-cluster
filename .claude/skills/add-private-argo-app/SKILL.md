---
name: add-private-argo-app
description: >-
  Add a NEW application to the PRIVATE sibling repo `../home-cluster-private`
  (not this public repo) as an ArgoCD Application using the bjw-s app-template
  chart. Use whenever the user wants to add / deploy / stand up / onboard an app
  "privately", "in the private repo", "in home-cluster-private", "somewhere it
  won't be public", or names an app they don't want advertised in the public
  home-cluster repo. Runs the exact
  same workflow as `add-argo-app` — subagent deep-read of the upstream docs,
  AskUserQuestion for optional add-ons, values.yaml + Argo Application + ksops
  secrets (encrypted with sops yourself), house patterns, tag@sha256 pins,
  GitOps commit+push, MCP verification — but every file, commit, and push goes
  to `../home-cluster-private`, wired in via the `private-apps` app-of-apps, and
  nothing about the app may leak into the public repo.
---

# Add a new PRIVATE ArgoCD app (home-cluster-private)

This is `add-argo-app` pointed at a different repo. **Read
`.claude/skills/add-argo-app/SKILL.md` now and follow every phase of it**
(escalation ladder → Phase 0a subagent deep-read → 0a.1 AskUserQuestion → 0b
decisions → 1 scaffold → 2 secrets → 3 central Postgres → 4 commit/push/verify)
— with the overrides below. Where this file and `add-argo-app` disagree, this
file wins. Where neither covers something, `AGENTS.md` in *this* (public) repo is
still the values.yaml cookbook — the two repos share value conventions.

**Standing permission:** the user has granted this skill — on every run — read
and write access to `/Users/zac/projects/lab_casa/home-cluster-private` (also
registered as an additional working directory in `.claude/settings.local.json`).
No need to ask before reading, editing, committing, or pushing there.

## The two-repo topology (why this works)

```
lab_casa/
├── home-cluster/            ← PUBLIC (you are here). Owns the cluster + the parent:
│   └── kubernetes/argo/apps/private-apps/private-apps.yaml
│         app `private-apps` → repoURL home-cluster-private.git, path kubernetes/argo/apps,
│         directory.recurse: true, automated prune+selfHeal
└── home-cluster-private/    ← PRIVATE. App values + Argo Applications ONLY
    └── kubernetes/
        ├── apps/<ns>/<app>/            values.yaml, kustomization, secrets
        └── argo/apps/<ns>/<app>.yaml   Argo Application
```

Dropping an `Application` file under `home-cluster-private/kubernetes/argo/apps/**`
and pushing is all it takes — `private-apps` picks it up. **Do not edit
`private-apps.yaml`** to add an app.

In every command below, `P=/Users/zac/projects/lab_casa/home-cluster-private`.
The Bash cwd resets to home-cluster between calls, so use absolute paths,
`git -C "$P"`, or `cd "$P" && …` in the same command.

## Overrides to add-argo-app

### Preflight (before Phase 0a)

```bash
P=/Users/zac/projects/lab_casa/home-cluster-private
git -C "$P" status -sb && git -C "$P" pull --ff-only
```
Renovate merges into the private repo constantly; start from a fresh `main`.
If the tree is dirty, stop and tell the user rather than committing over their
work. Read `$P/AGENTS.md` and `ls $P/kubernetes/apps/*/` to see what's there.

### Escalation ladder, rung 1

Search **both** repos: `grep -rl "<thing>" "$P/kubernetes/apps/" kubernetes/apps/`.
The private repo is small (all apps currently in `downloads`); this public repo
has the larger set of patterns. Older private apps use the
`controllers.main` / per-container `securityContext` shape and some omit digests —
**scaffold from add-argo-app's template, not by copying those.**

### Repo facts (replace add-argo-app's table where they differ)

| Fact | Value |
|-|-|
| Repo root | `$P` = `/Users/zac/projects/lab_casa/home-cluster-private` |
| App dir | `$P/kubernetes/apps/<namespace>/<app>/` |
| Argo Application | `$P/kubernetes/argo/apps/<namespace>/<app>.yaml` |
| Git repoURL (Argo source) | `https://github.com/mebezac/home-cluster-private.git` |
| app-template version | match the repo: `grep -rh 'chart: app-template' -A1 "$P/kubernetes/argo/apps/"` (both repos on 5.2.1 at last check — never trust a number in a doc) |
| Argo namespace / project | `argo-system` / `kubernetes` (same as public) |
| App-of-apps parent | `private-apps` (lives in THIS repo, see above) |
| SOPS | `$P/.sops.yaml` — same age recipient + `encrypted_regex: ^(data\|stringData)$` as public; `$P/age.key` is the same key |
| Shared PVCs (namespace `downloads` only) | download staging + NAS media claims — list them with `grep -rh 'existingClaim' "$P/kubernetes/apps" \| sort -u` (names deliberately not written here) |

Central Postgres / postgres-init / valkey / run-as 3000 / domain are identical to
add-argo-app's table.

### Phase 0b — decisions

1. **Namespace.** `downloads` if the app belongs with the download stack (needs
   the shared PVCs or talks to the existing download apps by in-namespace
   service name). Otherwise its own namespace = app name. PVCs are namespaced — the
   shared claims above are only mountable from `downloads`.
4. **Route.** Every private route today is on `envoy-internal` **plus
   Authelia forward-auth** (the `auth: authelia` label). Default to that unless
   the app does its own OIDC login (then ask). HTTPRoutes only — no `ingress:`
   block, no nginx annotations:
   ```yaml
   route:
     app:
       labels:
         auth: authelia
       hostnames:
         - <subdomain>.laboratory.casa
       parentRefs:
         - name: envoy-internal
           namespace: network
           sectionName: https
       rules:
         - backendRefs:
             - identifier: app
               port: http
   ```
   The label only takes effect where an `authelia` SecurityPolicy exists in the
   route's namespace. `downloads` has one (`$P/kubernetes/apps/downloads/gateway/authelia.yaml`,
   Argo app `downloads-gateway`). A **new private namespace** needs its own copy
   of that file AND an entry in the PUBLIC repo's
   `kubernetes/apps/security/authelia/referencegrant.yaml` (else the route fails
   closed with 500) — that public edit exposes the namespace name, so ask first
   (see the privacy guardrail).
   Apps that support trusting a reverse-proxy auth header (an "External" /
   "header" auth mode) should be set to use it. Prefer a terse/non-obvious
   subdomain if the app name itself is something the user wouldn't want in DNS
   (existing private apps do this — check their hosts).
   Never `external` without asking.
5. **Persistence.** Same Longhorn right-size-down rule. For downloads/media, mount
   the shared claims with `existingClaim:` rather than creating new bulk storage.

### Phase 1 — scaffold

Write both files under `$P`, using add-argo-app's templates verbatim except the
Argo Application's repo source:

```yaml
    - repoURL: https://github.com/mebezac/home-cluster-private.git
      path: kubernetes/apps/<namespace>/<app>
      targetRevision: main
      ref: <app>-repo
```
(and `targetRevision` of the chart = the grepped version). Same `ref:` rule — only
with a consuming `$<app>-repo/...` valueFiles entry.

### Phase 2 — secrets: encrypt yourself, from INSIDE the private repo

Same three files and same rule as add-argo-app (write plaintext, encrypt in
place, verify, *then* `git add`). The only difference is where sops runs — sops
picks its `.sops.yaml` by walking up from the **cwd**, so run it from `$P`:

```bash
cd /Users/zac/projects/lab_casa/home-cluster-private && \
  sops --encrypt --in-place kubernetes/apps/<ns>/<app>/<app>-secret.sops.yaml && \
  grep -q 'ENC\[' kubernetes/apps/<ns>/<app>/<app>-secret.sops.yaml && echo ENCRYPTED
```
Decrypt/edit likewise from `$P` (`SOPS_AGE_KEY_FILE` points at `$P/age.key` under
that repo's mise env; the public repo's key is identical if mise didn't load).
The private repo's `CLAUDE.md`/`AGENTS.md` once said "never encrypt, leave
plaintext" — that rule is **retired**; the user chose self-encryption for this
skill (2026-10-01).

Never `git add` `age.key`, `admin.key`, `ca.key`, or the `.decrypted~*` files
that sit in that tree (gitignored — keep it that way).

### Phase 4 — commit, push, verify

1. Render-check: `kustomize build "$P/kubernetes/apps/<ns>/<app>"` if there's a
   kustomization.
2. Stage **explicit paths only** — never `git add -A` in `$P`:
   ```bash
   git -C "$P" add kubernetes/apps/<ns>/<app> kubernetes/argo/apps/<ns>/<app>.yaml
   git -C "$P" diff --cached --stat     # eyeball: no keys, no plaintext secrets
   git -C "$P" commit -m "feat(<app>): add <app>"
   git -C "$P" push origin main
   ```
   Push straight to `main`, no attribution trailer (same as public). Auth is the
   same `gh-pat` HTTPS credential helper as the public repo.
3. Verify via MCP: `private-apps` should pick it up within its poll; if not,
   `mcp__argocd-mcp__sync_application` on **`private-apps`** (not `apps`). Then
   `get_application <app>` → Synced/Healthy, pods running in `<ns>`, init-db
   completed, route hostname responds (expect an Authelia redirect, i.e. 302 to
   `login.laboratory.casa`, if forward-auth is on).

## Privacy guardrail — nothing leaks into the public repo

This repo (`home-cluster`) is **public**. During and after this skill:
- Make **no** commits in `home-cluster`. If the app truly needs a shared or
  cluster-scoped resource defined there, stop and ask first, and keep the
  private app's name out of that change.
- Don't name the private app, its hostname, or its secrets in any file tracked
  here (CLAUDE.md, AGENTS.md, skills, docs). Local auto-memory is fine.
- Before finishing, run `git status` here and confirm it's clean.
