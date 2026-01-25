---
description: Translate a flux helm release to argo app
---

To translate a Flux HelmRelease to an Argo CD Application in the home-cluster:

1. Create app directory structure:

   ```
   kubernetes/apps/<app-name>/<app-name>/
   ```

   Note: Unless specified otherwise, each app should have its own namespace with the same name as the app itself.

2. Create values.yaml with the Helm chart values from the Flux HelmRelease

3. For secrets, create:

   - `<secret-name>.sops.yaml` - Contains encrypted sensitive data
   - `secret-generator.yaml` - ksops configuration referencing the sops file
   - `kustomization.yaml` - References the secret generator

In the home-cluster project, secrets are managed using ksops with the following pattern:

A. Create a `secret-generator.yaml` file with:
`yaml
    apiVersion: viaduct.ai/v1
    kind: ksops
    metadata:
      name: [app-name]-secret-generator
      annotations:
        config.kubernetes.io/function: |
          exec:
            path: ksops
    files:
      - ./[secret-file].sops.yaml
    `

B. Create a SOPS-encrypted secret file (e.g., `[secret-file].sops.yaml`) with the actual secret data.

C. Include the secret generator in a `kustomization.yaml` file:
`yaml
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    generators:
      - secret-generator.yaml
    `

This pattern is used throughout the cluster for managing sensitive configuration data securely.
Don't run or attempt to run, or suggest to run the sops encryption, leave that up to the user to do on their own.
Also note whenever you see https://bjw-s.github.io/helm-charts/ change it to ghcr.io/bjw-s-labs/helm

4. Create Argo CD Application definition:

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
           releaseName: <release-name>
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

5. Place the Application definition at:

   ```
   kubernetes/argo/apps/<app-name>/<app-name>.yaml
   ```

6. For ingress configuration:

   - When a Flux app includes "routes", convert them to ingresses following these rules:
   - Always change the domain to `laboratory.casa`
   - Choose an appropriate subdomain based on the service function (e.g., `speedtest` for OpenSpeedTest, `photos` for photo services)
   - Only include annotations if they are nginx-specific configuration
   - Use the `internal` className for ingresses
   - Do not include TLS configuration
   - Make sure the service identifier matches the service name (usually `app`)
   - Ensure the port matches the name of the port in the service (usually `http`)
   - Example ingress configuration in values.yaml:

   ```yaml
   ingress:
     app:
       enabled: true
       className: internal
       hosts:
         - host: <appropriate-subdomain>.laboratory.casa
           paths:
             - path: /
               service:
                 identifier: app
                 port: http
   ```

Key differences from Flux:

- Uses Argo CD's Application resource instead of Flux's HelmRelease
- References values from Git repo using the `$<app-name>-repo` syntax
- Uses ksops for secret management instead of Flux's valuesFrom
- No need to add Helm repositories in the repositories directory as they're referenced directly in the Application
- Standardizes on `laboratory.casa` domain with appropriate subdomains
- Only preserves nginx-specific annotations in ingress configurations

7. For persistence configuration:

   Most apps require persistent storage. The standard pattern is to create a PVC using Longhorn with ReadWriteOnce access mode.

   A. Basic PVC with Longhorn (most common):

   ```yaml
   persistence:
     <name>:
       type: persistentVolumeClaim
       storageClass: longhorn
       accessMode: ReadWriteOnce
       size: <size>  # e.g., 1Gi, 5Gi
       suffix: <name>  # Optional: appended to PVC name for clarity
       globalMounts:
         - path: /mount/path
           subPath: subfolder  # Optional: creates subfolder in PVC
   ```

   B. emptyDir (for temporary data that doesn't need persistence):

   ```yaml
   persistence:
     <name>:
       type: emptyDir
       globalMounts:
         - path: /tmp
   ```

   C. Mounting secrets as files (for sensitive configuration):

   ```yaml
   persistence:
     <name>:
       type: secret
       name: <secret-name>
       globalMounts:
         - path: /path/to/file
           subPath: <key-name>  # The secret key to mount as file
           readOnly: true
   ```

   D. Mounting ConfigMaps as files:

   ```yaml
   persistence:
     <name>:
       type: configMap
       name: <configmap-name>
       globalMounts:
         - path: /path/to/file
           subPath: <key-name>
           readOnly: true
   ```

   E. Advanced mounts (per-controller/per-container):

   Use `advancedMounts` instead of `globalMounts` when you need different mounts for different containers:

   ```yaml
   persistence:
     <name>:
       type: persistentVolumeClaim
       storageClass: longhorn
       accessMode: ReadWriteOnce
       size: 1Gi
       advancedMounts:
         <controller-name>:
           <container-name>:
             - path: /path
               subPath: subfolder
               readOnly: true
               mountPropagation: HostToContainer  # Optional: for host path access
   ```

   Notes:
   - Always use `storageClass: longhorn` and `accessMode: ReadWriteOnce` unless specifically required otherwise
   - Use `suffix` to make PVC names more descriptive (e.g., `suffix: config` → `appname-config`)
   - Use `subPath` to organize data within a single PVC
   - Multiple persistence entries can be defined for different data types (e.g., `config`, `data`, `cache`)
