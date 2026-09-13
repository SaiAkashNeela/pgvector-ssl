#!/bin/bash
# ssl-init.sh — self-contained SSL setup for the pgvector variant image
# (Dockerfile.pgvector). Runs once during initdb from
# /docker-entrypoint-initdb.d/.
#
# Generates a self-signed CA + server certificate and enables ssl in
# postgresql.conf. Depends on nothing except the official postgres base
# image and openssl.
#
# Runs as the postgres user inside docker-entrypoint's gosu context.

set -e

SSL_DIR="${PGDATA}/certs"
SSL_SERVER_CRT="$SSL_DIR/server.crt"
SSL_SERVER_KEY="$SSL_DIR/server.key"
SSL_SERVER_CSR="$SSL_DIR/server.csr"
SSL_ROOT_KEY="$SSL_DIR/root.key"
SSL_ROOT_CRT="$SSL_DIR/root.crt"
SSL_V3_EXT="$SSL_DIR/v3.ext"
POSTGRES_CONF_FILE="$PGDATA/postgresql.conf"

SSL_CERT_DAYS_VALUE="${SSL_CERT_DAYS:-820}"
case "$SSL_CERT_DAYS_VALUE" in
  ''|0|*[!0-9]*)
    echo "ssl-init: SSL_CERT_DAYS='${SSL_CERT_DAYS}' is not a positive integer; using 820" >&2
    SSL_CERT_DAYS_VALUE=820
    ;;
esac

mkdir -p "$SSL_DIR"

openssl req -new -x509 -days "$SSL_CERT_DAYS_VALUE" -nodes -text \
  -out "$SSL_ROOT_CRT" -keyout "$SSL_ROOT_KEY" -subj "/CN=root-ca"
chmod 600 "$SSL_ROOT_KEY"

openssl req -new -nodes -text \
  -out "$SSL_SERVER_CSR" -keyout "$SSL_SERVER_KEY" -subj "/CN=localhost"
chmod 600 "$SSL_SERVER_KEY"

SSL_SAN="DNS:localhost"
if [ -n "${RAILWAY_PRIVATE_DOMAIN:-}" ]; then
  SSL_SAN="${SSL_SAN},DNS:${RAILWAY_PRIVATE_DOMAIN}"
fi

cat > "$SSL_V3_EXT" <<EOF
[v3_req]
authorityKeyIdentifier = keyid, issuer
basicConstraints = critical, CA:TRUE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = ${SSL_SAN}
EOF

rm -f "$SSL_DIR/root.srl"
openssl x509 -req -in "$SSL_SERVER_CSR" -extfile "$SSL_V3_EXT" -extensions v3_req \
  -text -days "$SSL_CERT_DAYS_VALUE" \
  -CA "$SSL_ROOT_CRT" -CAkey "$SSL_ROOT_KEY" -CAcreateserial \
  -out "$SSL_SERVER_CRT"

if ! grep -q "^ssl_cert_file = '$SSL_SERVER_CRT'" "$POSTGRES_CONF_FILE" 2>/dev/null; then
  cat >> "$POSTGRES_CONF_FILE" <<EOF
ssl = on
ssl_cert_file = '$SSL_SERVER_CRT'
ssl_key_file = '$SSL_SERVER_KEY'
ssl_ca_file = '$SSL_ROOT_CRT'
EOF
fi

echo "ssl-init: certificates generated in $SSL_DIR (valid ${SSL_CERT_DAYS_VALUE} days)"
