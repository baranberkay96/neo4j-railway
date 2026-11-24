# Notice

## Upstream software

This repository contains Railway configuration and small scripts only. Neo4j, Caddy and rclone are pulled at build time from their official container images; they are not stored in this repository.

| Software | License | Source (publisher) |
|---|---|---|
| Neo4j 5.26.34 Community Edition (with the APOC core plugin bundled in the image) | GPL-3.0 (Neo4j Community Edition); Apache-2.0 (APOC core) | `neo4j:5.26.34-community-trixie@sha256:2c48628bc28c68d7e2787f76262dfc9d7c21a8f7f290e30da901c489aa7fe50d` (Docker Official Image, maintained by Neo4j) |
| Caddy 2.11.9 | Apache-2.0 | `caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0` (Docker Official Image) |
| rclone 1.76.0 | MIT | `rclone/rclone:1.76.0@sha256:7cbeec24a44f206067597c0368be4de90ae19a64d5113c7d1938bd737a81e466` |
| OpenSSL, curl, jq, zstd | their own licenses (Debian packages) | Debian trixie |

Neo4j Community Edition source: https://github.com/neo4j/neo4j (GPL-3.0). Docker image source: https://github.com/neo4j/docker-neo4j.

## Verified against

| What | Upstream file | Ref | Checked |
|---|---|---|---|
| Current releases (`5.26.34` LTS, `2026.10.2` calendar line) | Docker Hub tags of `neo4j` | 5.26.34 | 2026-11-24 |
| Entrypoint: `NEO4J_*` to settings, plugins, `NEO4J_AUTH`, `EXTENSION_SCRIPT` hook, `bash -eu` | `docker-image-src/5/coredb/docker-entrypoint.sh`, `neo4j-plugins.json`, `Dockerfile-trixie` | master (5.x) | 2026-11-24 |
| Launcher reads `HEAP_SIZE` itself (helper variables renamed to `MEMORY_*`) | Observed on the test deploy (`-Xmsauto`) | 5.26.34 | 2026-11-24 |
| Bolt TLS (`dbms.ssl.policy.bolt.*`, `server.bolt.tls_level`), listen/advertised addresses, memory settings | Neo4j Operations Manual 5 | 5.26 | 2026-11-24 |
| APOC `apoc.export.cypher.all` (stream, `cypher-shell` format) | APOC 5 documentation | 5.26 | 2026-11-24 |

## Adapted code

| Our file | Source | Changes |
|---|---|---|
| `services/neo4j/railway-start.sh`, `railway-extension.sh`, `Caddyfile` | Written for this template | — |
| `services/backup/neo4j-backup.sh` | Our CouchDB Railway template's backup script (same author): Bucket/rclone setup, retention, run layout | Neo4j export over the HTTP API, cypher-shell restore into an empty database |

## Trademarks

"Neo4j" is a trademark of Neo4j, Inc.; "Railway", "Caddy" and "rclone" belong to their respective owners. This is a community template and is not affiliated with or endorsed by them.
