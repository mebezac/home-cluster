---
description: Translate a flux helm release to argo app
---

To translate a Flux HelmRelease to an Argo CD Application in the home-cluster:

1. Create app directory structure:

   ```
   kubernetes/apps/<category>/<app-name>/
   ```

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
         path: kubernetes/apps/<category>/<app-name>
         targetRevision: main
         ref: <app-name>-repo
       - repoURL: <helm-repo-url>
         chart: <chart-name>
         targetRevision: <chart-version>
         helm:
           releaseName: <release-name>
           valueFiles:
             - $<app-name>-repo/kubernetes/apps/<category>/<app-name>/values.yaml
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

5. Place the Application definition at:
   ```
   kubernetes/argo/apps/<category>/<app-name>.yaml
   ```

Key differences from Flux:

- Uses Argo CD's Application resource instead of Flux's HelmRelease
- References values from Git repo using the `$<app-name>-repo` syntax
- Uses ksops for secret management instead of Flux's valuesFrom
- No need to add Helm repositories in the repositories directory as they're referenced directly in the Application
