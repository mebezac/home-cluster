# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a home Kubernetes cluster repository using ArgoCD for GitOps. Applications are deployed using Helm charts with custom values, and secrets are managed using SOPS encryption with ksops.

## Repository Structure

### Application Layout
```
kubernetes/apps/<namespace>/<app-name>/
├── values.yaml                 # Helm chart values
├── kustomization.yaml          # Kustomize configuration (if secrets exist)
├── secret-generator.yaml       # ksops secret generator (if secrets exist)
└── <secret-name>.sops.yaml     # SOPS-encrypted secrets (if needed)
```

### ArgoCD Applications
```
kubernetes/argo/apps/<namespace>/<app-name>.yaml
```

## Creating New Applications

### 0. Documentation Research
When translating an application to ArgoCD, use the `context7` MCP server to fetch current documentation:
- Always retrieve ArgoCD documentation for application structure and best practices
- Use BJW-S Labs Helm Charts documentation when using the `app-template` chart
- This ensures up-to-date configuration patterns and syntax

### 1. Application Directory Structure
- Each app gets its own namespace (same name as the app unless specified otherwise)
- Create directory: `kubernetes/apps/<app-name>/<app-name>/`
- Multi-component apps (like Immich) can have subdirectories for each component

### 2. Helm Values Configuration
Create `values.yaml` with the chart values. Key patterns:

**Ingress Configuration:**
- Always use domain `laboratory.casa`
- Choose appropriate subdomain based on service function
- Use `internal` className for internal access
- No TLS configuration needed (handled by cert-manager)
- Example:
```yaml
ingress:
  app:
    enabled: true
    className: internal
    hosts:
      - host: <subdomain>.laboratory.casa
        paths:
          - path: /
            service:
              identifier: app
              port: http
```

**Chart Repository Changes:**
- Replace `https://bjw-s.github.io/helm-charts/` with `ghcr.io/bjw-s-labs/helm`

### 3. Secret Management
When secrets are needed, create three files:

**secret-generator.yaml:**
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
  - ./<secret-file>.sops.yaml
```

**kustomization.yaml:**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
generators:
  - secret-generator.yaml
```

**<secret-file>.sops.yaml:** (write plaintext values, then `sops --encrypt --in-place` it yourself before committing)

### 4. ArgoCD Application Definition
Create application at `kubernetes/argo/apps/<namespace>/<app-name>.yaml`:

**Single Chart Application:**
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
      path: kubernetes/apps/<app-name>/<app-name>
      targetRevision: main
      ref: <app-name>-repo
    - repoURL: <helm-repo-url>
      chart: <chart-name>
      targetRevision: <chart-version>
      helm:
        releaseName: <app-name>
        valueFiles:
          - $<app-name>-repo/kubernetes/apps/<app-name>/<app-name>/values.yaml
  destination:
    name: in-cluster
    namespace: <app-name>
  syncPolicy:
    automated:
      allowEmpty: true
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Multi-Component Application (like Immich):**
```yaml
spec:
  sources:
    - repoURL: https://github.com/mebezac/home-cluster.git
      path: kubernetes/apps/<app>/component1
      targetRevision: main
      ref: component1-repo
    - repoURL: <helm-repo>
      chart: <chart>
      targetRevision: <version>
      helm:
        releaseName: <app>-component1
        valueFiles:
          - $component1-repo/kubernetes/apps/<app>/component1/values.yaml
    - repoURL: https://github.com/mebezac/home-cluster.git
      path: kubernetes/apps/<app>/component2
      targetRevision: main
      ref: component2-repo
    - repoURL: <helm-repo>
      chart: <chart>
      targetRevision: <version>
      helm:
        releaseName: <app>-component2
        valueFiles:
          - $component2-repo/kubernetes/apps/<app>/component2/values.yaml
```

## Common Helm Repositories

- **bjw-s app-template**: `ghcr.io/bjw-s-labs/helm`
- **Bitnami**: `registry-1.docker.io/bitnamicharts`
- **Prometheus Community**: `oci://ghcr.io/prometheus-community/charts`

## Ingress Classes

- **`internal`**: For applications accessed only within the network
- **`external`**: For applications exposed to the internet (uses Cloudflare)

## Secret Patterns

- Never commit unencrypted secrets — encrypt with `sops --encrypt --in-place <file>.sops.yaml` before `git add`, and verify `stringData` values show `ENC[...]`
- Encrypt/edit secrets directly yourself: `.sops.yaml` creation rules auto-match `kubernetes/**/*.sops.yaml` and `SOPS_AGE_KEY_FILE` is exported via mise, so no flags are needed (`sops <file>` to edit, `sops decrypt <file>` to read)
- **NEVER commit or push the age PRIVATE key** (`age.key`, `*.agekey`, `*.key`) or any decrypted key material — these are gitignored; only the public age recipient goes in `.sops.yaml`
- Use descriptive names for secret files (e.g., `authelia-initdb-secret.sops.yaml`)
- Multiple secrets can be referenced in one secret-generator

## Development Notes

- Each application is automatically deployed by ArgoCD when changes are pushed
- Sync waves can be used to control deployment order (`argocd.argoproj.io/sync-wave`)
- The root app-of-apps is at `kubernetes/argo/apps.yaml`
- Applications use the `kubernetes` project in ArgoCD
- When making secrets, don't use Opaque, always just do stringData and don't set a type
- when possible run containers as user 3000
- remember for future that I use a central PG database where possible and then an init container to provision a database for the apps that need it. You can look at @kubernetes/apps/lubelog/lubelog/ for examples
- I use a central valkey deployment as my redis equivalent
- ALWAYS pin container images to a concrete version-number tag plus sha256 digest (e.g. `tag: 3.1.2@sha256:...`). NEVER use `latest` — it breaks Renovate version tracking and makes rollbacks ambiguous. Only fall back to `latest@sha256:...` when the image publishes no versioned tags at all.