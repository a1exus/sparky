#!/usr/bin/env bash
# Standalone test for `make hf-sync`'s collision handling. No framework —
# copies the Makefile into a scratch dir (the real envs/ is never touched),
# builds a scratch HF cache with a real collision (two orgs publishing a
# repo with the same name) and a non-colliding entry, runs `make hf-sync`,
# and asserts on the resulting env files. Run directly:
#   ./test-hf-sync.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cp "$SCRIPT_DIR/Makefile" "$tmp/Makefile"
mkdir -p "$tmp/envs"

hf_cache="$tmp/hf-cache"
mk_repo() {
    # mk_repo <org> <repo>
    mkdir -p "$hf_cache/hub/models--$1--$2"
}

mk_repo orgA Shared-Model      # collision: same repo-name, different org
mk_repo orgB Shared-Model
mk_repo orgC Unique-Model      # no collision

out=$(cd "$tmp" && make hf-sync HF_CACHE="$hf_cache")

fail=0

if [[ ! -f "$tmp/envs/unique-model.env" ]]; then
    echo "FAIL: orgC/Unique-Model should keep its plain env filename"; fail=1
fi
if [[ -f "$tmp/envs/shared-model.env" ]]; then
    echo "FAIL: shared-model.env should not exist under the plain name — it collides"; fail=1
fi
if [[ ! -f "$tmp/envs/orga-shared-model.env" ]]; then
    echo "FAIL: orgA/Shared-Model should get an org-qualified env file"; fail=1
fi
if [[ ! -f "$tmp/envs/orgb-shared-model.env" ]]; then
    echo "FAIL: orgB/Shared-Model should get an org-qualified env file"; fail=1
fi
if ! grep -q '^VLLM_MODEL=orgA/Shared-Model$' "$tmp/envs/orga-shared-model.env"; then
    echo "FAIL: orga-shared-model.env has the wrong VLLM_MODEL"; fail=1
fi
if ! grep -q '^VLLM_MODEL=orgB/Shared-Model$' "$tmp/envs/orgb-shared-model.env"; then
    echo "FAIL: orgb-shared-model.env has the wrong VLLM_MODEL"; fail=1
fi
if ! grep -q '^VLLM_SERVED_NAME=orga-shared-model$' "$tmp/envs/orga-shared-model.env"; then
    echo "FAIL: orga-shared-model.env has the wrong VLLM_SERVED_NAME"; fail=1
fi
if ! echo "$out" | grep -q 'collision:'; then
    echo "FAIL: hf-sync didn't report the collision"; fail=1
fi
if ! echo "$out" | grep -qE '^summary — 3 created, 0 restored, 0 orphaned, 1 collisions$'; then
    echo "FAIL: unexpected summary line: $(echo "$out" | grep '^summary')"; fail=1
fi

if [[ $fail -eq 0 ]]; then
    echo "PASS: vllm hf-sync collision handling"
else
    exit 1
fi
