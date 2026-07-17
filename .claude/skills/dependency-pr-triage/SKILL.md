---
name: dependency-pr-triage
description: >-
  Triage the open Renovate dependency-update PRs on this home-cluster repo. Use
  whenever the user wants to review, work through, clear out, or "do the
  renovate PRs" / "dependency PRs" / "update PRs" / "the weekend bumps" — even
  if they don't say "Renovate" by name. Groups minor+major bumps of the same
  dependency, hunts down changelogs, scans the repo (and the live cluster via
  the kubernetes MCP) for changes we'd need to make, sorts everything by
  danger/blast-radius, then walks the user through each one interactively so
  they decide what to merge, defer, or dig into, and confirms via the ArgoCD MCP
  that each merged bump actually synced and went healthy. Reach for this any time
  there's a pile of Renovate PRs to get through.
---

# Dependency PR Triage

Renovate opens a batch of dependency-update PRs against this repo every weekend
(see `.github/renovate.json5`: `schedule: ["every weekend"]`). This skill turns
that undifferentiated pile into an ordered, changelog-backed, impact-assessed
worklist and then merges the ones the user approves.

The goal is that the user makes a fast, informed decision on every PR — *this
one is a safe patch, merge it*; *this one is a major bump that touches config we
actually set, let's look closer*; *this one has a minor version also open, do
that one first* — without having to open twenty browser tabs and read twenty
changelogs themselves.

## Ground rules for this repo (read before acting)

This is a **GitOps** cluster. ArgoCD watches `main` and auto-syncs. That has two
consequences that shape everything below:

- **Merging a PR *is* the deploy.** There is no separate rollout step. When the
  user approves a PR and you merge it, it ships. Treat merges with the weight of
  a deploy, not the weight of a code review approval.
- **Never mutate the cluster directly.** No `kubectl apply`, `helm install`,
  `helm upgrade`, or edits to live resources. You **may** *read* the live
  cluster through the kubernetes MCP (`mcp__kubernetes-mcp-server__*`) to check
  what's actually running (step 4) and through the ArgoCD MCP
  (`mcp__argocd-mcp__*`) to confirm a merge synced and went healthy (step 7).
  Read-only, always — the ArgoCD MCP exposes write verbs (`sync_application`,
  `run_resource_action`, `update_application`, `delete_application`); those are
  off-limits, same as `kubectl apply`. ArgoCD auto-syncs `main` on its own; you
  never need to trigger a sync.

Renovate is the PR author. Filter with `--author "app/renovate"`.

## Workflow

Work the phases in order. Phases 1–4 are research and produce a briefing; phase
5 presents an up-front, PR-by-PR summary of *what changed* (features, fixes,
improvements worth knowing about); phase 6 is the interactive merge session where
you classify by danger and the user decides; phase 7 confirms each merge actually
deployed. Do all the research *before* talking the user through decisions — they
should never wait on a changelog fetch mid-conversation.

For any non-trivial batch (say 8+ PRs), the research in phases 2–4 is
per-PR and independent — fan it out with parallel subagents (one per PR or per
dependency group) rather than fetching serially. Give each subagent the PR
number and the instructions from the relevant phase, and have it return a
compact structured summary (package, versions, update type, changelog
highlights, repo files that reference it, impact verdict). Then you assemble the
briefing. This keeps the whole triage fast even when there are twenty PRs.

### 1. Enumerate and group the PRs

Pull every open Renovate PR with the metadata you need in one shot:

```bash
gh pr list --author "app/renovate" --state open --limit 100 \
  --json number,title,labels,headRefName,createdAt,isDraft
```

**Drop anything labeled `on-hold` before you do anything else with the list.**
The user applies `on-hold` to Renovate PRs they already know about but aren't
ready to work on yet — parking them deliberately. Filter these out at the source
so they never reach grouping, changelog research, the phase-5 summary, or the
phase-6 merge session; spending subagent time researching a PR the user has
already set aside is wasted work, and surfacing it invites a decision they've
told you they don't want to make right now. `gh` has no exclude-label flag, so
filter client-side on the `labels` array you just fetched (keep only PRs whose
labels don't include `on-hold`). Don't silently disappear them, though: once, up
front, note how many you skipped and why (e.g. "Skipping 2 on-hold PRs: #123
argo-cd, #145 cilium"), so the user can see their parked items were recognized
and correct you if one is actually ready. If, after this filter, there are no
PRs left to triage, say so and stop.

Read the **update type straight off the title/labels** — this repo's Renovate
config encodes it deterministically, so you don't have to guess from version
numbers:

| Signal in title | Labels | Update type |
|-|-|-|
| `feat(...)!:` (bang) | `type/major` | **major** — potentially breaking |
| `feat(...)` no bang | `type/minor` | **minor** — new features, usually compatible |
| `fix(...)` | `type/patch` | **patch** — bugfixes |
| `chore(...)` with short shas `( abc123 → def456 )` | — | **digest** — same version, new image digest |

`renovate/container`, `renovate/helm`, `renovate/github-release` labels tell you
the *manager* (what kind of dependency it is), which decides where to scan in
phase 3.

**Group PRs by dependency.** Renovate opens *separate* PRs when patch, minor,
and major are available for the same package (`:separatePatchReleases` +
`docker:enableMajor` in the config) — so a single dependency can have **two or
three** PRs open at once, all sharing the same `current` version. Detect groups
by matching on the package name in the title (e.g. argo-cd commonly has all
three open: `9.5.20 → 9.5.22`, `→ 9.7.1`, `→ 10.1.1`). When you find a group:

- The **lower bump is usually the safer stepping stone** — often the right move
  is to merge the minor now and let the major get re-based, or to skip the minor
  entirely and take the major. Surface the choice; don't silently pick.
- Never present them as unrelated PRs. The user needs to see "argo-cd has both a
  9.7.1 and a 10.1.1 open" as *one* decision.

### 2. Gather the changelog for every bump

The changelog is what makes the merge decision possible. Find the best source
available, in this order:

0. **Check for a breadcrumb comment first.** A previous run of this skill leaves
   a one-line `# changelog: ...` comment next to the version it had to chase down
   (see below). When you locate our usage in phase 3, if such a comment is there,
   follow it *first* — it tells you exactly where this project publishes its
   notes, saving the whole hunt. (You can grep ahead of time:
   `grep -rn "# changelog:" kubernetes/`.)
1. **PR body first.** Renovate embeds release notes inline. Fetch with
   `gh pr view <n> --json body` and look for the `### Release Notes` section —
   it contains collapsible `<details>` blocks with one entry per intervening
   version. This covers the large majority of PRs and needs no extra fetch.
2. **Upstream GitHub releases** when the body says *"Some dependencies could not
   be looked up"* or the release-notes section is thin/absent. The package links
   in the body point at the source repo (e.g. `argoproj/argo-helm`). Pull the
   releases between the two versions — `gh release view` / the releases API, or
   `mcp__git-grep__searchGitHub` to read the repo's release/changelog files.
3. **Commit diff as last resort.** Some projects publish no release notes. Read
   the commit messages between the two version tags
   (`https://github.com/OWNER/REPO/compare/vOLD...vNEW`, or `gh api` the compare
   endpoint) and summarize what actually changed.

For a **grouped** dependency, get the changelog spanning the *whole* range up to
the major, so the user sees everything they'd be adopting if they jump straight
to it.

**Leave a breadcrumb when the PR body wasn't enough.** Any time you had to go
past step 1 — i.e. the changelog came from upstream releases (source 2) or the
commit diff (source 3) — record *where you found it* with a one-line comment on
the line directly above the version Renovate updates, in the repo file from
phase 3. This is memoization: the next run reads it and skips straight to the
right source instead of re-discovering it. Keep it to one line and describe the
*process*, e.g.:

```yaml
# changelog: github releases at getsops/sops (not in PR body)
tag: 3.13.2@sha256:...
```
```yaml
# changelog: no releases published — read commit diff at github.com/OWNER/REPO/compare
tag: 1.9.0@sha256:...
```

Put it on the line above so Renovate preserves it across future bumps (it only
rewrites the version, not the comment). This edit is a normal repo change — add
it alongside any other change the PR needs, and let the user commit it per their
workflow. If a `# changelog:` comment is already there and still accurate, leave
it; refresh it only if the project moved where it publishes notes.

Distil each changelog along **two** lenses — you're reading it anyway, so
capture both:

1. **Impact on us** (drives the merge decision in phase 6): breaking changes,
   removed or renamed config options, new required settings, changed defaults,
   deprecations, and DB/schema migrations.
2. **What's new that the user might actually want** (drives the summary in phase
   5): notable new features, improvements, and bug fixes — especially anything
   that lines up with how the user runs this cluster (a new config knob for an
   app we deploy, a fixed bug we've hit, a performance/UX win, a new integration
   worth turning on). Don't editorialize every line item — surface the two or
   three things a user would be glad to know shipped, and say plainly when a bump
   is purely internal ("no user-facing changes").

Skip the noise for both lenses (dependency bumps inside the upstream project, CI
changes, typo fixes).

### 3. Scan our repo for required changes

For each bump, find where we actually use the thing and whether the changelog's
breaking items touch our config. This is the step that separates "safe" from
"needs work."

Locate our usage — the package name from the PR maps to files under
`kubernetes/`:

```bash
# The image repo / chart name in the PR title is the search key
grep -rn "<image-repo-or-chart-name>" kubernetes/
```

- **Container images** → `kubernetes/apps/<ns>/<app>/values.yaml` (the
  `image.repository`/`tag`), sometimes `helmfile.yaml` or bootstrap.
- **Helm charts** → the `targetRevision` in `kubernetes/argo/apps/<ns>/<app>.yaml`
  and the chart's values in the app's `values.yaml`.
- **github-release** tools (talos, sops, helmfile, talhelper) → `helmfile.yaml`,
  `kubernetes/bootstrap/`, and CI/workflow files.

Then ask: *does anything in the changelog's breaking/changed list correspond to
a key we actually set?* A renamed Helm value only matters if our `values.yaml`
sets the old name. A changed default only matters if we relied on the old
default. A required new env var always matters. Cross-reference the changelog
against the real file contents — don't assume.

See `references/repo-map.md` for the full dependency-kind → file-location map and
the repo's conventions (image pinning, app-template structure, central Postgres
& Valkey) so you can judge impact accurately.

### 4. Check the live cluster when it changes the answer

Sometimes the repo alone can't tell you whether a bump is safe — you need to
know what's actually running or how a resource is currently configured. Use the
kubernetes MCP (read-only) for these, e.g.:

- A CRD-bearing chart (prometheus-operator-crds, cert-manager, cloudnative-pg):
  check installed CRD versions / whether a new API version is served before a
  major that drops an old one — `mcp__kubernetes-mcp-server__resources_list`.
- A DB or stateful app major: check the running version and health before
  adopting a bump that implies a data migration —
  `mcp__kubernetes-mcp-server__pods_list_in_namespace`, `..._pods_log`.
- Anything where "is this even deployed / healthy right now" changes whether the
  user wants to touch it this weekend.

Don't reflexively hit the cluster for every PR — only when it materially changes
the recommendation. A digest bump of a leaf app never needs it.

### 5. Present the change summary up front (PR by PR)

You went to the trouble of chasing down every changelog — so before any
merge-or-defer talk, give the user the payoff: a **complete, PR-by-PR summary of
what actually changed.** This is a *what shipped* readout, not a *should we merge
it* readout — that comes next, in phase 6. Keep the two separate so the user gets
the interesting part (new capabilities they can now turn on) without it being
buried under risk classification.

Present it as a walk through **every** PR/group, in a sensible reading order
(group members together; roughly most-interesting or most-substantial first is
fine — danger ordering is phase 6's job, not this one's). For each PR give:

- package, `current → new`, update type
- **What changed** — 2–4 bullets from the "what's new" lens in phase 2: the
  notable new features, improvements, and bug fixes. Call out explicitly
  anything that could be **useful to the user** given how they run this cluster
  (a new setting for an app we deploy, a bug we've plausibly hit, a UX/perf win,
  a new integration worth enabling). Prefix those with **💡** so they're easy to
  spot.
- If a bump is purely internal, say so in one line ("digest refresh, no
  user-facing changes") rather than padding it.

Keep each PR's entry tight — this is a scannable digest of twenty changelogs, not
twenty full changelogs. The point is that the user learns everything worth
knowing that shipped this week in one pass, *then* moves into the merge
decisions with that context already in hand.

### 6. Classify by danger, then triage interactively

Rank every PR (and group) into impact tiers. Impact is **semver × blast
radius** — a *minor* bump of cluster-wide infra can be riskier than a *major*
bump of a single leaf app.

- **✅ Safe** — digests and patches of leaf apps; minors with empty/cosmetic
  changelogs and no config overlap. Candidates for batch-merge.
- **⚠️ Review** — minors of infra, majors of leaf apps, anything whose changelog
  has breaking items that *don't* touch our config, anything with an open
  grouped alternative.
- **🛑 Careful** — majors of platform/infra (argocd, cert-manager,
  cloudnative-pg / database, cilium & network, longhorn/openebs storage,
  victoria-metrics/prometheus observability, talos, sops), anything needing a
  repo change before it's mergeable, anything with a DB/schema migration. See
  `references/repo-map.md` for which components are platform-critical.

Now that the user has the full change summary from phase 5, this phase is about
*safety and decisions*. Present it tightest-first: lead with a one-line-per-PR
overview grouped by tier, flag every grouped dependency explicitly, then go
**one PR (or group) at a time**, giving for each:

- package, `current → new`, update type, tier
- the changelog distilled to **what affects us** (the impact lens — breaking
  changes, config overlap, migrations; 2–4 bullets, not a wall). Don't re-narrate
  the feature list from phase 5 — reference it briefly and focus here on risk.
- **whether we need a repo change** and if so exactly what
- your recommendation (merge / merge-the-minor-first / defer / needs-work) with
  the reason

Then let the user decide. They drive — you're surfacing the decision, not making
it for them. Support at least these outcomes:

- **Merge it** → `gh pr merge <n> --squash`. This repo squash-merges Renovate
  PRs (preserves the semantic-commit title with the PR number) and auto-deletes
  the branch. Merging ships it via ArgoCD — confirm before merging anything 🛑.
  After merging, verify the deploy actually landed — see step 7. Watch closely
  for anything ⚠️/🛑 or with a schema migration; a quick spot-check is enough for
  the ✅ batch.
  - A merge can fail on a **conflict** (`Pull Request has merge conflicts`),
    typically when two PRs in the same batch touch one file (e.g. two
    github-release tools both editing `.mise.toml`). That's not a cluster
    problem — the PR just needs a rebase. Renovate auto-rebases conflicted PRs on
    its next run, so leave it open and note it; don't hand-resolve unless asked.
- **Needs work** → note what has to change first (a `values.yaml` edit for a
  renamed key, etc.). Offer to make that edit as a normal repo change (edit,
  don't touch the cluster); the user commits/pushes per their workflow.
- **Skip/defer** → leave it open, move on. If a grouped minor is being merged as
  a stepping stone, say that Renovate will rebase or re-open the major next run.
- **Close** → only if the user explicitly wants it gone.

Batch-merging several ✅ PRs at once is fine when the user says so — do it in one
go and report back.

### 7. Verify the deploy landed (post-merge, via the ArgoCD MCP)

A merge is only half the story — in GitOps the deploy happens *after*, when
ArgoCD syncs `main`. Merging then walking away means you never learn whether the
bump actually rolled out or wedged the app. Close that loop with the ArgoCD MCP
(`mcp__argocd-mcp__*`, read-only). It's the authoritative view of what GitOps
did with your merge, and it's more direct than eyeballing pods through the k8s
MCP — it tells you sync state *and* health in one place.

Timing: ArgoCD auto-syncs `main` on its own (default poll ~3 min, faster if a
webhook is wired), so the sync won't be instant. Merge the batch, then give it a
moment before checking — or check, see `OutOfSync`/`Progressing`, and look again
shortly rather than concluding it failed.

What to look at:

- **Find the app** — `mcp__argocd-mcp__list_applications`. The app name maps from
  the repo path (`kubernetes/argo/apps/<ns>/<app>.yaml`), e.g. the argo-cd bump
  is the `argo-cd` Application. For a self-managed component (argo-cd itself),
  it manages its own Application — the sync still shows up here.
- **Confirm it synced to your merge** — `mcp__argocd-mcp__get_application` for the
  app. Success = `sync.status: Synced` **at the revision of your merge commit**
  (check the synced revision matches, not just that it says Synced — it may still
  be showing the *previous* synced revision if the poll hasn't fired yet) **and**
  `health.status: Healthy`. `Progressing` right after a merge is normal — a
  rollout in flight; recheck. `Degraded`, `OutOfSync` that won't clear, or a
  `SyncFailed` is the signal to dig in.
- **When it's not healthy** — `mcp__argocd-mcp__get_application_resource_tree`
  (which resource is unhealthy) and `mcp__argocd-mcp__get_application_events` /
  `mcp__argocd-mcp__get_application_workload_logs` (why). For a suspected image
  problem or a stateful app running its startup migration (the immich/DB case),
  cross-check the pod directly with the k8s MCP
  (`mcp__kubernetes-mcp-server__pods_log`) — ArgoCD can report `Healthy` while an
  app crashloops *after* a migration, so for anything with a schema migration
  confirm at the pod, not just the sync status.

Scope the check to the risk: for a big ✅ batch, spot-check that ArgoCD is
overall `Synced`/`Healthy` and that the couple of infra bumps landed — you don't
need to open all eleven. For anything ⚠️/🛑, or with a DB/schema migration, watch
that specific app through to `Healthy` and confirm at the pod. If a sync goes
`Degraded` or `SyncFailed`, surface it immediately with the app name and the
failing resource — a merged-but-broken deploy is exactly the outcome the user
needs to hear about, and the fix is a follow-up commit (a revert or a values
edit), **never** a live-cluster mutation or an MCP sync/rollback verb.

Setup note: the ArgoCD MCP authenticates as the `mcp` local account
(`role:admin`) with a token in the shell env — if the MCP tools error on auth,
that token/config is the thing to check, and it's fine to tell the user the
verification step is unavailable rather than falling back to guesswork.

## Style

Terse, decision-oriented. The user is an expert running their own cluster; they
want signal (what changed, does it touch us, what do you recommend), not a
tutorial on semver. Never merge anything without an explicit go, and always
treat a merge as a live deploy because it is.
