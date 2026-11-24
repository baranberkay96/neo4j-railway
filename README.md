# Deploy and Host Neo4j with Railway

Neo4j is a native graph database: data is stored as nodes and relationships and queried with Cypher. This community template runs Neo4j 5.26 LTS Community Edition with the APOC library, Neo4j Browser on your HTTPS domain, Bolt for drivers through a Railway TCP proxy, a generated password, and a daily backup job that writes to a Railway Bucket.

## About Hosting Neo4j

Neo4j needs one long-running server with persistent storage, enough memory for its JVM heap and page cache, and two ways in: HTTP for Neo4j Browser and the HTTP API, and the Bolt protocol for application drivers. This template runs the official Neo4j image on a Railway volume and puts a small Caddy proxy in front of it, so Neo4j Browser on the HTTPS domain reaches Bolt over a secure WebSocket on the same domain. Drivers connect through a Railway TCP proxy, with TLS on Bolt using a self-signed certificate. Authentication is always on: the password of the `neo4j` user is generated at deploy. Memory is sized from the service's limit, and a cron job exports the graph every night with APOC while Neo4j keeps running.

## Common Use Cases

- Knowledge graphs and GraphRAG backends for LLM applications (LangChain, LlamaIndex)
- Recommendation engines, fraud detection and network or IT dependency analysis
- Identity, access and master-data graphs that are awkward in relational tables
- Learning Cypher and prototyping graph models with Neo4j Browser

## Dependencies for Neo4j Hosting

- Neo4j 5.26.34 LTS Community Edition (Docker Official Image `neo4j`, pinned by digest) with APOC core 5.26
- Caddy 2.11 (inside the Neo4j service) for Browser, HTTP API and Bolt over WebSocket on one domain
- A Railway Bucket and rclone 1.76 for backups

### Deployment Dependencies

- Neo4j Operations Manual (Docker): https://neo4j.com/docs/operations-manual/5/docker/
- Neo4j configuration settings: https://neo4j.com/docs/operations-manual/5/configuration/configuration-settings/
- APOC export to Cypher: https://neo4j.com/docs/apoc/5/export/cypher/
- Neo4j drivers: https://neo4j.com/docs/create-applications/

### Implementation Details

| Service | Role | Public |
|---|---|---|
| Neo4j | Neo4j server (volume `/data`: databases, transaction logs, Bolt certificate) and Caddy on `PORT` 8080 | HTTPS domain (Browser, HTTP API, Bolt over WebSocket) and a TCP proxy to Bolt 7687 |
| Neo4j Backup | Cron job, 03:30 UTC daily: APOC Cypher export, zstd, upload to the Bucket, retention | no |
| Bucket | Railway Bucket holding the backups | no |

**First login**

1. Wait until the Neo4j service is healthy (the first deploy builds two thin images, about 3-5 minutes).
2. Copy `DB_PASSWORD` from the Neo4j service's Variables. The user is `neo4j`.
3. Open the service's public domain. You land on Neo4j Browser with the connect URL `bolt+s://{your-domain}:443` filled in; choose username/password and sign in.

**Connecting applications**

- From other Railway services (private network): `bolt://neo4j.railway.internal:7687`, user `neo4j`, password `${{Neo4j.DB_PASSWORD}}`.
- From outside Railway: the TCP proxy shown under the service's Networking settings, as `bolt+ssc://{proxy-host}:{proxy-port}` or `neo4j+ssc://{proxy-host}:{proxy-port}` (encrypted; the certificate is self-signed, so the driver does not verify it). Plain `bolt://` also works unless you set `BOLT_TLS=required`.
- JavaScript in a browser, or tools that need a trusted certificate: `bolt+s://{your-domain}:443` (Bolt over WebSocket through the HTTPS domain).
- HTTP API: `https://{your-domain}/db/neo4j/query/v2` or `/db/neo4j/tx/commit` with basic auth.

**Password.** `DB_PASSWORD` is set as the initial password on the first boot. Change it later in Browser (`ALTER CURRENT USER SET PASSWORD FROM 'old' TO 'new'`) and update `DB_PASSWORD` so the backup job keeps working. Forgot it? Set a new `DB_PASSWORD` and `DB_PASSWORD_RESET=true`, redeploy (Neo4j starts once on localhost without authentication to set it), then set `DB_PASSWORD_RESET` back to `false`. A password shorter than 8 characters never breaks the deploy: on the first boot the instance is locked with a random password until you set a valid `DB_PASSWORD` and redeploy.

**Memory.** `MEMORY_HEAP` and `MEMORY_PAGECACHE` default to `auto`: 30% and 20% of the service's memory limit, each capped at 1 GB. For larger graphs set them explicitly (for example `4g` and `8g`) and give the service enough memory; the page cache should hold your store files for the best speed. Neo4j's `NEO4J_*` variables are passed straight to Neo4j and are validated strictly: a misspelled one stops Neo4j, so this template keeps its own options outside that prefix.

**Plugins.** `PLUGINS` is a JSON list; APOC core is bundled. Others from the official image's list (for example `graph-data-science` or `n10s`) are downloaded at boot.

**Backups and restore.** Neo4j Community Edition has no online backup, and `neo4j-admin database dump` needs the database stopped. The Neo4j Backup job therefore uses `apoc.export.cypher.all`: schema, nodes and relationships as a Cypher script, written while Neo4j keeps serving, compressed and stored as `neo4j/{UTC timestamp}/neo4j.cypher.zst` with a `MANIFEST.txt`. Runs older than 14 days are pruned, at least 3 are kept. Users and passwords (system database) are not included. To restore into an empty database: empty it in Browser if needed (`MATCH (n) DETACH DELETE n`), open the Neo4j Backup service's settings, set the start command to `/usr/local/bin/neo4j-backup restore` (optionally `RESTORE_RUN={timestamp}`) and remove the cron schedule for now, so the next deploy runs it once; deploy, check the log, then clear the start command and put the schedule `30 3 * * *` back. For very large graphs, prefer offline dumps or Railway volume backups as well.

**Resources and plans.** Measured on Railway (2026-11-24): with `auto` sizing on a large memory limit (1 GB heap, 1 GB page cache) Neo4j used about 1.6 GB of RAM after a backup and restore had warmed it up; under a 1 GB limit (Trial plan) it starts with a 285 MB heap and 190 MB page cache, uses about 0.8 GB (including file cache) and serves small graphs. The backup job only runs a few seconds a day. Expect roughly $8-18 a month depending on the graph; Hobby or Pro is recommended for real data.

**Scaling.** Community Edition is a single server (clustering is Enterprise only). Raise the service's memory and CPU and the two memory variables as the graph grows.

**Upgrading.** The versions are pinned in `services/neo4j/Dockerfile` and `services/backup/Dockerfile` (tag and digest). Neo4j upgrades the store format on start within the 5.x line; take a backup first. Moving to Neo4j 2025.x/2026.x calendar versions is a separate, documented migration.

**License.** Neo4j Community Edition is licensed under GPL-3.0; APOC core under Apache-2.0. This is a community template, not affiliated with or endorsed by Neo4j, Inc.

### Why Deploy Neo4j on Railway?

Railway runs Neo4j, its backup job and the Bucket in one project with a private network, an HTTPS domain, a TCP proxy, persistent volumes, logs and usage-based pricing. This template gives you a secured, ready-to-use graph database in a few minutes: Browser and drivers work out of the box, nothing is left open without a password, and nightly backups land in object storage.
