# Successor survey brief (template, cluster-audit §4)

The parent copies this file into each alternatives researcher's prompt (or points at it), with
`<scratchpad>` filled in and the researcher's app group appended.

You are one of several parallel researchers. Goal: for EVERY app in your group, find out whether
something better now does the same JOB. A sweep that only checks whether each project is alive misses, for
example:
- `TheBadFella/Pinchflat-NGX`, a fork that may now be the successor of pinchflat;
- EMQX, which some homelabbers now run instead of mosquitto as the MQTT broker.
The 2026-11-26 audit missed both until a second pass with this method. Your job is to catch that class of finding. **Do NOT change anything** in the repo or the cluster.

Repo: /home/zac/projects/home-cluster (public; private apps in ../home-cluster-private).
Read each app's `kubernetes/apps/<ns>/<app>/values.yaml` and `kubernetes/argo/apps/**/<app>.yaml`
for the current chart, image and version. Live images per namespace:
`<scratchpad>/images-by-ns.txt`.

## Method — do all four for each app

1. **Name the job, not the product.** One line: what the app does for this household
   (e.g. "MQTT broker for zigbee2mqtt and HA", "YouTube channel downloader into Jellyfin").
2. **Search for alternatives that do that job** with the Tavily connector
   (`mcp__claude_ai_Tavily__tavily_search`; fall back to `mcp__claude_ai_Exa__web_search_exa`).
   Run at least two queries per app, e.g.
   `"<app> alternative self-hosted 2026"`, `"<app> fork"`, `"best self-hosted <job> 2026"`,
   `"<app> vs <candidate>"`, and a reddit r/selfhosted or r/homelab query. Check awesome-selfhosted
   for the category. Look for: active forks, rewrites, successors named by the upstream itself,
   and the tool the community now recommends for the job.
3. **Count peer adoption on kubesearch** (the home-ops index, ~305 repos). Helper script:
   `.claude/skills/cluster-audit/kubesearch.sh <tool> '<json>'` (or the `kubesearch` MCP tools, if this session has them)
   - `kubesearch.sh search_images '{"query":"pinchflat"}'` → repos that run an image (repo_count per image repo).
   - `kubesearch.sh search_releases '{"query":"emqx"}'` → repos that deploy a chart (deployment_count).
   - `kubesearch.sh repo_grep_all '{"query":"emqx","max_per_repo":3}'` → hits in the 10 most-starred repos.
   - `kubesearch.sh grep_values '{"query":"..."}'` → a literal in Helm values.
   Output is JSON; pipe through `jq`. Compare the count for our choice against each candidate,
   and sum repo_count over all image names of one product (e.g. `eclipse-mosquitto` appears under
   several registries). Note the newest tags seen, which shows whether peers are current.
4. **Compare the projects with hard data**, not READMEs: `gh api repos/<owner>/<repo>` (stars,
   pushed_at, archived, open issues), `gh api repos/<o>/<r>/releases?per_page=5` (dates),
   `gh api 'repos/<o>/<r>/commits?since=<90 days ago>&per_page=100' --paginate | jq length`
   and the number of distinct authors in that window. For a fork, compare fork vs original.

## Verdicts and signals (from the cluster-audit skill)
- **migrate**: upstream dead, deprecated or unsafe, and a successor exists.
- **evaluate**: a real gain for THIS cluster is on the table; worth a trial.
- **watch**: promising but young (under a year, one maintainer, little peer adoption).
- **keep**: checked, and the current choice is still right. Give the reason.
A finding needs at least one hard signal with a link and a date: an archive/deprecation notice,
no release in 12 months, a licence change, a fork with clearly more activity (numbers), or a peer
adoption count from kubesearch. "New hotness" alone is watch at most. For every non-keep row, name
the GAIN for this cluster (a defect it removes, a feature the household would use, memory freed,
a manual step deleted) and the COST (data migration, downtime, re-learning).
Be honest when the popular candidate is NOT better for us (e.g. it needs a cluster we do not need).

## Report (your final message, text only)
One block per app, in this exact shape, keeps included:

```
APP: <name> — job: <one line>
current: <image/chart:version>, upstream <owner/repo>: <stars>★, last release <date>, commits 90d <n>/<authors>
kubesearch: <ours n repos> | <candidate A n repos> | <candidate B n repos>
candidates: <name (link)>: <one-line fact with numbers and date>; ...
verdict: <migrate|evaluate|watch|keep> — <current → candidate> | gain: ... | cost: ...
```

Then a short list "Searches that found nothing useful" (so the next audit can skip them).
Every number must come from a tool call you made in this session. If a tool failed, say so.
Keep the whole report under ~1500 words.
