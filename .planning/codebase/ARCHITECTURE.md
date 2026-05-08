<!-- refreshed: 2026-05-08 -->
# Architecture

**Analysis Date:** 2026-05-08

## System Overview

```text
┌────────────────────────────────────────────────────────────────────┐
│              ArgoCD App-of-Apps Bootstrap                          │
│              `kubernetes/argo/apps.yaml`                           │
└──────────────────────────────┬───────────────────────────────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
        ▼                      ▼                      ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│ Cluster Infra│     │   Database   │     │ Applications │
│ kube-system  │     │  postgres    │     │   immich,    │
│ cert-manager │     │   valkey     │     │  mealie,etc  │
└──────────────┘     └──────────────┘     └──────────────┘
        │                      │                      │
        └──────────────────────┼──────────────────────┘
                               │
        ┌──────────────────────┴──────────────────────┐
        │                                             │
        ▼                                             ▼
┌──────────────────────────┐         ┌─────────────────────────────┐
│  Helm app-template 5.0.0 │         │  SOPS Encrypted Secrets     │
│  ghcr.io/bjw-s-labs/helm │         │  kubernetes/apps/*/*/       │
│                          │         │  *.sops.yaml                │
└──────────────────────────┘         └─────────────────────────────┘
```

## Component Responsibilities

| Component | Responsibility | File |
|-----------|----------------|------|
| App-of-Apps | Root ArgoCD Application that discovers and syncs all apps | `kubernetes/argo/apps.yaml` |
| App Manifests | Individual ArgoCD Application resources for each app | `kubernetes/argo/apps/<namespace>/<app>.yaml` |
| Helm Values | Chart configuration per application | `kubernetes/apps/<namespace>/<app>/values.yaml` |
| Secret Generation | ksops/Kustomize secret management | `kubernetes/apps/<namespace>/<app>/secret-generator.yaml` |
| SOPS Secrets | Encrypted secret files | `kubernetes/apps/<namespace>/<app>/*.sops.yaml` |
| Bootstrap | Initial cluster setup, Helm install sequence | `kubernetes/bootstrap/helmfile.yaml` |
| Talos Config | Talos OS cluster configuration | `kubernetes/bootstrap/talos/talconfig.yaml` |

## Pattern Overview

**Overall:** App-of-Apps with multi-source Helm deployments

**Key Characteristics:**
- Root Application at `kubernetes/argo/apps.yaml` uses `directory.recurse: true` to auto-discover all apps in `kubernetes/argo/apps/`
- Each app is a separate ArgoCD Application manifesting as `<app-name>.yaml` 
- Multi-source applications pull Helm charts from registries (e.g., `ghcr.io/bjw-s-labs/helm`) and values from git
- Secrets encrypted with SOPS, decrypted by ksops during Kustomize generation
- Init-containers provision databases from central PostgreSQL cluster
- Sync waves control deployment order (all currently `"0"` for parallel sync)

## Layers

**Bootstrap Layer (kubernetes/bootstrap/):**
- Purpose: Initial cluster provisioning via Helmfile, Talos OS configuration
- Location: `kubernetes/bootstrap/helmfile.yaml`, `kubernetes/bootstrap/talos/talconfig.yaml`
- Contains: Helmfile releases for infrastructure (Cilium, CoreDNS, ArgoCD, CRDs)
- Depends on: Helm repositories, cluster network configuration
- Used by: One-time cluster initialization

**ArgoCD Layer (kubernetes/argo/):**
- Purpose: Declarative application management, source of truth for cluster state
- Location: `kubernetes/argo/apps.yaml` (root), `kubernetes/argo/apps/<namespace>/*.yaml` (individual apps)
- Contains: Application manifests with multi-source references
- Depends on: Git repository (`https://github.com/mebezac/home-cluster.git`), external Helm registries
- Used by: All deployed workloads

**Application Layer (kubernetes/apps/):**
- Purpose: Application-specific configuration and secrets
- Location: `kubernetes/apps/<namespace>/<app>/`
- Contains: Helm values.yaml, Kustomization with secret generators, SOPS-encrypted secrets
- Depends on: Helm charts from registries, central database/cache services
- Used by: ArgoCD for templating and secret injection

## Data Flow

### Primary Application Deployment

1. ArgoCD reads root app (`kubernetes/argo/apps.yaml`) - discovers all apps via `directory.recurse: true`
2. ArgoCD syncs individual Application manifests (`kubernetes/argo/apps/<namespace>/<app>.yaml`)
3. Application specifies multiple sources:
   - Git source: `kubernetes/apps/<app>/<app>` (values.yaml location)
   - Helm registry source: chart URL and version
4. Kustomize generator runs, decrypts SOPS secrets via ksops
5. Helm template merges chart + values + decrypted secrets
6. Resources deployed to cluster namespace

### Database Initialization Flow

1. Application init-container `postgres-init` starts first
2. Connects to central PostgreSQL (`postgres-17-cluster` in `database` namespace)
3. Queries secrets for database credentials
4. Creates app-specific database if not exists
5. Main application container starts with DB connection string

### Multi-Component Application (Immich Example)

1. Single Application manifest (`kubernetes/argo/apps/immich/immich.yaml`)
2. Four sources defined:
   - `postgres-repo`: `kubernetes/apps/immich/postgres/` + app-template chart → `immich-db` release
   - `immich-repo`: `kubernetes/apps/immich/immich/` + app-template chart → `immich` release
3. Both components deploy to same namespace `immich`

**State Management:**
- Secrets: SOPS-encrypted, managed via ksops in Kustomization
- Configuration: Stored in `values.yaml`, immutable once applied
- Persistent data: Via PersistentVolumeClaims (e.g., Longhorn storage)
- Database state: Central PostgreSQL cluster with per-app databases

## Key Abstractions

**Application Manifest (ArgoCD Application):**
- Purpose: Declarative definition of what to deploy, where, and how to keep it synced
- Examples: `kubernetes/argo/apps/immich/immich.yaml`, `kubernetes/argo/apps/lubelog/lubelog.yaml`
- Pattern: Multi-source with git + Helm registry, valueFiles reference pattern `$<ref>/path/to/values.yaml`

**Values File (Helm Configuration):**
- Purpose: Chart-agnostic application configuration
- Examples: `kubernetes/apps/lubelog/lubelog/values.yaml`, `kubernetes/apps/immich/immich/values.yaml`
- Pattern: Uses bjw-s app-template spec (image, service, ingress, persistence, security context, resources)

**Secret Generator (ksops):**
- Purpose: Declarative secret provisioning with Kustomize integration
- Examples: 46 apps with `secret-generator.yaml` + `*.sops.yaml` pairs
- Pattern: Viaduct.ai ksops kind with `files:` list pointing to SOPS-encrypted YAML files

## Entry Points

**Root App-of-Apps:**
- Location: `kubernetes/argo/apps.yaml`
- Triggers: Git push to `main` branch, manual ArgoCD sync
- Responsibilities: Discover all applications via directory recursion, sync all apps in cluster

**Individual Application:**
- Location: `kubernetes/argo/apps/<namespace>/<app>.yaml`
- Triggers: Auto-sync via `automated.selfHeal: true`
- Responsibilities: Fetch Helm chart, merge values, decrypt secrets, apply manifests

**Bootstrap Entry:**
- Location: `kubernetes/bootstrap/helmfile.yaml`
- Triggers: Manual `helmfile sync` during cluster initialization
- Responsibilities: Install cluster infrastructure (Cilium, CoreDNS, ArgoCD, Prometheus CRDs)

## Architectural Constraints

- **Threading:** Single-threaded ArgoCD controller orchestration; Helm rendering sequential per application
- **Global state:** Central PostgreSQL cluster (`postgres-17-cluster`) shared across all apps needing databases
- **Global state:** Central Valkey deployment for caching/session storage across apps
- **Circular imports:** None detected; dependency ordering via sync-waves and init-containers
- **Namespace isolation:** Each app deploys to its own namespace (name == app name unless overridden)
- **Secret handling:** SOPS encryption required for all sensitive data; no unencrypted secrets in git
- **Helm registry:** Single source of truth for app-template: `ghcr.io/bjw-s-labs/helm`, version 5.0.0

## Anti-Patterns

### Hardcoded Database Credentials

**What happens:** Some legacy apps may still have DB credentials in values.yaml instead of secrets
**Why it's wrong:** Exposes credentials in git history, violates least-privilege access
**Do this instead:** Use secret-generator + ksops to inject database URL/credentials from encrypted secrets into Pod env

### Manual Secret Creation

**What happens:** Manually running `kubectl create secret` or `sops` commands instead of declarative generation
**Why it's wrong:** Breaks GitOps principle, secrets not recoverable if lost
**Do this instead:** Create `<app>-secret.sops.yaml`, add to `secret-generator.yaml`, commit encrypted file

### Inline Secrets in Helm Values

**What happens:** Storing API keys or passwords directly in `values.yaml`
**Why it's wrong:** Violates security, not appropriate for git version control
**Do this instead:** Reference secret sources via `secretRef` or `valueFrom.secretKeyRef`

## Error Handling

**Strategy:** ArgoCD reports sync status; applications log errors to stdout (captured by Kubernetes logging)

**Patterns:**
- Pod init-container failures block main container (e.g., `postgres-init` failure prevents app startup)
- Application resource mismatches show in ArgoCD UI with specific error messages
- SOPS decryption failures during Kustomize generation fail Application sync

## Cross-Cutting Concerns

**Logging:** Applications log to stdout; collected by Kubernetes logging sidecar or aggregator (not shown in this architecture)

**Validation:** ArgoCD validates manifests at sync time; Helm chart validation via chart linting rules

**Authentication:** Database access via central PostgreSQL; app credentials stored in SOPS secrets

---

*Architecture analysis: 2026-05-08*
