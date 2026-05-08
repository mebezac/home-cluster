# Technology Stack

**Analysis Date:** 2026-05-08

## Languages

**Primary:**
- YAML - Kubernetes manifests, Helm values, ArgoCD applications

**Secondary:**
- Python 3.14.4 - Task automation and scripting via `.mise.toml`
- Shell - Task files and bootstrap scripts

## Runtime

**Environment:**
- Kubernetes (self-hosted, Talos-based cluster)
- Talos 1.13.0 - OS layer for worker nodes

**Container Orchestration:**
- Kubernetes 1.32.2 (kubectl)
- ArgoCD 3.4.0 - GitOps deployment controller

## Frameworks & Core Components

**Kubernetes Infrastructure:**
- Cilium 1.18.4 - CNI/networking
- CoreDNS 1.45.2 - In-cluster DNS
- Ingress NGINX 4.15.1 - Dual ingress controllers (`internal`, `external`)
- Cert-Manager (Jetstack) - TLS certificate management
- External DNS 1.21.1 - DNS record synchronization

**Storage:**
- Longhorn 1.11.2 - Block storage provisioning
- OpenEBS - Storage abstraction (hostpath provisioner)
- CloudNative-PG - PostgreSQL operator for database management
- Garage - S3-compatible object storage

**Observability Stack:**
- Prometheus Operator 28.0.1 (CRDs)
- Victoria Metrics - Time-series metrics storage
- Grafana - Metrics visualization
- Prometheus Redis Exporter 6.23.0

**Networking & Security:**
- Cilium - Service mesh capabilities
- Tailscale Operator - VPN mesh access
- K8s Gateway - Gateway API implementation
- External Service Ingresses - Remote service exposure

**Utility & Automation:**
- Reloader (Stakater) - Pod restarter for config changes
- Spegel - Registry mirror/cache
- Reflector - Secret/ConfigMap sync across namespaces
- Node Feature Discovery - Hardware capability detection
- Metrics Server - Resource metrics provider

## Package Manager

**Tool:** Aqua + ASDF
- Aqua 1.0+ - Tool version management
- ASDF 0.11+ - Polyglot version management
- ksops 4.3.3 - Kustomize SOPS integration (ASDF)

## Configuration Management

**Helm:**
- Version: 4.1.4
- Helmfile: 1.5.0 - Multi-chart orchestration
- Template defaults at `kubernetes/bootstrap/helmfile.yaml`

**Kustomize:**
- Version: 5.6.0
- Used within ArgoCD applications for patch/overlay management

**Secret Encryption:**
- SOPS 3.12.2 - Encryption tool
- Age 1.3.1 - Encryption backend
- Key file: `age.key` (loaded via SOPS_AGE_KEY_FILE env var from `.mise.toml`)
- Encryption rules: `kubernetes/` YAML files encrypt `data`/`stringData` fields only via `.sops.yaml`

## Helm Chart Repositories

**Public:**
- `ghcr.io/bjw-s-labs/helm` - BJW-S app-template (primary app chart)
- `ghcr.io/prometheus-community/charts` - Prometheus/observability
- `ghcr.io/grafana/helm-charts` - Grafana
- `https://charts.jetstack.io` - Cert-Manager
- `https://charts.longhorn.io/` - Longhorn
- `https://cloudnative-pg.github.io/charts` - CloudNative-PG
- `https://helm.cilium.io` - Cilium
- `https://kubernetes.github.io/ingress-nginx` - Ingress NGINX
- `https://kubernetes-sigs.github.io/external-dns` - External DNS
- `https://kubernetes-sigs.github.io/metrics-server` - Metrics Server
- `https://kubernetes-sigs.github.io/node-feature-discovery/charts` - NFD
- `https://openebs.github.io/openebs` - OpenEBS
- `https://ori-edge.github.io/k8s_gateway` - K8s Gateway
- `https://stakater.github.io/stakater-charts` - Stakater (reloader, reflector)
- `https://victoriametrics.github.io/helm-charts` - Victoria Metrics
- `https://pkgs.tailscale.com/helmcharts` - Tailscale Operator
- `https://piraeus.io/helm-charts/` - LINSTOR
- `https://intel.github.io/helm-charts` - Intel GPU plugins
- `https://coredns.github.io/helm` - CoreDNS
- `https://kubernetes.github.io/ingress-nginx` - Ingress NGINX
- `https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/charts` - SMB CSI

**Custom:**
- `https://zac.pizza/helm-charts` - Custom organizational charts
- `https://zac.pizza/democratic-csi-charts/` - Democratic-CSI variants
- `https://github.com/mebezac/home-cluster.git` - Local chart values (via `ref:` in ArgoCD sources)
- `https://github.com/mebezac/home-cluster-private.git` - Private app values

## Application Stack

**Database:**
- PostgreSQL 18.3 - Central database with CloudNative-PG operator
- Barman Cloud - WAL archival to S3 via Garage

**Data Layer:**
- Valkey (Redis-compatible) - Central caching layer at `valkey.valkey.svc.cluster.local`
- Garage S3-compatible storage - Object store with WAL archival

**Observability & Logging:**
- Victoria Logs - Log aggregation
- Prometheus - Metrics collection
- Grafana - Visualization

**Applications Deployed (153 total via ArgoCD):**
- Home Assistant ecosystem (zigbee2mqtt, esphome, zwave-js-ui, mosquitto)
- Jellyfin + Pinchflat - Media streaming
- Immich - Photo management
- Mealie - Recipe management
- Lubelog - Vehicle maintenance
- Audiobookshelf - Audiobook server
- Changedetection - Web monitoring
- Lychee - Photo gallery
- Jotty - Notes
- N8N - Automation/workflows
- Music Assistant
- Homeassistant Integrations
- Calibre Web Automated
- Copyparty - File sharing
- AdventureLog

## Development Tools

**Installed via `.mise.toml`:**
- Task 3.50.0 - Task runner (`.taskfiles/`)
- K9s 0.50.18 - Kubernetes CLI UI
- Kubectl 1.32.2 - Kubernetes CLI
- Kustomize 5.6.0 - YAML patching
- Helm 4.1.4 - Chart management
- Helmfile 1.5.0 - Multi-chart orchestration
- ArgoCD CLI 3.4.0 - GitOps management
- SOPS 3.12.2 - Secret encryption
- Age 1.3.1 - Encryption backend
- Talhelper 3.1.9 - Talos cluster config generator
- Cloudflared 2026.3.0 - Cloudflare Tunnel client
- YQ 4.53.3 - YAML processor
- JQ 1.7.1 - JSON processor
- Kubeconform 0.7.0 - Kubernetes manifest validation

**Python Environment:**
- uv 0.11.9 - Fast Python package installer
- requirements.txt - Python dependencies (via Task: `task deps`)

## CI/CD

**GitHub Actions:**
- Labeler - Automated PR labeling (`.github/workflows/labeler.yaml`)
- Label Sync - Maintain label schema (`.github/workflows/label-sync.yaml`)
- Release workflow - Automated releases (`.github/workflows/release.yaml`)

**No Renovate detected** - Manual dependency updates via ArgoCD Application manifests

## Networking Configuration

**DNS:**
- Primary domain: `laboratory.casa` (internal network)
- Secondary domain: `zac.pizza` (external via Cloudflare)
- External DNS targets Cloudflare for `laboratory.casa` subdomain delegation

**TLS:**
- Default certificate: `network/laboratory-casa-production-tls` (ingress-nginx config)
- Cert-Manager issues Let's Encrypt certificates
- Cloudflare tunnel for external access

**Ingress Classes:**
- `internal` - Tailscale-exposed, nginx controller
- `external` - Cloudflare-proxied, nginx controller

## Secrets Management

**Encryption:**
- Tool: SOPS with Age encryption
- Config: `.sops.yaml` - Age public key for encryption
- Key file: `.sops/age.key` (git-ignored, user-managed)
- Files: `*.sops.yaml` pattern within `kubernetes/`
- Only `data` and `stringData` fields encrypted (not metadata)

**Example structure:**
```
kubernetes/apps/<namespace>/<app>/
├── secret-generator.yaml      # ksops configuration
├── kustomization.yaml          # Kustomize definition
└── <secret-name>.sops.yaml     # Encrypted YAML
```

**ArgoCD Access:**
- Git auth via GitHub SSH (stored as `kubernetes/argo/repositories/github.yaml`)

---

*Stack analysis: 2026-05-08*
