#!/bin/bash
#
# wrapper-pgvector.sh — entrypoint for the pgvector variant image
# (Dockerfile.pgvector). Self-contained: depends on nothing in this repo
# except the official postgres base image's own docker-entrypoint.sh.
#
# On every boot, before handing off to the official entrypoint:
#   1. SSL: if the cluster is already initialized, make sure a valid server
#      certificate exists (generate one if missing, regenerate if it is not
#      an x509v3 SAN certificate or expires within 30 days) and that
#      postgresql.conf enables ssl. Fresh clusters skip this — ssl-init.sh
#      handles initdb.
#   2. pgvector: fork a background ensure, repeated every
#      PGVECTOR_ENSURE_INTERVAL_SECONDS (default 300), that keeps template0
#      as a clone of template1 (rebuilt when missing, misflagged, or cloned
#      from an older vector version), CREATEs the `vector` extension where
#      missing — template1 first, so every future CREATE DATABASE inherits
#      it — and UPDATEs an outdated vector catalog. Never fails the boot.
#
# Then runs the official docker-entrypoint.sh in the FOREGROUND (never
# exec'd, so background helpers stay children of this shell and never of
# the postmaster) and shapes the exit code for restart policies.
#
# Knobs:
#   PGVECTOR_AUTO_INSTALL_DISABLED=1 — skip both vector halves (binaries
#     stay installed).
#   PGVECTOR_ENSURE_INTERVAL_SECONDS — how often the boot-time ensure
#     re-runs (default 300; 0 = once at boot).
#   SSL_CERT_DAYS — certificate validity period (default 820).

set -e

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
SSL_DIR="$PGDATA/certs"
POSTGRES_CONF_FILE="$PGDATA/postgresql.conf"

# Local libpq calls must always reach this container's own postgres:
# a customer-set PGHOST/PGHOSTADDR/PGPORT would divert them.
unset PGHOST
unset PGHOSTADDR
unset PGPORT

pgvector_ssl_days() {
  local days="${SSL_CERT_DAYS:-820}"
  case "$days" in
    ''|0|*[!0-9]*)
      echo "wrapper-pgvector: SSL_CERT_DAYS='${SSL_CERT_DAYS}' is not a positive integer; using 820" >&2
      days=820
      ;;
  esac
  printf '%s' "$days"
}

pgvector_ssl_san() {
  local san="DNS:localhost"
  if [ -n "${RAILWAY_PRIVATE_DOMAIN:-}" ]; then
    san="${san},DNS:${RAILWAY_PRIVATE_DOMAIN}"
  fi
  printf '%s' "$san"
}

pgvector_write_certs() {
  local days="$1" san="$2"
  mkdir -p "$SSL_DIR"
  chown postgres:postgres "$SSL_DIR"
  openssl req -new -x509 -days "$days" -nodes -text \
    -out "$SSL_DIR/root.crt" -keyout "$SSL_DIR/root.key" -subj "/CN=root-ca"
  chmod 600 "$SSL_DIR/root.key"
  openssl req -new -nodes -text \
    -out "$SSL_DIR/server.csr" -keyout "$SSL_DIR/server.key" -subj "/CN=localhost"
  chown postgres:postgres "$SSL_DIR/server.key"
  chmod 600 "$SSL_DIR/server.key"
  cat > "$SSL_DIR/v3.ext" <<EOF
[v3_req]
authorityKeyIdentifier = keyid, issuer
basicConstraints = critical, CA:TRUE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = ${san}
EOF
  rm -f "$SSL_DIR/root.srl"
  openssl x509 -req -in "$SSL_DIR/server.csr" -extfile "$SSL_DIR/v3.ext" -extensions v3_req \
    -text -days "$days" \
    -CA "$SSL_DIR/root.crt" -CAkey "$SSL_DIR/root.key" -CAcreateserial \
    -out "$SSL_DIR/server.crt"
  chown postgres:postgres "$SSL_DIR/server.crt" "$SSL_DIR/root.crt"
}

# Synchronous pre-entrypoint SSL check. No-ops on a fresh volume
# (postgresql.conf does not exist yet — ssl-init.sh runs during initdb).
ensure_ssl() {
  [ -f "$POSTGRES_CONF_FILE" ] || return 0
  local days regen=0
  days=$(pgvector_ssl_days)
  if [ ! -f "$SSL_DIR/server.crt" ] || [ ! -f "$SSL_DIR/server.key" ] || [ ! -f "$SSL_DIR/root.crt" ]; then
    echo "wrapper-pgvector: server certificate missing; generating"
    regen=1
  elif ! openssl x509 -noout -text -in "$SSL_DIR/server.crt" 2>/dev/null | grep -q "DNS:localhost"; then
    echo "wrapper-pgvector: server certificate is not x509v3 with SAN; regenerating"
    regen=1
  elif ! openssl x509 -checkend 2592000 -noout -in "$SSL_DIR/server.crt" 2>/dev/null; then
    echo "wrapper-pgvector: server certificate expired or expiring within 30 days; regenerating"
    regen=1
  fi
  if [ "$regen" = "1" ]; then
    pgvector_write_certs "$days" "$(pgvector_ssl_san)"
  fi
  if ! grep -qE "^[[:space:]]*ssl[[:space:]]*=" "$POSTGRES_CONF_FILE" 2>/dev/null; then
    echo "wrapper-pgvector: enabling ssl in postgresql.conf"
    cat >> "$POSTGRES_CONF_FILE" <<EOF
ssl = on
ssl_cert_file = '$SSL_DIR/server.crt'
ssl_key_file = '$SSL_DIR/server.key'
ssl_ca_file = '$SSL_DIR/root.crt'
EOF
  fi
}

fork_pgvector_ensure() {
  if [ "${PGVECTOR_AUTO_INSTALL_DISABLED:-0}" = "1" ]; then
    echo "pgvector-ensure: disabled (PGVECTOR_AUTO_INSTALL_DISABLED=1); skipping"
    return 0
  fi
  (
    trap '' INT TERM  # background helper: never catch the stop signal mid-statement
    i=0
    while ! gosu postgres pg_isready -q 2>/dev/null; do
      sleep 2
      i=$((i + 1))
      [ "$i" -ge 120 ] && exit 0
    done

    # Connect as the cluster's actual superuser: a custom-POSTGRES_USER
    # cluster has no 'postgres' role (the entrypoint initdb's with
    # --username="$POSTGRES_USER"). template1 always exists, so it is the
    # safe target regardless of POSTGRES_DB.
    _pgv_psql() { gosu postgres psql -h /var/run/postgresql -p 5432 -U "${POSTGRES_USER:-postgres}" "$@"; }

    # Which vector version the template0 clone was built from. Compared
    # against template1's live version every pass; a mismatch rebuilds it.
    clone_marker="$PGDATA/.pgvector_template0_clone"

    # Rebuilds template0 as a fresh clone of template1 with stock template
    # flags (usable as a template, no direct connections). Tolerates every
    # intermediate failure — a half-finished rebuild just retries next pass.
    pgvector_rebuild_template0() {
      echo "pgvector-ensure: rebuilding template0 as a clone of template1"
      _pgv_psql -v ON_ERROR_STOP=0 -qAt -d template1 -c "UPDATE pg_database SET datistemplate = false WHERE datname = 'template0'" 2>/dev/null || true
      _pgv_psql -v ON_ERROR_STOP=0 -qAt -d template1 -c "DROP DATABASE IF EXISTS template0" 2>&1 \
        | while IFS= read -r line; do [ -n "$line" ] && echo "pgvector-ensure: $line"; done
      _pgv_psql -v ON_ERROR_STOP=0 -qAt -d template1 -c "CREATE DATABASE template0 TEMPLATE template1" 2>&1 \
        | while IFS= read -r line; do [ -n "$line" ] && echo "pgvector-ensure: $line"; done
      _pgv_psql -v ON_ERROR_STOP=0 -qAt -d template1 -c "UPDATE pg_database SET datistemplate = true, datallowconn = false WHERE datname = 'template0'" 2>&1 \
        | while IFS= read -r line; do [ -n "$line" ] && echo "pgvector-ensure: $line"; done
      local ver tmp
      ver="$(_pgv_psql -qAt -d template1 -c "SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'vector'" 2>/dev/null)" || ver=""
      if [ -n "$ver" ]; then
        tmp="$(mktemp "${clone_marker}.XXXX")" || return 0
        printf 'vector=%s\n' "$ver" > "$tmp" || { rm -f "$tmp"; return 0; }
        chown postgres:postgres "$tmp" 2>/dev/null || true
        mv "$tmp" "$clone_marker" 2>/dev/null || rm -f "$tmp"
      fi
    }

    # One ensure pass. Quiet when there is nothing to do: the vector block
    # only raises when it actually creates or updates, and the template0
    # clone is only rebuilt when missing, misflagged, or stale — so a
    # steady-state pass logs nothing.
    pgvector_ensure_pass() {
      if [ "$(_pgv_psql -qAt -d template1 -c 'SELECT pg_is_in_recovery()' 2>/dev/null)" != "f" ]; then
        echo "pgvector-ensure: postgres is in recovery; skipping this pass"
        return 0
      fi

      # template0 is a clone of template1 (stock template flags) on this
      # image. Rebuild it when it is missing, its flags drifted, or it was
      # cloned from an older vector version — so whichever template a
      # CREATE DATABASE names, vector is already there.
      local clone_shape clone_live_ver clone_marker_ver clone_needs_rebuild
      clone_shape="$(_pgv_psql -qAt -d template1 -c "SELECT count(*) FROM pg_database WHERE datname = 'template0' AND datistemplate AND NOT datallowconn" 2>/dev/null)" || clone_shape=""
      clone_live_ver="$(_pgv_psql -qAt -d template1 -c "SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'vector'" 2>/dev/null)" || clone_live_ver=""
      clone_marker_ver=""
      [ -f "$clone_marker" ] && clone_marker_ver="$(cat "$clone_marker" 2>/dev/null)" || true
      clone_needs_rebuild=0
      [ "$clone_shape" != "1" ] && clone_needs_rebuild=1
      if [ -n "$clone_live_ver" ] && [ "$clone_marker_ver" != "vector=$clone_live_ver" ]; then
        clone_needs_rebuild=1
      fi
      if [ "$clone_needs_rebuild" = "1" ]; then
        pgvector_rebuild_template0 || true
      fi

      ensure_sql="$(cat << 'ENDSQL'
DO $body$
DECLARE
  already boolean;
  installed text;
  available text;
BEGIN
  SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'vector') INTO already;
  IF NOT already THEN
    BEGIN
      EXECUTE 'CREATE EXTENSION vector';
      RAISE NOTICE 'vector extension created';
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'vector create failed: %', SQLERRM;
    END;
  END IF;
  SELECT e.extversion, ae.default_version INTO installed, available
  FROM pg_catalog.pg_extension e
  JOIN pg_catalog.pg_available_extensions ae ON ae.name = e.extname
  WHERE e.extname = 'vector';
  IF installed IS NOT NULL AND available IS NOT NULL AND installed <> available THEN
    BEGIN
      EXECUTE 'ALTER EXTENSION vector UPDATE';
      RAISE NOTICE 'vector updated % -> %', installed, available;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'vector update % -> % failed: %', installed, available, SQLERRM;
    END;
  END IF;
END
$body$;
ENDSQL
)"
      # template1 FIRST: every CREATE DATABASE copies template1, so this
      # keeps "no manual intervention, ever" true for databases that don't
      # exist yet.
      _pgv_psql -v ON_ERROR_STOP=0 -qAt -d template1 -c "$ensure_sql" 2>&1 \
        | while IFS= read -r line; do [ -n "$line" ] && echo "pgvector-ensure: [template1] $line"; done
      dbs=$(_pgv_psql -qAt -c "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate" 2>/dev/null) || return 0
      while IFS= read -r db; do
        [ -z "$db" ] && continue
        _pgv_psql -v ON_ERROR_STOP=0 -qAt -d "$db" -c "$ensure_sql" 2>&1 \
          | while IFS= read -r line; do [ -n "$line" ] && echo "pgvector-ensure: [$db] $line"; done
      done <<< "$dbs"
    }

    interval="${PGVECTOR_ENSURE_INTERVAL_SECONDS:-300}"
    case "$interval" in ''|*[!0-9]*) interval=300 ;; esac
    while true; do
      pgvector_ensure_pass || true
      [ "$interval" = "0" ] && exit 0
      sleep "$interval"
    done
  ) &
}

ensure_ssl
fork_pgvector_ensure

STOP_REQUESTED=0
trap 'STOP_REQUESTED=1' TERM INT

ENTRYPOINT_EXIT=0
/usr/local/bin/docker-entrypoint.sh "$@" || ENTRYPOINT_EXIT=$?

if [ "$ENTRYPOINT_EXIT" -ne 0 ]; then
  exit "$ENTRYPOINT_EXIT"
fi
if [ "$STOP_REQUESTED" = "1" ]; then
  exit 0
fi
echo "wrapper-pgvector: postgres exited cleanly but no stop was requested; exiting nonzero so the restart policy can recover the database"
exit 1
