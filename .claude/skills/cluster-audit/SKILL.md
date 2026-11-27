---
name: cluster-audit
description: >-
  Run a full-cluster health audit of EVERY deployed workload in this home-cluster
  and publish the findings as a plain-English HTML report. Use whenever the user
  wants a sweeping review rather than one specific problem: "audit the cluster",
  "full cluster audit", "check everything", "what's wrong with my cluster",
  "review all my workloads", "health check the whole thing", "find anything
  amiss", or asks for logs/resources/best-practices to be reviewed across all
  apps at once. Fans the work out across parallel domain subagents (networking,
  storage, database, observability, security/GitOps, media, home automation, web
  apps, platform/capacity), each reading pod logs, comparing live resource usage
  against requests/limits, and checking config against BOTH this repo's CLAUDE.md
  rules and current upstream best practice via context7/web/git-grep, and
  flagging superseded apps, forks, settings, procedures and infrastructure with
  evidence-backed successors, searching job-level alternatives for every app
  (Tavily, kubesearch peer counts, a survey of popular home-ops repos) (also
  triggers on "what's outdated", "anything better than what we run"). The parent
  runs the cross-cutting sweeps subagents cannot see (image pinning, SOPS
  hygiene, deprecated APIs), sizes resources from 7 DAYS of VictoriaMetrics
  history rather than a point-in-time snapshot, starts from the previous audit's
  report (listed in audits.md) as a baseline without limiting itself to it, then
  publishes a new ASD-STE100 Simplified Technical English report as an Artifact,
  logs it in audits.md, and works the fixes interactively — only ever with
  explicit per-item permission, updating the report after each decisive action. Reach for this for
  periodic health reviews, before/after a big migration, or when something feels
  off but nothing is alerting.
---

# Full-cluster audit

Sweeping review of every workload: logs, resources, best practice. Ends with a
published HTML report the user works through with you. **Find and report first;
change nothing until they say so, item by item.**

Sister skills: `debug-alerts` (one firing alert), `dependency-pr-triage`
(Renovate PRs), `talos-upgrade` (node layer). This one is the wide sweep.

## The shape

0. Parent reads the last audit's report as a baseline
1. Parent takes inventory (cheap, keeps context clean)
2. Parent fans out ~10 subagents (9 domain slices + 1 successor slice) **in one
   message** so they run in parallel
3. Parent runs the cross-cutting sweeps subagents structurally cannot do
4. Parent publishes the report as a NEW Artifact and logs it in `audits.md`
5. Fix loop — one item at a time, explicit permission each time; the Artifact
   is updated after every decisive action

---

## 0. Baseline — read the last audit first, then look past it

[`audits.md`](audits.md) (next to this file) lists every past report, newest
first. Before inventory, read the newest one with the `Artifact` tool
(`action: "read"`, `url: <link>`). If the user pastes a link, use that.

From it, extract:

- every item **not** marked done (open "fix now", "fix soon", resource rows,
  clean-up, hygiene). Each one goes into the brief of the slice that owns it,
  as "re-check: still true?". The new report marks each as carried, closed or
  changed — say which.
- items marked done: spot-check the important ones. A fix can regress
  (e.g. a scrape selector reverted by a chart bump).
- its Successors table: carry every _watch_ item as "re-check", and every
  _keep_ verdict with its reason, so the next run re-opens it only on a new
  signal (§4).
- its HTML: the new report reuses the same visual system (see §6).

**The baseline is a checklist, not the scope.** Do the full deep-dive anyway.
Every brief must say "find what the last audit missed". The 2026-10-21 run found
its most important item (a control-plane node that stalled when it ran out of
memory, caused by unused hugepages) because the platform auditor dug past the
carried "hugepages" line. Last time that line was ranked low, as a memory-saving
nicety. Re-rank carried items on new evidence, never on their old position.

Also read `git log --since=<last audit date>` for both repos. Changes since the
baseline (major bumps, new apps, new namespaces) are where new defects hide.

## 1. Inventory (parent, before any subagent)

```bash
kubectl get ns --no-headers; kubectl get nodes -o wide
kubectl get applications -n argo-system \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' --no-headers | sort
S=<scratchpad>
kubectl get pods -A -o wide > $S/pods.txt
kubectl get pods -A -o json > $S/pods.json
kubectl top pods -A --containers --no-headers > $S/top-pods.txt
kubectl get pvc -A --no-headers > $S/pvcs.txt
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -40
```

Derive a `resources.txt` (ns / owner / container / requests / limits) from
`pods.json` — subagents join it against `top-pods.txt`.

**Argo `Healthy` is not proof.** In the last run every app read Synced/Healthy
while a garage pod was in `BackOff`. Always cross-check pod phase and Warning
events against the Argo view; say so in the subagent briefs.

Note `Unknown` sync states — they usually mean a repo credential died and those
apps have silently stopped reconciling.

## 2. Fan out (one message, all agents)

Nine domain slices, one successor slice for the shared layer, and the
alternatives wave of §4 (one researcher per job group plus one peer survey).
Adjust to what actually exists, but keep them disjoint and name the
namespaces explicitly so nothing is audited twice or missed:

| Slice | Covers |
|---|---|
| Networking | `network`, `network-optimizer`, `cilium-secrets`, + cilium/coredns/k8s-gateway/spegel in kube-system |
| Storage | `longhorn-system`, `storage` |
| Database | `database`, `valkey` |
| Observability | `observability` + metrics-server — **and list every firing/pending alert** (vmalert `/api/v1/alerts`) |
| Security/GitOps | `security`, `cert-manager`, `argo-system`, `forgejo` |
| Media | `jellyfin`, `immich`, `audiobookshelf`, `calibre-web-automated`, `romm`, `music-assistant`, `lychee`, `downloads`, `gluetun-proxy`, `ps5` (private) |
| Home automation | `homeassistant`, `birdnet-go` |
| Web apps | `n8n`, `umami`, `jotty`, `lubelog`, `changedetection`, `trek`, `reckage`, `heremag`, `owncloud`, `pcab`, `default` |
| Platform/capacity | rest of kube-system + **cluster-wide node capacity** (per-node MemAvailable 7d minimum, not just requests) |
| Successors (shared layer) | no namespace: the infrastructure and procedure layers of §4 — Talos/topf, Cilium, Longhorn, CNPG, Envoy Gateway, ArgoCD, VictoriaMetrics, cert-manager, external-dns, cloudflared, Kopiur, sops/ksops, Renovate, mise, plus `.claude/skills/`, `AGENTS.md` and `CLAUDE.md` procedures |
| Alternatives ×4–5 | §4 "Alternatives": every app, grouped by job (media and downloads; home automation and IoT; productivity and web apps; network, storage and data; observability, GitOps and node) |
| Peer survey | §4 "Peer survey": the ~12 most-starred home-ops repos against ours, by job |

The namespace list drifts. Diff `kubectl get ns` against this table at inventory
time and put any new namespace in a slice.

Every brief must include:

- the scratchpad paths and "read these, don't recollect"
- **logs**: `kubectl logs -n <ns> <pod> --all-containers --since=24h --tail=400 | grep -iE 'error|warn|fail|fatal|panic|deprecat|refused|timeout|denied|unable|cannot|invalid' | sort | uniq -c | sort -rn | head -30`, plus `--previous` for anything restarted
- **judge each hit** — real problem or expected noise; report only real ones with the exact line and how often it repeats
- **resources**: compare `resources.txt` against `top-pods.txt`
- **best practice, both halves**: (a) this repo's CLAUDE.md rules — images pinned `tag@sha256`, never `latest`; `laboratory.casa` + `internal`/`external`; runAs 3000; `stringData` with no `type:`; `ghcr.io/bjw-s-labs/helm`; single-source Argo app must not carry an unconsumed `ref:`; central PG + central valkey. (b) upstream current practice via `mcp__context7__query-docs`, `mcp__git-grep__searchGitHub`, web search
- **move to git**: list app settings that live only in the app's UI, database or
  volume (e.g. HA `.storage/*`, Jellyfin `network.xml`, Z-Wave JS UI
  `settings.json`, *arr settings in their SQLite, Grafana dashboards in its
  DB) and say for each whether git can own it: an env var (`<APP>__SECTION__KEY`
  for the *arr apps), a config file from a ConfigMap or sops secret, a provisioning
  mechanism (Grafana), or an init container that sets just those keys at
  start. Read-only: look at the files with `kubectl exec … cat`, never edit
  them. Check upstream docs before you claim an option exists. Skip settings
  that the app rewrites at runtime, or that are only runtime state.
- **successors**: paste §4's layer table, signals and verdicts into the brief.
  For every app, chart and image source in the slice, check upstream status
  and check the settings in its values against current docs and the release
  notes since our version. The search for alternatives that do the same job
  belongs to the alternatives researchers, not to the domain slices. Return one line per finding:
  `current → candidate | signal (link, date) | gain | cost | verdict`, keeps included.
- **return findings as text, not a file** — subagents are blocked from writing report files; ask for a ~1000-word structured summary (Critical / Warning / Resources / Best practice / Successors / Healthy)
- "Every finding needs concrete evidence (log line, number, file:line). **Do NOT change anything.**"

### Do not trust subagent numbers blindly

They get rates and aggregates wrong. Last run one reported oCIS token errors at
"12/day"; the real figure was **293/24h**. Another said generic-device-plugin
published no versioned tags — it publishes `0.1.0` and `0.2.0`, just past the
first page of a 256-tag list. **Re-derive any number you are about to put in the
report or act on.**

When two subagents explain one event differently, build the timeline yourself.
On 2026-10-21 one blamed a Cilium rollout for a burst of restarts. Per-node
`node_memory_MemAvailable_bytes` at 2.5-min steps showed that the rollout ended
16 min earlier and that one node fell to 212 Mi at the time of the restarts.
Also check a subagent's "everything is pinned" claim against the live pod specs.
Pod-spec image strings are the ground truth.

## 3. Cross-cutting sweeps (parent only — subagents can't see across slices)

```bash
# images with neither tag@sha256 NOR a separate digest: field
# (a tag-only grep FALSELY flags charts that use `digest:` — e.g. forgejo-runner)
# deprecated apiVersions
grep -rEn 'apiVersion: (extensions/v1beta1|apps/v1beta|networking.k8s.io/v1beta1|policy/v1beta1|batch/v1beta1|autoscaling/v2beta|rbac.authorization.k8s.io/v1beta1)' kubernetes/
# secret hygiene
for f in $(git ls-files 'kubernetes/**/*.sops.yaml'); do grep -q 'ENC\[' "$f" || echo "PLAINTEXT: $f"; done
git ls-files | grep -iE '\.(key|agekey)$'     # must be empty
grep -rn 'type: Opaque' kubernetes/
```

`.sops.yaml` at the repo root matches `*.sops.yaml` but is the **config file**,
not a secret — expect it as a false positive.

**Renovate blind spots.** Classify every image tag by whether Renovate can read
it as a version. Date tags (`2025-04-04`), floating names (`stable`, `latest`,
`native-app`) and compound tags (`18-vectorchord0.5.3-pgvector0.8.1`) are
invisible to it — that is how lldap sat 13 months stale while everything else
stayed current. Prefer switching to a real version stream over adding a
`versioning:` regex; a regex has to be maintained against upstream.

## 4. Successors — find what the world has moved past

Logs and resources show what is broken now. This sweep finds what is
_superseded_: an app, chart, setting, procedure or piece of infrastructure that
upstream or the wider homelab ecosystem has moved past. Example: pinchflat may
have a community fork that is more active than the original. The repo has made
this move well before: ingress-nginx → Envoy Gateway, talhelper → topf, Longhorn
backups → Kopiur, Garage → SILO. Each audit finds the next one before it is
urgent.

The domain slices cover the app, chart and setting layers for their own
namespaces. The successor slice covers infrastructure and procedures.

| Layer | The question |
|---|---|
| App | Is the project archived, in maintenance mode, relicensed, or overtaken by a fork? Did a successor take its niche? |
| Chart / image source | Did the chart or image move, get deprecated in favour of an operator, or stop being free? Does upstream now ship an official chart or image we could use? |
| Setting | Does our config use a flag, env var or CRD field that upstream marks deprecated or replaced? Is a value we override now upstream's default? |
| Procedure | Does a skill, script or runbook here do by hand what a tool, controller or CRD now does? |
| Infrastructure | Which new features of the tools we run do we not use yet? Which rivals did peers move to, and why? |

### Signals: evidence, not hype

A finding needs at least one hard signal, with a link and a date:

- an upstream archive banner, deprecation or end-of-life notice, or migration guide
- a deprecation warning in our own logs or in `helm template` output
- no release or commit in 12 months, or security advisories with no fix
- a licence change that affects us
- a fork with clearly more recent releases, commits and maintainers than the
  original — compare both repos with `gh api repos/<owner>/<repo>` and their
  release lists, not the fork's README
- peer adoption: [kubesearch.dev](https://kubesearch.dev) and
  `mcp__git-grep__searchGitHub` over home-ops repos. Count who moved from X to Y,
  and when. A count is evidence; one blog post is not.

"New hotness" with no hard signal is a _watch_ item at most. For every finding,
name what the switch gains for THIS cluster (a defect it removes, an alert it
silences, a manual step it deletes, memory it frees) and what it costs (data
migration, downtime, new failure modes, re-learning).

Open the cited link yourself before a _migrate_ verdict goes into the report.
Subagents misread release pages and fork activity the same way they misread
rates (§2).

### Verdicts

- **migrate**: upstream is dead, deprecated or unsafe. It goes in Fix soon, or
  Fix now when a security advisory or an end-of-life date is close.
- **evaluate**: a real gain is on the table; worth a trial.
- **watch**: promising but young (under a year, one maintainer, no peer
  adoption). Re-check next audit.
- **keep**: checked, and the current choice is still right. Record the reason so
  the next audit starts from it, not from zero.

A migration is a project, not a fix. In the fix loop, offer a plan built on
`add-argo-app` and `remove-argo-app` instead of editing values in place.

### Alternatives — search by job, for every app

A liveness check ("is the project archived?") is not enough. The 2026-11-26
first pass checked every app for liveness and still missed two things the user
knew about: `TheBadFella/Pinchflat-NGX`, a fork that may succeed pinchflat, and
EMQX, which some peers run instead of mosquitto. A second pass with the method
below was needed. Run it in the first fan-out, not as a repair.

Give each researcher [`successor-brief.md`](successor-brief.md) (fill in
`<scratchpad>`) and one job group of apps. Per app it must:

1. **Name the job, not the product** ("MQTT broker for zigbee2mqtt and HA").
2. **Search for alternatives that do that job** with the Tavily connector
   (`mcp__claude_ai_Tavily__tavily_search`; Exa as the fallback): at least two
   queries, such as `"<app> alternative self-hosted <year>"`, `"<app> fork"`,
   `"best self-hosted <job> <year>"`, and an r/selfhosted query.
3. **Count peer adoption on kubesearch.** The kubesearch MCP server
   (`https://beta.kubesearch.dev/mcp`, in `.mcp.json` as `kubesearch`) indexes
   about 305 home-ops repos. Where a session or subagent does not have its tools,
   [`kubesearch.sh`](kubesearch.sh) calls the same server with curl:
   `search_images` (repos per image), `search_releases` (repos per chart),
   `repo_grep_all` (the 10 most-starred repos), `grep_values`, and
   `repo_clone` + `repo_list_files` to read one repo. Sum `repo_count` over
   every registry name of one product: mosquitto appears as
   `public.ecr.aws/docker/library/eclipse-mosquitto`, `eclipse-mosquitto` and
   `docker.io/library/eclipse-mosquitto`.
4. **Compare with hard data**: `gh api repos/<o>/<r>` (stars, `pushed_at`,
   archived), its releases, and commits and distinct authors in the last 90
   days. For a fork, compare fork against original.

A popular candidate is not automatically better for us. Report the count
honestly (for example, more home-ops repos may still run mosquitto than EMQX),
and say what the switch would gain for this cluster.

### Peer survey — what the popular repos converge on

One researcher picks the ~12 most-starred, active home-ops repos (kubesearch
ranks them by stars), lists what each deploys, and builds a matrix by job. It
reports: jobs where peers converge on a different tool from ours, with counts
("8 of 12 run X, we run Y"); at most 10 capabilities most peers have and we
lack, each with the gain for this household; and structural patterns (a shared
component, a Renovate pattern, a CI check) that would remove a defect or a
manual step here, each with a link to a peer file.

## 5. Sizing resources — use 7 days, never a snapshot

**This is the single most important technique in this skill.** A point-in-time
reading will make you shrink something that bursts, and miss things that are
chronically under-requested.

**Start from the Grafana dashboard Homelab / Right-sizing** (`homelab-rightsizing`).
It shows every workload container with request, own-memory p99/max,
`working_set` max, RSS max, a suggested request and limit, and request/p99 as a
coloured cell. Then confirm the rows you will act on with the queries below.

**Size memory from `working_set − active_file`, never from `working_set`.**
`working_set` still counts *active* page cache. An app that copies big files over
NFS fills that cache, and the kernel reclaims it before it OOM-kills anything.
On 2026-10-21 this audit told sonarr to go to 1.4Gi/3.5Gi off a 1.9Gi
`working_set` peak. Its own memory peaked at 369Mi, and there was never an OOM
kill. pinchflat, qbittorrent, vmsingle and immich-microservices were over-read
the same way. **RSS alone is also wrong**: it leaves out shared memory, so
Postgres-type apps look far too small (immich-db RSS 343Mi, real 992Mi).
The recording rule `container_memory_nofile_bytes` (and
`workload_container:container_memory_nofile_bytes:max`) holds this metric from
2026-10-21 on. For a window that starts earlier, use the raw expression.

**Merge all pods of a workload before you take a percentile.** The max of each
pod's own p95 lets a short-lived pod (restart, rollout) set the number. Strip the
pod hash with `label_replace` and take `max by` at each step. Every pod
generation is still included, because the max over pods is taken at each step,
so the old lesson still holds (jellyfin's 1.1Gi transcode peak was in an older
pod).

```bash
VM=http://vmsingle-victoria-metrics-stack.observability.svc.cluster.local:8428
# query via: kubectl exec -n observability <vmalert pod> -c vmalert -- wget -qO- --post-data="query=<urlencoded>" $VM/api/v1/query
RE='^(.+?)(?:(?:-[a-z0-9]{8,10})?-[a-z0-9]{5})?$'     # always matches, so StatefulSets keep a workload label
S='metrics_path="/metrics/cadvisor",container!="",container!="POD"'   # /metrics/resource duplicates working_set
NOFILE = max by (namespace,wl,container) (label_replace(container_memory_working_set_bytes{S} - container_memory_total_active_file_bytes{S}, "wl","$1","pod",RE))
quantile_over_time(0.99, (NOFILE)[14d:5m])      # request ≈ this × 1.1
max_over_time((NOFILE)[14d:5m])                 # limit ≥ 2 × this
# CPU: same wrapping on rate(container_cpu_usage_seconds_total{S}[5m]), p95
```

Sizing rule: **memory request ≈ own-memory p99 × 1.1**, **memory limit ≥ 2 ×
own-memory max**, CPU request from p95 with no CPU limit (repo convention). Keep
an existing limit when it is above that. For a big-I/O app the limit also bounds
its page cache, and a tight limit just makes the cache reclaim more often.
**5-minute samples miss startup spikes.** copyparty peaked at 231Mi in 14 days of
data, so it got a 512Mi limit. It was then OOM-killed ~10s after every start
(378Mi seen at startup) and crash-looped for 35 minutes before anyone noticed.
When you add a limit to a container that had **none**, give it ≥ 4 × the
recorded max (or 2Gi), watch the first restart with `kubectl top` for 3
minutes, and sweep `lastState.terminated.reason=="OOMKilled"` across the
cluster after the batch lands. Tighten later, from data recorded under the
new limit.
**A limit with no request sets the request equal to the limit.** That is how
4 Envoy proxies reserved 4Gi for 260Mi of use, so always set both. Expect some
requests to go up and some to go down. Under-requesting is as real a defect as
over-provisioning.

## 6. The report — Artifact, ASD-STE100 Simplified Technical English

Load `artifact-design` first, write HTML, publish with the `Artifact` tool.
This is the deliverable the user keeps; it is worth real care.

**One new Artifact per audit, same look every time.** Write it to
`<scratchpad>/cluster-audit-YYYY-MM-DD.html`, `<title>Cluster Audit YYYY-MM-DD</title>`,
`icon: "checklist"`. Do not overwrite the previous audit's Artifact; it is the
historical record. Copy the `<style>` block and the tokens from the baseline
report's HTML, so the reports read as a series. The IBM Plex Sans Condensed,
Sans and Mono faces and the slate/blue palette with severity tokens come from it.
Keep this section order, and drop a section only when it has nothing in it:

1. Header: eyebrow (date · Talos · k8s · nodes · apps · pods), one-paragraph
   lede that says the outcome first, tally chips
2. Incident panel (only if something happened): a timeline of what happened
   and when, with the evidence
3. **Fix now**: numbered work order, `what / why / fix` per item
4. **Fix soon**: unordered
5. **Resources**: the 7-day table (p95, peak, request/limit, proposal)
6. Clean-up, then Hygiene (house rules), then **Move to git**: one numbered
   row per setting that lives only in an app's UI/DB/volume, with the way
   git could own it. Every setting the fix loop changes by hand inside an app
   (not in git) also becomes a Move-to-git row, so manual changes never go
   unrecorded.
7. **Successors**: a table with one numbered row per _migrate_, _evaluate_ and
   _watch_ finding: `# / current → candidate / signal (link, date) / peers
   (kubesearch counts, ours vs candidate) / gain / cost / verdict chip`. Follow
   it with the peer survey: the jobs where peers converge elsewhere, and the
   capabilities we lack. Sort by verdict, then by cost. Put the _keep_ rows,
   with their reasons, under a closed `<details>` "Checked and kept", with no
   numbers. A _migrate_ row that is urgent also appears in Fix now or Fix soon,
   and that entry links to the row.
8. **Closed since <baseline date>**: what the last audit flagged that is now fixed
9. **What is good**: a grid; always present
10. Footer: method, the repo commits audited, the baseline used

Tag carried items with a `from <baseline date>` chip, so the user sees what has
been open for more than one cycle.

**Give every actionable item its own number, so the user can say "do #14".**
- One sequence across the whole report: Fix now first (1–N), then Fix soon,
  then each open Resources row and each leftover resource note, then
  Clean-up, then Hygiene, then Move to git, then Successors. Not-actionable
  sections (incident, Closed since, What is good, the kept successors) get no numbers.
- Show the number as a `<span class="id">#14</span>` badge, and put
  `id="i14"` on the element, so `<link>#i14` jumps to it. Fix now draws its
  number with the CSS counter and still gets the `id`.
- Clean-up and Hygiene are an `<ol class="ids">` of numbered rows, not a bullet
  list. A Resources row gets a `#` column. Rows already applied show ✓ and no
  number.
- Under the header tally, add one line that gives the ranges ("Fix now is
  1–10, fix soon is 11–30, …").
- **Numbers never change inside a report.** A done item keeps its number,
  struck through. An item found during the fix loop gets the next free number
  at the end, even if it belongs in an earlier section. Never renumber to tidy
  up: the user refers to the old numbers.
- In the next audit, numbering starts again at 1. A carried item shows its old
  number in the chip (`from 2 Oct #14`), so the user can trace it.
- Copy the `.id`, `ol.ids` and `tr.done` styles from the baseline report along
  with the rest of its `<style>`.

**Tables must read on a phone.** The user reads the report on a phone, and a
wide table that scrolls sideways is hard to read there. Below 720 px, each row
becomes a card: the first two cells (`#` and the name) form the title, and every
other cell shows its column name on its left.
- Put `data-label="<column name>"` on every `<td>` and class `lead` on the
  first two cells of each row. [`label-tables.py`](label-tables.py)
  `<report.html>` does this from the `<th>` texts, and is safe to run again; the 2026-11-26 report's `<style>` has the card CSS
  (`@media (max-width:720px)`, `.tablewrap td::before{content:attr(data-label)}`).
- Lay the cell out as a block with an absolutely placed label, not as a grid: a
  grid makes each link and text run inside a cell its own column.
- Never give a table cell the class `wrap`: the page wrapper `.wrap` has
  `margin-inline:auto` and `display:flex`, which centred and squeezed cells.
  Cells that wrap use `wt`.
- Check it before the first publish: open the file in chrome-devtools, emulate
  `400x860x2,mobile,touch`, add a `<meta name="viewport"
  content="width=device-width">` with a script (the publish skeleton adds it,
  the local file does not), and confirm `scrollWidth` is 400 and a screenshot
  reads well.

**Log it right away.** As soon as the first publish succeeds, add a row at the
top of [`audits.md`](audits.md) with the date, the link, the baseline used and
a status. Commit it with the next fix commit, or on its own if no fix follows.
Keep that row free of sensitive detail, because the repo is public.

- **ASD-STE100**: short sentences, active voice, present tense, one idea per
  sentence, plain approved vocabulary, consistent terms. Write for someone with
  ADHD scanning under load.
- **Ordered by what to do first**, not by severity taxonomy. Numbered "Fix now"
  entries are a work order — numbering is meaningful there and nowhere else.
- Each finding: what it is / why it matters / the fix — three short lines.
- Machine identifiers in mono; severity as a chip **and** a left stripe.
- **Always include a "What is good" section.** Most of the cluster is fine and
  the user needs to see that, not just a wall of problems.
- See §7 for keeping the report current during the fix loop.

## 7. Fix loop — explicit permission, one item at a time

Never batch-apply findings. For each item the user picks:

- **Read the git history before "fixing" a deliberate setting.** `git log -L`
  found that Longhorn's pre-upgrade checker was disabled for a *reason* (an image
  was pinned to a non-standard `-hotfix-` tag) and that the reason had expired.
- **Check whether the change needs a restart.** `pg_settings.context` —
  `postmaster` needs a restart, `user`/`sighup` reload live. Picking the
  reloadable subset is what made the Postgres tuning a no-downtime change.
- **Render before you commit.** `helm template` the chart with the new values and
  diff against `HEAD` so you can prove only the intended fields moved.
- **Validate every image digest** against its registry (expect HTTP 200) before
  committing — a wrong digest is an ImagePullBackOff.
- **Test risky container changes in a throwaway pod first** under the identical
  securityContext. lldap crash-looped on the first attempt; the second attempt
  was verified before it was pushed.
- Commit per logical fix, push, sync via the argocd MCP, then **verify in the
  cluster** — rollout status, 0 restarts, no OOMKilled, app Synced/Healthy, and
  the dependent apps' logs clean.
- No attribution trailers in commit messages (repo convention).

### Keep the report current — update it after every decisive action

The Artifact is the user's record, so update it as each decisive action lands,
not only at the end. Decisive actions: a fix verified in the cluster; a
decision ("leave it", "defer to the Talos upgrade", "hold for my call"); a
manual operation (data deleted or restarted); and a finding proved wrong.

- Republish the **same file path** with `edits` (old_str/new_str copied from
  the file), so the URL stays the same. From a later session, the scratchpad
  file is gone: `Artifact` `read` the link from `audits.md`, edit the HTML it
  returns, and publish with `url:` set to that link.
- When the user names an item by number ("#14"), work that item. In the reply
  and the commit message, mention the number ("fixes audit 2026-10-21 #14").
- Done item: add class `done` to the `<li>` (strikethrough plus fade). Keep its
  number. Add a
  `<p class="result">` with the commit hash(es) and the **verified** result in
  numbers (e.g. "231 s → 10 s", "14.1 GB → 365 MB").
- Held or deferred item: leave it as is. Add a chip (`on hold`,
  `with Talos upgrade`) and a one-line `result` that says why and what is
  needed.
- When a fix needed more than one attempt, say so in the result. That history
  is useful the next time.
- **Sweep the whole report for the item, every time.** A fix closes more than
  its own row. Jellyfin (#11) and Grafana (#12) were marked done in Fix soon on
  2026-11-26, but their Successors rows (#89, #91), the Renovate blind-spot list
  (#67), the digest-pin count (#66), the tally ("4 done" with 14 done) and the
  footer stayed stale until the user noticed. After each item, run
  `grep -n '#<n>\b\|<app name>' <report>` and update every hit: the Successors
  row, Hygiene, Clean-up and Move-to-git mentions, the Resources row, counts
  that the fix changed (re-measure them), and any "What is good" claim it changed.
- Keep a `<p class="status">` line under the tally ("Status <date, time>: …")
  that says what is done, on hold, and open, so the top of the report is current.
- Update the header tally chips and the footer, and the status column of the
  row in `audits.md`.
- Batch the update when several items land together, but do it before you
  report back to the user.

### Gotchas this repo has already paid for

- **Container ordering** needs **native sidecars** (`initContainers` with
  `restartPolicy: Always`). A plain init container deadlocks — it completes
  before any regular container starts, so it waits forever on a sidecar that has
  not started. app-template renders initContainers **alphabetically**, so order
  is not what you wrote it as.
- **`allowPrivilegeEscalation` and `capabilities` are container-level** and are
  NOT inherited from `defaultPodOptions.securityContext`. That is why a pod that
  looks hardened still fails PodSecurity admission.
- **`readOnlyRootFilesystem` is not required by `restricted`.** Do not set it
  just to look thorough — it breaks rootless images that write to their own paths.
- **Privileged ports.** An app on :80/:389 runs as root for that reason alone.
  Move the container to unprivileged ports and keep the Service on the old ones
  via `targetPort`; consumers never notice.
- **`imageMaximumGCAge` tracking is in-memory and resets on every kubelet
  restart.** Enabling it frees nothing today, and each config apply restarts the
  clock.
- **A "full" Longhorn disk may not be Longhorn.** Check
  `storageScheduled` and `imageFs.usedBytes` from the node stats summary before
  blaming storage — on talmac-01 the culprit was 147.7GB of container images.
- **`container_*` series come twice** (`/metrics/cadvisor` and
  `/metrics/resource`). `max by` is safe. `sum` doubles every value. Filter on
  `metrics_path="/metrics/cadvisor"` when you need a sum.
- **VictoriaLogs fields** are `kubernetes.pod_name`, `kubernetes.pod_namespace`
  and `kubernetes.pod_node_name` (not `node_name`). The server pod has no wget;
  query it from the vmalert pod.
- **oCIS upload sessions**: "expired" includes complete uploads stuck in
  processing, which can be real user files. List with `--json` first. Clean
  partial ones with `--expired --processing=false --clean`. Ask before you clean
  the processing ones. The CLI only works inside the oCIS pod, because it needs
  oCIS's 127.0.0.1 services.
- **gluetun's firewall blocks all traffic outside the tunnel**, its own server-list
  updater included. Fetch the list in an init container, before the firewall
  starts.
- Commits are not signed in this repo (`commit.gpgsign false`), so `git commit` does not wait for
  a key prompt. Do not add signing steps.

## Scope

Read-only until told otherwise. The private repo
(`../home-cluster-private`, holds the *arr stack) is in scope for reading always,
and for edits only when the user grants it. Never touch `age.key` / `*.key`.
