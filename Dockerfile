# pg-core — Cloudcafe's CNPG-compatible PostgreSQL image.
#
# Hosted in this public GitHub repo (cloud-cafe-dev/pg-core) and published to
# ghcr.io/cloud-cafe-dev/pg-core. Hosting externally to ghcr.io (rather than in
# Cloudcafe's own Gitea container registry) is deliberate: the cluster pulls
# this image during CNPG rolling restarts, when our own Gitea/Authentik may be
# transiently degraded. ghcr.io has no Cloudcafe dependency, eliminating the
# chicken-and-egg deadlock.
#
# Extends ghcr.io/cloudnative-pg/postgresql:<X>-standard-trixie with extensions
# Cloudcafe apps need that the upstream Standard variant does not ship:
#
#   - pgroonga       — Zulip full-text search (apt: packages.groonga.org)
#   - tsearch_extras — Zulip search ranking (built from source)
#
# Inherited from CNPG Standard:
#
#   - pgvector  — Open WebUI embeddings, future LLM apps
#   - pgaudit   — available if/when audit logging is wanted
#   - LLVM JIT, PostgreSQL locales
#
# See README.md for build/test/bump procedure and pinning policy.

# Base: CNPG Standard for PostgreSQL 18.4 on Debian trixie.
# SHA pinned for reproducibility — Renovate auto-PRs base updates.
ARG CNPG_BASE=ghcr.io/cloudnative-pg/postgresql:18.4-standard-trixie@sha256:58c9a9e29a23b814f8f335ce178727d83bc40d96ed7fe8977192d2d8cdcb3927

FROM ${CNPG_BASE}

# CNPG runs as non-root (uid 26). Switch to root only for build steps; revert at end.
USER root

# pgroonga — install from the official Groonga apt repo.
# packages.groonga.org publishes postgresql-18-pgdg-pgroonga compatible with the
# PGDG-sourced PostgreSQL 18 already present in the CNPG Standard image.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates wget gnupg lsb-release; \
    wget -qO /usr/share/keyrings/groonga-archive-keyring.gpg \
        https://packages.groonga.org/debian/groonga-archive-keyring.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/groonga-archive-keyring.gpg] https://packages.groonga.org/debian/ trixie main" \
        > /etc/apt/sources.list.d/groonga.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        postgresql-18-pgdg-pgroonga; \
    rm -rf /var/lib/apt/lists/*

# tsearch_extras — built from source (no apt package on Debian).
# Pin to a specific commit SHA for reproducibility. Bump deliberately when a
# newer commit is verified compatible with the target PostgreSQL minor version.
ARG TSEARCH_EXTRAS_REF=f566e9606bac00a22c4b62e9511b022c861db05c
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential postgresql-server-dev-18; \
    wget -qO /tmp/tsearch.tar.gz \
        "https://github.com/zulip/tsearch_extras/archive/${TSEARCH_EXTRAS_REF}.tar.gz"; \
    tar -xzf /tmp/tsearch.tar.gz -C /tmp; \
    cd "/tmp/tsearch_extras-${TSEARCH_EXTRAS_REF}"; \
    make; \
    make install; \
    cd /; \
    rm -rf /tmp/tsearch*; \
    apt-get purge -y --auto-remove build-essential postgresql-server-dev-18; \
    rm -rf /var/lib/apt/lists/*

# Return to the CNPG runtime user. Required: CNPG's instance manager refuses to
# start the cluster as root.
USER 26
