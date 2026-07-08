---
name: debug-alerts
description: >-
  Find, read, and debug firing alerts in this home-cluster's VictoriaMetrics /
  vmalert monitoring stack. Use whenever the user asks what's alerting, why an
  alert is firing, to "check the alerts", "look at monitoring", "debug the
  vmalerts", "what's firing", "is anything broken", or names a specific alert
  ("why is KubePodCrashLooping firing", "silence X"). Walks the whole loop:
  query vmalert's live alerts API for what's firing, read each alert's
  expression/labels/annotations, reproduce the expression against
  VictoriaMetrics to see the real numbers, tell genuine problems apart from the
  always-on meta-alerts (Watchdog, InfoInhibitor) and benign empty-recording-rule
  false-positives, then fix — either resolve the underlying condition or, for a
  noisy/false-positive rule, disable/tune it via the vm-k8s-stack defaultRules in
  values.yaml (GitOps) and let ArgoCD sync. Knows the pod/port layout (vmalert
  :8080, vmsingle :8428), the kubectl-exec + busybox-wget query pattern, and
  where the rules live in the repo. Reach for this any time a monitoring alert
  needs triaging or a VMRule needs tuning.
---

# Debug vmalert / VictoriaMetrics alerts

Triage firing alerts in the `observability` namespace. The loop: **list what's
firing → read the rule → reproduce its expression against VM → classify (real vs.
meta vs. benign false-positive) → fix**. Most "firing" alerts on a healthy
cluster are noise; the job is separating signal from noise before touching config.

## The stack (pod / port layout)

| Component | Label selector | Port | Role |
|-|-|-|-|
| vmalert | `app.kubernetes.io/name=vmalert` | 8080 (container `vmalert`) | evaluates rules, holds firing state |
| vmsingle | `app.kubernetes.io/name=vmsingle` | 8428 | the TSDB — query metrics here |
| vmalertmanager | `app.kubernetes.io/name=vmalertmanager` | 9093 | routing, silences, inhibition |

Ports drift between chart versions — if a query gets `Connection refused`, don't
guess. Confirm the listening port:

```bash
kubectl exec -n observability <pod> -- sh -c 'netstat -tlnp 2>/dev/null' | grep LISTEN
```

Containers are busybox (no curl). Use `wget -qO-`, and URL-encode PromQL:
`==` → `%3D%3D`, `:` → `%3A`, space → `%20`, `{`/`}` → `%7B`/`%7D`.

## 1. List what's firing

```bash
POD=$(kubectl get pod -n observability -l app.kubernetes.io/name=vmalert -o name | head -1)
kubectl exec -n observability ${POD#pod/} -c vmalert -- \
  wget -qO- 'http://127.0.0.1:8080/api/v1/alerts'
```

Each alert gives you `name`, `labels` (incl. `alertgroup`, `severity`,
`recording` if it's about a recording rule), `annotations`
(`description`, `runbook_url`, `dashboard`), `expression`, and `activeAt`.
`/api/v1/rules` lists every group + rule (useful to see what else lives in a
group before disabling the whole group).

## 2. Classify before you debug

Skip the alerts that fire **by design** on every healthy cluster:

| Alert | Meaning | Action |
|-|-|-|
| `Watchdog` | Always fires, proves the alert pipeline is alive (dead-man's-switch). | None. Firing = healthy. |
| `InfoInhibitor` | Meta-alert that fires whenever *any* `severity=info` alert exists, to inhibit info noise. Routed to null. | None directly — it clears when the real info alert(s) it shadows clear. |

So a run showing `Watchdog` + `InfoInhibitor` + one `severity=info` alert is
effectively **one** alert to look at. Fixing the info alert clears the inhibitor too.

Then watch for **benign empty-recording-rule false-positives**. `RecordingRulesNoData`
fires when a recording rule yields 0 samples — but some rules are *legitimately*
empty on a healthy cluster. The classic: `count:up0` counts DOWN scrape targets
(`count without(instance,pod,node)(up == 0)`), so it produces zero series exactly
when nothing is down. That's a good state misreported as a problem.

## 3. Reproduce the expression against VM

Confirm what the number actually is — don't trust the alert's framing. Query
vmsingle directly:

```bash
VM=$(kubectl get pod -n observability -l app.kubernetes.io/name=vmsingle -o name | head -1)
Q(){ kubectl exec -n observability ${VM#pod/} -- wget -qO- "http://127.0.0.1:8428/api/v1/query?query=$1"; }
Q 'up%3D%3D0'          # which targets are actually down (empty = all up)
Q 'count(up)'          # total scrape targets
Q 'count%3Aup1'        # a recording rule that SHOULD be populated (sanity)
```

Paste the alert's own `expression` (URL-encoded) to see exactly what it evaluated.
An empty `result` array with `resultType:vector` means "no series" — for a
count-of-bad-things rule that's healthy, for a should-always-exist rule it's a
real gap.

For deeper digging use the **kubernetes MCP** (`pods_log`, `events_list`,
`resources_get`) on whatever workload the alert points at, and the **argocd MCP**
if an alert traces back to an out-of-sync / degraded Application.

## 4. Fix

**If it's a real condition** — fix the workload (crashloop, PVC full, target
down, cert expiring). The alert clears on its own once the metric recovers.

**If it's a noisy / false-positive rule** — tune it in GitOps. Rules come from the
vm-k8s-stack chart's `defaultRules` in
`kubernetes/apps/observability/victoria-metrics-stack/values.yaml`.

Per-rule override (0.85+ schema — `rules:` is a map keyed by exact alertname):

```yaml
defaultRules:
  rules:
    RecordingRulesNoData:
      enabled: false        # disable one rule, keep the rest of its group
      # or tune instead of kill:
      # spec:
      #   for: 30m
      #   labels: { severity: warning }
```

Whole rule group toggle (keys must match upstream group names exactly):

```yaml
defaultRules:
  groups:
    vmcluster:
      enabled: false
```

Prefer a **per-rule** disable over nuking a group — groups like `vmalert` mix one
noisy rule (`RecordingRulesNoData`) with genuinely useful ones (`RemoteWriteErrors`,
`ConfigurationReloadFailure`, `AlertingRulesError`). Check `/api/v1/rules` for the
group's contents first.

Custom/non-default alerts live as `VMRule` CRs
(`kubectl get vmrule -A`) — edit the owning app's values, not defaultRules.

## 5. Ship it

Commit + push to main (single-user repo, no PR, no attribution trailer). ArgoCD
syncs the VMRule; on vm-k8s-stack ≥0.85 a deploy-time **sync-job** re-renders
rules/dashboards. It's annotation-tracked, so re-renders are safe. Confirm after
sync:

```bash
kubectl exec -n observability ${POD#pod/} -c vmalert -- \
  wget -qO- 'http://127.0.0.1:8080/api/v1/alerts'   # the alert should be gone
```
