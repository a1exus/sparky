#!/usr/bin/env bash
# Standalone test for `make hf-sync`'s collision handling. No framework —
# copies the Makefile into scratch dirs (the real envs/ is never touched).
# Run directly:
#   ./test-hf-sync.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail=0

# --- scenario 1: clean-slate collision ---
s1="$tmp/scenario1"
cp "$SCRIPT_DIR/Makefile" "$s1/Makefile" 2>/dev/null || { mkdir -p "$s1"; cp "$SCRIPT_DIR/Makefile" "$s1/Makefile"; }
mkdir -p "$s1/envs"

hf_cache="$s1/hf-cache"
mk_repo() {
    # mk_repo <root> <org> <repo>
    mkdir -p "$1/hub/models--$2--$3"
}

mk_repo "$hf_cache" orgA Shared-Model      # collision: same repo-name, different org
mk_repo "$hf_cache" orgB Shared-Model
mk_repo "$hf_cache" orgC Unique-Model      # no collision

out=$(cd "$s1" && make hf-sync HF_CACHE="$hf_cache")

if [[ ! -f "$s1/envs/unique-model.env" ]]; then
    echo "FAIL: scenario 1 — orgC/Unique-Model should keep its plain env filename"; fail=1
fi
if [[ -f "$s1/envs/shared-model.env" ]]; then
    echo "FAIL: scenario 1 — shared-model.env should not exist under the plain name — it collides"; fail=1
fi
if [[ ! -f "$s1/envs/orga-shared-model.env" ]]; then
    echo "FAIL: scenario 1 — orgA/Shared-Model should get an org-qualified env file"; fail=1
fi
if [[ ! -f "$s1/envs/orgb-shared-model.env" ]]; then
    echo "FAIL: scenario 1 — orgB/Shared-Model should get an org-qualified env file"; fail=1
fi
if ! grep -q '^VLLM_MODEL=orgA/Shared-Model$' "$s1/envs/orga-shared-model.env"; then
    echo "FAIL: scenario 1 — orga-shared-model.env has the wrong VLLM_MODEL"; fail=1
fi
if ! grep -q '^VLLM_MODEL=orgB/Shared-Model$' "$s1/envs/orgb-shared-model.env"; then
    echo "FAIL: scenario 1 — orgb-shared-model.env has the wrong VLLM_MODEL"; fail=1
fi
if ! grep -q '^VLLM_SERVED_NAME=orga-shared-model$' "$s1/envs/orga-shared-model.env"; then
    echo "FAIL: scenario 1 — orga-shared-model.env has the wrong VLLM_SERVED_NAME"; fail=1
fi
if ! echo "$out" | grep -q 'collision:'; then
    echo "FAIL: scenario 1 — hf-sync didn't report the collision"; fail=1
fi
if ! echo "$out" | grep -qE '^summary — 3 created, 0 restored, 0 renamed, 0 orphaned, 1 collisions$'; then
    echo "FAIL: scenario 1 — unexpected summary line: $(echo "$out" | grep '^summary')"; fail=1
fi

# --- scenario 2: incremental collision — one side already synced under a
# plain name BEFORE the collision existed. Every colliding file must end up
# consistently, correctly named regardless of sync history. ---
s2="$tmp/scenario2"
mkdir -p "$s2/envs"
cp "$SCRIPT_DIR/Makefile" "$s2/Makefile"
cat > "$s2/envs/shared-model.env" <<'ENVEOF'
# orgA/Shared-Model. Layered on top of ../.env by `make up ENV=shared-model`.
# Host-wide values (VLLM_TAG, HF_CACHE_HOST, HF_TOKEN, defaults)
# live in ../.env.

VLLM_MODEL=orgA/Shared-Model
VLLM_SERVED_NAME=shared-model

# Optional per-variant overrides — uncomment to use.
# VLLM_GPU_MEM=0.9
# VLLM_MAX_LEN=32768
ENVEOF

hf_cache2="$s2/hf-cache"
mk_repo "$hf_cache2" orgA Shared-Model
mk_repo "$hf_cache2" orgB Shared-Model   # collision introduced after orgA was already synced

out2=$(cd "$s2" && make hf-sync HF_CACHE="$hf_cache2")

if [[ -f "$s2/envs/shared-model.env" ]]; then
    echo "FAIL: scenario 2 — shared-model.env (orgA's stale plain name) should have been renamed away"; fail=1
fi
if [[ ! -f "$s2/envs/orga-shared-model.env" ]]; then
    echo "FAIL: scenario 2 — orgA's file should be renamed to orga-shared-model.env"; fail=1
fi
if [[ ! -f "$s2/envs/orgb-shared-model.env" ]]; then
    echo "FAIL: scenario 2 — orgB's file should be created as orgb-shared-model.env"; fail=1
fi
if ! grep -q '^VLLM_MODEL=orgA/Shared-Model$' "$s2/envs/orga-shared-model.env" 2>/dev/null; then
    echo "FAIL: scenario 2 — orga-shared-model.env has wrong/missing VLLM_MODEL"; fail=1
fi
if ! grep -q '^VLLM_SERVED_NAME=orga-shared-model$' "$s2/envs/orga-shared-model.env" 2>/dev/null; then
    echo "FAIL: scenario 2 — orga-shared-model.env has a stale VLLM_SERVED_NAME"; fail=1
fi
if ! echo "$out2" | grep -q '↺ rename'; then
    echo "FAIL: scenario 2 — hf-sync didn't report the rename"; fail=1
fi

# --- scenario 3: rename guard — destination file already exists (unrelated content) ---
# Verify that rename doesn't clobber an existing file at the target name.
s3="$tmp/scenario3"
mkdir -p "$s3/envs"
cp "$SCRIPT_DIR/Makefile" "$s3/Makefile"

# Create the stale plain-named file (would normally get renamed)
cat > "$s3/envs/shared-model.env" <<'ENVEOF'
# orgA/Shared-Model. Layered on top of ../.env by `make up ENV=shared-model`.
# Host-wide values (VLLM_TAG, HF_CACHE_HOST, HF_TOKEN, defaults)
# live in ../.env.

VLLM_MODEL=orgA/Shared-Model
VLLM_SERVED_NAME=shared-model

# Optional per-variant overrides — uncomment to use.
# VLLM_GPU_MEM=0.9
# VLLM_MAX_LEN=32768
ENVEOF

# Create an unrelated file at the target rename destination
cat > "$s3/envs/orga-shared-model.env" <<'ENVEOF'
# someUnrelatedOrg/SomeOtherRepo — unrelated existing file
VLLM_MODEL=someUnrelatedOrg/SomeOtherRepo
VLLM_SERVED_NAME=unrelated-model
ENVEOF

hf_cache3="$s3/hf-cache"
mk_repo "$hf_cache3" orgA Shared-Model
mk_repo "$hf_cache3" orgB Shared-Model

out3=$(cd "$s3" && make hf-sync HF_CACHE="$hf_cache3")

# Verify shared-model.env (source) still exists — rename was blocked
if [[ ! -f "$s3/envs/shared-model.env" ]]; then
    echo "FAIL: scenario 3 — shared-model.env should still exist (rename was blocked)"; fail=1
fi

# Verify orga-shared-model.env (target) not clobbered — either still exists or moved to .bak
if [[ -f "$s3/envs/orga-shared-model.env" ]]; then
    if ! grep -q '^VLLM_MODEL=someUnrelatedOrg/SomeOtherRepo$' "$s3/envs/orga-shared-model.env"; then
        echo "FAIL: scenario 3 — orga-shared-model.env was modified (content should be unrelated)"; fail=1
    fi
elif [[ -f "$s3/envs/orga-shared-model.env.bak" ]]; then
    if ! grep -q '^VLLM_MODEL=someUnrelatedOrg/SomeOtherRepo$' "$s3/envs/orga-shared-model.env.bak"; then
        echo "FAIL: scenario 3 — orga-shared-model.env.bak has wrong content"; fail=1
    fi
else
    echo "FAIL: scenario 3 — orga-shared-model.env was lost (neither exists nor .bak)"; fail=1
fi

# Verify the rename was blocked with a message
if ! echo "$out3" | grep -q 'rename blocked:'; then
    echo "FAIL: scenario 3 — hf-sync didn't report the rename block"; fail=1
fi

if [[ $fail -eq 0 ]]; then
    echo "PASS: vllm hf-sync collision handling (clean-slate + incremental + rename guard)"
else
    exit 1
fi
