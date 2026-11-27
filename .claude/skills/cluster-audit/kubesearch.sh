#!/usr/bin/env bash
# Call the kubesearch MCP (https://beta.kubesearch.dev/mcp) over plain JSON-RPC.
# Usage: kubesearch.sh <tool> '<json arguments>'   e.g. kubesearch.sh search_releases '{"query":"emqx"}'
# Tools: status, search_releases, get_release, search_images, grep_values,
#        repo_grep_all, repo_clone, repo_list_files, repo_read_file, repo_grep, repo_cleanup
set -euo pipefail
tool=$1; args=${2:-'{}'}
curl -sS -m 60 -X POST https://beta.kubesearch.dev/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d "$(jq -cn --arg t "$tool" --argjson a "$args" '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$t,arguments:$a}}')" \
  | jq -r 'if .error then "ERROR: \(.error.message)" else (.result.content[]?.text // .result | tostring) end'
