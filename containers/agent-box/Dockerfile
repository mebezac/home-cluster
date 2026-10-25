# agent-box: minimal SSH target for Paperclip agents that do not need homelab
# tooling (the "Real Life" company). Paperclip's SSH environment driver runs
# `codex` here; the pod is locked down in kubernetes/apps/real-life-agents/.
# sshd runs as the unprivileged `agent` user (uid 3000), so only that user can log in.
FROM node:24.22.1-trixie-slim@sha256:43b9ba1142b8dcf33fa8f922ca1be85714adc444e0586c7cf7726daaeabc1bea

# renovate: datasource=npm depName=@openai/codex
ARG CODEX_VERSION=0.164.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq openssh-server ripgrep tini \
 && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_* \
 && npm install -g "@openai/codex@${CODEX_VERSION}" \
 && npm cache clean --force \
 && groupadd -g 3000 agent \
 && useradd -u 3000 -g 3000 -m -d /home/agent -s /bin/bash agent \
 && usermod -p '*' agent \
 && codex --version

COPY sshd_config /etc/agent-box/sshd_config
COPY --chmod=0755 entrypoint.sh /usr/local/bin/agent-box-entrypoint

USER 3000:3000
WORKDIR /home/agent
EXPOSE 2222
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/agent-box-entrypoint"]
