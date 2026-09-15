#!/bin/sh
# Shared by every SDK repo's gate: compare freshly written envelopes against
# the committed goldens, and — when an app-atlas checkout is reachable — hand
# the same bytes to the server's own parser and claim schema.
#
#   check-golden.sh <written-dir> <sdk-name> <claim-os> <claim-via>
#
# ATLAS_GOLDEN=update rewrites the goldens instead of comparing, for the one
# commit where the wire format legitimately changes.
set -e

WRITTEN="$1"
SDK_NAME="$2"
CLAIM_OS="$3"
CLAIM_VIA="$4"
GOLDEN="$(cd "$(dirname "$0")" && pwd)/golden"

if [ "$ATLAS_GOLDEN" = "update" ]; then
    mkdir -p "$GOLDEN"
    cp "$WRITTEN"/*.envelope "$WRITTEN"/claim-request.json "$GOLDEN/"
    echo "golden: rewritten from this run — review the diff before committing"
else
    for file in open.envelope hostile.envelope pair.envelope claim-request.json; do
        if ! cmp -s "$GOLDEN/$file" "$WRITTEN/$file"; then
            echo "golden: $file drifted from tools/golden/$file" >&2
            diff "$GOLDEN/$file" "$WRITTEN/$file" || true
            exit 1
        fi
    done

    echo "golden: the writer still produces the committed bytes"
fi

# The strong tier. Absent, the goldens above are the contract; present, the
# real parser is.
if [ -n "$ATLAS_SERVER" ] && [ -f "$ATLAS_SERVER/scripts/sdk/validate_envelopes.py" ]; then
    DATABASE_URL='sqlite://' "$ATLAS_SERVER/.venv/bin/python" \
        "$ATLAS_SERVER/scripts/sdk/validate_envelopes.py" "$WRITTEN" "$SDK_NAME" "$CLAIM_OS" "$CLAIM_VIA"
else
    echo "golden: ATLAS_SERVER not set, skipping the server-parser tier"
fi
