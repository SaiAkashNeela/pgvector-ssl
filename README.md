# postgres-ssl-pgvector

PostgreSQL with pgvector pre-installed, self-signed SSL baked in, and the
`vector` extension enabled automatically in every database. No `CREATE
EXTENSION`, no certificate wrangling — build, run, store embeddings.

Built `FROM` the official [`pgvector/pgvector`](https://hub.docker.com/r/pgvector/pgvector)
image, plus three standalone scripts. There are no other dependencies.

## Features

- **pgvector out of the box.** The binaries come from the official image,
  and the extension is created for you — in `template1`, in the initial
  databases, and in every database you create later.
- **Self-signed SSL, always on.** A CA and server certificate are generated
  at initialization, `ssl` is enabled, and certificates renew themselves
  when they go missing or come within 30 days of expiry.
- **Both templates carry vector.** `template0` is rebuilt as a clone of the
  seeded `template1`, so it doesn't matter which template a `CREATE
  DATABASE` names — the extension is already there.
- **Self-healing.** A background loop (every 5 minutes by default) recreates
  the extension wherever it's missing, refreshes the `template0` clone when
  it drifts, and moves outdated extension catalogs forward. It only logs
  when it actually changes something, and it can never fail your boot.

## Quickstart

```bash
# pgvector 0.8.6 on PostgreSQL 17
docker build -f Dockerfile.pgvector -t postgres-ssl-pgvector:17 .

docker run -d --name pgvector \
  -e POSTGRES_PASSWORD=secret \
  -p 5432:5432 \
  -v pgdata:/var/lib/postgresql/data \
  postgres-ssl-pgvector:17
```

Connect with SSL enforced:

```bash
psql "host=localhost port=5432 dbname=postgres user=postgres password=secret sslmode=require"
```

## Storing embeddings

No setup step — `vector` already exists in every database, including ones
you create later from psql, `createdb`, or any IDE/GUI:

```sql
CREATE TABLE documents (
  id serial PRIMARY KEY,
  content text,
  embedding vector(3)
);

INSERT INTO documents (content, embedding) VALUES
  ('The Matrix', '[1,2,3]'),
  ('Inception',  '[1.1,2.1,2.9]'),
  ('Toy Story',  '[8,7,9]');

CREATE INDEX ON documents USING hnsw (embedding vector_l2_ops);

-- nearest neighbors to [1,2,3]
SELECT content
FROM documents
ORDER BY embedding <-> '[1,2,3]'
LIMIT 3;
```

## Configuration

| Variable | Purpose | Default |
|---|---|---|
| `POSTGRES_PASSWORD` | Superuser password (standard postgres var) | — |
| `POSTGRES_USER` / `POSTGRES_DB` | Superuser / initial database (standard postgres vars) | `postgres` |
| `SSL_CERT_DAYS` | Certificate validity period, in days | `820` |
| `PGVECTOR_AUTO_INSTALL_DISABLED=1` | Skip auto-enable and the `template0` upkeep (binaries stay installed; SSL unaffected) | off |
| `PGVECTOR_ENSURE_INTERVAL_SECONDS` | How often the background ensure re-runs (`0` = once at boot) | `300` |

## Other versions

```bash
docker build -f Dockerfile.pgvector \
  --build-arg PGVECTOR_VERSION=0.8.6 --build-arg PG_MAJOR=18 \
  -t postgres-ssl-pgvector:18 .
```

Any `PGVECTOR_VERSION` × `PG_MAJOR` combo published under
`pgvector/pgvector` on Docker Hub works (e.g. `0.8.6-pg18`). Multi-arch
(`amd64` + `arm64`) via buildx:

```bash
docker buildx build -f Dockerfile.pgvector \
  --platform linux/amd64,linux/arm64 \
  -t postgres-ssl-pgvector:17 --push .
```

## How it works

| File | Runs | Does |
|---|---|---|
| `Dockerfile.pgvector` | build | Official pgvector base + `openssl`/`tini` + the scripts below |
| `ssl-init.sh` | once, at initdb | Generates the CA + server cert, enables `ssl` |
| `init-pgvector.sh` | once, at initdb | Creates `vector` in `template1`/`postgres`/`$POSTGRES_DB`, rebuilds `template0` as a clone |
| `wrapper-pgvector.sh` | every boot (entrypoint) | Regenerates expiring certs, then a background loop keeps the extension and the `template0` clone ensured before handing off to the official entrypoint |

Certificate state and the clone stamp live alongside the data so they
survive restarts: certs in `$PGDATA/certs`, the clone version in
`$PGDATA/.pgvector_template0_clone`.

## License

MIT — see [LICENSE](LICENSE).
