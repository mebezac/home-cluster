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
exec /usr/sbin/sshd -D -e -f /etc/agent-box/sshd_config
