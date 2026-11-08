# Job image for the tofu-runner Forgejo Actions labels (kubernetes/apps/tofu/tofu-runner).
# tofu plus the tools the gate script needs: sh/bash, git, jq, curl. No node, so
# workflows use plain `run:` steps, not `uses:` actions.
#
# Since OpenTofu 1.10 the official image is a binary donor only: copy tofu out
# of the -minimal image. Keep this tofu version equal to the mise pin in
# laboratory-casa/silo-tofu.
FROM ghcr.io/opentofu/opentofu:1.13.2-minimal@sha256:622dc6bb98b105c18f53cf419ab64a4f3b88bd9f8c16cc978cf89e4202f4613f AS tofu

FROM docker.io/library/alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf
RUN apk add --no-cache bash ca-certificates curl git jq
COPY --from=tofu /usr/local/bin/tofu /usr/local/bin/tofu
# The job pod runs as 3000 with a read-only root filesystem. HOME is on the
# /tmp emptyDir of the podspec; the runner mounts the job workdir itself.
ENV HOME=/tmp/home \
    TF_IN_AUTOMATION=1 \
    CHECKPOINT_DISABLE=1
USER 3000:3000
