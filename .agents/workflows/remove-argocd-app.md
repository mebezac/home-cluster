# Remove an Argo CD app (GitOps-first)

This workflow removes an app with Argo CD doing the resource cleanup (no direct kubectl deletes).

## Core rule

- Deleting an `Application` only cascades to workloads if `metadata.finalizers` contains `resources-finalizer.argocd.argoproj.io` (or `/background`).
- Non-cascading deletion removes the `Application` CR and leaves workloads orphaned.

## Correct decommission flow (App-of-Apps)

1. **Phase 1 - prepare cascade delete**
   - Ensure child app manifest has:
     - `metadata.finalizers: [resources-finalizer.argocd.argoproj.io]`
     - `spec.syncPolicy.automated.prune: true`
   - Merge and wait for child app to be `Synced/Healthy`.
2. **Phase 2 - remove app from Git**
   - Delete `kubernetes/argo/apps/<namespace>/<app>.yaml`.
   - Delete `kubernetes/apps/<namespace>/<app>/`.
   - Merge; parent app prunes child `Application`; child finalizer drives workload deletion.

## Recovery flow if workloads were orphaned already

If the app was already removed without cascading delete:

1. Re-add the child app manifest and app directory exactly (same app name/path), with deletion finalizer enabled.
2. Wait for Argo CD to adopt/reconcile resources (`Synced/Healthy`).
3. Run **Phase 2** above to remove again; this time Argo cascades deletion.

## Preserve workloads intentionally

If you want to remove Argo management but keep workloads, use non-cascading delete and do not use the resources finalizer.

## References

- Argo CD app deletion: https://argo-cd.readthedocs.io/en/latest/user-guide/app_deletion/
- Argo CD cascading deletion in App-of-Apps: https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#cascading-deletion
- Argo CD ApplicationSet deletion behavior: https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Application-Deletion/
