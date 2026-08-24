# Testing Patterns

**Analysis Date:** 2026-05-08

## Validation Approach

**No Application Tests:**
This is a declarative Kubernetes GitOps repository (no application code). Testing focuses on manifest validation and dependency version management.

## Manifest Validation

**No Linting Tool Configured:**
- No `yamllint`, `kubeval`, `kubeconform`, or similar validation present
- No `.github/workflows` validation step for YAML syntax or Kubernetes schema
- Validation delegated to:
  - ArgoCD diff preview (manual review before sync)
  - kubectl dry-run on cluster during apply

**Manual Validation Process:**
- Changes pushed to main branch
- ArgoCD detects via webhook
- User reviews diff in ArgoCD UI
- Auto-sync enabled, but changes are visible before application

## Dependency Updates & Testing

**Renovate Automation** (`.github/renovate.json5`):

**Scope:**
- Docker images (container registries)
- Helm charts
- GitHub Actions
- GitHub releases (CLI tools, installers)

**Excluded:**
- SOPS-encrypted files (`ignorePaths: ["**/*.sops.*"]`)

**Custom Dependency Managers:**
1. CloudNative-PG `imageName` field (regex parser)
2. Generic dependency comments via regex (datasource + depName + version)

**Package Rules & Auto-Merge:**
- GitHub Actions minor/patch updates: Auto-merge via `automerge: true`, `automergeType: "branch"`
- Container images: Semantic version commits, no auto-merge
- Helm charts: Semantic version commits, no auto-merge
- Patch versions labeled `type/patch`, minor `type/minor`, major `type/major`

**Run Schedule:**
- Weekly: `schedule: ["every weekend"]`
- Rate limiting disabled: `:disableRateLimiting`

## CI/CD Workflows

**Workflows Present** (`.github/workflows/`):
- `labeler.yaml` - PR labeling (not validation)
- `label-sync.yaml` - Label sync (not validation)
- `release.yaml` - Release automation (not validation)

**No Validation Workflows:**
- No pre-commit hook file (`.pre-commit*`)
- No syntax check on PR
- No schema validation on PR
- No kustomize build validation
- No kubeval/kubeconform checks
- All changes applied directly via ArgoCD

## Testing Flow

**Dependency Update Testing:**
```
1. Renovate creates branch with updated chart/image versions
2. Branch pushed to GitHub
3. GitHub Actions (labeler, label-sync) run
4. PR created automatically
5. ArgoCD shows diff preview in PR (manual review)
6. User approves & merges
7. ArgoCD auto-syncs on main branch push
8. Cluster applies changes
9. App restart / rollout occurs
```

**Rollback on Failure:**
- No automated rollback
- Manual revert commit if update breaks cluster
- ArgoCD can sync to previous commit

## Secret Validation

**No Schema Validation for Secrets:**
- SOPS-encrypted `.sops.yaml` files not validated by linters (content is encrypted)
- Runtime validation: ksops decryption must succeed or kustomize build fails
- No pre-commit check for missing secret files

## Integration with ArgoCD

**ArgoCD as Validator:**
- Manual diff review before auto-sync
- Schema validation happens at apply time (kubectl)
- Failed syncs visible in ArgoCD UI with error messages

**Sync Strategies:**
- All applications: `syncPolicy.automated.allowEmpty: true` (deploy even with no changes)
- Pruning enabled: `prune: true` (delete resources removed from git)
- Self-heal enabled: `selfHeal: true` (reconcile if manually changed on cluster)

## Test Data & Fixtures

**No Test Fixtures:**
- Not applicable (declarative manifests, not code)
- Production values in `kubernetes/apps/*/values.yaml`
- No staging/dev values separate from production

## Coverage & Observability

**No Code Coverage:**
- Not applicable

**Change Observability:**
- Git commits tracked automatically by Renovate
- ArgoCD tracks all syncs in UI + audit log
- Kubernetes events visible via kubectl or Longhorn dashboard

---

*Testing analysis: 2026-05-08*
