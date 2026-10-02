# External Integrations

**Analysis Date:** 2026-05-08

## DNS & Domain Management

**Cloudflare:**
- Provider for `laboratory.casa` delegation
- Service: External DNS integration; the `envoy-external` Gateway carries `external-dns.kubernetes.io/target: external.laboratory.casa`, so routes need no annotations
- Config: `kubernetes/apps/network/external-dns/values.yaml`
- Auth: Environment variable `CF_API_TOKEN` (stored as `external-dns-secret`)
- Integration: External-DNS (sources `crd` + `gateway-httproute`, `--gateway-name=envoy-external`) synchronizes HTTPRoute hostnames → Cloudflare DNS
- heremag.free / zac.pizza hostnames are NOT automatic: add manual CNAMEs (to `external.heremag.free` / `external.zac.pizza`) in `kubernetes/apps/network/cloudflared-{heremag-free,zac-pizza}/config/dnsendpoint.sops.yaml`
- Tunnel: Cloudflared 2026.3.0 (3 tunnels) targeting the `envoy-external` Gateway (10.25.30.122) for external HTTP/HTTPS routing
- Config path: `kubernetes/apps/network/cloudflared/` (encrypted: `cloudflared.sops.yaml`, `dnsendpoint.sops.yaml`)

## Certificate Management

**Let's Encrypt (via cert-manager):**
- Provider: ACME HTTP-01 and DNS-01 challenges
- Config: `kubernetes/apps/cert-manager/cert-manager/`
- Issuers: `kubernetes/apps/cert-manager/cert-manager/issuers/` (zac-pizza, laboratory.casa ClusterIssuers)
- TLS certs for the Gateways: wildcard `laboratory-casa-production-tls`, `heremag-free-production-tls`, `zac-pizza-production-tls` in `network` (Certificates in `kubernetes/apps/network/envoy-gateway/certificates/`); terminated at `envoy-internal` / `envoy-external`, no Reflector copying

## Data Storage

**PostgreSQL:**
- Type: Central SQL database (CloudNative-PG operator)
- Version: 18.3-standard-trixie
- Location: `kubernetes/apps/database/postgres-17-cluster/`
- Cluster definition: `postgres-17-cluster.yaml` (3-instance cluster)
- Connection: Services created in `database` namespace
- Access method: Init containers provision per-app databases
- Storage: 16Gi Longhorn single-replica PVC (`longhorn-single-replica` StorageClass)
- Extensions: PostGIS 3.6.2 enabled for spatial queries
- Monitoring: Prometheus PodMonitor enabled
- Backup: Barman Cloud plugin (`plugin-barman-cloud` Helm release) for WAL archival to S3

**Example usage:**
- Lubelog, Jotty, Immich, and other apps use init containers to provision databases
- Connection string pattern: `postgres://app-user:password@postgres-17-cluster.database.svc.cluster.local:5432/app-name`

**S3-Compatible Storage (Garage):**
- Service: Garage 2.3.0 - Distributed object storage
- Location: `kubernetes/apps/garage/garage/`
- Admin endpoint: `garage-admin.garage.svc.cluster.local:3903`
- S3 endpoint: `garage-s3.garage.svc.cluster.local:3900`
- Web UI: `kubernetes/apps/garage/webui/` (khairul169/garage-webui 1.1.0)
- Use: Barman Cloud WAL archival, media storage for applications
- Auth: Secret-based credentials in `garage-secret`

**File Storage:**
- Type: Longhorn volumes (persistent block storage)
- StorageClasses:
  - `longhorn-single-replica` - Database storage
  - `openebs-hostpath` - Local path provisioning (OpenEBS)
- CSI Drivers:
  - SMB CSI - Network file shares (Windows/Samba)
  - Democratic-CSI - Advanced storage management

## Caching & Sessions

**Valkey (Redis-compatible):**
- Service: Valkey cluster at `valkey.valkey.svc.cluster.local`
- Location: `kubernetes/apps/valkey/valkey/`
- Clients: Authelia, and other session-dependent services
- Config: Encrypted in `valkey-conf.sops.yaml`
- Monitoring: Prometheus Redis Exporter 6.23.0 scrapes metrics

## Message Broker

**MQTT (Mosquitto):**
- Service: Mosquitto broker in homeassistant namespace
- Location: `kubernetes/apps/homeassistant/mosquitto/`
- Primary use: Home Assistant integrations (IoT, smart home)
- Port: Standard MQTT (1883) + TLS variant

## Authentication & Authorization

**Authelia:**
- Service: Authentication + authorization gateway
- Location: `kubernetes/apps/security/authelia/`
- Config: `authelia-config.yaml` (encrypted secrets)
- Session backend: Valkey at `valkey.valkey.svc.cluster.local`
- Integration points:
  - Envoy Gateway forward auth: routes labelled `auth: authelia` are checked by a label-selected `authelia` SecurityPolicy in the route's namespace (`network`, private `downloads`)
  - New namespaces need their own SecurityPolicy copy plus an entry in `kubernetes/apps/security/authelia/referencegrant.yaml`, or auth routes fail closed (500)
  - Login portal: `https://login.laboratory.casa`
- Single sign-on: OIDC/LDAP capable (secrets in `authelia-initdb-secret.sops.yaml`)

## Media & Content Services

**Home Assistant Ecosystem:**
- Home Assistant main app + plugins
- Zigbee2MQTT - Zigbee device bridge
- ESPHome - ESP8266/32 firmware management
- Z-Wave JS UI - Z-Wave device control
- Mosquitto - MQTT message broker (coordinator)
- Location: `kubernetes/apps/homeassistant/`

**Jellyfin + Pinchflat:**
- Jellyfin - Media server
- Pinchflat - YouTube downloader integration
- Location: `kubernetes/apps/jellyfin/`

**Immich:**
- Photo/video management system (multi-component)
- Location: `kubernetes/apps/immich/` (microservices: api, server, machine-learning)
- Database: PostgreSQL via init container
- Storage: S3 (Garage) or local PVC

**Media Management:**
- Calibre-Web-Automated - eBook server with auto-sync
- Audiobookshelf - Audiobook server
- Lychee - Photo gallery
- Location: `kubernetes/apps/[app-name]/`

## Automation & Workflows

**N8N:**
- Workflow automation engine
- Location: `kubernetes/apps/n8n/`
- Database: PostgreSQL integration

**Changedetection.io:**
- Web monitoring and change detection
- Location: `kubernetes/apps/changedetection/`
- Browser component: Browserless Chrome 2.48.3 for rendering
- Playwright driver: WebSocket connection to browserless service
- Storage: PostgreSQL for history

## Container Image Repositories

**Sources:**
- `ghcr.io` - GitHub Container Registry (bjw-s, prometheus, grafana, cloudnative-pg, etc.)
- `quay.io` - Red Hat Quay (OpenEBS helpers)
- `docker.io`/`registry-1.docker.io` - Docker Hub (Bitnami, valkey, etc.)
- `khairul169/` - DockerHub (Garage webui)
- `dxflrs/` - DockerHub (Garage)
- `dgtlmoon/` - GitHub (changedetection.io)
- `ghcr.io/browserless/` - GitHub (Browserless Chrome)
- Private registry: `zac.pizza` - Custom charts hosted

**Image pulling:**
- All images pinned to exact digest SHA-256
- No `latest` tags used
- Registry mirror: Spegel for local caching

## External Services & Endpoints

**TrueNAS:**
- External NAS exposed via HTTPRoute
- Domain: `truenas.laboratory.casa`
- Access: External service (non-Kubernetes; Service + EndpointSlice + HTTPRoute)
- Config: `kubernetes/apps/network/external-services/truenas.yaml` (one file per LAN device, listed in its kustomization; also adguard-pi-02/03, zigbee-hub, frigate, garage-tc, garage-tc-console)

**AdGuard Home (Pi instances):**
- Multiple external Pi instances
- Domains: `adguard-pi-02.laboratory.casa`, `adguard-pi-03.laboratory.casa`
- Access: External service (`kubernetes/apps/network/external-services/`)

**Frigate (Camera system):**
- Video surveillance backend
- Exposed via: `frigate.laboratory.casa`
- Target: External network service
- Auth: Authelia via `auth: authelia` route label

**Zigbee Hub:**
- Zigbee coordinator device
- Domain: `zigbee-hub.laboratory.casa`

**BirdNet:**
- Bird species identification service
- Domain: `birdnet.laboratory.casa`

**MinIO (local S3 proxy):**
- S3 testing/dev endpoint
- Domain: `minio-tc.laboratory.casa`
- Target: External network service

## Monitoring & Observability

**Prometheus:**
- Collection: Built-in via observability stack
- Targets: All services with ServiceMonitor CRDs
- Location: `kubernetes/apps/observability/prometheus-*`

**Victoria Metrics:**
- Time-series database replacement for Prometheus
- Single instance + logs collector
- Location: `kubernetes/apps/observability/victoria-*`

**Prometheus Exporters:**
- Redis exporter for Valkey metrics
- SMARTCTL exporter for disk health
- Cilium exporter (built-in)
- Config: `kubernetes/apps/observability/prometheus-*.yaml`

**Grafana:**
- Visualization frontend
- Location: `kubernetes/apps/observability/grafana`
- Datasource: Victoria Metrics
- Authentication: Authelia

## Networking Components

**Tailscale:**
- VPN mesh for secure access
- Operator: Tailscale Operator for Kubernetes integration
- Exposed services: the Envoy proxy Services of both Gateways, via `tailscale.com/expose: "true"` in each Gateway's `spec.infrastructure.annotations` (`kubernetes/apps/network/envoy-gateway/gateways.yaml`); tailnet nodes `network-envoy-internal` (100.94.67.88) and `network-envoy-external` (100.84.161.122)
- Location: `kubernetes/apps/network/tailscale-operator`

**Envoy Gateway:**
- Gateway API implementation (v1.9.2, GatewayClass `envoy`; Gateway API CRDs v1.6.1 experimental via Argo app `gateway-api-crds`)
- Gateways in `network`: `envoy-internal` (10.25.30.117, LAN only, shares IP with forgejo-ssh) and `envoy-external` (10.25.30.122, target of the cloudflared tunnels)
- Location: `kubernetes/apps/network/envoy-gateway/`

**K8s Gateway:**
- DNS server (not a Gateway API implementation) at 10.25.30.118
- Answers LAN DNS for every attached HTTPRoute hostname
- Location: `kubernetes/apps/network/k8s-gateway`

**LINSTOR/Piraeus:**
- Advanced storage volume management
- CSI driver for dynamic provisioning
- Location: `kubernetes/apps/database/piraeus/` (if deployed)

## Git & Version Control

**GitHub:**
- Repository: `https://github.com/mebezac/home-cluster.git`
- Private apps: `https://github.com/mebezac/home-cluster-private.git`
- Auth: SSH key (managed in `kubernetes/argo/repositories/github.yaml` secret)
- Integration: ArgoCD pulls from GitHub for GitOps reconciliation
- Actions: Labeler, label-sync, release workflows

## Environment Configuration

**Required Secrets (Environment Variables):**
- `CF_API_TOKEN` - Cloudflare API token for external-dns
- `GITHUB_TOKEN` - GitHub repo access (for ArgoCD)
- Database credentials - PostgreSQL superuser password (CloudNative-PG)
- Valkey auth - Redis password
- Authelia OIDC/LDAP credentials - Authentication backend
- Garage admin token - Object store access
- Tailscale auth token - VPN mesh join key

**Secrets Location:**
- All stored as Kubernetes Secrets encrypted with SOPS
- File pattern: `*.sops.yaml` in application directories
- Decryption key: Age private key in `.sops/age.key`
- Secret generator: `secret-generator.yaml` + `kustomization.yaml` in each app

**Configuration Files:**
- Helm values: `kubernetes/apps/<namespace>/<app>/values.yaml`
- Encrypted values: `values.sops.yaml` pattern
- Config maps: `*.configmap.yaml` or embedded in values YAML

## Webhooks & Callbacks

**Incoming Webhooks:**
- N8N workflow triggers
- Changedetection.io - Webhook notifications
- GitHub Actions - ArgoCD notifications (via Argo Notifications)

**Outgoing Webhooks:**
- Not explicitly configured in stack; services use HTTP integrations

---

*Integration audit: 2026-05-08*
