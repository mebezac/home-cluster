# Job image for the tofu-runner Forgejo Actions labels (kubernetes/apps/tofu/tofu-runner).
# tofu plus the tools the gate script needs: sh/bash, git, jq, curl. No node, so
# workflows use plain `run:` steps, not `uses:` actions.
#
# Since OpenTofu 1.10 the official image is a binary donor only: copy tofu out
# of the -minimal image. Keep this tofu version equal to the mise pin in
# laboratory-casa/silo-tofu.
FROM ghcr.io/opentofu/opentofu:1.13.9-minimal@sha256:84af0049634b7a7c455ab79c485818a8ef7f775cad3b2d42ce1c98ade720b5d1 AS tofu

FROM docker.io/library/alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a
RUN apk add --no-cache bash ca-certificates curl git jq
COPY --from=tofu /usr/local/bin/tofu /usr/local/bin/tofu
# The job pod runs as 3000 with a read-only root filesystem. HOME is on the
# /tmp emptyDir of the podspec; the runner mounts the job workdir itself.
ENV HOME=/tmp/home \
    TF_IN_AUTOMATION=1 \
    CHECKPOINT_DISABLE=1
USER 3000:3000
