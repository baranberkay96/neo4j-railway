# Sourced by the official docker-entrypoint.sh (EXTENSION_SCRIPT) as root, after neo4j.conf
# has been written and right before Neo4j starts. Do not `exit` here: that would stop the
# entrypoint (which runs with bash -eu). Handles the password of the 'neo4j' user:
#
#   First boot (no system database yet): DB_PASSWORD becomes the initial password. If it is
#   unusable (shorter than 8 characters, or 'neo4j'), the instance is locked with a random
#   password nobody knows and the log says how to fix it; the deploy does not fail
#   (STANDARD 8.29).
#   Later boots: with DB_PASSWORD_RESET=true, or while the instance is locked, Neo4j is
#   started once on 127.0.0.1 with authentication off, the password of 'neo4j' is set to
#   DB_PASSWORD, and Neo4j is stopped again before the normal start.

railway_log() { printf '[railway-password] %s\n' "$*"; }

railway_password_ok() {
  local pw="$1"
  [ "${#pw}" -ge 8 ] && [ "${pw}" != neo4j ] && [[ "${pw}" != *[[:cntrl:]]* ]]
}

railway_cypher_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\'/\\\'}"
  printf "'%s'" "${s}"
}

railway_set_password_offline() {
  local pw="$1" conf setting waited=0 ok=1
  conf="$(mktemp -d /tmp/railway-recovery-conf.XXXXXX)"
  cp -a "${NEO4J_HOME}/conf/." "${conf}/"
  for setting in dbms.security.auth_enabled server.default_listen_address server.http.enabled \
                 server.https.enabled server.bolt.tls_level server.bolt.listen_address server.bolt.advertised_address; do
    sed -i "/^[[:space:]]*${setting//./\\.}[[:space:]]*=/d" "${conf}/neo4j.conf"
  done
  printf '\n%s\n' \
    "dbms.security.auth_enabled=false" \
    "server.default_listen_address=127.0.0.1" \
    "server.http.enabled=false" \
    "server.https.enabled=false" \
    "server.bolt.tls_level=DISABLED" \
    "server.bolt.listen_address=127.0.0.1:7687" >> "${conf}/neo4j.conf"
  chown -R neo4j:neo4j "${conf}"
  chmod 0700 "${conf}"

  railway_log "starting Neo4j on 127.0.0.1 without authentication to set the password of 'neo4j'"
  if ! NEO4J_CONF="${conf}" su-exec neo4j:neo4j neo4j start >/dev/null 2>&1; then
    railway_log "WARNING: the temporary Neo4j did not start; password unchanged."
    rm -rf "${conf}"
    return 1
  fi
  until su-exec neo4j:neo4j cypher-shell -a bolt://127.0.0.1:7687 -u neo4j -p unused -d system \
          --non-interactive "SHOW DATABASES YIELD name RETURN count(*)" >/dev/null 2>&1; do
    if [ "${waited}" -ge 300 ]; then
      railway_log "WARNING: the temporary Neo4j did not answer within 300 s; password unchanged."
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done
  if [ "${waited}" -lt 300 ]; then
    if su-exec neo4j:neo4j cypher-shell -a bolt://127.0.0.1:7687 -u neo4j -p unused -d system --non-interactive \
         --param "{pw: $(railway_cypher_string "${pw}")}" \
         'ALTER USER neo4j SET PASSWORD $pw CHANGE NOT REQUIRED' >/dev/null 2>/tmp/railway-alter.err; then
      ok=0
    else
      railway_log "WARNING: setting the password failed: $(tail -n 1 /tmp/railway-alter.err)"
    fi
    rm -f /tmp/railway-alter.err
  fi
  NEO4J_CONF="${conf}" su-exec neo4j:neo4j neo4j stop >/dev/null 2>&1
  rm -f "${NEO4J_HOME}/run/neo4j.pid"
  rm -rf "${conf}"
  return "${ok}"
}

railway_password() {
  local pw="${DB_PASSWORD:-}" reset="${DB_PASSWORD_RESET:-false}" marker=/data/.railway/locked
  mkdir -p /data/.railway && chmod 0700 /data/.railway

  if [ ! -d /data/databases/system ]; then
    if railway_password_ok "${pw}"; then
      ${neo4j_admin_cmd} dbms set-initial-password "${pw}" >/dev/null && rm -f "${marker}" \
        && railway_log "initial password of 'neo4j' set from DB_PASSWORD"
    else
      ${neo4j_admin_cmd} dbms set-initial-password "$(openssl rand -hex 32)" >/dev/null
      touch "${marker}"
      railway_log "WARNING: DB_PASSWORD is shorter than 8 characters (or is 'neo4j'). The instance is LOCKED with a random password. Set DB_PASSWORD to at least 8 characters and redeploy to unlock it."
    fi
    return 0
  fi

  if [ "${reset,,}" = true ] || [ -e "${marker}" ]; then
    if ! railway_password_ok "${pw}"; then
      if [ -e "${marker}" ]; then
        railway_log "WARNING: the instance is still LOCKED: DB_PASSWORD must have at least 8 characters (and not be 'neo4j')."
      else
        railway_log "WARNING: DB_PASSWORD_RESET=true but DB_PASSWORD is unusable (under 8 characters or 'neo4j'); password unchanged."
      fi
      return 0
    fi
    if railway_set_password_offline "${pw}"; then
      rm -f "${marker}"
      railway_log "password of 'neo4j' set from DB_PASSWORD. Set DB_PASSWORD_RESET back to false."
    fi
  fi
  return 0
}

# Called in a || list so that the entrypoint's `set -e` never stops the start from in here.
railway_password || railway_log "WARNING: password handling failed; Neo4j starts with the stored password."
