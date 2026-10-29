# agent-box: minimal SSH target for Paperclip agents that do not need homelab
# tooling (the "Real Life" company). Paperclip's SSH environment driver runs
# `codex` here; the pod is locked down in kubernetes/apps/real-life-agents/.
# sshd runs as the unprivileged `agent` user (uid 3000), so only that user can log in.
FROM node:24.22.1-trixie-slim@sha256:89c5244bc22a9bc3287d89ebc7e49b9cb5bb84cd40e6175ac3421d5a9f68b95a

# renovate: datasource=npm depName=@openai/codex
ARG CODEX_VERSION=0.165.0

# Common CLI tools for agents. No pip/npm registry egress at runtime, so
# Python is stdlib-only.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bc ca-certificates curl diffutils fd-find file git jq less openssh-server \
      patch procps python3 ripgrep sqlite3 tini tree unzip xz-utils zip \
 && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_* \
 && ln -s /usr/bin/fdfind /usr/local/bin/fd \
 && npm install -g "@openai/codex@${CODEX_VERSION}" \
 && npm cache clean --force \
 && groupadd -g 3000 agent \
 && useradd -u 3000 -g 3000 -m -d /home/agent -s /bin/bash agent \
 && usermod -p '*' agent \
 && codex --version

# yq (mikefarah, Go) from its official image; Debian's yq is a different tool.
COPY --from=docker.io/mikefarah/yq:4.54.1@sha256:4b3d9475d65571d28cbb19544d3820ec2945e4c8b2f18279394282b8dc3a592e /usr/bin/yq /usr/local/bin/yq

COPY sshd_config /etc/agent-box/sshd_config
COPY --chmod=0755 entrypoint.sh /usr/local/bin/agent-box-entrypoint

USER 3000:3000
WORKDIR /home/agent
EXPOSE 2222
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/agent-box-entrypoint"]
