# pg-core

Cloudcafe's CNPG-compatible PostgreSQL image. Extends the upstream CNPG `Standard` variant with the extensions Cloudcafe apps need but the upstream image doesn't ship.

- **Registry**: `ghcr.io/cloud-cafe-dev/pg-core`
- **Built by**: `.github/workflows/build.yml`
- **Consumed by**: [`cloudcafe/core`](https://git.cloudcafe.dev/cloudcafe/core) — `pg/kube/prod/cluster.yaml` `spec.imageName`

This repo is intentionally hosted on GitHub (not on Cloudcafe's own Gitea). The cluster pulls this image during CNPG rolling restarts, when our own Gitea/Authentik may be transiently degraded. Hosting on ghcr.io removes any Cloudcafe-internal dependency from the pull path, which eliminates a chicken-and-egg deadlock the Cloudcafe team hit during a previous attempt to host the image internally.

## Extensions

| Extension | Origin | Purpose |
|---|---|---|
| `pgroonga` | added (apt: packages.groonga.org) | Zulip full-text search |
| `tsearch_extras` | added (source build) | Zulip search ranking |
| `vector` (pgvector) | inherited from CNPG Standard | Open WebUI embeddings, future LLM apps |
| `pgaudit` | inherited from CNPG Standard | Available if audit logging is wanted (requires `shared_preload_libraries=pgaudit` set on the cluster) |

Add a new extension only when an app needs it. Unused extensions are still maintenance surface.

## Tagging policy

Two tags pushed per `main` build:

- `ghcr.io/cloud-cafe-dev/pg-core:17-<short-sha>` — **immutable**, the only tag that should be referenced from cloudcafe/core's `cluster.yaml`.
- `ghcr.io/cloud-cafe-dev/pg-core:17-latest` — **floating**, for humans browsing the registry. Never used by manifests.

Cluster adoption is always a manual `cluster.yaml` PR. ArgoCD never silently rolls the database — image rebuilds land in the registry but the cluster only adopts a new image when a human bumps `imageName` to a new SHA tag.

## Pinning policy

The `Dockerfile` pins:

- `CNPG_BASE` to a specific minor tag **and** SHA digest (`17.6-standard-bookworm@sha256:...`).
- `TSEARCH_EXTRAS_REF` to a specific commit SHA on `zulip/tsearch_extras`.

`renovate.json` auto-PRs base SHA bumps. `tsearch_extras` is bumped manually because the upstream tags lag behind `main` and not every commit is verified against current PostgreSQL minor versions.

## Local build and smoke test

CI runs the same loop on every PR and main push, so failing locally typically means failing in CI too.

```sh
docker build -t pg-core:test .

docker run -d --name pgtest \
  --entrypoint /bin/bash \
  pg-core:test \
  -c '
    set -e
    PGDATA=/var/lib/postgresql/data
    export PATH=/usr/lib/postgresql/17/bin:$PATH
    mkdir -p "$PGDATA"
    initdb --auth-host=trust --auth-local=trust --username=postgres "$PGDATA"
    postgres -D "$PGDATA" -c listen_addresses="*" -c shared_preload_libraries=pgaudit
  '

until docker exec pgtest pg_isready -U postgres; do sleep 1; done

for ext in pgroonga tsearch_extras vector pgaudit; do
  docker exec pgtest psql -U postgres -c "CREATE EXTENSION ${ext};"
done

docker rm -f pgtest
```

The `--entrypoint /bin/bash` + manual `initdb` + `postgres` invocation is needed because the CNPG base image strips the upstream `docker-entrypoint.sh` (CNPG's instance manager replaces it in production).

## First-publish setup

After the first successful workflow run on `main`, the published package will be private by default on ghcr.io. To make it pullable by anonymous clients:

1. Open `https://github.com/orgs/cloud-cafe-dev/packages` → `pg-core` → Package settings.
2. Change visibility to **Public**.

Without this step, kubelet pulling from a Kubernetes cluster will get 401 unless an `imagePullSecret` is configured.

## Bumping the base image (PostgreSQL minor patch)

PostgreSQL 17.6 → 17.7 (or future minors):

1. Update `CNPG_BASE` ARG default in `Dockerfile` to the new tag and SHA digest.
2. Open a PR. CI builds and smoke-tests the image; merge requires green.
3. After merge, find the new `:17-<short-sha>` tag in ghcr.io.
4. Open a PR in `cloudcafe/core` bumping `pg/kube/prod/cluster.yaml` `imageName` to that SHA tag. Schedule for a low-traffic window — CNPG performs a rolling restart.
5. Verify post-rollout per cloudcafe/core's `docs/apps/pg.md` § Custom image.

Renovate typically opens the first PR automatically. The cluster bump is always a deliberate human action.

## Bumping for a PostgreSQL major version (17 → 18+)

Discrete project. Steps:

1. Verify all extensions ship for the new major (`pgroonga`, `tsearch_extras`, `vector`, `pgaudit`).
2. Bump `Dockerfile` `CNPG_BASE` and `postgresql-17-pgdg-pgroonga` / `postgresql-server-dev-17` package names to the new major.
3. Build and smoke-test. Plan a CNPG major upgrade in cloudcafe/core separately — that involves `pg_upgrade` or logical replication, not just an `imageName` bump.

## Adding a new extension

If a future app needs an extension not currently baked in:

1. Add the install steps to `Dockerfile` (apt or source build).
2. Add the extension name to the smoke-test loop in `.github/workflows/build.yml`.
3. Update the table in this README and in cloudcafe/core's `docs/apps/pg.md` § Custom image.
4. After the image lands, the consuming app enables it declaratively via the CNPG `Database` CR's `extensions` field — no `cluster.yaml` change needed.

## Recovery from a registry outage

ghcr.io has substantially better availability than this homelab. The realistic outage modes are:

- **GitHub Actions outage** preventing new builds — affects only the ability to ship updates, not running clusters; existing `imageName` references continue to pull fine.
- **ghcr.io outage during a rolling restart** — kubelet `imagePullPolicy: IfNotPresent` (k8s default for non-`:latest` tags) means already-cached images on the node still start; only first-pulls of new tags are affected.
- **Permanent loss** — the Dockerfile and workflow here are the source of truth; anyone with this repo can rebuild and republish.

If pulling ever genuinely fails for an extended period, fall back to `ghcr.io/cloudnative-pg/postgresql:17` in cloudcafe/core's `cluster.yaml`. Apps that depend on the custom extensions (today: Zulip) stay degraded until pulls work again; everything else keeps running. The PG17 → PG17 transition is data-safe.

## Security and supply-chain notes

- Build-essential and `postgresql-server-dev-17` are purged in the same `RUN` layer that builds tsearch_extras, so the final image carries no compiler toolchain.
- The Groonga apt repo is signed; the keyring is fetched once over HTTPS and stored at `/usr/share/keyrings/groonga-archive-keyring.gpg`.
- The image runs as uid `26` (CNPG's expected non-root user). CNPG's instance manager refuses to start as root.
- Workflow auth uses the built-in `${{ secrets.GITHUB_TOKEN }}` with `permissions: packages: write` only — no PAT, no broader scope, automatic rotation per workflow run.
