#!/bin/bash
# Start Neo4j Community and Caddy on Railway.
#
# Deploy-form values are validated here and turned into Neo4j settings; invalid values fall
# back to safe defaults with a warning instead of failing the deploy (STANDARD 8.29). The
# official image converts every NEO4J_* variable into a setting with strict validation, so
# this template keeps its own knobs outside that prefix (STANDARD 8.18):
#
#   DB_PASSWORD            password of the 'neo4j' user (initial password; see the extension script)
#   DB_PASSWORD_RESET      true = set the password of 'neo4j' to DB_PASSWORD on this boot
#   MEMORY_HEAP            JVM heap (not HEAP_SIZE: Neo4j's own launcher reads that name), e.g. 512m or 2g; auto = sized from the memory limit
#   MEMORY_PAGECACHE         page cache, e.g. 512m or 2g; auto = sized from the memory limit
#   BOLT_ADVERTISED_ADDRESS  host:port drivers are told to use (the Railway TCP proxy)
#   BOLT_TLS               disabled | optional | required (TLS on Bolt with a self-signed certificate)
#   PLUGINS                JSON list of Neo4j plugins, e.g. ["apoc"]
set -uo pipefail

log() { printf '[railway-start] %s\n' "$*"; }

# ---- memory -------------------------------------------------------------------------------
limit_mib() {
  local raw
  raw="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo max)"
  if [[ "${raw}" =~ ^[0-9]+$ ]] && [ "${raw}" -lt $((1 << 50)) ]; then
    echo $((raw / 1048576))
  else
    awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo
  fi
}

clamp() { local v="$1" lo="$2" hi="$3"; [ "${v}" -lt "${lo}" ] && v="${lo}"; [ "${v}" -gt "${hi}" ] && v="${hi}"; echo "${v}"; }

size_or_auto() {
  # Echo a valid Neo4j size (e.g. 512m, 2g) or "auto".
  local name="$1" value="${2,,}"
  if [ -z "${value}" ] || [ "${value}" = auto ]; then
    echo auto
  elif [[ "${value}" =~ ^[1-9][0-9]{0,5}[mg]$ ]]; then
    echo "${value}"
  else
    log "WARNING: ${name}='$2' is not a size like 512m or 2g; using auto." >&2
    echo auto
  fi
}

configure_memory() {
  local mem heap cache heap_auto cache_auto
  mem="$(limit_mib)"
  # Small instances: ~30% heap and ~20% page cache leave room for the JVM's own memory,
  # Caddy and the OS. Large limits are capped; raise MEMORY_HEAP/MEMORY_PAGECACHE for big graphs.
  heap_auto="$(clamp $((mem * 30 / 100)) 256 1024)m"
  cache_auto="$(clamp $((mem * 20 / 100)) 128 1024)m"
  heap="$(size_or_auto MEMORY_HEAP "${MEMORY_HEAP:-auto}")"
  cache="$(size_or_auto MEMORY_PAGECACHE "${MEMORY_PAGECACHE:-auto}")"
  [ "${heap}" = auto ] && heap="${heap_auto}"
  [ "${cache}" = auto ] && cache="${cache_auto}"
  export NEO4J_server_memory_heap_initial__size="${heap}"
  export NEO4J_server_memory_heap_max__size="${heap}"
  export NEO4J_server_memory_pagecache_size="${cache}"
  log "memory limit ${mem} MiB: heap ${heap}, page cache ${cache}"
  if [ "${mem}" -lt 900 ]; then
    log "WARNING: less than 1 GB of memory; Neo4j may be killed under load. Use a plan with at least 1 GB per service."
  fi
}

# ---- network --------------------------------------------------------------------------------
configure_network() {
  # Bolt and HTTP listen on all interfaces (IPv4 and IPv6, private network); the public HTTPS
  # domain reaches them only through Caddy on PORT.
  export NEO4J_server_default__listen__address="::"
  export NEO4J_server_bolt_listen__address=":7687"
  export NEO4J_server_http_listen__address=":7474"
  export NEO4J_server_https_enabled="false"

  local adv="${BOLT_ADVERTISED_ADDRESS:-}"
  if [[ "${adv}" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]]; then
    export NEO4J_server_bolt_advertised__address="${adv}"
    log "Bolt advertised to drivers as ${adv}"
  else
    [ -n "${adv}" ] && [ "${adv}" != ":" ] && log "WARNING: BOLT_ADVERTISED_ADDRESS='${adv}' is not host:port; not advertising it."
    unset NEO4J_server_bolt_advertised__address
  fi

  local tls="${BOLT_TLS:-optional}"
  tls="${tls,,}"
  case "${tls}" in
    disabled|optional|required) ;;
    *) log "WARNING: BOLT_TLS='${BOLT_TLS}' is not disabled, optional or required; using optional."; tls=optional ;;
  esac
  if [ "${tls}" = disabled ]; then
    export NEO4J_server_bolt_tls__level="DISABLED"
  else
    if bolt_certificate; then
      export NEO4J_dbms_ssl_policy_bolt_enabled="true"
      export NEO4J_dbms_ssl_policy_bolt_base__directory="/data/certificates/bolt"
      export NEO4J_dbms_ssl_policy_bolt_client__auth="NONE"
      export NEO4J_server_bolt_tls__level="${tls^^}"
      log "Bolt TLS ${tls} (self-signed certificate in /data/certificates/bolt; drivers use bolt+ssc:// or neo4j+ssc://)"
    else
      log "WARNING: could not create the Bolt TLS certificate; Bolt runs without TLS on this boot."
      export NEO4J_server_bolt_tls__level="DISABLED"
    fi
  fi
}

bolt_certificate() {
  local dir=/data/certificates/bolt cn="${BOLT_ADVERTISED_ADDRESS%%:*}"
  mkdir -p "${dir}/trusted" "${dir}/revoked" || return 1
  if [ ! -s "${dir}/private.key" ] || [ ! -s "${dir}/public.crt" ]; then
    [[ "${cn}" =~ ^[A-Za-z0-9.-]+$ ]] || cn="neo4j.railway.internal"
    log "creating a self-signed Bolt certificate for ${cn}"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=${cn}" \
      -addext "subjectAltName=DNS:${cn},DNS:localhost,IP:127.0.0.1" \
      -keyout "${dir}/private.key" -out "${dir}/public.crt" >/dev/null 2>&1 || return 1
  fi
  chown -R neo4j:neo4j /data/certificates && chmod 0600 "${dir}/private.key"
}

# ---- plugins ------------------------------------------------------------------------------
configure_plugins() {
  local plugins="${PLUGINS-[\"apoc\"]}" known
  unset NEO4J_PLUGINS NEO4JLABS_PLUGINS
  [ -z "${plugins}" ] && { log "no plugins requested"; return; }
  known="$(jq -c 'keys' /startup/neo4j-plugins.json)"
  if echo "${plugins}" | jq -e --argjson known "${known}" \
       'type == "array" and length > 0 and all(.[]; type == "string" and (. as $p | $known | index($p)))' >/dev/null 2>&1; then
    export NEO4J_PLUGINS="${plugins}"
    log "plugins: ${plugins}"
    if echo "${plugins}" | jq -e 'index("apoc")' >/dev/null && [ -z "${NEO4J_dbms_security_procedures_unrestricted:-}" ]; then
      export NEO4J_dbms_security_procedures_unrestricted="apoc.*"
    fi
  else
    log "WARNING: PLUGINS='${plugins}' is not a JSON list of known plugins (${known}); using [\"apoc\"]."
    export NEO4J_PLUGINS='["apoc"]'
    [ -z "${NEO4J_dbms_security_procedures_unrestricted:-}" ] && export NEO4J_dbms_security_procedures_unrestricted="apoc.*"
  fi
}

# ---- processes ------------------------------------------------------------------------------
NEO4J_PID=""
CADDY_PID=""

shutdown() {
  log "stopping"
  [ -n "${NEO4J_PID}" ] && kill -TERM "${NEO4J_PID}" 2>/dev/null
  [ -n "${CADDY_PID}" ] && kill -TERM "${CADDY_PID}" 2>/dev/null
  wait "${NEO4J_PID}" 2>/dev/null
  exit 0
}

main() {
  # Fixed internal values: users set the public port through PORT only.
  [[ "${PORT:-}" =~ ^[0-9]{2,5}$ ]] && [ "${PORT}" != 7474 ] && [ "${PORT}" != 7687 ] || { log "WARNING: PORT='${PORT:-}' unusable; using 8080."; export PORT=8080; }
  # A leftover NEO4J_AUTH would bypass our password handling (and '/' in it stops the image).
  unset NEO4J_AUTH NEO4J_AUTH_PATH
  # Neo4j's launcher reads HEAP_SIZE itself (as -Xms/-Xmx); memory comes from MEMORY_HEAP only.
  unset HEAP_SIZE
  export TINI_SUBREAPER=1
  mkdir -p /data

  configure_memory
  configure_network
  configure_plugins
  export EXTENSION_SCRIPT=/startup/railway-extension.sh

  trap shutdown TERM INT

  caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
  CADDY_PID=$!

  tini -g -- /startup/docker-entrypoint.sh neo4j &
  NEO4J_PID=$!

  # Whichever exits first ends the container; Railway restarts it (restart policy ALWAYS).
  wait -n "${NEO4J_PID}" "${CADDY_PID}"
  local code=$?
  log "a process exited (code ${code}); stopping the container so Railway restarts it"
  kill -TERM "${NEO4J_PID}" "${CADDY_PID}" 2>/dev/null
  wait 2>/dev/null
  exit "${code}"
}

main "$@"
