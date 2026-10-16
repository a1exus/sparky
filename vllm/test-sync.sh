#!/usr/bin/env bash
# Standalone test for `make sync` (collision handling, non-chat update,
# retired .env defaults) and the deprecated `hf-sync` / `env-sync` aliases. No framework —
# copies the Makefile into scratch dirs (the real envs/ is never touched).
# Run directly:
#   ./test-sync.sh
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

out=$(cd "$s1" && make sync HF_CACHE="$hf_cache")

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
    echo "FAIL: scenario 1 — sync didn't report the collision"; fail=1
fi
if ! echo "$out" | grep -qE '^summary — 3 created, 0 restored, 0 renamed, 0 updated, 0 orphaned, 1 collisions$'; then
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

out2=$(cd "$s2" && make sync HF_CACHE="$hf_cache2")

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
    echo "FAIL: scenario 2 — sync didn't report the rename"; fail=1
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

out3=$(cd "$s3" && make sync HF_CACHE="$hf_cache3")

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
    echo "FAIL: scenario 3 — sync didn't report the rename block"; fail=1
fi

# --- scenario 4: .bak restore path is collision-aware — a repo archived to
# .bak under its old plain name (before any collision existed) must be
# restored AND renamed when a collision exists at sync time, not silently
# dropped in favor of a freshly-created default file. ---
s4="$tmp/scenario4"
mkdir -p "$s4/envs"
cp "$SCRIPT_DIR/Makefile" "$s4/Makefile"
cat > "$s4/envs/shared-model.env.bak" <<'ENVEOF'
# orgA/Shared-Model. Layered on top of ../.env by `make up ENV=shared-model`.
VLLM_MODEL=orgA/Shared-Model
VLLM_SERVED_NAME=shared-model

# Optional per-variant overrides — uncomment to use.
VLLM_GPU_MEM=0.95
ENVEOF

hf_cache4="$s4/hf-cache"
mk_repo "$hf_cache4" orgA Shared-Model
mk_repo "$hf_cache4" orgB Shared-Model   # collision at sync time

out4=$(cd "$s4" && make sync HF_CACHE="$hf_cache4")

if [[ -f "$s4/envs/shared-model.env.bak" ]]; then
    echo "FAIL: scenario 4 — shared-model.env.bak should no longer exist (should have been restored)"; fail=1
fi
if [[ ! -f "$s4/envs/orga-shared-model.env" ]]; then
    echo "FAIL: scenario 4 — orga-shared-model.env should exist (restored + renamed from .bak)"; fail=1
fi
if ! grep -q '^VLLM_MODEL=orgA/Shared-Model$' "$s4/envs/orga-shared-model.env" 2>/dev/null; then
    echo "FAIL: scenario 4 — orga-shared-model.env has wrong/missing VLLM_MODEL"; fail=1
fi
if ! grep -q '^VLLM_SERVED_NAME=orga-shared-model$' "$s4/envs/orga-shared-model.env" 2>/dev/null; then
    echo "FAIL: scenario 4 — orga-shared-model.env has a stale VLLM_SERVED_NAME"; fail=1
fi
if ! grep -q '^VLLM_GPU_MEM=0.95$' "$s4/envs/orga-shared-model.env" 2>/dev/null; then
    echo "FAIL: scenario 4 — orga-shared-model.env lost the user's VLLM_GPU_MEM customization"; fail=1
fi
if [[ ! -f "$s4/envs/orgb-shared-model.env" ]]; then
    echo "FAIL: scenario 4 — orgb-shared-model.env should have been created normally"; fail=1
fi
if ! echo "$out4" | grep -q '↩ restore'; then
    echo "FAIL: scenario 4 — sync didn't report the restore"; fail=1
fi

# --- scenario 5: non-chat detection — a cached repo whose config.json
# architecture is in NON_CHAT_ARCHS (Whisper) gets VLLM_TOOL_PARSER= on
# create AND on an existing env file; chat models (even ones without a chat
# template, like MTP drafters) and repos without config.json are left alone;
# a second run is a no-op; a user-set value is respected. ---
s5="$tmp/scenario5"
mkdir -p "$s5/envs"
cp "$SCRIPT_DIR/Makefile" "$s5/Makefile"
hf_cache5="$s5/hf-cache"
mk_snap() {
    # mk_snap <root> <org> <repo> <architecture|->
    local d="$1/hub/models--$2--$3/snapshots/abc123"
    mkdir -p "$d"
    [[ "$4" != "-" ]] && printf '{\n  "architectures": [\n    "%s"\n  ]\n}\n' "$4" > "$d/config.json"
    return 0
}
mk_snap "$hf_cache5" openai Whisper-New   WhisperForConditionalGeneration
mk_snap "$hf_cache5" openai Whisper-Old   WhisperForConditionalGeneration
mk_snap "$hf_cache5" openai Whisper-Mine  WhisperForConditionalGeneration
mk_snap "$hf_cache5" Qwen   Chat-Model    Qwen3ForCausalLM
mk_snap "$hf_cache5" google Gemma-Drafter Gemma4AssistantForCausalLM
mk_snap "$hf_cache5" orgX   No-Config     -
# Pre-existing env written by an older hf-sync (no VLLM_TOOL_PARSER line).
printf 'VLLM_MODEL=openai/Whisper-Old\nVLLM_SERVED_NAME=whisper-old\n' > "$s5/envs/whisper-old.env"
# Pre-existing env where the user chose a parser explicitly.
printf 'VLLM_MODEL=openai/Whisper-Mine\nVLLM_SERVED_NAME=whisper-mine\nVLLM_TOOL_PARSER=hermes\n' > "$s5/envs/whisper-mine.env"

out5=$(cd "$s5" && make sync HF_CACHE="$hf_cache5")

for f in whisper-new whisper-old; do
    if [[ $(grep -c '^VLLM_TOOL_PARSER=$' "$s5/envs/$f.env" 2>/dev/null) != 1 ]]; then
        echo "FAIL: scenario 5 — $f.env should carry exactly one active 'VLLM_TOOL_PARSER='"; fail=1
    fi
done
if [[ $(grep -c '^VLLM_TOOL_PARSER=' "$s5/envs/whisper-mine.env") != 1 ]] \
   || ! grep -q '^VLLM_TOOL_PARSER=hermes$' "$s5/envs/whisper-mine.env"; then
    echo "FAIL: scenario 5 — whisper-mine.env's user-set VLLM_TOOL_PARSER must be left alone"; fail=1
fi
for f in chat-model gemma-drafter no-config; do
    if grep -q '^VLLM_TOOL_PARSER=' "$s5/envs/$f.env" 2>/dev/null; then
        echo "FAIL: scenario 5 — $f.env must not get an active VLLM_TOOL_PARSER"; fail=1
    fi
done
if ! echo "$out5" | grep -qE '^summary — 4 created, 0 restored, 0 renamed, 2 updated, 0 orphaned, 0 collisions$'; then
    echo "FAIL: scenario 5 — unexpected summary line: $(echo "$out5" | grep '^summary')"; fail=1
fi
out5b=$(cd "$s5" && make sync HF_CACHE="$hf_cache5")
if ! echo "$out5b" | grep -qE '^summary — 0 created, 0 restored, 0 renamed, 0 updated, 0 orphaned, 0 collisions$'; then
    echo "FAIL: scenario 5 — second run should be a no-op: $(echo "$out5b" | grep '^summary')"; fail=1
fi

# --- scenario 6: sync drops retired defaults from .env, keeps everything
# else (including a customized VLLM_MAX_LEN), and is a no-op on re-run. ---
s6="$tmp/scenario6"
mkdir -p "$s6"
cp "$SCRIPT_DIR/Makefile" "$s6/Makefile"
printf 'VLLM_TAG=latest\nVLLM_GPU_MEM=0.9\nVLLM_MAX_LEN=32768\nVLLM_MODEL=placeholder\n' > "$s6/.env"

out6=$(cd "$s6" && make sync HF_CACHE="$s6/no-cache")

if grep -q '^VLLM_MAX_LEN=' "$s6/.env"; then
    echo "FAIL: scenario 6 — retired VLLM_MAX_LEN=32768 should be removed from .env"; fail=1
fi
if [[ $(grep -c . "$s6/.env") != 3 ]] || ! grep -q '^VLLM_TAG=latest$' "$s6/.env"; then
    echo "FAIL: scenario 6 — sync must keep every other line of .env"; fail=1
fi
if ! grep -q '^VLLM_MAX_LEN=32768$' "$s6/.env.bak" 2>/dev/null; then
    echo "FAIL: scenario 6 — sync should leave the original in .env.bak"; fail=1
fi
if ! echo "$out6" | grep -q 'removed retired default VLLM_MAX_LEN=32768'; then
    echo "FAIL: scenario 6 — sync didn't report the removal"; fail=1
fi
if (cd "$s6" && make sync HF_CACHE="$s6/no-cache") | grep -q 'removed retired default'; then
    echo "FAIL: scenario 6 — second sync should not remove anything"; fail=1
fi
printf 'VLLM_MAX_LEN=65536\n' > "$s6/.env"
(cd "$s6" && make sync HF_CACHE="$s6/no-cache" >/dev/null)
if ! grep -q '^VLLM_MAX_LEN=65536$' "$s6/.env"; then
    echo "FAIL: scenario 6 — a customized VLLM_MAX_LEN must be left alone"; fail=1
fi

# --- scenario 7: deprecated aliases still work and point at the new name ---
s7="$tmp/scenario7"
mkdir -p "$s7/envs"
cp "$SCRIPT_DIR/Makefile" "$s7/Makefile"
hf_cache7="$s7/hf-cache"
mk_repo "$hf_cache7" orgC Unique-Model
for alias in hf-sync env-sync; do
    rm -f "$s7/envs/unique-model.env"
    err7=$(cd "$s7" && make "$alias" HF_CACHE="$hf_cache7" 2>&1 >/dev/null)
    if [[ ! -f "$s7/envs/unique-model.env" ]]; then
        echo "FAIL: scenario 7 — \`make $alias\` should still run sync"; fail=1
    fi
    if ! grep -q "is now \`make sync\`" <<<"$err7"; then
        echo "FAIL: scenario 7 — \`make $alias\` should print a rename note on stderr"; fail=1
    fi
done

if [[ $fail -eq 0 ]]; then
    echo "PASS: vllm sync (collisions + incremental + rename guard + .bak restore + non-chat update + retired .env defaults + aliases)"
else
    exit 1
fi
