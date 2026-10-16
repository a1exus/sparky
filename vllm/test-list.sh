#!/usr/bin/env bash
# Standalone test for `make list`: variants with their repo, collision
# flags, cached-but-unsynced repos, and the deprecated `hf-cache` alias.
# No framework; works on a scratch copy of the Makefile.
# Run directly:
#   ./test-list.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

hf_cache="$tmp/hf-cache"
mk_repo() { mkdir -p "$hf_cache/hub/models--$1--$2"; }

mk_repo orgA Shared-Model
mk_repo orgB Shared-Model
mk_repo orgC Unique-Model
mk_repo orgD Not-Synced

work="$tmp/work"
mkdir -p "$work/envs"
cp "$SCRIPT_DIR/Makefile" "$work/Makefile"
printf 'VLLM_MODEL=orgA/Shared-Model\n' > "$work/envs/orga-shared-model.env"
printf 'VLLM_MODEL=orgB/Shared-Model\n' > "$work/envs/orgb-shared-model.env"
printf 'VLLM_MODEL=orgC/Unique-Model\n' > "$work/envs/unique-model.env"
printf 'VLLM_MODEL=orgE/Gone-Model\n'   > "$work/envs/gone-model.env"

out=$(make -C "$work" list HF_CACHE="$hf_cache")

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

if ! echo "$out" | grep -qE '^unique-model +orgC/Unique-Model$'; then
    echo "FAIL: unique-model should be listed with its repo and no flags"; fail=1
fi
if ! echo "$out" | grep 'orgD/Not-Synced' | grep -q 'not synced'; then
    echo "FAIL: orgD/Not-Synced is cached without an env — should be flagged 'not synced'"; fail=1
fi
if ! echo "$out" | grep '^gone-model' | grep -q 'not cached'; then
    echo "FAIL: gone-model's repo isn't cached — should be flagged 'not cached'"; fail=1
fi
alias_out=$(make -C "$work" hf-cache HF_CACHE="$hf_cache" 2>/dev/null)
if [[ "$alias_out" != "$out" ]]; then
    echo "FAIL: deprecated \`make hf-cache\` should print the same as \`make list\`"; fail=1
fi

if [[ $fail -eq 0 ]]; then
    echo "PASS: vllm list (variants + collision / not-synced / not-cached flags + hf-cache alias)"
else
    exit 1
fi
