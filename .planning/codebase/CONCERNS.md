# Codebase Concerns

**Analysis Date:** 2026-05-08

## Single Points of Failure

**Centralized PostgreSQL Cluster (3-replica):**
- Issue: All database-dependent apps (`adventurelog`, `immich`, `umami`, `lubelog`, etc.) rely on single `postgres-17-cluster` deployment
- Files: `kubernetes/apps/database/postgres-17-cluster/postgres-17-cluster.yaml`
- Impact: Cluster failure blocks all apps requiring persistent data; no read replicas for load distribution
- Fix approach: Implement read replicas using CloudNativePG; add Pgpool for connection pooling and failover
- Note: Barman backups configured (`plugin-barman-cloud.yaml`) mitigates recovery time but not availability

**Centralized Valkey Cache (single instance):**
- Issue: Single `valkey` StatefulSet at `kubernetes/apps/valkey/valkey/values.yaml` with no replication
- Impact: Session loss, cache misses during pod restarts; no sentinel failover
- Fix approach: Enable Valkey Sentinel mode with 3 sentinels; upgrade to Valkey cluster mode (requires major refactor)

## Missing Resource Configurations

**23 apps without defined resource limits:**
Critical apps missing CPU/memory limits (allow unbounded resource consumption):
- System-critical: `kubernetes/apps/kube-system/cilium/values.yaml`, `spegel/`, `coredns/`, `reloader/`
- Storage: `kubernetes/apps/openebs-system/openebs/values.yaml`, `longhorn-system/longhorn/values.yaml`
- DNS: `kubernetes/apps/network/external-dns/values.yaml`, `k8s-gateway/values.yaml`
- Observability: `kubernetes/apps/observability/grafana/values.yaml`, `prometheus-redis-exporter/`
- Cert: `kubernetes/apps/cert-manager/cert-manager/values.yaml`

**Impact:** Nodes can be starved; misconfigured workload can crash cluster
**Fix approach:** Define minimum CPU (5-50m), memory (32-256Mi) requests; limits 2-4x requests for headroom

## Missing Health Checks

**73 of 75 apps lack probes:**
Missing `livenessProbe`, `readinessProbe`, or `startupProbe` in:
- `kubernetes/apps/adventurelog/adventurelog/values.yaml`
- `kubernetes/apps/audiobookshelf/audiobookshelf/values.yaml`
- `kubernetes/apps/calibre-web-automated/calibre-web-automated/values.yaml`
- `kubernetes/apps/argo-system/argo-cd/values.yaml` (critical: ArgoCD itself)
- `kubernetes/apps/gluetun-proxy/gluetun-proxy/values.yaml`
- `kubernetes/apps/garage/webui/values.yaml`
- All `network/external-dns*` apps
- `kubernetes/apps/observability/grafana/values.yaml`
- Full list: 70+ additional apps

**Impact:** Failed pods don't restart; ArgoCD outages not auto-recovered; zombie containers serve traffic
**Fix approach:** Add HTTP readiness probes (first), exec/TCP probes for non-HTTP apps

## Missing PodDisruptionBudgets

**Issue:** Zero PDBs defined across entire cluster
- Files: None found in `kubernetes/apps/`
- Impact: Node drains, cluster upgrades kill all replicas of apps with single instance; data loss potential

**Affected stateful workloads:**
- `postgres-17-cluster` (3 replicas, but PDB would enforce minimum)
- `longhorn-system/longhorn` (distributed storage controller)
- Any multi-instance app without PDB guarantees

**Fix approach:** Add PDB minAvailable:1 for all StatefulSets and replicated Deployments

## Orphaned App Directories

**Issue:** Applications with values.yaml deployed but no ArgoCD Application manifest:**
- `kubernetes/apps/adventurelog/postgres/` — Postgres DB component
- `kubernetes/apps/copyparty/copyparty/` — App dir exists, no ArgoCD sync
- `kubernetes/apps/garage/webui/` — UI component deployed but not managed
- `kubernetes/apps/immich/postgres/` — Postgres component (should use central PG, see ARCHITECTURE)
- `kubernetes/apps/observability/decommissioned-empty/` — Stale directory, cleanup needed

**Impact:** Drift possible; manual kubectl applies not tracked; Renovate can't auto-update versions
**Fix approach:** Either create ArgoCD Application manifests or delete orphaned dirs

## Chart Version Pins

**Issue:** App-template chart frozen at v5.0.0 across ~40 apps
- Examples: `jotty.yaml`, `pgadmin.yaml`, `pcab.yaml`, `audiobookshelf.yaml`, `jellyfin.yaml`, `homeassistant.yaml`, `esphome.yaml`, `immich.yaml`, `authelia.yaml`, `umami.yaml`, `shlink.yaml`
- Files: Multiple in `kubernetes/argo/apps/*/`

**Impact:** Security patches, bug fixes, feature improvements not applied; Renovate may be auto-updating container images without chart bumps
**Fix approach:** Monitor app-template releases; test v6.0.0+ (if available); consider auto-update via Renovate with pre-merge hooks

**Other pinned versions:**
- `plugin-barman-cloud.yaml`: targetRevision `0.6.0` (check if updates available)
- `longhorn.yaml`: `1.11.2` (check recent commits for newer versions)
- `cloudnative-pg.yaml`: `0.28.0` (PostgreSQL operator, verify current version)

## Documentation Drift

**README.md vs Actual State:**
- Describes generic "cluster template" setup process but actual repo is heavily customized (no `config.sample.yaml` mentioned in CLAUDE.md as critical for init)
- No mention of private apps or `.private/` directory structure
- Chart repo change (`ghcr.io/bjw-s-labs/helm`) documented but not all apps verified to use it
- Setup stages outdated; actual workflow uses pre-configured state

**CLAUDE.md Coverage Gaps:**
- No mention of handling apps needing init containers (PG provisioning pattern) in "Creating New Applications"
- Valkey singleton pattern not documented; future maintainers may add HA incorrectly
- No guidance on sync-wave ordering for multi-app deployments
- Missing note about allowing `allowEmpty: true` on certain apps (jotty, pgadmin, postgres, plugin-barman-cloud use it)

**Impact:** New contributors follow outdated guidance; manual steps repeated
**Fix approach:** Update README with actual init workflow; add Valkey/Postgres HA caveats to CLAUDE.md; document init-container pattern

## Ingress Configuration Consistency

**Issue:** All apps using `laboratory.casa` domain and `internal` className (correct pattern verified), but:
- No `external` className apps found; no dual ingress (internal/external) apps
- No validation that cert-manager is issuing TLS for all ingress hosts
- No gap found but fragility: if cert-manager fails, all HTTPS fails silently

**Files:** Scattered in `kubernetes/apps/*/*/values.yaml` ingress blocks
**Fix approach:** Add cert-manager PDB; monitor certificate expiry; test ingress failover

## SOPS Encryption Status

**All `.sops.yaml` files properly encrypted:**
- Verified: `kubernetes/bootstrap/talos/talsecret.sops.yaml`, `garage-secret.sops.yaml`, `homeassistant/secrets.sops.yaml`
- No unencrypted plaintext secrets found in git
- `.sops.yaml` config present and valid

**No .env files in repo** (good security posture)

**Risk:** SOPS key rotation not visible in codebase; unclear if AGE key/PGP key backed up

## Stale/Decommissioned Components

**Directory:** `kubernetes/apps/observability/decommissioned-empty/`
- Issue: Empty placeholder directory, no ArgoCD manifest, clutters namespace list
- Files: Directory exists with no content or value
- Fix approach: Delete directory; document removed apps in git history if needed

## Deprecated Kubernetes APIs

**Checked for v1beta1, v2alpha, extensions/v1beta:**
- No deprecated Ingress, Deployment, or StatefulSet APIs found
- Kustomize v1beta1 used throughout (standard and current)
- No deprecated extensions/v1beta APIs detected

**Status:** API surface current for Kubernetes 1.27+

---

*Concerns audit: 2026-05-08*
