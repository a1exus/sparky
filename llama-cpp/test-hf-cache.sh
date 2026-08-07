#!/usr/bin/env bash
# Standalone test for `make hf-cache`'s collision annotation. No framework —
# builds a scratch HF cache + farm with a real collision, runs sync-router.sh
# to populate config.ini's COLLISIONS block, then runs `make hf-cache` and
# asserts the output flags the right repos. Uses a bogus docker volume name
# so the (Docker-dependent) volume-listing half of hf-cache contributes
# nothing — this test needs no Docker. Run directly:
#   ./test-hf-cache.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

hf_cache="$tmp/hf-cache"
farm="$tmp/farm"

mk_gguf() {
    local dir="$hf_cache/hub/models--$1--$2/snapshots/rev1"
    mkdir -p "$dir"
    touch "$dir/$3"
}

mk_gguf vendorA Model-X-GGUF Model-X-Q4_K_M.gguf
mk_gguf vendorB Model-X-GGUF Model-X-Q4_K_M.gguf
mk_gguf vendorC Model-Y-GGUF Model-Y-Q8_0.gguf
mk_gguf vendorA Model-Pro-GGUF Model-Pro-Q4.gguf
mk_gguf vendorB Model-Pro-GGUF Model-Pro-Q4.gguf
mk_gguf vendorA Model-Pro Model-Pro-unique.gguf

HF_CACHE="$hf_cache" SYMLINK_FARM="$farm" CTX_DEFAULT=8192 NGL_DEFAULT=999 \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SCRIPT_DIR/scripts/sync-router.sh" >/dev/null 2>&1

out=$(make -C "$SCRIPT_DIR" hf-cache HF_CACHE="$hf_cache" SYMLINK_FARM_HOST="$farm" LLAMACPP_CACHE_VOL=test-vol-that-does-not-exist-xyz 2>/dev/null)

fail=0
if ! echo "$out" | grep 'vendorA/Model-X-GGUF' | grep -q '⚠ collision'; then
    echo "FAIL: vendorA/Model-X-GGUF should be flagged as a collision"; fail=1
fi
if ! echo "$out" | grep 'vendorB/Model-X-GGUF' | grep -q '⚠ collision'; then
    echo "FAIL: vendorB/Model-X-GGUF should be flagged as a collision"; fail=1
fi
if echo "$out" | grep 'vendorC/Model-Y-GGUF' | grep -q '⚠ collision'; then
    echo "FAIL: vendorC/Model-Y-GGUF should NOT be flagged — it doesn't collide"; fail=1
fi
if ! echo "$out" | grep -F 'vendorA/Model-Pro-GGUF' | grep -q '⚠ collision'; then
    echo "FAIL: vendorA/Model-Pro-GGUF should be flagged as a collision"; fail=1
fi
if ! echo "$out" | grep -F 'vendorB/Model-Pro-GGUF' | grep -q '⚠ collision'; then
    echo "FAIL: vendorB/Model-Pro-GGUF should be flagged as a collision"; fail=1
fi
if echo "$out" | grep -F 'vendorA/Model-Pro ' | grep -q '⚠ collision'; then
    echo "FAIL: vendorA/Model-Pro (prefix of a colliding repo's name, but NOT itself colliding) was falsely flagged — substring-match bug"; fail=1
fi

if [[ $fail -eq 0 ]]; then
    echo "PASS: llama-cpp hf-cache collision annotation"
else
    exit 1
fi
