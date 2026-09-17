#!/usr/bin/env bash
set -euo pipefail

# Publish the latest GitHub release's APK to Zapstore.
#
# Usage:
#   SIGN_WITH=nsec1... ./scripts/zapstore-publish.sh              # publish
#   SIGN_WITH=nsec1... ./scripts/zapstore-publish.sh --check      # dry run (no publish)
#   SIGN_WITH=nsec1... ./scripts/zapstore-publish.sh --overwrite  # replace an already-published
#                                                                  # release with the same version
#                                                                  # code (e.g. to fix bad metadata)
#
# Requires the `zsp` CLI (https://github.com/zapstore/zsp) and a SIGN_WITH
# value the Zapstore relay has already whitelisted — see zapstore.yaml's
# `pubkey` field and the NIP-C1 identity proof (`zsp identity --link-key`)
# tying the release keystore's certificate to that pubkey.

if ! command -v zsp >/dev/null 2>&1; then
    echo "✗ zsp not found. Install: go install github.com/zapstore/zsp/cmd/zsp@v0.5.1" >&2
    exit 1
fi

if [ -z "${SIGN_WITH:-}" ]; then
    echo "✗ SIGN_WITH is not set. Provide an nsec or bunker:// URL for the identity" >&2
    echo "  already whitelisted on relay.zapstore.dev (see zapstore.yaml's pubkey)." >&2
    exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ "${1:-}" = "--check" ]; then
    echo "▸ Dry run: verifying zapstore.yaml resolves the latest release..."
    zsp publish --check zapstore.yaml
    echo "✓ Config is valid — nothing published"
elif [ "${1:-}" = "--overwrite" ]; then
    echo "▸ Republishing latest GitHub release to Zapstore (overwriting same version code)..."
    zsp publish zapstore.yaml --quiet --overwrite-release
    echo "✓ Published"
else
    echo "▸ Publishing latest GitHub release to Zapstore..."
    zsp publish zapstore.yaml --quiet
    echo "✓ Published"
fi
