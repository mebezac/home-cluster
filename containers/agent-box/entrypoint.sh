#!/bin/sh
# Create the SSH host key on first start. It lives on the PVC, so it survives
# restarts; Paperclip pins it with strict host-key checking.
set -eu
keys=/home/agent/.sshd
mkdir -p "$keys"
chmod 700 "$keys"
if [ ! -s "$keys/ssh_host_ed25519_key" ]; then
  ssh-keygen -q -t ed25519 -N '' -C agent-box -f "$keys/ssh_host_ed25519_key"
fi
echo "agent-box host key: $(cut -d' ' -f1,2 "$keys/ssh_host_ed25519_key.pub")"

# Paperclip never deletes SSH run folders (paperclipai/paperclip#14527). Each
# one holds a copy of the codex auth.json and the session transcripts, so drop
# a run folder once nothing in it has changed for RUN_RETENTION_MINUTES.
runs=/home/agent/paperclip/.paperclip-runtime/runs
keep=${RUN_RETENTION_MINUTES:-1440}
(
  while :; do
    if [ -d "$runs" ]; then
      for d in "$runs"/*/; do
        [ -d "$d" ] || continue
        if [ -z "$(find "$d" -mmin "-$keep" -print -quit)" ]; then
          echo "agent-box cleanup: removing idle run folder ${d%/}"
          rm -rf -- "${d%/}"
        fi
      done
    fi
    sleep 3600
  done
) &

exec /usr/sbin/sshd -D -e -f /etc/agent-box/sshd_config
