---
description: Guidelines for developing and maintaining applications in the home-cluster
---

# Home Cluster Application Guidelines

This document provides comprehensive guidelines for developing, deploying, and maintaining applications in the home-cluster using Argo CD and the bjw-s app-template Helm chart.

## Important: GitOps Workflow

**This cluster uses a GitOps approach with Argo CD.**

- **NEVER** attempt to deploy changes directly to the Kubernetes cluster (no `kubectl apply`, `helm install`, etc.)
- You **MAY** however use the kubernetes mcp to interact with the cluster to investigate issues when directed to
- All changes are made by editing files in the repository, committing, and pushing
- Argo CD automatically detects changes and reconciles the cluster state

**Workflow:**

1. Edit the necessary files (values.yaml, Application definitions, secrets, etc.)
2. Commit the changes to Git
3. Push to the repository
4. Argo CD will automatically sync and deploy the changes

## Table of Contents

1. [Directory Structure](#directory-structure)
2. [Argo CD Application Definition](#argo-cd-application-definition)
3. [Values.yaml Configuration](#valuesyaml-configuration)
4. [Secrets Management with ksops](#secrets-management-with-ksops)
5. [Ingress Configuration](#ingress-configuration)
6. [Persistence Configuration](#persistence-configuration)
7. [Security Context](#security-context)
8. [Common Patterns](#common-patterns)
9. [Anti-patterns to Avoid](#anti-patterns-to-avoid)

---

## Directory Structure

Each application follows a consistent directory structure:

```
kubernetes/apps/<namespace>/<app-name>/
├── kustomization.yaml          # Required if using secrets or configmaps
├── values.yaml                 # Helm chart values
├── secret-generator.yaml       # ksops generator (if secrets needed)
├── <app-name>-secret.sops.yaml # SOPS-encrypted secrets (if needed)
└── <config-file>.yaml          # Additional configs (configmaps, etc.)

kubernetes/argo/apps/<namespace>/<app-name>.yaml  # Argo CD Application definition
```

**Notes:**

- Each app typically has its own namespace with the same name as the app (e.g., `mealie` app in `mealie` namespace)
- Apps can be grouped by function (e.g., `homeassistant/`, `database/`, `security/`, `network/`)
- The inner directory name should match the app name

**Examples:**

- Simple app: `kubernetes/apps/mealie/mealie/`
- Grouped apps: `kubernetes/apps/homeassistant/zigbee2mqtt/`
- System apps: `kubernetes/apps/security/authelia/`

---

## Argo CD Application Definition

Every app needs an Argo CD Application resource at `kubernetes/argo/apps/<namespace>/<app-name>.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app-name>
  namespace: argo-system
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: kubernetes
  sources:
    - repoURL: https://github.com/mebezac/home-cluster.git
      path: kubernetes/apps/<namespace>/<app-name>
      targetRevision: main
      ref: <app-name>-repo
    - repoURL: ghcr.io/bjw-s-labs/helm
      chart: app-template
      targetRevision: 4.6.2
      helm:
        releaseName: <app-name>
        valueFiles:
          - $<app-name>-repo/kubernetes/apps/<namespace>/<app-name>/values.yaml
  destination:
    name: in-cluster
    namespace: <namespace>
  syncPolicy:
    automated:
      allowEmpty: true
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Key points:**

- Always use `ghcr.io/bjw-s-labs/helm` as the chart repository (NOT `https://bjw-s.github.io/helm-charts/`)
- Standard app-template version is **4.6.2**
- The `ref` name must match the pattern `<app-name>-repo`
- Value files are referenced using `$<app-name>-repo/...` syntax

---

## Values.yaml Configuration

### Basic Structure

```yaml
# Optional: Default pod options applied to all pods
defaultPodOptions:
  securityContext:
    runAsNonRoot: true
    runAsUser: 3000
    runAsGroup: 3000
    fsGroup: 3000
    fsGroupChangePolicy: OnRootMismatch
    seccompProfile: { type: RuntimeDefault }

controllers:
  <controller-name>: # Usually 'main' or the app name
    annotations:
      reloader.stakater.com/auto: "true" # Auto-reload on secret/configmap changes
    containers:
      app: # Container name, usually 'app' or 'main'
        image:
          repository: ghcr.io/example/app
          tag: 1.0.0@sha256:abc123... # Pin with SHA for reproducibility
        env:
          TZ: America/New_York # Always use explicit timezone, not variables
        resources:
          requests:
            cpu: 10m
            memory: 128Mi
          limits:
            memory: 512Mi

service:
  app:
    controller: <controller-name>
    ports:
      http:
        port: 8080

ingress:
  app:
    enabled: true
    className: internal
    hosts:
      - host: <app-name>.laboratory.casa
        paths:
          - path: /
            service:
              identifier: app
              port: http

persistence:
  data:
    type: persistentVolumeClaim
    storageClass: longhorn
    accessMode: ReadWriteOnce
    size: 1Gi
    globalMounts:
      - path: /data
```

### Image Tags

Prefer pinning images with SHA256 digests for reproducibility:

```yaml
image:
  repository: ghcr.io/example/app
  tag: 1.0.0@sha256:abc123def456...
```

For frequently updated apps where you want automatic updates, a simple tag is acceptable:

```yaml
image:
  repository: ghcr.io/example/app
  tag: 1.0.0
```

### Environment Variables

**DO:**

- Use explicit values for timezone: `TZ: America/New_York`
- Reference secrets via `envFrom`:

  ```yaml
  envFrom:
    - secretRef:
        name: <app-name>-secret
  ```

- Use YAML anchors for reuse:

  ```yaml
  envFrom: &envFrom
    - secretRef:
        name: app-secret
  # Later in the file:
  envFrom: *envFrom
  ```

**DON'T:**

- Use variable substitution like `${TIMEZONE}` or `${VOLSYNC_CLAIM}` - these are Flux patterns
- Hardcode secrets in values.yaml

### Port References

Use YAML anchors for port consistency:

```yaml
containers:
  app:
    env:
      PORT: &port 8080
service:
  app:
    ports:
      http:
        port: *port
```

---

## Secrets Management with ksops

### Required Files

When an app needs secrets, create these files:

**1. kustomization.yaml:**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
generators:
  - secret-generator.yaml
```

**2. secret-generator.yaml:**

```yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: <app-name>-secret-generator
  annotations:
    config.kubernetes.io/function: |
      exec:
        path: ksops
files:
  - ./<app-name>-secret.sops.yaml
```

**3. <app-name>-secret.sops.yaml:** (encrypted with SOPS)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: <app-name>-secret
  namespace: <namespace>
type: Opaque
stringData:
  SECRET_KEY: encrypted-value
```

**Important:** When creating new secrets:

- Create the secret file with plaintext values as a template
- **Leave the SOPS encryption to the user** - never run or suggest running `sops --encrypt` commands
- The user will encrypt the file themselves using their own age keys

### Multiple Secrets

For apps with multiple secrets (e.g., authelia):

```yaml
# secret-generator.yaml
files:
  - ./authelia-initdb-secret.sops.yaml
  - ./authelia-oidc-private-key.sops.yaml
  - ./authelia-secret.sops.yaml
```

### ConfigMaps

For non-sensitive configuration files, use kustomize configMapGenerator:

```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
configMapGenerator:
  - name: <app-name>-config
    files:
      - configuration.yaml=./<app-name>-config.yaml
    options:
      disableNameSuffixHash: true
generators:
  - secret-generator.yaml
```

---

## Ingress Configuration

### Internal Ingress (Default)

For apps only accessible within the network:

```yaml
ingress:
  app:
    enabled: true
    className: internal
    hosts:
      - host: <app-name>.laboratory.casa
        paths:
          - path: /
            service:
              identifier: app
              port: http
```

### External Ingress

For apps accessible from the internet:

```yaml
ingress:
  app:
    enabled: true
    className: external
    annotations:
      external-dns.alpha.kubernetes.io/target: external.laboratory.casa
    hosts:
      - host: <app-name>.laboratory.casa
        paths:
          - path: /
            service:
              identifier: app
              port: http
```

### With Authelia Authentication

```yaml
ingress:
  app:
    className: external
    annotations:
      external-dns.alpha.kubernetes.io/target: external.laboratory.casa
      nginx.ingress.kubernetes.io/auth-method: GET
      nginx.ingress.kubernetes.io/auth-url: http://authelia.security.svc.cluster.local/api/authz/auth-request
      nginx.ingress.kubernetes.io/auth-signin: https://login.laboratory.casa?rm=$request_method
      nginx.ingress.kubernetes.io/auth-response-headers: Remote-User,Remote-Name,Remote-Groups,Remote-Email
    hosts:
      - host: <app-name>.laboratory.casa
        paths:
          - path: /
            service:
              identifier: app
              port: http
```

### Domain Guidelines

- Primary domain: `laboratory.casa`
- Use descriptive subdomains: `mealie.laboratory.casa`, `ha.laboratory.casa`
- External services (like biglink.party) may have separate TLS configuration
- Do NOT include TLS configuration for laboratory.casa - it's handled automatically

---

## Persistence Configuration

### Standard Longhorn PVC (Most Common)

```yaml
persistence:
  data:
    type: persistentVolumeClaim
    storageClass: longhorn
    accessMode: ReadWriteOnce
    size: 1Gi
    suffix: data # Optional: creates PVC named <app>-data
    globalMounts:
      - path: /data
```

### Multiple Mount Points from Single PVC

```yaml
persistence:
  config:
    type: persistentVolumeClaim
    storageClass: longhorn
    accessMode: ReadWriteOnce
    size: 500Mi
    suffix: config
    globalMounts:
      - path: /config
        subPath: config
      - path: /metadata
        subPath: metadata
```

### EmptyDir (Temporary Data)

```yaml
persistence:
  tmp:
    type: emptyDir
    globalMounts:
      - path: /tmp
  cache:
    type: emptyDir
    globalMounts:
      - path: /app/.cache
```

### NFS Mounts (Media, Large Files)

```yaml
persistence:
  media:
    type: nfs
    server: nas.laboratory.casa
    path: /mnt/data/10tb/Media
    globalMounts:
      - path: /media
```

### Mounting Secrets as Files

```yaml
persistence:
  secrets:
    type: secret
    name: <app-name>-secret
    globalMounts:
      - path: /config/secrets.yaml
        subPath: secrets.yaml
        readOnly: true
```

### Mounting ConfigMaps as Files

```yaml
persistence:
  config-file:
    type: configMap
    name: <app-name>-config
    advancedMounts:
      main:
        app:
          - path: /config/configuration.yaml
            subPath: configuration.yaml
```

### Advanced Mounts (Per-Controller/Container)

For different mounts per container:

```yaml
persistence:
  data:
    type: persistentVolumeClaim
    storageClass: longhorn
    accessMode: ReadWriteOnce
    size: 1Gi
    advancedMounts:
      <controller-name>:
        <container-name>:
          - path: /data
            subPath: data
            readOnly: false
```

### Storage Classes

| Storage Class             | Use Case                                          |
| ------------------------- | ------------------------------------------------- |
| `longhorn`                | Default for all persistent data (replicated)      |
| `longhorn-single-replica` | Less critical data, saves space                   |
| `openebs-hostpath`        | High-performance local storage (e.g., transcodes) |
| `freenas-api-nfs`         | NFS-backed storage from TrueNAS                   |

---

## Security Context

### Standard Security Context (Recommended)

```yaml
defaultPodOptions:
  securityContext:
    runAsNonRoot: true
    runAsUser: 3000
    runAsGroup: 3000
    fsGroup: 3000
    fsGroupChangePolicy: OnRootMismatch
    seccompProfile: { type: RuntimeDefault }
```

### Container-Level Security

```yaml
containers:
  app:
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
          - ALL
```

### Common User IDs

| UID   | Use Case                              |
| ----- | ------------------------------------- |
| 3000  | Default for most apps                 |
| 568   | Apps from k8s-at-home/bjw-s ecosystem |
| 1000  | Generic unprivileged user             |
| 65534 | nobody user (most restrictive)        |

### Privileged Containers

Only use when absolutely necessary (e.g., Home Assistant with USB devices):

```yaml
containers:
  app:
    securityContext:
      privileged: true
```

---

## Common Patterns

### Apps with Database (PostgreSQL)

```yaml
controllers:
  app:
    annotations:
      reloader.stakater.com/auto: "true"
    initContainers:
      init-db:
        image:
          repository: ghcr.io/home-operations/postgres-init
          tag: 18.1
        envFrom: &envFrom
          - secretRef:
              name: <app-name>-secret
    containers:
      app:
        envFrom: *envFrom
        env:
          DB_TYPE: postgres
          # ... other env vars
```

### Sidecar Containers

```yaml
controllers:
  main:
    containers:
      app:
        image:
          repository: ghcr.io/example/app
          tag: 1.0.0
      browser: # Sidecar container
        image:
          repository: ghcr.io/browserless/chrome
          tag: v2.38.3
        env:
          SCREEN_WIDTH: "1920"
```

### CronJobs

```yaml
controllers:
  ip-rotator:
    type: cronjob
    cronjob:
      schedule: "15 * * * *"
      successfulJobsHistory: 1
      failedJobsHistory: 1
    containers:
      rotate:
        image:
          repository: curlimages/curl
          tag: 8.18.0
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "Running task..."
```

### LoadBalancer Services

```yaml
service:
  main:
    annotations:
      lbipam.cilium.io/ips: 10.25.30.56
    controller: main
    type: LoadBalancer
    ports:
      http:
        port: 8123
```

### Custom Health Probes

```yaml
containers:
  app:
    probes:
      startup:
        enabled: true
        custom: true
        spec:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
          failureThreshold: 30
      liveness:
        enabled: true
        custom: true
        spec:
          httpGet:
            path: /healthz
            port: 8080
          periodSeconds: 10
          failureThreshold: 3
      readiness:
        enabled: true
        custom: true
        spec:
          httpGet:
            path: /healthz
            port: 8080
          periodSeconds: 10
          failureThreshold: 3
```

### Reloader Annotations

Enable automatic pod restarts when secrets/configmaps change:

```yaml
controllers:
  main:
    annotations:
      reloader.stakater.com/auto: "true" # Auto-detect all secrets/configmaps
      # OR be specific:
      secret.reloader.stakater.com/reload: <secret-name>
      configmap.reloader.stakater.com/reload: <configmap-name>
```

---

## Anti-patterns to Avoid

### 1. Flux Variable Substitution

**Bad:**

```yaml
env:
  TZ: ${TIMEZONE}
persistence:
  config:
    existingClaim: "${VOLSYNC_CLAIM}"
```

**Good:**

```yaml
env:
  TZ: America/New_York
persistence:
  config:
    type: persistentVolumeClaim
    storageClass: longhorn
    accessMode: ReadWriteOnce
    size: 1Gi
```

### 2. Old Helm Chart Repository

**Bad:**

```yaml
repoURL: https://bjw-s.github.io/helm-charts/
```

**Good:**

```yaml
repoURL: ghcr.io/bjw-s-labs/helm
```

### 3. Missing Security Context

**Bad:**

```yaml
controllers:
  main:
    containers:
      app:
        image: ...
        # No security context
```

**Good:**

```yaml
defaultPodOptions:
  securityContext:
    runAsNonRoot: true
    runAsUser: 3000
    runAsGroup: 3000
    fsGroup: 3000
```

### 4. Hardcoded Secrets

**Bad:**

```yaml
env:
  DATABASE_PASSWORD: mysecretpassword
```

**Good:**

```yaml
envFrom:
  - secretRef:
      name: app-secret
```

### 5. Missing Resource Limits

**Bad:**

```yaml
containers:
  app:
    image: ...
    # No resources defined
```

**Good:**

```yaml
containers:
  app:
    image: ...
    resources:
      requests:
        cpu: 10m
        memory: 128Mi
      limits:
        memory: 512Mi
```

### 6. Inconsistent Naming

**Bad:**

```yaml
service:
  myservice:
    controller: main
ingress:
  myingress:
    # ...
    service:
      identifier: differentname # Doesn't match
```

**Good:**

```yaml
service:
  app:
    controller: main
ingress:
  app:
    # ...
    service:
      identifier: app # Matches service name
```

---

## Additional Resources

- See `.agents/workflows/translate-flux-to-argo.md` for migrating Flux apps
- bjw-s app-template documentation: <https://bjw-s-labs.github.io/helm-charts/>
- Argo CD documentation: <https://argo-cd.readthedocs.io/>
