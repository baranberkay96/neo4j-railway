#!/bin/bash
# Neo4j backups to a Railway Bucket, with retention. Runs once and exits ("Neo4j Backup" is a
# Railway cron job).
#
#   neo4j-backup backup    export the graph -> Bucket, verify, prune (default)
#   neo4j-backup list      list the backup runs stored in the Bucket
#   neo4j-backup restore   load RESTORE_RUN into the database; only into an EMPTY database
#
# Neo4j Community has no online backup (neo4j-admin database dump needs the database stopped).
# This job uses APOC's cypher export instead: `apoc.export.cypher.all` streams the schema
# (indexes, constraints), nodes and relationships as a cypher-shell script while Neo4j keeps
# serving. The export is read over Neo4j's HTTP API on the private network, compressed with
# zstd and uploaded with rclone. Users and passwords (system database) are not part of it.
#
# Bucket layout (one folder per run, UTC timestamp):
#   {BACKUP_PREFIX}/20261124T033000Z/{database}.cypher.zst
#   {BACKUP_PREFIX}/20261124T033000Z/MANIFEST.txt    written last; a run without it is incomplete
set -Eeuo pipefail

PREFIX="${BACKUP_PREFIX:-neo4j}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
KEEP_MIN="${BACKUP_KEEP_MIN:-3}"
ZSTD_LEVEL="${BACKUP_ZSTD_LEVEL:-6}"
WAIT_SECONDS="${BACKUP_WAIT_SECONDS:-300}"
DATABASE="${DB_NAME:-neo4j}"
INCOMPLETE_GRACE_DAYS=2
RUN_RE='^[0-9]{8}T[0-9]{6}Z$'
REMOTE=""
HTTP_BASE=""
BOLT_URI=""
WORK="${TMPDIR:-/tmp}/neo4j-backup.$$"

log() { printf '[neo4j-backup] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

require_uint() {
  [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge "$3" ] || die "$1 must be a whole number >= $3 (got '$2')"
}

validate_settings() {
  require_uint BACKUP_RETENTION_DAYS "${RETENTION_DAYS}" 1
  require_uint BACKUP_KEEP_MIN "${KEEP_MIN}" 1
  require_uint BACKUP_WAIT_SECONDS "${WAIT_SECONDS}" 0
  require_uint BACKUP_ZSTD_LEVEL "${ZSTD_LEVEL}" 1
  [ "${ZSTD_LEVEL}" -le 19 ] || die "BACKUP_ZSTD_LEVEL must be 1-19"
  [[ "${PREFIX}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] && [[ "/${PREFIX}/" != */./* ]] && [[ "/${PREFIX}/" != */../* ]] \
    || die "BACKUP_PREFIX must be a folder path of letters, digits, '.', '_' and '-'"
  [[ "${DATABASE}" =~ ^[A-Za-z][A-Za-z0-9.-]{2,62}$ ]] || die "DB_NAME '${DATABASE}' is not a Neo4j database name"
  local var missing=()
  for var in DB_HOST DB_USER DB_PASSWORD; do
    [ -n "${!var:-}" ] || missing+=("${var}")
  done
  [ "${#missing[@]}" -eq 0 ] || die "Neo4j connection not configured (missing: ${missing[*]})"
  HTTP_BASE="http://${DB_HOST}:${DB_HTTP_PORT:-7474}"
  BOLT_URI="bolt://${DB_HOST}:${DB_BOLT_PORT:-7687}"
  mkdir -p "${WORK}"
  chmod 0700 "${WORK}"
  printf 'user = "%s:%s"\n' "${DB_USER}" "${DB_PASSWORD//\"/\\\"}" > "${WORK}/curl.conf"
}

configure_remote() {
  local var missing=()
  for var in BACKUP_S3_BUCKET BACKUP_S3_ENDPOINT BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY; do
    [ -n "${!var:-}" ] || missing+=("${var}")
  done
  [ "${#missing[@]}" -eq 0 ] || die "Bucket not configured (missing: ${missing[*]})"
  export RCLONE_CONFIG="${HOME:-/tmp}/rclone.conf"
  : > "${RCLONE_CONFIG}"
  export RCLONE_CONFIG_BUCKET_TYPE=s3
  export RCLONE_CONFIG_BUCKET_PROVIDER=Other
  export RCLONE_CONFIG_BUCKET_ENDPOINT="${BACKUP_S3_ENDPOINT}"
  export RCLONE_CONFIG_BUCKET_REGION="${BACKUP_S3_REGION:-auto}"
  export RCLONE_CONFIG_BUCKET_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID}"
  export RCLONE_CONFIG_BUCKET_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY}"
  export RCLONE_CONFIG_BUCKET_FORCE_PATH_STYLE="${BACKUP_S3_FORCE_PATH_STYLE:-false}"
  export RCLONE_CONFIG_BUCKET_NO_CHECK_BUCKET=true
  export RCLONE_CONFIG_BUCKET_CHUNK_SIZE=16M
  REMOTE="bucket:${BACKUP_S3_BUCKET}/${PREFIX}"
}

# Run one Cypher statement over the HTTP API; the JSON response goes to stdout.
cypher_http() {
  jq -n --arg q "$1" '{statements: [{statement: $q}]}' \
    | curl -sS --fail -K "${WORK}/curl.conf" --max-time "${2:-120}" -H 'Content-Type: application/json' \
        -H 'Accept: application/json' --data-binary @- "${HTTP_BASE}/db/${DATABASE}/tx/commit"
}

# First value of a single-row query, or fail on a Cypher error.
cypher_value() {
  local out
  out="$(cypher_http "$1")" || return 1
  if [ "$(jq '.errors | length' <<< "${out}")" != 0 ]; then
    log "Cypher error: $(jq -r '.errors[0].code + ": " + .errors[0].message' <<< "${out}" | head -c 300)" >&2
    return 1
  fi
  jq -r '.results[0].data[0].row[0]' <<< "${out}"
}

wait_for_neo4j() {
  local waited=0
  until NEO4J_VERSION="$(cypher_value 'CALL dbms.components() YIELD versions RETURN versions[0]' 2>/dev/null)"; do
    [ "${waited}" -ge "${WAIT_SECONDS}" ] && die "Neo4j at ${HTTP_BASE} not ready (or login refused) after ${WAIT_SECONDS}s"
    log "waiting for Neo4j at ${HTTP_BASE}"
    sleep 10
    waited=$((waited + 10))
  done
}

counts() {
  printf '%s %s' "$(cypher_value 'MATCH (n) RETURN count(n)')" "$(cypher_value 'MATCH ()-[r]->() RETURN count(r)')"
}

run_backup() {
  local run_id dest obj nodes rels size lines
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="${REMOTE}/${run_id}"
  obj="${DATABASE}.cypher.zst"
  read -r nodes rels <<< "$(counts)"
  log "starting run ${run_id} -> ${PREFIX}/${run_id}/ in bucket ${BACKUP_S3_BUCKET} (Neo4j ${NEO4J_VERSION}, database ${DATABASE}: ${nodes} node(s), ${rels} relationship(s))"
  # The streamed export arrives as rows of script batches; the whole response is kept on
  # local disk once so that an error reported at the end of the stream is never uploaded.
  cypher_http "CALL apoc.export.cypher.all(null, {stream: true, format: 'cypher-shell', useOptimizations: {type: 'UNWIND_BATCH', unwindBatchSize: 100}}) YIELD cypherStatements RETURN cypherStatements" 3600 \
    > "${WORK}/export.json" || die "export request failed"
  if [ "$(jq '.errors | length' "${WORK}/export.json")" != 0 ]; then
    die "export failed: $(jq -r '.errors[0].code + ": " + .errors[0].message' "${WORK}/export.json" | head -c 300)"
  fi
  jq -r '.results[0].data[].row[0] // empty' "${WORK}/export.json" | zstd -q -T0 "-${ZSTD_LEVEL}" | rclone rcat --retries 1 "${dest}/${obj}" \
    || die "upload failed"
  rm -f "${WORK}/export.json"
  lines="$(rclone cat "${dest}/${obj}" | zstd -q -dc | wc -l)" || die "the uploaded backup does not decompress"
  if [ "${nodes}" -gt 0 ] && [ "${lines}" -eq 0 ]; then
    die "the uploaded backup is empty although the database has ${nodes} node(s)"
  fi
  size="$(rclone size --json "${dest}/${obj}" 2>/dev/null | sed -nE 's/.*"bytes":[[:space:]]*([0-9]+).*/\1/p')"
  printf 'run=%s\nneo4j_version=%s\ndatabase=%s\nnodes=%s\nrelationships=%s\nformat=apoc.export.cypher.all cypher-shell script, zstd level %s\nobject=%s (%s bytes, %s lines)\n' \
    "${run_id}" "${NEO4J_VERSION}" "${DATABASE}" "${nodes}" "${rels}" "${ZSTD_LEVEL}" "${obj}" "${size:-?}" "${lines}" \
    | rclone rcat "${dest}/MANIFEST.txt"
  log "run ${run_id} complete: ${obj}, ${size:-?} bytes compressed, ${lines} script lines (read back and decompressed)"
  CURRENT_RUN="${run_id}"
}

list_runs() {
  rclone lsf --dirs-only "${REMOTE}/" 2>/dev/null | sed 's#/$##' | grep -E "${RUN_RE}" | sort || true
}

list_complete_runs() {
  rclone lsf -R --files-only --max-depth 2 --include 'MANIFEST.txt' "${REMOTE}/" 2>/dev/null \
    | sed 's#/MANIFEST.txt$##' | grep -E "${RUN_RE}" | sort || true
}

prune() {
  local now cutoff incomplete_cutoff complete=() run keep protected=" " total
  now="$(date -u +%s)"
  cutoff="$(date -u -d "@$((now - RETENTION_DAYS * 86400))" +%Y%m%dT%H%M%SZ)"
  incomplete_cutoff="$(date -u -d "@$((now - INCOMPLETE_GRACE_DAYS * 86400))" +%Y%m%dT%H%M%SZ)"
  while IFS= read -r run; do [ -n "${run}" ] && complete+=("${run}"); done < <(list_complete_runs)
  total="${#complete[@]}"
  keep=$((total - KEEP_MIN))
  for run in ${complete[@]+"${complete[@]}"}; do
    if [ "${keep}" -le 0 ]; then protected="${protected}${run} "; fi
    keep=$((keep - 1))
  done
  log "retention: ${total} complete run(s), keep ${RETENTION_DAYS} days, at least ${KEEP_MIN}"
  while IFS= read -r run; do
    [ -n "${run}" ] || continue
    [ "${run}" = "${CURRENT_RUN:-}" ] && continue
    case "${protected}" in *" ${run} "*) continue ;; esac
    if printf '%s\n' ${complete[@]+"${complete[@]}"} | grep -qx "${run}"; then
      [[ "${run}" < "${cutoff}" ]] || continue
      log "deleting expired run ${run}"
    else
      [[ "${run}" < "${incomplete_cutoff}" ]] || continue
      log "deleting incomplete run ${run}"
    fi
    rclone purge "${REMOTE}/${run}" || log "WARNING: could not delete ${run}"
  done < <(list_runs)
}

show_runs() {
  local complete=" " run
  while IFS= read -r run; do complete="${complete}${run} "; done < <(list_complete_runs)
  while IFS= read -r run; do
    [ -n "${run}" ] || continue
    case "${complete}" in *" ${run} "*) printf '%s complete\n' "${run}" ;; *) printf '%s incomplete\n' "${run}" ;; esac
  done < <(list_runs)
}

# Load a backup into the database, which must be empty (no nodes): an existing graph is never
# overwritten or merged. Empty it first in Neo4j Browser (MATCH (n) DETACH DELETE n) if needed.
run_restore() {
  local run="${RESTORE_RUN:-latest}" obj nodes rels uri
  if [ "${run}" = latest ]; then
    run="$(list_complete_runs | tail -n 1)"
    [ -n "${run}" ] || die "no complete backup run in ${PREFIX}/"
  fi
  [[ "${run}" =~ ${RUN_RE} ]] || die "RESTORE_RUN must be 'latest' or a run folder like 20261124T033000Z"
  obj="${RESTORE_DATABASE:-${DATABASE}}.cypher.zst"
  rclone lsf "${REMOTE}/${run}/" | grep -qxF "${obj}" || die "${PREFIX}/${run}/${obj} does not exist"
  read -r nodes rels <<< "$(counts)"
  [ "${nodes}" = 0 ] || die "database ${DATABASE} is not empty (${nodes} node(s)); restore only loads into an empty database"
  rclone cat "${REMOTE}/${run}/${obj}" | zstd -q -dc > "${WORK}/restore.cypher" || die "download failed"
  # Bolt on the private network: plain first, then TLS with the self-signed certificate
  # (BOLT_TLS=required on the Neo4j service).
  for uri in "${BOLT_URI}" "${BOLT_URI/bolt:/bolt+ssc:}"; do
    if NEO4J_PASSWORD="${DB_PASSWORD}" cypher-shell -a "${uri}" -u "${DB_USER}" -d "${DATABASE}" --non-interactive "RETURN 1" >/dev/null 2>&1; then
      log "restoring ${PREFIX}/${run}/${obj} into ${DATABASE} over ${uri%%://*}"
      NEO4J_PASSWORD="${DB_PASSWORD}" cypher-shell -a "${uri}" -u "${DB_USER}" -d "${DATABASE}" --non-interactive \
        --fail-fast -f "${WORK}/restore.cypher" > /dev/null || die "cypher-shell failed; the database is partly restored"
      read -r nodes rels <<< "$(counts)"
      log "restore finished: ${DATABASE} has ${nodes} node(s) and ${rels} relationship(s)"
      return 0
    fi
  done
  die "could not connect to Bolt at ${BOLT_URI}"
}

main() {
  # A Railway start command such as "/usr/local/bin/neo4j-backup restore" arrives as
  # arguments of the entrypoint; drop the repeated program name.
  case "${1:-}" in */neo4j-backup | neo4j-backup) shift ;; esac
  local cmd="${1:-backup}"
  case "${cmd}" in
    backup)
      validate_settings
      configure_remote
      wait_for_neo4j
      run_backup
      prune
      log "done"
      ;;
    list)
      configure_remote
      show_runs
      ;;
    restore)
      validate_settings
      configure_remote
      wait_for_neo4j
      run_restore
      ;;
    *) die "unknown command '${cmd}' (use: backup, list, restore)" ;;
  esac
}

main "$@"
