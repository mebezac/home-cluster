#!/usr/bin/env bash
# Diff two image digests of the SAME tag, to answer the only question a digest
# bump raises: did anything but the build timestamp actually change?
#
# Usage: image-digest-diff.sh <image> <old-digest> <new-digest>
#   image        repository without a tag, e.g. valkey/valkey, ghcr.io/foo/bar
#   old/new      full sha256:... digests, straight off the PR diff
#
# Requires crane (pinned in .mise.toml as aqua:google/go-containerregistry).
set -euo pipefail

if [[ $# -ne 3 ]]; then
  sed -n '2,9p' "$0" >&2
  exit 64
fi

image=$1 old=$2 new=$3
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for side in old new; do
  digest=${!side}
  if ! crane config "${image}@${digest}" >"${tmp}/${side}.json" 2>"${tmp}/${side}.err"; then
    echo "FAILED to read ${side} config for ${image}@${digest}:" >&2
    cat "${tmp}/${side}.err" >&2
    exit 1
  fi
done

runtime() {
  jq -S '{Env:.config.Env, Entrypoint:.config.Entrypoint, Cmd:.config.Cmd,
          User:.config.User, WorkingDir:.config.WorkingDir,
          ExposedPorts:.config.ExposedPorts, Volumes:.config.Volumes,
          Labels:.config.Labels}' "$1"
}

echo "== runtime config =="
if diff -u <(runtime "${tmp}/old.json") <(runtime "${tmp}/new.json"); then
  echo "IDENTICAL — env, entrypoint, cmd, user, ports, volumes and labels all unchanged."
else
  echo ">>> RUNTIME CONFIG CHANGED. This is NOT a plain rebuild — read the diff above."
fi

echo
echo "== build timestamps =="
printf 'old: %s\nnew: %s\n' \
  "$(jq -r '.created' "${tmp}/old.json")" "$(jq -r '.created' "${tmp}/new.json")"

echo
echo "== layer history (added/removed steps) =="
if diff -u <(jq -r '.history[].created_by' "${tmp}/old.json") \
           <(jq -r '.history[].created_by' "${tmp}/new.json"); then
  echo "IDENTICAL — same Dockerfile instructions, so the source did not change."
fi

echo
echo "== layer sizes (which layer actually moved) =="
# A pinned digest usually points at a multi-arch INDEX, which has .manifests[]
# and no .layers[]. Resolve linux/amd64 first, then read that manifest.
layers_for() {
  local ref=$1 raw
  raw=$(crane manifest "$ref" 2>/dev/null) || return 1
  if [[ $(jq -r 'has("layers")' <<<"$raw") == true ]]; then
    jq -r '.layers[] | "\(.size)\t\(.digest[7:19])"' <<<"$raw"
  else
    local sub
    sub=$(jq -r '.manifests[] | select(.platform.os=="linux" and .platform.architecture=="amd64")
                 | .digest' <<<"$raw" | head -1)
    [[ -n $sub ]] || return 1
    crane manifest "${image}@${sub}" 2>/dev/null \
      | jq -r '.layers[] | "\(.size)\t\(.digest[7:19])"'
  fi
}

layers_for "${image}@${old}" >"${tmp}/old.layers" 2>/dev/null || true
layers_for "${image}@${new}" >"${tmp}/new.layers" 2>/dev/null || true

if [[ -s ${tmp}/old.layers && -s ${tmp}/new.layers ]]; then
  paste "${tmp}/old.layers" "${tmp}/new.layers" \
    | awk -F'\t' 'BEGIN{printf "%-14s %-14s %s\n","OLD BYTES","NEW BYTES","STATUS"}
        {d=$3-$1; printf "%-14s %-14s %s\n", $1, $3,
          ($2==$4 ? "same layer" : (d>0 ? "CHANGED (+" d " bytes)" : "CHANGED (" d " bytes)"))}'
  echo
  echo "A large delta on a package layer (apk/apt/yum) is a base-package refresh."
  echo "A few bytes on the application layer is the same source recompiled."
else
  echo "(could not read layer sizes for linux/amd64 — skip this section)"
fi

echo "== interpretation =="
echo "Identical runtime config + identical history + a newer timestamp means a"
echo "REBUILD: same source, refreshed base packages (usually a distro security"
echo "update). That is the reason to take the bump, and it is safe."
echo "Any diff above means the image genuinely changed — investigate before merging."
