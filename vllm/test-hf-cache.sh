#!/usr/bin/env bash
# Standalone test for `make hf-cache`'s collision annotation. No framework.
# Run directly:
#   ./test-hf-cache.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

hf_cache="$tmp/hf-cache"
mk_repo() { mkdir -p "$hf_cache/hub/models--$1--$2"; }

mk_repo orgA Shared-Model
mk_repo orgB Shared-Model
mk_repo orgC Unique-Model

out=$(make -C "$SCRIPT_DIR" hf-cache HF_CACHE="$hf_cache")

fail=0
if ! echo "$out" | grep 'orgA/Shared-Model' | grep -q '⚠ collision'; then
    echo "FAIL: orgA/Shared-Model should be flagged as a collision"; fail=1
fi
if ! echo "$out" | grep 'orgB/Shared-Model' | grep -q '⚠ collision'; then
    echo "FAIL: orgB/Shared-Model should be flagged as a collision"; fail=1
fi
if echo "$out" | grep 'orgC/Unique-Model' | grep -q '⚠ collision'; then
    echo "FAIL: orgC/Unique-Model should NOT be flagged — it doesn't collide"; fail=1
fi

if [[ $fail -eq 0 ]]; then
    echo "PASS: vllm hf-cache collision annotation"
else
    exit 1
fi
