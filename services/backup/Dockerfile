# Neo4j Backup (Railway cron job): an online logical backup of the graph with APOC's
# cypher export (works on Community Edition while Neo4j keeps running), compressed with
# zstd and uploaded to a Railway Bucket with rclone. Restores use cypher-shell from the
# same Neo4j release, so the backup image is the Neo4j image itself (not started).
FROM rclone/rclone:1.76.0@sha256:7cbeec24a44f206067597c0368be4de90ae19a64d5113c7d1938bd737a81e466 AS rclone

FROM neo4j:5.26.34-community-trixie@sha256:2c48628bc28c68d7e2787f76262dfc9d7c21a8f7f290e30da901c489aa7fe50d

RUN apt-get update \
 && apt-get install --no-install-recommends -o Acquire::Retries=10 -y curl jq zstd ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone
COPY --chmod=0755 neo4j-backup.sh /usr/local/bin/neo4j-backup

ENV HOME=/tmp

RUN rclone version >/dev/null \
 && cypher-shell --version \
 && zstd --version >/dev/null \
 && jq --version >/dev/null \
 && bash -n /usr/local/bin/neo4j-backup

USER neo4j
WORKDIR /tmp

ENTRYPOINT ["/usr/local/bin/neo4j-backup"]
CMD ["backup"]
