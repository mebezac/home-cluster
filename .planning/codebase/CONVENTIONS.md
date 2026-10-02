# Coding Conventions

**Analysis Date:** 2026-05-08

## Manifest Patterns

**File Organization:**
- Application manifests organized under `kubernetes/apps/<namespace>/<app-name>/`
- Helm values stored in `values.yaml` per application
- Secret files use `.sops.yaml` extension (SOPS-encrypted)
- Kustomization files at `kustomization.yaml` alongside secrets
- Secret generators at `secret-generator.yaml` in application directory

**Naming Conventions:**
- Namespace and application share the same name (e.g., app `lubelog` → namespace `lubelog`)
- ArgoCD Application resources stored in `kubernetes/argo/apps/<namespace>/<app-name>.yaml`
- Multi-component apps (e.g., Garage: garage + webui) have separate subdirectories with individual Helm releases
- Secret files named descriptively: `<app>-secret.sops.yaml`, `<app-initdb-secret.sops.yaml>`, etc.

## Helm Configuration

**Chart Repository Pattern:**
- Primary: `ghcr.io/bjw-s-labs/helm` for `app-template` chart
- Bitnami: `registry-1.docker.io/bitnamicharts`
- Prometheus Community: `oci://ghcr.io/prometheus-community/charts`

**Chart Pinning:**
- Chart versions explicitly pinned in ArgoCD Application definitions (e.g., `targetRevision: 5.0.0`)
- Container images pinned with both tag AND sha256 digest: `tag: 1.1.0@sha256:17c793551873155065bf9a022dabcde874de808a1f26e648d4b82e168806439c`
  - ALWAYS use a concrete version-number tag (e.g. `3.1.2`), NEVER `latest`. `latest` defeats Renovate version tracking and makes rollbacks ambiguous. Only fall back to `latest@sha256:...` when an image publishes no versioned tags at all (rare).
- Renovate auto-updates both helm charts and container images

**Values File Pattern:**
- Values stored as `values.yaml` referenced via `$<app>-repo` reference in ArgoCD sources
- Routing configured under the top-level `route.<identifier>` key (Gateway API HTTPRoute; never Ingress) with standardized keys:
  - `hostnames[]`: Always `<subdomain>.laboratory.casa`
  - `parentRefs`: `envoy-internal` (LAN) or `envoy-external` (internet) in namespace `network`, `sectionName: https`
  - `rules[].backendRefs[].identifier`: Service key (often `app`)
  - `rules[].backendRefs[].port`: Port name (often `http`)
- Charts with their own Gateway API values use those with the same parentRefs: argo-cd `server.httproute`, longhorn `httproute`, grafana `route.main`, victoria `route`

Example route pattern:
```yaml
route:
  app:
    hostnames:
      - <sub>.laboratory.casa
    parentRefs:
      - name: envoy-internal
        namespace: network
        sectionName: https
    rules:
      - backendRefs:
          - identifier: app
            port: http
```

## Secret Handling

**CRITICAL Rules (from CLAUDE.md, enforced in `.sops.yaml` files):**
- Never commit unencrypted secrets; `.sops.yaml` files contain SOPS-encrypted content only
- All secrets use `stringData:` block (NOT `data:`)
- Secret resources MUST NOT have `type: Opaque` field — omit type entirely
- Renovate ignores SOPS files via `ignorePaths: ["**/*.sops.*"]` in renovate.json5

**Secret Generator Pattern** (`kubernetes/apps/<app>/secret-generator.yaml`):
```yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: <app>-secret-generator
  annotations:
    config.kubernetes.io/function: |
      exec:
        path: ksops
files:
  - ./<secret-file>.sops.yaml
  - ./another-secret.sops.yaml  # Multiple secrets supported
```

**Kustomization Pattern** (`kubernetes/apps/<app>/kustomization.yaml`):
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
generators:
  - secret-generator.yaml
```

**Example SOPS Secret File Header** (content encrypted):
```yaml
kind: Secret
metadata:
  name: <app>-secret
  namespace: <app>
data:
  # Encrypted content below
sops:
  kms: []
  gcp_kms: []
  azure_kv: []
  hc_vault: []
  aws_kms: []
  lastmodified: "2026-05-08T..."
  encrypted_regex: ^(data|stringData)$
```

**Secrets NOT created via ksops** (applied directly):
- CloudNative-PG: Uses ksops for database credentials
- Init containers: Reference centralized database provisioning secrets
- Private registry access: GHCR secrets for image pull

## Security Context & User Policies

**Default Run-As User:**
- Run pods as user `3000` where possible (non-root least privilege)
- Examples:
  - `kubernetes/apps/jotty/jotty/values.yaml`: `runAsUser: 3000`
  - `kubernetes/apps/database/pgadmin/values.yaml`: `runAsUser: 3000`
  - `kubernetes/apps/pcab/pcab/values.yaml`: `runAsUser: 3000`
- Some apps override with service-specific user (e.g., Garage uses `568` for storage permissions)

**Security Context Pattern:**
```yaml
defaultPodOptions:
  securityContext:
    runAsUser: 3000
    fsGroup: 3000
    fsGroupChangePolicy: "OnRootMismatch"
```

## Route Domain & External Access

**Base Domain:** `laboratory.casa`

**Gateways (namespace `network`, GatewayClass `envoy`):**
- `envoy-internal` (10.25.30.117): LAN only (e.g., pgadmin, longhorn dashboard); k8s-gateway answers LAN DNS for attached route hostnames
- `envoy-external`: Internet-exposed via the cloudflared tunnels (e.g., jotty, pcab, jellyfin, audiobookshelf)
- Never attach one route to both Gateways

**External DNS Pattern:**
Routes on `envoy-external` need NO annotations: external-dns reads the CNAME target (`external.laboratory.casa`) from the Gateway. heremag.free / zac.pizza hosts need manual CNAMEs in `cloudflared-{heremag-free,zac-pizza}/config/dnsendpoint.sops.yaml`.

**Authelia:** add `labels: { auth: authelia }` to the route.

No manual TLS configuration — the Gateways terminate TLS with cert-manager wildcard certs from `network`; no timeout/body-size config is needed (gateway-wide policy).

**ArgoCD diff:** ServerSideDiff is enabled globally (`controller.diff.server.side` in argo-cd values), so no per-app annotation is needed.

## ArgoCD Application Pattern

**Standard Application Definition** (`kubernetes/argo/apps/<app>.yaml`):
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app>
  namespace: argo-system
  annotations:
    argocd.argoproj.io/sync-wave: "0"  # Deployment order
spec:
  project: kubernetes  # Fixed project
  sources:
    - repoURL: https://github.com/mebezac/home-cluster.git
      path: kubernetes/apps/<app>/<app>
      targetRevision: main
      ref: <app>-repo
    - repoURL: <helm-chart-repo>
      chart: <chart-name>
      targetRevision: <pinned-version>
      helm:
        releaseName: <app>
        valueFiles:
          - $<app>-repo/kubernetes/apps/<app>/<app>/values.yaml
  destination:
    name: in-cluster
    namespace: <app>
  syncPolicy:
    automated:
      allowEmpty: true
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true  # Auto-create namespace
```

**Sync Waves:** Ordered deployment using `argocd.argoproj.io/sync-wave: "0"` / `"1"` / etc.

**Multi-Component Apps:**
- List each component as separate source block in `spec.sources`
- Each component gets own `releaseName` (e.g., `garage` and `garage-webui`)
- Shared namespace via single `destination`

## Formatting & Whitespace

**EditorConfig** (`.editorconfig`):
- Indent: 2 spaces (YAML, JSON)
- Indent: 4 spaces (bash, python, shell scripts)
- Line endings: LF
- Charset: UTF-8
- Trim trailing whitespace
- Insert final newline

**No Linting Tool Configured:**
- No `.yamllint`, `.prettier`, or similar enforcement file present
- Conventions rely on manual adherence and code review
- Renovate handles dependency updates (not code style)

## Commit Message Conventions

**Semantic Commits via Renovate** (`.github/renovate.json5`):

**Format:** `<type>(<scope>): <subject> ( <version-from> → <version-to> )`

**Types by Dependency:**
- Docker images:
  - `feat(container)`: Minor updates
  - `fix(container)`: Patch updates
  - `chore(container)`: Digest-only updates
  - `feat(container)!:`: Major updates (breaking)
- Helm charts:
  - `feat(helm)`: Minor updates
  - `fix(helm)`: Patch updates
  - `feat(helm)!:`: Major updates
- GitHub Actions:
  - `feat(github-action)`: Minor
  - `fix(github-action)`: Patch
  - `feat(github-action)!:`: Major
- GitHub Releases:
  - `feat(github-release)`: Minor
  - `fix(github-release)`: Patch
  - `feat(github-release)!:`: Major

**Examples:**
- `feat(container): update ghcr.io/home-assistant/home-assistant ( 2026.4.4 → 2026.5.0 )`
- `fix(helm): update longhorn ( 1.11.1 → 1.11.2 )`
- `feat(github-action): update actions/checkout ( v3 → v4 )`

**Automerge Behavior:**
- GitHub Actions: Auto-merge minor & patch (no tests required)
- Manual review: Major versions, helm charts, container updates

## Database & Centralized Services

**Central PostgreSQL:**
- Apps provision individual databases via init containers
- Connection credentials stored in app-specific secrets
- Example: `kubernetes/apps/database/postgres-17-cluster/`

**Central Redis (Valkey):**
- Single cluster deployment as dependency
- Apps reference via service hostname: `valkey.<namespace>.svc.cluster.local`

**Barman Backup Configuration:**
- S3 storage via Garage: `kubernetes/apps/database/postgres-17-cluster/barman-object-store.yaml`
- S3 endpoint: `https://garage-tc.laboratory.casa`

---

*Convention analysis: 2026-05-08*
