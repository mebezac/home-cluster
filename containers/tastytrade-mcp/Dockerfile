# tastytrade's official MCP server (stdio only) behind supergateway, which
# serves it as stateful Streamable HTTP on :8000/mcp. Stateful = one server
# process per MCP session, so the dry-run confirmation tokens (kept in memory)
# survive between calls. Upstream publishes no image and no tags, so the source
# is pinned by commit.
ARG NODE_IMAGE=node:24.22.1-trixie-slim@sha256:89c5244bc22a9bc3287d89ebc7e49b9cb5bb84cd40e6175ac3421d5a9f68b95a

FROM ${NODE_IMAGE} AS build
# renovate: datasource=git-refs depName=https://github.com/tastytrade/tastytrade-mcp branch=main
ARG TASTYTRADE_MCP_REF=7f2bb636a8a1906fecc28f5da27ab382dd966941
# renovate: datasource=npm depName=supergateway
ARG SUPERGATEWAY_VERSION=4.2.1
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git init -q . \
 && git fetch -q --depth 1 https://github.com/tastytrade/tastytrade-mcp.git "${TASTYTRADE_MCP_REF}" \
 && git checkout -q FETCH_HEAD \
 && npm ci --ignore-scripts \
 && npm run build \
 && npm prune --omit=dev
WORKDIR /gw
RUN npm init -y >/dev/null \
 && npm install --ignore-scripts --omit=dev "supergateway@${SUPERGATEWAY_VERSION}" \
 && npm cache clean --force

FROM ${NODE_IMAGE}
ENV NODE_ENV=production
# The runtime installs nothing; drop the package managers.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
      /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
      /usr/local/bin/yarn /usr/local/bin/yarnpkg /opt/yarn-v* \
 && node --version
# Root-owned on purpose: the server only reads its code.
COPY --from=build /src/node_modules /app/node_modules
COPY --from=build /src/dist /app/dist
COPY --from=build /src/package.json /src/LICENSE /app/
# Read at module load by the static MCP resources.
COPY --from=build /src/tastytrade-llms-txt-docs /app/tastytrade-llms-txt-docs
COPY --from=build /gw/node_modules /opt/supergateway/node_modules
USER 3000:3000
WORKDIR /app
EXPOSE 8000
# SUPERGATEWAY_API_KEY (required bearer key) and the TASTYTRADE_* settings come
# from the environment.
ENTRYPOINT ["node", "/opt/supergateway/node_modules/supergateway/dist/index.js", \
  "--stdio", "node /app/dist/index.js", \
  "--outputTransport", "streamableHttp", "--stateful", \
  "--port", "8000", "--healthEndpoint", "/healthz"]
