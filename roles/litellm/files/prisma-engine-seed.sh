#!/bin/sh
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# =============================================================================
# Seed the prisma query engines into an emptyDir mounted over /root
# =============================================================================
# Runs as the `prisma-engine-seed` initContainer in the LiteLLM pod, using the
# LiteLLM image itself as the source of the binaries.
#
# Why this is needed:
#   The generated prisma client bakes absolute engine paths into
#   site-packages/prisma/client.py (BINARY_PATHS) at image build time, under
#     /root/.cache/prisma-python/binaries/<version>/<hash>/node_modules/prisma/
#   The proxy runs as uid 1000 and /root is 0700 root, so prisma's resolver
#   (prisma/engine/utils.py:_resolve_from_binary_paths) raises EACCES out of
#   Path.exists() before it ever consults PRISMA_QUERY_ENGINE_BINARY — which is
#   why that env var cannot be used to work around it. The proxy then fails with
#   `NotConnectedError: Not connected to the query engine` and crash-loops.
#
#   Copying the engines the image already ships into a world-readable emptyDir
#   at the exact baked path resolves it, with no network access required.
#
# Constraints this script has to respect:
#   - It runs as uid 0 but with all capabilities dropped, so it can chmod but
#     NOT chown (CAP_CHOWN is gone).
#   - Its own root filesystem is read-only; only $SEED_ROOT is writable.
#   - The version and hash in the source path are globbed rather than pinned so
#     that a LiteLLM image upgrade doesn't silently break the seeding.
# =============================================================================

set -eu

# Must match the initContainer's volumeMount path for the prisma-root emptyDir.
SEED_ROOT="${SEED_ROOT:-/rootvol}"

# Baked location of the engines inside the image. Two wildcards: version, hash.
ENGINE_GLOB="/root/.cache/prisma-python/binaries/*/*/node_modules/prisma"

# ── Locate the engines in the image ──────────────────────────────────────────
# Deliberately unquoted so the shell expands the glob; an unmatched glob stays
# literal, hence the -d test.
src=""
# shellcheck disable=SC2086
for candidate in $ENGINE_GLOB; do
    [ -d "$candidate" ] || continue
    src="$candidate"
    break
done

if [ -z "$src" ]; then
    echo "FATAL: no prisma engine directory matches $ENGINE_GLOB in this image" >&2
    exit 1
fi

# ── Copy them to the same path inside the writable volume ────────────────────
dst="${SEED_ROOT}${src#/root}"
mkdir -p "$dst"

seeded=0
for engine in "$src"/query-engine-*; do
    [ -f "$engine" ] || continue
    cp "$engine" "$dst/"
    seeded=$((seeded + 1))
done

if [ "$seeded" -eq 0 ]; then
    echo "FATAL: $src contains no query-engine-* binaries" >&2
    exit 1
fi

# uid 1000 needs to traverse every directory down to the engines and execute
# them. chmod, not chown — see the capability note above.
chmod -R a+rX "$SEED_ROOT"

echo "seeded $seeded query engine(s) into ${dst#"$SEED_ROOT"}"
ls -l "$dst"
