# Codebase Structure

**Analysis Date:** 2026-05-08

## Directory Layout

```
home-cluster/
├── kubernetes/
│   ├── argo/                    # ArgoCD configuration (root app + individual apps)
│   │   ├── apps.yaml            # Root app-of-apps discovering kubernetes/argo/apps/**
│   │   ├── apps/                # Individual application manifests
│   │   │   ├── <namespace>/
│   │   │   │   └── <app>.yaml   # Single ArgoCD Application per app
│   │   │   ├── database/        # Database apps (postgres, pgadmin, etc)
│   │   │   ├── kube-system/     # System components (cilium, coredns, etc)
│   │   │   ├── argo-system/     # ArgoCD itself
│   │   │   └── ...              # 39+ app namespaces total
│   │   ├── repositories.yaml    # Helm/OCI repository credentials
│   │   └── settings.yaml        # ArgoCD global settings
│   │
│   ├── apps/                    # Application configurations (values + secrets)
│   │   ├── <namespace>/
│   │   │   └── <app>/           # Per-app directory
│   │   │       ├── values.yaml  # Helm chart values
│   │   │       ├── kustomization.yaml  # Kustomize base (if secrets)
│   │   │       ├── secret-generator.yaml  # ksops generator (if secrets)
│   │   │       └── *.sops.yaml  # SOPS-encrypted secrets (if needed)
│   │   ├── lubelog/             # Single-component app example
│   │   │   └── lubelog/
│   │   │       ├── values.yaml
│   │   │       ├── kustomization.yaml
│   │   │       ├── secret-generator.yaml
│   │   │       └── lubelog-secret.sops.yaml
│   │   ├── immich/              # Multi-component app example
│   │   │   ├── immich/          # App component
│   │   │   │   ├── values.yaml
│   │   │   │   └── ...
│   │   │   └── postgres/        # Database component
│   │   │       ├── values.yaml
│   │   │       └── ...
│   │   ├── database/            # Shared database infrastructure
│   │   │   ├── postgres-17-cluster/  # Central PostgreSQL (Kustomize-based)
│   │   │   ├── cloudnative-pg/
│   │   │   └── pgadmin/
│   │   └── ... (39+ app namespaces)
│   │
│   └── bootstrap/               # Cluster initialization
│       ├── helmfile.yaml        # Helmfile for bootstrap Helm releases
│       └── talos/               # Talos OS cluster configuration
│           ├── talconfig.yaml   # Talos cluster definition
│           ├── talsecret.sops.yaml
│           ├── clusterconfig/   # Generated Talos machine configs
│           └── patches/         # Talos machine patches
│
└── ... (other project files: scripts, docs, CI/CD config)
```

## Directory Purposes

**kubernetes/argo/:**
- Purpose: ArgoCD configuration and application discovery
- Contains: Application manifests (YAML), repository configuration, ArgoCD settings
- Key files: `apps.yaml` (root app), individual `<app>.yaml` per application

**kubernetes/argo/apps/:**
- Purpose: Individual ArgoCD Application resources, organized by namespace
- Contains: Application manifests defining sources, chart references, sync policy
- Key subdirectories: `database/`, `kube-system/`, `argo-system/`, and 36+ app namespaces

**kubernetes/apps/:**
- Purpose: Application-specific configuration and secrets
- Contains: Helm values, secret generators, encrypted SOPS files, Kustomization bases
- Key subdirectories: One per namespace (lubelog, immich, mealie, etc.), and supporting infrastructure

**kubernetes/bootstrap/:**
- Purpose: One-time cluster initialization
- Contains: Helmfile for bootstrap infrastructure installation, Talos OS configuration
- Key files: `helmfile.yaml` (installs Cilium, CoreDNS, ArgoCD, Prometheus CRDs)

**kubernetes/bootstrap/talos/:**
- Purpose: Talos OS cluster definition
- Contains: Talos configuration, machine configs, encrypted secrets
- Key files: `talconfig.yaml` (cluster definition), generated `clusterconfig/` machine files

## Key File Locations

**Entry Points:**
- `kubernetes/argo/apps.yaml`: Root ArgoCD Application (app-of-apps pattern)
- `kubernetes/bootstrap/helmfile.yaml`: Cluster bootstrap via Helmfile

**Configuration:**
- `kubernetes/argo/repositories.yaml`: Helm/OCI repository credentials
- `kubernetes/argo/settings.yaml`: ArgoCD global configuration
- `kubernetes/bootstrap/talos/talconfig.yaml`: Talos OS cluster definition

**Core Logic:**
- `kubernetes/argo/apps/<namespace>/<app>.yaml`: Per-app ArgoCD Application (multi-source references)
- `kubernetes/apps/<namespace>/<app>/values.yaml`: Helm chart values for each app

**Secrets:**
- `kubernetes/apps/<namespace>/<app>/secret-generator.yaml`: ksops secret generation
- `kubernetes/apps/<namespace>/<app>/*.sops.yaml`: SOPS-encrypted secrets (46 apps)

## Naming Conventions

**Files:**

| Pattern | Example | Purpose |
|---------|---------|---------|
| `<app>.yaml` | `lubelog.yaml`, `immich.yaml` | ArgoCD Application manifest |
| `values.yaml` | `kubernetes/apps/lubelog/lubelog/values.yaml` | Helm chart values |
| `secret-generator.yaml` | In 46 app directories | ksops Kustomize generator |
| `<app>-secret.sops.yaml` | `lubelog-secret.sops.yaml` | SOPS-encrypted secrets |
| `kustomization.yaml` | In 61 app directories | Kustomize configuration with secret generators |
| `talconfig.yaml` | Talos cluster definition | Talos OS configuration |

**Directories:**

| Pattern | Example | Purpose |
|---------|---------|---------|
| `<namespace>/` | `lubelog/`, `immich/`, `database/` | Kubernetes namespace grouping |
| `<app>/` | `kubernetes/apps/lubelog/lubelog/` | Per-app Helm values and secrets |
| `<app>/postgres/` | `kubernetes/apps/immich/postgres/` | Component subdirectory (multi-component apps) |

## Where to Add New Code

**New Feature (App):**
- Primary code: `kubernetes/apps/<new-app>/<new-app>/values.yaml`
- Manifest: `kubernetes/argo/apps/<namespace>/<new-app>.yaml`
- Secrets: `kubernetes/apps/<new-app>/<new-app>/secret-generator.yaml` + `<new-app>-secret.sops.yaml`
- Pattern: Use bjw-s app-template chart; follow lubelog/immich pattern

**New Component (Multi-App):**
- Implementation: Create subdirectory in `kubernetes/apps/<app>/`
- Add to ArgoCD manifest: New source in `kubernetes/argo/apps/<namespace>/<app>.yaml`
- Pattern: Follow immich pattern (multiple sources, same Application resource)

**Infrastructure Changes:**
- Cluster-level: `kubernetes/bootstrap/helmfile.yaml`
- Cluster config: `kubernetes/bootstrap/talos/talconfig.yaml`

**Shared Database:**
- Central PostgreSQL: `kubernetes/apps/database/postgres-17-cluster/`
- App DB provisioning: Use init-container (see `kubernetes/apps/lubelog/lubelog/values.yaml` line 14-21)

**Shared Cache:**
- Central Valkey: Located in `kubernetes/apps/` (Redis-equivalent for caching)
- App integration: Connect via service DNS `valkey.valkey.svc.cluster.local:6379`

## Special Directories

**kubernetes/argo/apps/ (61 Kustomization.yaml files):**
- Purpose: Enable secret injection via Kustomize generators
- Generated: Kustomization creates merged resources with SOPS decryption
- Committed: Both kustomization.yaml and *.sops.yaml committed; secrets decrypted at sync time

**kubernetes/bootstrap/talos/clusterconfig/:**
- Purpose: Generated Talos machine configuration files
- Generated: By talosctl from talconfig.yaml
- Committed: Generally not committed; regenerated per deployment

**kubernetes/apps/database/:**
- Purpose: Centralized database infrastructure (PostgreSQL 17, pgAdmin, plugins)
- Deployed first: Sync-wave "0" ensures ready before dependent apps
- Shared by: 20+ apps requiring database access

---

*Structure analysis: 2026-05-08*
