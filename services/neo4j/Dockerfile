# Neo4j Community for Railway: the official image plus
#   - Caddy in front of Neo4j's HTTP port, so Neo4j Browser on the Railway HTTPS domain
#     reaches Bolt over a secure WebSocket on the same domain (wss://{domain}:443),
#   - a start wrapper that validates every deploy-form value before Neo4j sees it
#     (the image turns NEO4J_* variables into settings with strict validation),
#   - an extension script that sets the initial password, locks the instance with a
#     random password when the configured one is unusable, and recovers it later.
#
# Pinned by tag and digest. To upgrade, change both to a newer release:
# https://hub.docker.com/_/neo4j/tags (5.26 is Neo4j's long-term-support line)
ARG CADDY_IMAGE=caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0
FROM ${CADDY_IMAGE} AS caddy

FROM neo4j:5.26.34-community-trixie@sha256:2c48628bc28c68d7e2787f76262dfc9d7c21a8f7f290e30da901c489aa7fe50d

RUN apt-get update \
 && apt-get install --no-install-recommends -o Acquire::Retries=10 -y openssl \
 && rm -rf /var/lib/apt/lists/*

COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY --chmod=0755 railway-start.sh /usr/local/bin/railway-start
COPY --chmod=0755 railway-extension.sh /startup/railway-extension.sh
COPY --chmod=0644 Caddyfile /etc/caddy/Caddyfile

RUN caddy version \
 && caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile \
 && openssl version \
 && ls /var/lib/neo4j/labs/apoc-*-core.jar \
 && bash -n /usr/local/bin/railway-start \
 && bash -n /startup/railway-extension.sh

ENTRYPOINT ["/usr/local/bin/railway-start"]
