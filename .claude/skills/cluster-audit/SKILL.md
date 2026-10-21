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
  rules and current upstream best practice via context7/web/git-grep. The parent
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
2. Parent fans out ~9 domain subagents **in one message** so they run in parallel
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
- its HTML: the new report reuses the same visual system (see §5).

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

Nine slices. Adjust to what actually exists, but keep them disjoint and name the
namespaces explicitly so nothing is audited twice or missed:

| Slice | Covers |
|---|---|
| Networking | `network`, `network-optimizer`, `cilium-secrets`, + cilium/coredns/k8s-gateway/spegel in kube-system |
| Storage | `longhorn-system`, `storage`, `garage` |
| Database | `database`, `valkey` |
| Observability | `observability` + metrics-server — **and list every firing/pending alert** (vmalert `/api/v1/alerts`) |
| Security/GitOps | `security`, `cert-manager`, `argo-system`, `forgejo` |
| Media | `jellyfin`, `immich`, `audiobookshelf`, `calibre-web-automated`, `romm`, `music-assistant`, `lychee`, `downloads`, `gluetun-proxy`, `ps5` (private) |
| Home automation | `homeassistant`, `birdnet-go` |
| Web apps | `n8n`, `umami`, `jotty`, `lubelog`, `changedetection`, `trek`, `reckage`, `lastglance`, `heremag`, `owncloud`, `pcab`, `default` |
| Platform/capacity | rest of kube-system + **cluster-wide node capacity** (per-node MemAvailable 7d minimum, not just requests) |

The namespace list drifts. Diff `kubectl get ns` against this table at inventory
time and put any new namespace in a slice.

Every brief must include:

- the scratchpad paths and "read these, don't recollect"
- **logs**: `kubectl logs -n <ns> <pod> --all-containers --since=24h --tail=400 | grep -iE 'error|warn|fail|fatal|panic|deprecat|refused|timeout|denied|unable|cannot|invalid' | sort | uniq -c | sort -rn | head -30`, plus `--previous` for anything restarted
- **judge each hit** — real problem or expected noise; report only real ones with the exact line and how often it repeats
- **resources**: compare `resources.txt` against `top-pods.txt`
- **best practice, both halves**: (a) this repo's CLAUDE.md rules — images pinned `tag@sha256`, never `latest`; `laboratory.casa` + `internal`/`external`; runAs 3000; `stringData` with no `type:`; `ghcr.io/bjw-s-labs/helm`; single-source Argo app must not carry an unconsumed `ref:`; central PG + central valkey. (b) upstream current practice via `mcp__context7__query-docs`, `mcp__git-grep__searchGitHub`, web search
- **return findings as text, not a file** — subagents are blocked from writing report files; ask for a ~800-word structured summary (Critical / Warning / Resources / Best practice / Healthy)
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

## 4. Sizing resources — use 7 days, never a snapshot

**This is the single most important technique in this skill.** A point-in-time
reading will make you shrink something that bursts, and miss things that are
chronically under-requested.

```bash
VM=http://vmsingle-victoria-metrics-stack.observability.svc.cluster.local:8428
# run curl from a throwaway pod; RETRY, the transient pods are flaky
max by (namespace,pod,container) (max_over_time(container_memory_working_set_bytes{container!=""}[7d]))
max by (namespace,pod,container) (quantile_over_time(0.95, container_memory_working_set_bytes{container!=""}[7d]))
max by (namespace,pod,container) (max_over_time(rate(container_cpu_usage_seconds_total{container!=""}[5m])[7d:5m]))
```

**Query per-pod, and keep every pod generation.** Aggregating
`by (namespace,container)` — or stripping replicaset hashes and merging — silently
drops older pods. That is exactly what hid the two findings that mattered:

- **jellyfin** showed 183Mi live; an older pod had peaked at **1.1Gi** mid-transcode
- **sonarr** looked oversized at ~200Mi; it had peaked at **986Mi**, so its
  existing 384Mi/2Gi was correct and the right action was *no change*

Sizing rule: **request ≈ p95**, **memory limit ≈ 2× true peak**, CPU request from
p95 with no CPU limit (repo convention). Expect requests to go **up** for several
apps — being under-requested is as real a defect as being over-provisioned, and
only the 7d window reveals it.

## 5. The report — Artifact, ASD-STE100 Simplified Technical English

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
6. Clean-up, then Hygiene (house rules)
7. **Closed since <baseline date>**: what the last audit flagged that is now fixed
8. **What is good**: a grid; always present
9. Footer: method, the repo commits audited, the baseline used

Tag carried items with a `from <baseline date>` chip, so the user sees what has
been open for more than one cycle.

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
- See §6 for keeping the report current during the fix loop.

## 6. Fix loop — explicit permission, one item at a time

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
- Done item: add class `done` to the `<li>` (strikethrough plus fade), and add a
  `<p class="result">` with the commit hash(es) and the **verified** result in
  numbers (e.g. "231 s → 10 s", "14.1 GB → 365 MB").
- Held or deferred item: leave it as is. Add a chip (`on hold`,
  `with Talos upgrade`) and a one-line `result` that says why and what is
  needed.
- When a fix needed more than one attempt, say so in the result. That history
  is useful the next time.
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
  just to look thorough — it breaks rootless images and postgres-init.
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
- Commits are signed via Secretive (Touch ID). A `git commit` may hang waiting
  for approval — retry once, then hand the command to the user rather than
  reaching for `--no-gpg-sign`.

## Scope

Read-only until told otherwise. The private repo
(`../home-cluster-private`, holds the *arr stack) is in scope for reading always,
and for edits only when the user grants it. Never touch `age.key` / `*.key`.
