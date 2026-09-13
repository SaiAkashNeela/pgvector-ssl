#!/bin/bash
# init-pgvector.sh — runs once during initdb from /docker-entrypoint-initdb.d/.
#
# Auto-enables the pgvector extension so application code never needs a manual
# CREATE EXTENSION:
#   - template1: every future CREATE DATABASE (which copies template1 by
#     default) inherits vector automatically.
#   - the maintenance database (postgres) and $POSTGRES_DB: usable immediately.
#   - template0 is rebuilt as a clone of the seeded template1 (stock
#     template flags), so whichever template a CREATE DATABASE names,
#     vector is already there.
#
# This is the fresh-init half. wrapper-pgvector.sh (this variant's own
# entrypoint) is the other half: every few minutes it CREATEs where missing
# (and UPDATEs when the image's default extension version moved) in
# template1 and in each existing connectable database, and rebuilds the
# template0 clone when it is missing, misflagged, or stale — so volumes
# initialized before this file existed heal on their own.
#
# Opt-out: set PGVECTOR_AUTO_INSTALL_DISABLED=1. Both this script and
# wrapper-pgvector.sh honor it.
#
# Runs as the postgres user inside docker-entrypoint's gosu context.

set -e

if [ "${PGVECTOR_AUTO_INSTALL_DISABLED:-0}" = "1" ]; then
  echo "pgvector: auto-install disabled (PGVECTOR_AUTO_INSTALL_DISABLED=1); skipping"
  exit 0
fi

PG_SUPERUSER="${POSTGRES_USER:-postgres}"
DEFAULT_DB="${POSTGRES_DB:-$PG_SUPERUSER}"

# template1 first (future databases inherit it), then the databases that
# exist now. Dedup: POSTGRES_DB commonly equals the superuser name, and
# either can equal postgres.
seen=""
for db in template1 postgres "$DEFAULT_DB"; do
  case " $seen " in
    *" $db "*) continue ;;
  esac
  seen="$seen $db"
  echo "pgvector: creating extension vector in database ${db}"
  psql -v ON_ERROR_STOP=1 --username "$PG_SUPERUSER" --dbname "$db" \
    -c "CREATE EXTENSION IF NOT EXISTS vector;"
done

# template0 is rebuilt as a clone of the seeded template1 and given the
# stock template flags (usable as a template, no direct connections), so
# whichever template a CREATE DATABASE names, vector is already there.
# (DROP the stock one first: initdb's template0 lacks the extension. Unflag
# before dropping — Postgres refuses to DROP a database still marked as a
# template — and use one statement per psql call, since DROP/CREATE
# DATABASE cannot run inside the transaction block psql -c wraps multiple
# statements in.)
echo "pgvector: rebuilding template0 as a clone of template1"
psql -v ON_ERROR_STOP=1 --username "$PG_SUPERUSER" --dbname template1 \
  -c "UPDATE pg_database SET datistemplate = false WHERE datname = 'template0';"
psql -v ON_ERROR_STOP=1 --username "$PG_SUPERUSER" --dbname template1 \
  -c "DROP DATABASE IF EXISTS template0;"
psql -v ON_ERROR_STOP=1 --username "$PG_SUPERUSER" --dbname template1 \
  -c "CREATE DATABASE template0 TEMPLATE template1;"
psql -v ON_ERROR_STOP=1 --username "$PG_SUPERUSER" --dbname template1 \
  -c "UPDATE pg_database SET datistemplate = true, datallowconn = false WHERE datname = 'template0';"
psql -v ON_ERROR_STOP=1 --username "$PG_SUPERUSER" --dbname template1 -qAt \
  -c "SELECT 'vector=' || extversion FROM pg_extension WHERE extname = 'vector';" > "$PGDATA/.pgvector_template0_clone"

echo "pgvector: extension ensured (seeded:${seen})"
