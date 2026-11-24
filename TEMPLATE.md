# Neo4j 5.26 LTS Community: composer spec

Listing name: **Neo4j 5.26 LTS Community**
Description (73 chars): Graph database with Browser over HTTPS, Bolt via TCP proxy, daily backups
Category: Storage. Icon: `https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/neo4j.svg`
Repository: `baranberkay96/neo4j-railway` (this folder is the repo root).

## Services

| Service | Source | Public | Volume | Healthcheck |
|---|---|---|---|---|
| Neo4j | repo `/services/neo4j`: `FROM neo4j:5.26.34-community-trixie@sha256:2c48…e50d` + Caddy 2.11.9 + `railway-start.sh`, `railway-extension.sh`, `Caddyfile` | domain → 8080 (Caddy); TCP proxy → 7687 (Bolt) | `/data` | `/` (Neo4j discovery JSON through Caddy), 600 s |
| Neo4j Backup | repo `/services/backup`: same Neo4j image (cypher-shell) + curl/jq/zstd + rclone 1.76.0; cron `30 3 * * *`, restart NEVER | no | — | — (cron job) |
| Bucket | Railway Bucket | no | — | — |

Pinned 2026-11-24: Neo4j 5.26.34 (5.26 is the LTS line; the newer calendar-versioned line is 2026.10.x).

## Boot sequence (Neo4j)

1. `railway-start.sh` validates every deploy-form value and exports the matching `NEO4J_*` settings itself (STANDARD 8.18): memory (`MEMORY_HEAP`/`MEMORY_PAGECACHE`, `auto` = 30 %/20 % of the cgroup limit, 256m-1g/128m-1g), listen `::` (Bolt 7687, HTTP 7474), `server.bolt.advertised_address` from `BOLT_ADVERTISED_ADDRESS` (TCP proxy), Bolt TLS (`BOLT_TLS`, self-signed certificate created once in `/data/certificates/bolt`), plugins (`PLUGINS`, default APOC; `dbms.security.procedures.unrestricted=apoc.*`). `HEAP_SIZE`, `NEO4J_AUTH` are unset (Neo4j's launcher reads `HEAP_SIZE`; '/' in `NEO4J_AUTH` stops the image).
2. Caddy on `PORT` (8080): WebSocket upgrades → Bolt 7687; `GET /` from a browser → redirect to `/browser/?connectURL=bolt%2Bs://{host}:443`; everything else → 7474.
3. The official entrypoint writes `neo4j.conf`, then sources `railway-extension.sh` (`EXTENSION_SCRIPT`): first boot → `neo4j-admin dbms set-initial-password` from `DB_PASSWORD` (or a random one + lock marker if < 8 chars); later boots with `DB_PASSWORD_RESET=true` or the lock marker → temporary Neo4j on 127.0.0.1 with auth disabled, `ALTER USER neo4j SET PASSWORD … CHANGE NOT REQUIRED`, stop.
4. Neo4j console; the wrapper supervises Neo4j and Caddy (either exiting ends the container; restart policy ALWAYS) and forwards SIGTERM.

## Improvements over market templates

Market (2026-11): `sukrutnrvd/neo4j-template` (repo, APOC, password) ≈50 active; `neo4j:5.26-community-bullseye` with `NEO4J_AUTH=none` (no authentication, Bolt open on a TCP proxy) ≈33 active; `neo4j:5.26-community` with password ≈11 active.

- Authentication always on, generated password; invalid passwords never fail the deploy (8.29) and never leave the database open.
- Neo4j Browser actually works on the HTTPS domain (Bolt over `wss://` via Caddy); market templates expose Browser over HTTPS but Bolt only as plain TCP, which a browser on an HTTPS page cannot use.
- Bolt TLS (optional) with a persistent self-signed certificate for drivers through the TCP proxy.
- Memory sized from the container limit (market: fixed 2 g heap + 2 g page cache, which cannot start under Trial's 1 GB).
- Pinned by digest; daily online backups to a Bucket with retention and a tested restore.

## Resources

Measured on Railway, test project, 2026-11-24 (Neo4j 5.26.34):

| Service | Idle RAM | CPU idle |
|---|---|---|
| Neo4j, auto sizing on a large limit (heap 1 g, page cache 1 g), after backup/restore load | 1.6 GB | ~0.004 vCPU |
| Neo4j under a 1 GB limit (heap 285 m, page cache 190 m) | 0.8 GB (incl. file cache) | ~0.004 vCPU |
| Neo4j Backup | 0 (runs seconds per day) | — |

Estimate: ≈ $8-18/month. Minimum plan: Trial works for small graphs under 1 GB; Hobby recommended.

Railway prices: RAM $10/GB-month, vCPU $20/vCPU-month, volume $0.15/GB-month.

## Verification checklist

1. Neo4j SUCCESS; `GET /` 200 (JSON); browser `GET /` → 302 to `/browser/?connectURL=bolt%2Bs…`; `/browser/` 200.
2. HTTP API with `neo4j`/`DB_PASSWORD` 200; wrong password and anonymous 401.
3. Python driver through the TCP proxy with `bolt://`, `bolt+ssc://`, `neo4j+ssc://`; `apoc.version()`.
4. Bolt WebSocket handshake through `wss://{domain}/` negotiates a Bolt 5.x version.
5. Backup cron run → `MANIFEST.txt` written; restore (start command `neo4j-backup restore`, cron schedule removed, deploy) into an emptied database reproduces node/relationship counts, constraints and quoted strings.
6. `DB_PASSWORD=abc` + `DB_PASSWORD_RESET=true` → warning, healthy, old password still valid; valid password + reset → new password works.
7. Redeploy: data, password and certificate persist.

## Open questions

- Neo4j Bloom and Graph Data Science Enterprise features are not available in Community Edition.
- The APOC export holds the whole export in memory on the server side while streaming; very large graphs should also use Railway volume backups or offline dumps.
