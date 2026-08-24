---
name: remove-argo-app
description: >-
  Cleanly decommission an ArgoCD application from this home-cluster repo so it
  leaves NO traces behind in the cluster. Use whenever the user wants to remove,
  delete, decommission, retire, tear down, or "get rid of" an app, or says "I no
  longer want <app>" / "nuke <app>" / "remove <app> from argo" / "clean up
  <app>". Handles multi-component apps, the non-cascading-prune trap (orphaned
  workloads), cluster-scoped resources (ClusterRole/ClusterRoleBinding) that
  survive a namespace delete, PVC/PV reclaim, central-PG database rows, and
  runtime-created resources that no Application owns. Works GitOps-first (ArgoCD
  does the deletion), verifies every layer via the kubernetes + argocd MCP
  servers, and confirms zero residue at the end. Reach for this any time an app
  needs to go away completely.
---

# Remove an ArgoCD app (trace-free, GitOps-first)

Decommission an app so **nothing** survives: no Application CRs, no workloads,
no cluster-scoped RBAC, no PVs/volumes, no orphaned runtime objects, no
namespace, no rows in the central Postgres. ArgoCD does the deletion — we never
`kubectl delete` app-managed resources directly. The only direct cluster
mutations are the final sweep (namespace + any runtime orphans ArgoCD never
managed).

See also the terse companion note `.agents/workflows/remove-argocd-app.md`.

## The core hazard (read first)

This repo's app-of-apps parent (`kubernetes/argo/apps.yaml`, app name `apps`)
is a **directory-recurse generator with `prune: true`**. If you just delete a
child app's YAML, the parent prunes the child `Application` CR — but **pruning
an Application does NOT cascade to its workloads unless the Application carries
`metadata.finalizers: [resources-finalizer.argocd.argoproj.io]`.** Without that
finalizer you orphan every workload — including any cluster-scoped
ClusterRole/ClusterRoleBinding, which then become un-GitOps-managed zombies that
a namespace delete won't touch.

**So the finalizer must be armed and confirmed on the LIVE Application CRs
BEFORE the app files are deleted.** Two commits, in order.

## Phase 0 — Inventory (never skip)

Enumerate everything before deleting anything. Use the argocd + kubernetes MCP.

1. **Find every Application** belonging to the app (multi-component apps have
   several — e.g. app + postgres + a helper controller). Search the repo and
   the live CRs:
   - `ls kubernetes/argo/apps/<namespace>/` and `ls kubernetes/apps/<namespace>/`
   - `grep -rl "<app>" kubernetes/`
   - `kubectl get applications -n argo-system | grep -i <app>`
   - For each: `mcp__argocd-mcp__get_application` → note `spec.destination.namespace`,
     `spec.sources`, whether `metadata.finalizers` already present, and the full
     `status.resources` list.
2. **Classify managed resources** from each app's `status.resources`:
   - Namespaced (die with the namespace) vs **cluster-scoped**
     (ClusterRole, ClusterRoleBinding, ClusterIssuer, CRDs, PVs, webhooks,
     PriorityClass…). Cluster-scoped ones are the ones that survive a namespace
     delete — list them explicitly, you'll verify their removal later.
3. **PVCs / PVs / volumes**:
   - `kubectl get pvc -n <ns>` → for each PVC's bound PV,
     `kubectl get pv <name> -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'`.
   - `Delete` → volume auto-reclaims with the PVC. `Retain` → the PV + backing
     Longhorn/NFS volume will LINGER; flag it for manual cleanup.
4. **Central Postgres?** This repo uses a central PG (`database` ns) with an
   init-container provisioning pattern for many apps (see
   `kubernetes/apps/lubelog/lubelog/`). Check the app's values/secret for a DB
   name + `postgres.database.svc` host. If it uses central PG, the app's own
   DB/role remains in the central cluster after removal — decide with the user
   whether to `DROP DATABASE`/`DROP ROLE`. (Apps with their own bundled postgres
   + PVC need no central cleanup — the PVC delete takes the data.)
5. **Runtime-created orphans (the sneaky one).** If the app had broad RBAC (a
   `Role`/`ClusterRole` with `*` verbs) or is itself a controller/operator, it
   may have created resources at runtime that **no Application owns** — these
   have no `argocd.argoproj.io/tracking-id` annotation and will NOT be pruned by
   the cascade. After Phase 2, list everything left in the namespace and check
   ownership (see Phase 3). Note now whether the app is a resource-creator so
   you expect debris.

Present the full inventory to the user before proceeding.

## Phase 1 — Arm cascade delete (commit #1)

For **every** child Application manifest under
`kubernetes/argo/apps/<namespace>/`, add the finalizer (they already have
`prune: true` in this repo):

```yaml
metadata:
  name: <app>
  namespace: argo-system
  annotations:
    argocd.argoproj.io/sync-wave: "0"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
```

Commit + push. Then make the parent apply it and **verify the finalizer landed
on the live CRs** (the parent's `ignoreDifferences` is scoped to
`/spec/syncPolicy`, so it does not interfere with `metadata.finalizers`):

- `mcp__argocd-mcp__sync_application` on `apps` (namespace `argo-system`), or wait for auto-sync.
- Verify each: `kubectl get application <app> -n argo-system -o jsonpath='{.metadata.finalizers}'`
  → must show `["resources-finalizer.argocd.argoproj.io"]`, and sync=Synced health=Healthy.

**Do not proceed until all child CRs show the finalizer.**

## Phase 2 — Remove from Git (commit #2)

Delete the Argo app definitions and the app directory:

```
git rm -r kubernetes/argo/apps/<namespace>
git rm -r kubernetes/apps/<namespace>
```

Confirm no refs remain: `grep -rl "<app>" kubernetes/` → empty.
Commit (use `!` in the type for the breaking change) + push. Then trigger the
parent to prune:

- `mcp__argocd-mcp__sync_application` on `apps` with `prune: true`.

The parent prunes the child CRs; each finalizer drives **cascading deletion** of
all managed resources (workloads, Services, Secrets, Ingress, namespaced
Role/RoleBinding, **cluster-scoped ClusterRole/ClusterRoleBinding**, and PVCs →
PVs → volumes when reclaim=Delete).

Poll until the child CRs are gone:
```
kubectl get application <app> -n argo-system          # → NotFound
kubectl get pods,pvc -n <namespace>                   # → cascade emptying
```

## Phase 3 — Sweep the namespace + runtime orphans

ArgoCD created the namespace via `CreateNamespace=true` but does **not** manage
or prune it — and it never managed runtime-created orphans. Sweep both.

1. List what's actually left and check ownership:
   ```
   kubectl get all,ingress,secret,configmap,pvc -n <namespace>
   ```
   For anything still present, inspect
   `metadata.annotations."argocd.argoproj.io/tracking-id"` (empty = never
   GitOps-managed) and `metadata.labels`. Resources labelled `managed-by:
   <app>` or selecting the app's now-deleted pods are runtime debris the app
   created. Confirm they're dead (empty endpoints) and that **no other app**
   relies on the namespace before removing it.
2. Delete the namespace (removes it and any remaining orphans in it):
   ```
   kubectl delete namespace <namespace> --wait=false
   kubectl wait --for=delete ns/<namespace> --timeout=60s
   ```
   If it hangs in `Terminating`, a resource has a stuck finalizer — investigate
   `kubectl get ns <namespace> -o jsonpath='{.status.conditions}'`; do not
   blindly strip namespace finalizers.
3. If Phase 0 found **Retain PVs** or a **central-PG database/role**, clean
   those now (with user confirmation for DB drops).

## Phase 4 — Verify zero traces

All of these must return nothing / NotFound:

```
kubectl get ns <namespace>                                  # NotFound
kubectl get applications -n argo-system | grep -i <app>     # (none)
kubectl get clusterrole,clusterrolebinding | grep -i <app>  # (none)  ← the trap
kubectl get pv | grep -i <app>                              # (none)
grep -rl "<app>" kubernetes/                                # (none)
```
Plus: central PG has no leftover DB/role (if applicable), and no Retain PV /
Longhorn volume remains.

## Interaction & safety

- Committing/pushing triggers live cluster mutation. Confirm the push flow with
  the user (they may want to push each phase themselves) and walk phase by phase.
- Never `kubectl delete` an app-managed resource directly — let the finalizer
  cascade do it. The only direct deletes are the namespace and confirmed runtime
  orphans / Retain PVs / DB rows in Phase 3.
- If the app was **already** removed from Git without the finalizer (workloads
  orphaned): re-add the child manifest + directory exactly (same name/path) WITH
  the finalizer, let ArgoCD adopt/reconcile to Synced, then run Phases 1→4.

## Gotchas learned

- **Non-cascading prune is the default.** No finalizer → prune orphans workloads.
- **Cluster-scoped resources survive a namespace delete.** Enumerate and verify
  ClusterRole/ClusterRoleBinding/CRDs/PVs separately.
- **Runtime-created objects survive the GitOps cascade.** Apps with broad RBAC or
  controllers (e.g. a bundled `k8s-ttl-controller`, preview-env managers) leave
  bare Services/Ingress/etc. that no Application owns. The namespace delete is
  what actually sweeps them — which is why Phase 3 matters even when Phase 2
  "looks" complete.
- **PV reclaim policy dictates volume cleanup.** `Delete` = automatic; `Retain` =
  manual.
- **The namespace is not GitOps-managed** here — it needs an explicit delete.
- **Parent `ignoreDifferences: /spec/syncPolicy` does not block `metadata.finalizers`.**
