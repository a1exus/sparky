#!/usr/bin/env bash
# Build the symlink farm for llama.cpp router mode, then regenerate config.ini.
# Idempotent. Called by `make hf-sync` (which exports the env vars below).
#
# Env (with defaults):
#   HF_CACHE        host HuggingFace cache dir (default /opt/hf/.cache/huggingface)
#   SYMLINK_FARM    host symlink farm dir (default /opt/hf/.cache/llama-cpp-models)
#   CTX_DEFAULT     default ctx-size for new config.ini sections (default 8192)
#   NGL_DEFAULT     default n-gpu-layers for new config.ini sections (default 999)
#
# Collision handling: if two HF repos ship a GGUF with the identical
# basename, EVERY repo sharing that basename gets a qualified symlink name
# (`<org>-<repo>--<basename>`) instead of one silently winning and the
# other being dropped. This is deterministic regardless of scan order —
# there is no "first one wins" branch. Basenames used by exactly one repo
# keep their plain name, unchanged from before this existed.

set -euo pipefail

HF_CACHE="${HF_CACHE:-/opt/hf/.cache/huggingface}"
SYMLINK_FARM="${SYMLINK_FARM:-/opt/hf/.cache/llama-cpp-models}"
CTX_DEFAULT="${CTX_DEFAULT:-8192}"
NGL_DEFAULT="${NGL_DEFAULT:-999}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGEN="$SCRIPT_DIR/regen-config-ini.py"

if [[ ! -x "$REGEN" ]]; then
    echo "sync-router: $REGEN not executable" >&2
    exit 1
fi
mkdir -p "$SYMLINK_FARM"

# Enumerate GGUFs in the HF cache. Output: <repo-id>\t<host-path>
list_ggufs() {
    if command -v hf >/dev/null 2>&1; then
        if hf cache scan --format json 2>/dev/null \
            | jq -re --arg cache "$HF_CACHE" '
                .repos[]
                | .repo_id as $repo
                | .revisions[]
                | .files[]
                | select(.path | endswith(".gguf"))
                | "\($repo)\t\(.path)"
            '; then
            return
        fi
    fi
    # Fallback: find walk; derive repo from path.
    find "$HF_CACHE/hub" -name "*.gguf" 2>/dev/null \
        | while read -r fp; do
            repo=$(echo "$fp" | sed -nE 's|.*/hub/models--([^/]+)/.*|\1|p' | sed 's|--|/|g')
            [[ -n "$repo" ]] || continue
            printf '%s\t%s\n' "$repo" "$fp"
        done
}

# Portable associative-array shim — bash 3.2 (macOS system bash) lacks
# `declare -A`. The encoded variable name (`_seen_<mangled-key>`) uniquely
# identifies each key. Reused below under three key namespaces
# (`cnt:`, `repos:`, `reported:`, `link:`) — a plain get/set/has store is
# enough for all of them; `cnt:`/`repos:` layer increment/append on top.
_seen_encode() { printf '%s' "$1" | LC_ALL=C tr -cs 'A-Za-z0-9_' '_'; }
seen_set() { local k; k=$(_seen_encode "$1"); eval "_seen_${k}=\$2"; }
seen_get() { local k; k=$(_seen_encode "$1"); eval "printf '%s' \"\${_seen_${k}:-}\""; }
seen_has() { [[ -n "$(seen_get "$1")" ]]; }

cnt_incr() { local k v; k=$(_seen_encode "cnt:$1"); v=$(seen_get "cnt:$1"); eval "_seen_${k}=\$(( ${v:-0} + 1 ))"; }
cnt_get() { seen_get "cnt:$1"; }
repos_append() {
    local k cur; k=$(_seen_encode "repos:$1"); cur=$(seen_get "repos:$1")
    eval "_seen_${k}=\"\${cur:+\$cur,}\$2\""
}
repos_get() { seen_get "repos:$1"; }

# Capture the full inventory once (avoids re-running `hf cache scan` / the
# `find` fallback twice, and lets us count before naming anything).
entries=()
while IFS=$'\t' read -r repo host_path; do
    [[ -n "$host_path" ]] || continue
    entries+=("$repo"$'\t'"$host_path")
done < <(list_ggufs)

# Counting pass — every entry's basename count + repo list, computed before
# any symlink decision is made, so naming never depends on scan order.
for entry in "${entries[@]}"; do
    IFS=$'\t' read -r repo host_path <<<"$entry"
    base=$(basename "$host_path")
    cnt_incr "$base"
    repos_append "$base" "$repo"
done

collisions_file=$(mktemp)
trap 'rm -f "$collisions_file"' EXIT

specs=""
created=0
unchanged=0
collisions=0

for entry in "${entries[@]}"; do
    IFS=$'\t' read -r repo host_path <<<"$entry"
    base=$(basename "$host_path")
    container_path="/root/.cache/huggingface${host_path#"$HF_CACHE"}"
    n=$(cnt_get "$base")

    if [[ "$n" -gt 1 ]]; then
        repo_slug=$(echo "$repo" | tr '[:upper:]' '[:lower:]' | tr '/ ' '--')
        link_name="${repo_slug}--${base}"
        if ! seen_has "reported:$base"; then
            printf '%s\t%s\n' "$base" "$(repos_get "$base")" >> "$collisions_file"
            seen_set "reported:$base" 1
            echo "  collision: $base shared by $(repos_get "$base") — every repo gets a qualified name" >&2
            collisions=$((collisions + 1))
        fi
    else
        link_name="$base"
    fi
    seen_set "link:$link_name" 1

    target="$SYMLINK_FARM/$link_name"
    if [[ -L "$target" && "$(readlink "$target")" == "$container_path" ]]; then
        unchanged=$((unchanged + 1))
    else
        ln -sfn "$container_path" "$target"
        echo "+ symlink $link_name → $container_path"
        created=$((created + 1))
    fi

    # Strip GGUF extension, split-part suffix, then dash- or dot-separated quant.
    # HF filenames use both conventions (e.g. `model-Q4_K_M.gguf` vs `model.Q4_K_M.gguf`).
    section=$(echo "$link_name" \
        | sed -E 's/\.gguf$//; s/-0*[0-9]+-of-[0-9]+$//; s/-MXFP4.*//; s/\.[QqFf][0-9].*//; s/-Q[0-9].*//; s/-IQ[0-9].*//; s/-BF[0-9]+$//; s/-F[0-9]+$//' \
        | tr '[:upper:]' '[:lower:]')

    # The router auto-derives an HF-style ID (`<org>/<repo>:<quant>`) from the
    # symlink target path, so we don't emit `alias =` ourselves — doing so
    # produced a duplicate-name error at server startup.

    # Only the first part of a multi-part split is the load entry point.
    # Part-number detection uses the ORIGINAL basename — the qualifier
    # prefix never touches the `-NNNNN-of-NNNNN` suffix.
    part=$(echo "$base" | sed -nE 's/.*-0*([0-9]+)-of-[0-9]+\.gguf$/\1/p')
    if [[ -z "$part" || "$part" == "1" ]]; then
        specs+="$section"$'\t'"/models/$link_name"$'\n'
    fi
done

orphaned=0
shopt -s nullglob
for link in "$SYMLINK_FARM"/*.gguf; do
    link_base=$(basename "$link")
    if ! seen_has "link:$link_base"; then
        echo "→ orphan symlink: $link_base"
        rm "$link"
        orphaned=$((orphaned + 1))
    fi
done

printf '%s' "$specs" | "$REGEN" \
    "$SYMLINK_FARM/config.ini" \
    "$SYMLINK_FARM/config.ini.orphans" \
    "$CTX_DEFAULT" \
    "$NGL_DEFAULT" \
    "$SYMLINK_FARM" \
    "$collisions_file"

echo "router summary: $created symlinks created/updated, $unchanged unchanged, $orphaned orphaned, $collisions collision groups"
