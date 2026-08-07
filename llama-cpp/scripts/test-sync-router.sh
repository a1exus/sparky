#!/usr/bin/env bash
# Standalone test for sync-router.sh's collision handling. No framework —
# builds a scratch HF cache with a real collision (two repos sharing a GGUF
# basename) and a non-colliding entry, runs the script, and asserts on the
# resulting symlink farm + config.ini. Run directly:
#   ./scripts/test-sync-router.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

hf_cache="$tmp/hf-cache"
farm="$tmp/farm"

mk_gguf() {
    # mk_gguf <org> <repo> <rev> <filename>
    local dir="$hf_cache/hub/models--$1--$2/snapshots/$3"
    mkdir -p "$dir"
    touch "$dir/$4"
}

mk_gguf vendorA Model-X-GGUF rev1 Model-X-Q4_K_M.gguf
mk_gguf vendorB Model-X-GGUF rev1 Model-X-Q4_K_M.gguf   # same basename — collision
mk_gguf vendorC Model-Y-GGUF rev1 Model-Y-Q8_0.gguf     # unique — no collision

# Force the `find` fallback in list_ggufs — this test doesn't depend on the
# `hf` CLI being installed or its output format.
run_sync() {
    HF_CACHE="$hf_cache" SYMLINK_FARM="$farm" CTX_DEFAULT=8192 NGL_DEFAULT=999 \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        "$SCRIPT_DIR/sync-router.sh"
}

run_sync

fail=0

if [[ ! -L "$farm/Model-Y-Q8_0.gguf" ]]; then
    echo "FAIL: unique model Model-Y-Q8_0.gguf should keep its plain symlink name"; fail=1
fi
if [[ -e "$farm/Model-X-Q4_K_M.gguf" ]]; then
    echo "FAIL: colliding basename Model-X-Q4_K_M.gguf should NOT exist under its plain name"; fail=1
fi
if [[ ! -L "$farm/vendora-model-x-gguf--Model-X-Q4_K_M.gguf" ]]; then
    echo "FAIL: vendorA's colliding file should be qualified as vendora-model-x-gguf--Model-X-Q4_K_M.gguf"; fail=1
fi
if [[ ! -L "$farm/vendorb-model-x-gguf--Model-X-Q4_K_M.gguf" ]]; then
    echo "FAIL: vendorB's colliding file should be qualified as vendorb-model-x-gguf--Model-X-Q4_K_M.gguf"; fail=1
fi
if ! grep -q '^\[model-y\]' "$farm/config.ini"; then
    echo "FAIL: config.ini missing [model-y] section for the unique model"; fail=1
fi
if ! grep -q 'vendora-model-x-gguf' "$farm/config.ini"; then
    echo "FAIL: config.ini missing a section for vendorA's qualified model"; fail=1
fi
if ! grep -q 'vendorb-model-x-gguf' "$farm/config.ini"; then
    echo "FAIL: config.ini missing a section for vendorB's qualified model"; fail=1
fi
if ! grep -q '# COLLISIONS' "$farm/config.ini"; then
    echo "FAIL: config.ini missing the COLLISIONS header block"; fail=1
fi
if ! grep -q 'Model-X-Q4_K_M.gguf' "$farm/config.ini"; then
    echo "FAIL: COLLISIONS block doesn't mention the colliding basename"; fail=1
fi

out2=$(run_sync)
if ! echo "$out2" | grep -q '^router summary: 0 symlinks created/updated, 3 unchanged, 0 orphaned, 1 collision groups$'; then
    echo "FAIL: second run wasn't idempotent — got: $out2"; fail=1
fi

if [[ $fail -eq 0 ]]; then
    echo "PASS: sync-router.sh collision handling + idempotency"
else
    exit 1
fi
