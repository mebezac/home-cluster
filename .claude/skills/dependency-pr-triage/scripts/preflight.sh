#!/usr/bin/env bash
# Read-only runtime check. This script does not grant permission to merge.
# Run from a fresh checkout in an agent run (MISE_ENV=agent, repo tool pins).
# Usage: bash .claude/skills/dependency-pr-triage/scripts/preflight.sh
set -uo pipefail

failures=0
declare -A available=()
missing() { printf 'capability_missing: %s\n' "$1"; failures=$((failures + 1)); }
passed() { printf 'capability_ok: %s%s\n' "$1" "${2:+ $2}"; }

# A mise shim can exist without an active tool version. Check execution too.
check_tool() {
  local tool=$1 path
  shift
  if path=$(command -v "$tool") && timeout 20s "$tool" "$@" >/dev/null 2>&1; then
    available[$tool]=1
    passed "tool_$tool" "$path"
  else
    available[$tool]=0
    missing "tool_$tool"
  fi
}

if ! command -v timeout >/dev/null || ! timeout --version >/dev/null 2>&1; then
  missing tool_timeout
  exit 1
fi
passed tool_timeout "$(command -v timeout)"
check_tool bash --version
check_tool git --version
check_tool gh --version
check_tool mise --version
check_tool crane version
check_tool helm version --short
check_tool jq --version
check_tool yq --version
check_tool kubectl version --client -o json
check_tool curl --version
for tool in grep diff sort head mktemp sleep dirname rm sed cat paste awk tar; do
  check_tool "$tool" --version
done

# Agent runs must not see the human-only env from .mise.human.toml (age key,
# kubeconfig, decrypted MCP token). Only variable names are inspected.
if [[ ${MISE_ENV:-} == *human* || -n ${SOPS_AGE_KEY_FILE:-} || -n ${ARGOCD_API_TOKEN:-} ]] ||
   { [[ ${available[mise]} == 1 ]] &&
     timeout 20s mise env -s bash 2>/dev/null | grep -qE '(SOPS_AGE_KEY_FILE|ARGOCD_API_TOKEN)='; }; then
  missing human_env_absent
else
  passed human_env_absent "MISE_ENV=${MISE_ENV:-unset}"
fi

if [[ ${available[gh]} == 1 ]]; then
  if timeout 30s gh auth status >/dev/null 2>&1; then
    passed github_auth
  else
    missing github_auth
  fi
  if repo_json=$(timeout 30s gh api repos/mebezac/home-cluster 2>/dev/null) &&
     [[ ${available[jq]} == 1 ]] &&
     jq -e '.full_name == "mebezac/home-cluster"' <<<"$repo_json" >/dev/null; then
    passed github_repo_read
  else
    missing github_repo_read
  fi
else
  missing github_auth
  missing github_repo_read
fi

# Do not run repository hooks. Do not change refs, credentials, or Git config.
# A dry run checks receive-pack authentication. It cannot prove a real write
# will pass branch rules or server hooks. The probe branch is never created.
if [[ ${available[git]} == 1 ]] &&
   remote=$(git remote get-url --push origin 2>/dev/null) &&
   [[ $remote == https://github.com/mebezac/home-cluster.git ]] &&
   git rev-parse --verify HEAD >/dev/null 2>&1; then
  if GIT_TERMINAL_PROMPT=0 timeout 30s git -c core.hooksPath=/dev/null push \
       --dry-run --porcelain origin "HEAD:refs/heads/dependency-steward/preflight-probe-$$" \
       >/dev/null 2>&1; then
    passed github_push_dry_run
  else
    missing github_push_dry_run
  fi
else
  missing github_push_dry_run
fi

# Require an explicit kubeconfig. Never fall back to an in-cluster account.
# No raw kubeconfig or token is printed or decoded. An authenticated live
# request proves validity now; it does not prove a future expiry date.
kube_ready=0
if [[ ${available[kubectl]} == 1 && -n ${KUBECONFIG:-} && -r $KUBECONFIG &&
      $KUBECONFIG != *:* ]]; then
  kube_ready=1
  passed kubeconfig_explicit
else
  missing kubeconfig_explicit
fi
k() { timeout 25s kubectl --kubeconfig="$KUBECONFIG" --request-timeout=15s "$@"; }

if (( kube_ready )); then
  if identity=$(k auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null) &&
     [[ $identity == system:serviceaccount:* ]]; then
    passed kubeconfig_token_valid
    # The selected user name is only an alias. Check the API's actual identity.
    if [[ $identity == "system:serviceaccount:paperclip:paperclip" ]]; then
      passed kubeconfig_identity "$identity"
    else
      missing kubeconfig_identity
    fi
  else
    missing kubeconfig_token_valid
    missing kubeconfig_identity
  fi

  if app=$(k get applications.argoproj.io argo -n argo-system \
       -o jsonpath='{.metadata.name}{"|"}{.spec.sources[*].targetRevision}{"|"}{.status.sync.status}{"|"}{.status.health.status}' 2>/dev/null) &&
     [[ $app == argo\|?*\|?*\|?* ]]; then
    passed argocd_applications_read "$app"
  else
    missing argocd_applications_read
  fi
  if pods=$(k get pods -n argo-system \
       -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.containerStatuses[*].ready}{"|"}{.status.containerStatuses[*].restartCount}{"\n"}{end}' 2>/dev/null) &&
     [[ -n $pods ]]; then
    passed pods_read
  else
    missing pods_read
  fi

  # Authorization reviews do not retrieve Secrets or persist cluster objects.
  # Check all current namespaces and all-namespace collection access. A denial
  # must be an explicit 'no' (exit 1), never an auth/network error. These probes
  # do not rule out a grant restricted to an individual Secret resourceName.
  secrets_ok=1
  if namespaces=$(k get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) &&
     [[ -n $namespaces ]]; then
    read -r -a namespace_list <<<"$namespaces"
    for namespace in "${namespace_list[@]}" __all_namespaces__; do
      scope=(-n "$namespace")
      [[ $namespace == __all_namespaces__ ]] && scope=(--all-namespaces)
      for verb in get list watch; do
        answer=$(k auth can-i "$verb" secrets "${scope[@]}" 2>/dev/null)
        rc=$?
        if [[ $rc != 1 || $answer != no ]]; then
          secrets_ok=0
          break 2
        fi
      done
    done
  else
    secrets_ok=0
  fi
  if (( secrets_ok )); then
    passed secrets_denied "get/list/watch in all current namespaces and at cluster scope"
  else
    missing secrets_denied
  fi
else
  for capability in kubeconfig_token_valid kubeconfig_identity argocd_applications_read pods_read secrets_denied; do
    missing "$capability"
  done
fi

if (( failures )); then
  printf 'preflight_failed: %s\n' "$failures"
  exit 1
fi
printf 'preflight_passed\n'
