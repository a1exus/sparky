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
cp "$SCRIPT_DIR/Makefile" "$SCRIPT_DIR/model-format.sh" "$s1/" 2>/dev/null || { mkdir -p "$s1"; cp "$SCRIPT_DIR/Makefile" "$SCRIPT_DIR/model-format.sh" "$s1/"; }
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
if ! echo "$out" | grep -qE '^summary — 3 created, 0 restored, 0 renamed, 0 skipped, 0 orphaned, 1 collisions$'; then
    echo "FAIL: scenario 1 — unexpected summary line: $(echo "$out" | grep '^summary')"; fail=1
fi

# --- scenario 2: incremental collision — one side already synced under a
# plain name BEFORE the collision existed. Every colliding file must end up
# consistently, correctly named regardless of sync history. ---
s2="$tmp/scenario2"
mkdir -p "$s2/envs"
cp "$SCRIPT_DIR/Makefile" "$SCRIPT_DIR/model-format.sh" "$s2/"
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
cp "$SCRIPT_DIR/Makefile" "$SCRIPT_DIR/model-format.sh" "$s3/"

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
cp "$SCRIPT_DIR/Makefile" "$SCRIPT_DIR/model-format.sh" "$s4/"
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

# --- scenario 5: format guard — repos vLLM cannot load (GGUF, CTranslate2,
# no config) are skipped, never given a variant, and flagged by `list`;
# loadable ones (chat, speech-to-text, anything with a Transformers config)
# are created with NO tool-parser line: chat-vs-not is decided by vLLM at
# container start, so sync keeps no per-architecture list. Existing env files
# are never rewritten, and a second run is a no-op. ---
s5="$tmp/scenario5"
mkdir -p "$s5/envs"
cp "$SCRIPT_DIR/Makefile" "$SCRIPT_DIR/model-format.sh" "$s5/"
hf_cache5="$s5/hf-cache"
mk_snap() {
    # mk_snap <root> <org> <repo> <file[=content]>...   (files under snapshots/abc123/)
    local root="$1" org="$2" repo="$3"; shift 3
    local d="$root/hub/models--$org--$repo/snapshots/abc123" spec
    mkdir -p "$d"
    for spec in "$@"; do
        local name="${spec%%=*}" content=""
        [[ "$spec" == *=* ]] && content="${spec#*=}"
        mkdir -p "$(dirname "$d/$name")"
        printf '%s' "$content" > "$d/$name"
    done
    return 0
}
CFG='{"architectures":["X"],"model_type":"x"}'
mk_snap "$hf_cache5" openai Whisper-New  "config.json=$CFG" model.safetensors
mk_snap "$hf_cache5" Qwen   Chat-Model   "config.json=$CFG" model-00001.safetensors model-00002.safetensors
mk_snap "$hf_cache5" org    Old-Style    "config.json=$CFG" pytorch_model.bin
mk_snap "$hf_cache5" org    Brand-New    "config.json={\"model_type\":\"brandnew2030\"}" model.safetensors
mk_snap "$hf_cache5" unsloth Some-GGUF   model-Q4_K_M.gguf
mk_snap "$hf_cache5" deepdml Fast-CT2    'config.json={"alignment_heads":[[1,2]],"lang_ids":[1]}' model.bin vocabulary.json
mk_snap "$hf_cache5" org    No-Weights   "config.json=$CFG"
mkdir -p "$hf_cache5/hub/models--orgX--Not-Downloaded-Yet"   # no snapshots: unknown → treated as loadable
# A variant created by an older sync for a repo vLLM can't load.
printf 'VLLM_MODEL=unsloth/Some-GGUF\nVLLM_SERVED_NAME=some-gguf\n' > "$s5/envs/some-gguf.env"
# A user-edited variant: sync must not touch it.
printf 'VLLM_MODEL=openai/Whisper-New\nVLLM_SERVED_NAME=whisper-new\nVLLM_TOOL_PARSER=hermes\n' > "$s5/envs/whisper-new.env"

out5=$(cd "$s5" && make sync HF_CACHE="$hf_cache5")

for f in chat-model old-style brand-new not-downloaded-yet; do
    if [[ ! -f "$s5/envs/$f.env" ]]; then echo "FAIL: scenario 5 — $f.env should be created"; fail=1; fi
done
for f in fast-ct2 no-weights; do
    if [[ -e "$s5/envs/$f.env" ]]; then
        echo "FAIL: scenario 5 — $f.env must not be created (vLLM cannot load it)"; fail=1
    fi
done
if ! grep -q '^VLLM_MODEL=unsloth/Some-GGUF$' "$s5/envs/some-gguf.env"; then
    echo "FAIL: scenario 5 — an existing env file for a skipped repo must be left alone"; fail=1
fi
if ! grep -q '^VLLM_TOOL_PARSER=hermes$' "$s5/envs/whisper-new.env" || [[ $(grep -c . "$s5/envs/whisper-new.env") != 3 ]]; then
    echo "FAIL: scenario 5 — an existing variant must not be rewritten"; fail=1
fi
for f in chat-model old-style brand-new not-downloaded-yet; do
    if grep -q '^VLLM_TOOL_PARSER=' "$s5/envs/$f.env"; then
        echo "FAIL: scenario 5 — $f.env must not get an active VLLM_TOOL_PARSER (vLLM decides at start)"; fail=1
    fi
done
for r in 'unsloth/Some-GGUF — GGUF checkpoint' 'deepdml/Fast-CT2 — not a Transformers checkpoint' 'org/No-Weights — no safetensors'; do
    if ! echo "$out5" | grep -qF "· skip    $r"; then echo "FAIL: scenario 5 — no skip line for '$r'"; fail=1; fi
done
if ! echo "$out5" | grep -qE '^summary — 4 created, 0 restored, 0 renamed, 3 skipped, 0 orphaned, 0 collisions$'; then
    echo "FAIL: scenario 5 — unexpected summary line: $(echo "$out5" | grep '^summary')"; fail=1
fi
out5b=$(cd "$s5" && make sync HF_CACHE="$hf_cache5")
if ! echo "$out5b" | grep -qE '^summary — 0 created, 0 restored, 0 renamed, 3 skipped, 0 orphaned, 0 collisions$'; then
    echo "FAIL: scenario 5 — second run should create nothing: $(echo "$out5b" | grep '^summary')"; fail=1
fi

# list flags what vLLM can't load, and doesn't tell you to sync what sync skips.
list5=$(cd "$s5" && make list HF_CACHE="$hf_cache5")
if ! grep -E '^some-gguf ' <<<"$list5" | grep -q '✗ not loadable by vLLM: GGUF'; then
    echo "FAIL: scenario 5 — list should flag the stale GGUF variant"; fail=1
fi
if ! grep -E 'deepdml/Fast-CT2' <<<"$list5" | grep -q 'skipped by sync'; then
    echo "FAIL: scenario 5 — list should say sync skips the CT2 repo (not 'run make sync')"; fail=1
fi
if grep -q 'not synced — run make sync' <<<"$list5"; then
    echo "FAIL: scenario 5 — list must not ask for a sync that would skip again"; fail=1
fi

# up refuses an unloadable variant before touching docker; FORCE=1 overrides.
mkdir -p "$s5/bin"; printf '#!/usr/bin/env bash\necho "docker $*"\n' > "$s5/bin/docker"; chmod +x "$s5/bin/docker"
printf 'VLLM_TAG=latest\nVLLM_MODEL=placeholder\n' > "$s5/.env"; : > "$s5/.env.example"
if up5=$(cd "$s5" && PATH="$s5/bin:$PATH" make up ENV=some-gguf HF_CACHE="$hf_cache5" 2>&1); then rc=0; else rc=$?; fi
if [[ $rc -ne 2 ]] || ! grep -q 'refusing to start some-gguf: unsloth/Some-GGUF — GGUF checkpoint' <<<"$up5" || grep -q '^docker ' <<<"$up5"; then
    echo "FAIL: scenario 5 — up must refuse a GGUF variant (make exits 2 on the recipe's 65) without running docker: rc=$rc $up5"; fail=1
fi
# (capture first: `| grep -q` + pipefail turns grep's early exit into SIGPIPE on make)
force5=$(cd "$s5" && PATH="$s5/bin:$PATH" make up ENV=some-gguf FORCE=1 HF_CACHE="$hf_cache5" 2>&1)
if ! grep -q '^docker compose .* up -d' <<<"$force5"; then
    echo "FAIL: scenario 5 — FORCE=1 should bypass the guard: $force5"; fail=1
fi
ok5=$(cd "$s5" && PATH="$s5/bin:$PATH" make up ENV=chat-model HF_CACHE="$hf_cache5" 2>&1)
if ! grep -q '^docker compose .* up -d' <<<"$ok5"; then
    echo "FAIL: scenario 5 — a loadable variant must start normally: $ok5"; fail=1
fi

# The checker itself must exist: a missing script may not silently disable the guard.
rm "$s5/model-format.sh"
if (cd "$s5" && make sync HF_CACHE="$hf_cache5") >/dev/null 2>"$tmp/s5err"; then
    echo "FAIL: scenario 5 — sync must fail when model-format.sh is missing"; fail=1
elif ! grep -q 'model-format.sh is missing' "$tmp/s5err"; then
    echo "FAIL: scenario 5 — missing checker should be reported clearly: $(cat "$tmp/s5err")"; fail=1
fi

# --- scenario 6: sync drops retired defaults from .env, keeps everything
# else (including a customized VLLM_MAX_LEN), and is a no-op on re-run. ---
s6="$tmp/scenario6"
mkdir -p "$s6"
cp "$SCRIPT_DIR/Makefile" "$SCRIPT_DIR/model-format.sh" "$s6/"
printf 'VLLM_TAG=latest\nVLLM_GPU_MEM=0.9\nVLLM_MAX_LEN=32768\nVLLM_MODEL=placeholder\n' > "$s6/.env"

out6=$(cd "$s6" && make sync HF_CACHE="$s6/no-cache")

if grep -q '^VLLM_MAX_LEN=' "$s6/.env"; then
    echo "FAIL: scenario 6 — retired VLLM_MAX_LEN=32768 should be removed from .env"; fail=1
fi
if [[ $(grep -c . "$s6/.env") != 2 ]] || ! grep -q '^VLLM_TAG=latest$' "$s6/.env" \
   || ! grep -q '^VLLM_MODEL=placeholder$' "$s6/.env"; then
    echo "FAIL: scenario 6 — sync must keep every other line of .env"; fail=1
fi
if ! grep -q '^VLLM_MAX_LEN=32768$' "$s6/.env.bak" 2>/dev/null; then
    echo "FAIL: scenario 6 — sync should leave the original in .env.bak"; fail=1
fi
if grep -q '^VLLM_GPU_MEM=' "$s6/.env"; then
    echo "FAIL: scenario 6 — retired VLLM_GPU_MEM=0.9 should be removed (GPU share is sized per model now)"; fail=1
fi
if ! echo "$out6" | grep -q 'removed retired default VLLM_MAX_LEN=32768'; then
    echo "FAIL: scenario 6 — sync didn't report the removal"; fail=1
fi
if ! echo "$out6" | grep -q 'removed retired default VLLM_GPU_MEM=0.9'; then
    echo "FAIL: scenario 6 — sync didn't report the VLLM_GPU_MEM removal"; fail=1
fi
if (cd "$s6" && make sync HF_CACHE="$s6/no-cache") | grep -q 'removed retired default'; then
    echo "FAIL: scenario 6 — second sync should not remove anything"; fail=1
fi
printf 'VLLM_MAX_LEN=65536\nVLLM_GPU_MEM=0.35\n' > "$s6/.env"
(cd "$s6" && make sync HF_CACHE="$s6/no-cache" >/dev/null)
if ! grep -q '^VLLM_MAX_LEN=65536$' "$s6/.env"; then
    echo "FAIL: scenario 6 — a customized VLLM_MAX_LEN must be left alone"; fail=1
fi
if ! grep -q '^VLLM_GPU_MEM=0.35$' "$s6/.env"; then
    echo "FAIL: scenario 6 — a customized VLLM_GPU_MEM must be left alone"; fail=1
fi

# --- scenario 7: deprecated aliases still work and point at the new name ---
s7="$tmp/scenario7"
mkdir -p "$s7/envs"
cp "$SCRIPT_DIR/Makefile" "$SCRIPT_DIR/model-format.sh" "$s7/"
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
    echo "PASS: vllm sync (collisions + incremental + rename guard + .bak restore + format guard + retired .env defaults + aliases)"
else
    exit 1
fi
