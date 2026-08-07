# Model Identity Collision Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `llama-cpp/scripts/sync-router.sh` and `vllm/Makefile`'s `hf-sync` from silently dropping a model when two HF repos share a GGUF basename (llama-cpp) or a repo name (vllm) — every colliding entry gets a deterministic, qualified name instead of one winner and a silently-dropped loser.

**Architecture:** Both engines already compute a "short" identity by stripping vendor/org from a filename or repo name. Neither previously grouped entries by that identity before naming them — a `find`/`hf cache scan` walk assigned names one at a time, first one to claim a name won, the rest were skipped (llama-cpp) or left un-discoverable (vllm). The fix inserts a counting pass before naming: entries sharing an identity all get a qualified name (`<org>-<repo>--<basename>` / `<org>-<repo>`); entries that don't collide keep today's exact naming, unchanged. Collision groups get written into `config.ini`'s header (llama-cpp) and reported/annotated in `make hf-cache` (both), so they're visible without watching `hf-sync`'s live stdout.

**Tech Stack:** bash 3.2-compatible shell scripts, Python 3 stdlib (`configparser`, `pathlib`), GNU Make.

## Global Constraints

- Bash scripts must stay bash 3.2 compatible (macOS system bash) — no `declare -A`, no `mapfile`/`readarray`. `sync-router.sh` already documents and relies on this; don't regress it.
- No new external dependencies. Use only what's already in play: `jq`, `hf` (optional, falls back to `find`), `sed`, `grep`, Python stdlib.
- Zero behavior change for non-colliding entries — every task with a symlink/env-file naming change must be regression-tested to confirm the non-colliding majority keeps byte-identical names to today.
- Preserve existing atomic-write guarantees (`config.ini` / `config.ini.orphans` via `.tmp` + `os.replace()` in `regen-config-ini.py`) — don't introduce a non-atomic write path.
- Every test in this plan must be runnable standalone, without Docker or network access, except Task 6 which explicitly requires SSH to `spark-1822.local`.

---

### Task 1: `regen-config-ini.py` — preserve hand-added sections, render a COLLISIONS header

**Files:**
- Modify: `llama-cpp/scripts/regen-config-ini.py`
- Create: `llama-cpp/scripts/test-regen-config-ini.sh`

**Interfaces:**
- Produces: new CLI contract `regen-config-ini.py <config-path> <orphan-path> <ctx-default> <ngl-default> <symlink-farm-dir> <collisions-path>` (was 4 positional args, now 6). `<symlink-farm-dir>` is the host directory that backs `/models` inside the container — used to check whether a hand-added section's GGUF still physically exists. `<collisions-path>` is a file of `<basename>\t<comma-joined-repo-list>` lines (may be empty/absent — treated as "no collisions"). Task 2 depends on this exact argv order and the collisions-file format.

- [ ] **Step 1: Write the failing test**

Create `llama-cpp/scripts/test-regen-config-ini.sh`:

```bash
#!/usr/bin/env bash
# Standalone test for regen-config-ini.py. No framework — builds a scratch
# dir, runs the script, asserts on the resulting files. Run directly:
#   ./scripts/test-regen-config-ini.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGEN="$SCRIPT_DIR/regen-config-ini.py"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

farm="$tmp/farm"
mkdir -p "$farm"
touch "$farm/auto-model.gguf"
touch "$farm/manual-model.gguf"
# gone-model.gguf intentionally NOT created — simulates a removed GGUF.

fail=0

# --- scenario 1: hand-added section preservation + orphan archival ---
config="$tmp/config.ini"
orphans="$tmp/config.ini.orphans"
collisions="$tmp/collisions.txt"
: > "$collisions"

cat > "$config" <<'EOF'
[auto-model]
model = /models/auto-model.gguf
ctx-size = 4096

[manual-alias]
model = /models/manual-model.gguf
ctx-size = 16384

[gone-model]
model = /models/gone-model.gguf
EOF

printf 'auto-model\t/models/auto-model.gguf\n' | "$REGEN" "$config" "$orphans" 8192 999 "$farm" "$collisions"

if ! grep -q '^\[auto-model\]' "$config"; then
    echo "FAIL: [auto-model] missing from config.ini (should be managed+kept)"; fail=1
fi
if ! grep -q 'ctx-size = 4096' "$config"; then
    echo "FAIL: [auto-model] lost its user-set ctx-size"; fail=1
fi
if ! grep -q '^\[manual-alias\]' "$config"; then
    echo "FAIL: [manual-alias] missing from config.ini — hand-added section not preserved"; fail=1
fi
if ! grep -q 'ctx-size = 16384' "$config"; then
    echo "FAIL: [manual-alias] lost its user-set ctx-size"; fail=1
fi
if grep -q '^\[gone-model\]' "$config"; then
    echo "FAIL: [gone-model] still in config.ini — should have been archived (its GGUF is gone)"; fail=1
fi
if ! grep -q '^\[gone-model\]' "$orphans"; then
    echo "FAIL: [gone-model] not archived to config.ini.orphans"; fail=1
fi

# --- scenario 2: COLLISIONS header rendering ---
config2="$tmp/config2.ini"
orphans2="$tmp/config2.ini.orphans"
collisions2="$tmp/collisions2.txt"
printf 'model-x.gguf\tvendorA/Model-X-GGUF,vendorB/Model-X-GGUF\n' > "$collisions2"

printf 'vendora-model-x-gguf--model-x\t/models/vendora-model-x-gguf--model-x.gguf\nvendorb-model-x-gguf--model-x\t/models/vendorb-model-x-gguf--model-x.gguf\n' \
    | "$REGEN" "$config2" "$orphans2" 8192 999 "$farm" "$collisions2"

if ! grep -q '# COLLISIONS' "$config2"; then
    echo "FAIL: config.ini missing COLLISIONS header block"; fail=1
fi
if ! grep -q 'model-x.gguf' "$config2"; then
    echo "FAIL: COLLISIONS header doesn't mention the colliding basename"; fail=1
fi

if [[ $fail -eq 0 ]]; then
    echo "PASS: regen-config-ini.py"
else
    exit 1
fi
```

Make it executable:

```bash
chmod +x llama-cpp/scripts/test-regen-config-ini.sh
```

- [ ] **Step 2: Run it, confirm it fails**

Run: `./llama-cpp/scripts/test-regen-config-ini.sh`
Expected: FAIL — the current script only accepts 4 positional args (`usage: ... <config-path> <orphan-path> <ctx-default> <ngl-default>`); called with 6, it prints the usage error and exits 64 before either scenario's assertions get a chance to run.

- [ ] **Step 3: Modify `regen-config-ini.py`**

Replace the full file with:

```python
#!/usr/bin/env python3
"""Regenerate config.ini for llama.cpp router mode with managed-fields semantics.

Reads tab-separated GGUF inventory from stdin (one per line):
    <section-name>\t<container-model-path>

Writes:
    <config-path>          active sections (one per current GGUF)
    <orphan-path>          removed-GGUF archive (restored verbatim if GGUF returns)

Managed-fields rules:
    - On each run, hf-sync owns the `model =` line of every active section.
    - All other keys are user-editable and preserved verbatim across runs.
    - A new section gets default `ctx-size` and `n-gpu-layers` from CLI args.
    - When a GGUF disappears from the input, its section is moved to the
      orphan archive (kept verbatim). If the GGUF later returns, the archived
      section is restored as-is (preserving any user edits) — except `model`,
      which is rewritten from the current input.
    - A section that isn't in the current input at all (hand-added, or from
      before this run) is kept as-is, not archived, as long as its `model`
      file still exists in the symlink farm — lets a user manually assign a
      short alias to a model sync-router.sh didn't (e.g. a collision loser)
      and have it survive future runs.

Collision reporting: <collisions-path> holds tab-separated
    <basename>\t<comma-joined-repo-list>
lines (produced by sync-router.sh's counting pass). Rendered as a
`# COLLISIONS` block in config.ini's header. Empty/missing file → no block.

Atomic writes: <path>.tmp + os.replace() so concurrent readers never see a
half-written file.
"""

from __future__ import annotations

import configparser
import os
import sys
from pathlib import Path


def _load(path: Path) -> configparser.ConfigParser:
    cp = configparser.ConfigParser()
    cp.optionxform = str  # preserve key case
    if path.exists():
        cp.read(path)
    return cp


def _write_atomic(cp: configparser.ConfigParser, path: Path, header: str) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w") as f:
        f.write(header)
        cp.write(f)
    os.replace(tmp, path)


def _load_collisions(path: Path) -> list[tuple[str, str]]:
    if not path.exists():
        return []
    collisions: list[tuple[str, str]] = []
    for raw in path.read_text().splitlines():
        if not raw:
            continue
        basename, repos = raw.split("\t", 1)
        collisions.append((basename, repos))
    return collisions


def main() -> int:
    if len(sys.argv) != 7:
        print(
            f"usage: {sys.argv[0]} <config-path> <orphan-path> <ctx-default> "
            "<ngl-default> <symlink-farm-dir> <collisions-path>",
            file=sys.stderr,
        )
        return 64

    config_path = Path(sys.argv[1])
    orphan_path = Path(sys.argv[2])
    ctx_default = sys.argv[3]
    ngl_default = sys.argv[4]
    symlink_farm = Path(sys.argv[5])
    collisions_path = Path(sys.argv[6])

    for p in (config_path, orphan_path):
        if not p.parent.exists():
            print(f"error: parent directory does not exist: {p.parent}", file=sys.stderr)
            return 1

    current: dict[str, str] = {}
    for lineno, raw in enumerate(sys.stdin, 1):
        line = raw.rstrip("\r\n")
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 2:
            print(
                f"stdin line {lineno}: expected 2 tab-separated fields, got {len(parts)}: {line!r}",
                file=sys.stderr,
            )
            return 2
        section, model = parts
        current[section] = model

    existing = _load(config_path)
    orphans = _load(orphan_path)
    collisions = _load_collisions(collisions_path)

    new_config = configparser.ConfigParser()
    new_config.optionxform = str
    new_orphans = configparser.ConfigParser()
    new_orphans.optionxform = str

    for section, model in current.items():
        if existing.has_section(section):
            new_config[section] = dict(existing.items(section))
            new_config[section]["model"] = model  # managed field
        elif orphans.has_section(section):
            new_config[section] = dict(orphans.items(section))
            new_config[section]["model"] = model
        else:
            new_config[section] = {
                "model": model,
                "ctx-size": ctx_default,
                "n-gpu-layers": ngl_default,
            }

    for section in existing.sections():
        if section in current:
            continue
        model_value = existing.get(section, "model", fallback="")
        target = symlink_farm / Path(model_value).name if model_value else None
        if target is not None and target.exists():
            # Hand-added or previously-managed section whose GGUF is still
            # physically present — keep it, don't archive it.
            new_config[section] = dict(existing.items(section))
            continue
        new_orphans[section] = dict(existing.items(section))

    for section in orphans.sections():
        if section in current or new_config.has_section(section):
            continue
        if not new_orphans.has_section(section):
            new_orphans[section] = dict(orphans.items(section))

    config_header = (
        "# Auto-generated by `make hf-sync`. Sections are managed:\n"
        "#   - hf-sync owns the `model` line (rewritten every run).\n"
        "#   - All other keys are user-editable and preserved across runs.\n"
        "#   - Hand-added sections are kept as-is as long as their `model`\n"
        "#     file still exists in the symlink farm.\n"
        "#   - Removed GGUFs go to config.ini.orphans (restored if they return).\n"
    )
    if collisions:
        config_header += (
            "#\n"
            "# COLLISIONS — these basenames were shared by multiple HF repos;\n"
            "# every repo in the group got a qualified symlink name (see\n"
            "# sync-router.sh). Regenerated every hf-sync run.\n"
        )
        for basename, repos in collisions:
            config_header += f"#   {basename}: {repos}\n"
    config_header += "\n"

    orphan_header = (
        "# Orphan archive — sections for GGUFs no longer in the HF cache.\n"
        "# Restored verbatim if the GGUF returns. Edit freely.\n\n"
    )
    _write_atomic(new_config, config_path, config_header)
    _write_atomic(new_orphans, orphan_path, orphan_header)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Run the test again, confirm it passes**

Run: `./llama-cpp/scripts/test-regen-config-ini.sh`
Expected: `PASS: regen-config-ini.py`

- [ ] **Step 5: Commit**

```bash
git add llama-cpp/scripts/regen-config-ini.py llama-cpp/scripts/test-regen-config-ini.sh
git commit -m "llama-cpp: preserve hand-added config.ini sections, render COLLISIONS header"
```

---

### Task 2: `sync-router.sh` — always-qualify collision groups

**Files:**
- Modify: `llama-cpp/scripts/sync-router.sh`
- Create: `llama-cpp/scripts/test-sync-router.sh`

**Interfaces:**
- Consumes: Task 1's `regen-config-ini.py` argv contract (`<config> <orphans> <ctx> <ngl> <symlink-farm-dir> <collisions-path>`).
- Produces: symlink farm naming contract used by Task 4 — colliding basenames get `<org>-<repo>--<basename>` (org and repo lowercased, `/` and spaces replaced with `-`, joined to the original repo path); non-colliding basenames are unchanged from today.

- [ ] **Step 1: Write the failing test**

Create `llama-cpp/scripts/test-sync-router.sh`:

```bash
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
```

Make it executable:

```bash
chmod +x llama-cpp/scripts/test-sync-router.sh
```

- [ ] **Step 2: Run it, confirm it fails**

Run: `./llama-cpp/scripts/test-sync-router.sh`
Expected: FAIL — today's script calls `regen-config-ini.py` with only 4 args (breaks on Task 1's new 6-arg contract), and its first-wins collision logic drops `vendorB`'s file entirely rather than qualifying both names.

- [ ] **Step 3: Modify `sync-router.sh`**

Replace the full file with:

```bash
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
```

- [ ] **Step 4: Run the test again, confirm it passes**

Run: `./llama-cpp/scripts/test-sync-router.sh`
Expected: `PASS: sync-router.sh collision handling + idempotency`

- [ ] **Step 5: Commit**

```bash
git add llama-cpp/scripts/sync-router.sh llama-cpp/scripts/test-sync-router.sh
git commit -m "llama-cpp: qualify every repo in a basename collision, never drop one"
```

---

### Task 3: `vllm/Makefile` `hf-sync` — collision-safe env naming

**Files:**
- Modify: `vllm/Makefile`
- Create: `vllm/test-hf-sync.sh`

**Interfaces:**
- Produces: env-file naming contract used by Task 4 — colliding repo names get `envs/<org>-<repo-name>.env` (both lowercased); non-colliding repo names keep today's `envs/<repo-name>.env`. `VLLM_SERVED_NAME` inside the file matches the file's stem.

- [ ] **Step 1: Write the failing test**

Create `vllm/test-hf-sync.sh`:

```bash
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
```

Make it executable:

```bash
chmod +x vllm/test-hf-sync.sh
```

- [ ] **Step 2: Run it, confirm it fails**

Run: `./vllm/test-hf-sync.sh`
Expected: FAIL — today's `hf-sync` creates `shared-model.env` for whichever of orgA/orgB is processed first and prints `name clash: ... leave alone` for the other, so `orga-shared-model.env`/`orgb-shared-model.env` never get created and the summary line has no collision count.

- [ ] **Step 3: Modify `vllm/Makefile`**

Replace the `hf-sync:` target's recipe (the `.PHONY` line and other targets stay untouched) with:

```makefile
hf-sync:  ## Reconcile envs against the HF cache: create new, restore from .bak, orphan to .bak.
	@cached=$$(ls -d $(HF_CACHE)/hub/models--* 2>/dev/null | sed 's|.*/models--||; s|--|/|'); \
	if [[ -z "$$cached" ]]; then echo "no models in $(HF_CACHE)/hub/"; exit 0; fi; \
	cd envs; \
	created=0; restored=0; orphaned=0; collisions=0; \
	dupes=$$(echo "$$cached" | while read -r r; do [[ -z "$$r" ]] && continue; echo "$$r" | cut -d/ -f2 | tr 'A-Z' 'a-z'; done | sort | uniq -d); \
	if [[ -n "$$dupes" ]]; then \
	    while read -r d; do \
	        [[ -z "$$d" ]] && continue; \
	        echo "  collision: $$d shared by multiple orgs — every repo gets an org-qualified name"; \
	        collisions=$$((collisions + 1)); \
	    done <<<"$$dupes"; \
	fi; \
	while read -r repo; do \
	    [[ -z "$$repo" ]] && continue; \
	    short=$$(echo "$$repo" | cut -d/ -f2 | tr 'A-Z' 'a-z'); \
	    if echo "$$dupes" | grep -qFx "$$short"; then \
	        org=$$(echo "$$repo" | cut -d/ -f1 | tr 'A-Z' 'a-z'); \
	        slug="$$org-$$short"; \
	    else \
	        slug="$$short"; \
	    fi; \
	    file="$$slug.env"; \
	    if grep -lE "^VLLM_MODEL=$$repo[[:space:]]*\$$" *.env 2>/dev/null | head -1 >/dev/null; then \
	        :; \
	    elif [[ -f "$$file.bak" ]] && grep -qE "^VLLM_MODEL=$$repo[[:space:]]*\$$" "$$file.bak"; then \
	        printf '↩ restore %s ← %s.bak\n' "$$file" "$$file"; \
	        mv "$$file.bak" "$$file"; \
	        restored=$$((restored + 1)); \
	    elif [[ -f "$$file" ]]; then \
	        echo "  name clash: $$file already exists but points elsewhere — leave alone, rename manually if needed"; \
	    else \
	        printf '+ create  %s — %s\n' "$$file" "$$repo"; \
	        { \
	            echo "# $$repo. Layered on top of ../.env by \`make up ENV=$$slug\`."; \
	            echo "# Host-wide values (VLLM_TAG, HF_CACHE_HOST, HF_TOKEN, defaults)"; \
	            echo "# live in ../.env."; \
	            echo ""; \
	            echo "VLLM_MODEL=$$repo"; \
	            echo "VLLM_SERVED_NAME=$$slug"; \
	            echo ""; \
	            echo "# Optional per-variant overrides — uncomment to use."; \
	            echo "# VLLM_GPU_MEM=0.9"; \
	            echo "# VLLM_MAX_LEN=32768"; \
	        } > "$$file"; \
	        created=$$((created + 1)); \
	    fi; \
	done <<<"$$cached"; \
	for f in *.env; do \
	    [[ -f "$$f" ]] || continue; \
	    repo=$$(grep -E '^VLLM_MODEL=' "$$f" | head -1 | cut -d= -f2-); \
	    [[ -z "$$repo" ]] && continue; \
	    if ! grep -qFx "$$repo" <<<"$$cached"; then \
	        printf '→ orphan  %s → %s.bak\n' "$$f" "$$f"; \
	        mv "$$f" "$$f.bak"; \
	        orphaned=$$((orphaned + 1)); \
	    fi; \
	done; \
	echo "summary — $$created created, $$restored restored, $$orphaned orphaned, $$collisions collisions"
```

- [ ] **Step 4: Run the test again, confirm it passes**

Run: `./vllm/test-hf-sync.sh`
Expected: `PASS: vllm hf-sync collision handling`

- [ ] **Step 5: Commit**

```bash
git add vllm/Makefile vllm/test-hf-sync.sh
git commit -m "vllm: qualify every repo in an env-alias collision, never leave one undiscoverable"
```

---

### Task 4: `make hf-cache` — annotate collisions (both engines)

**Files:**
- Modify: `llama-cpp/Makefile`
- Modify: `vllm/Makefile`
- Create: `llama-cpp/test-hf-cache.sh`
- Create: `vllm/test-hf-cache.sh`

**Interfaces:**
- Consumes: Task 2's `config.ini` COLLISIONS header (llama-cpp); Task 3's `dupes`-detection logic, inlined identically here for vllm (no shared script between engines yet — that's Track B).

- [ ] **Step 1: Write the failing tests**

Create `llama-cpp/test-hf-cache.sh`:

```bash
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

if [[ $fail -eq 0 ]]; then
    echo "PASS: llama-cpp hf-cache collision annotation"
else
    exit 1
fi
```

Create `vllm/test-hf-cache.sh`:

```bash
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
```

Make both executable:

```bash
chmod +x llama-cpp/test-hf-cache.sh vllm/test-hf-cache.sh
```

- [ ] **Step 2: Run both, confirm they fail**

Run: `./llama-cpp/test-hf-cache.sh && ./vllm/test-hf-cache.sh`
Expected: both FAIL — neither `hf-cache` target currently emits a `⚠ collision` marker.

- [ ] **Step 3: Modify `llama-cpp/Makefile`**

In the `hf-cache:` target, find this block (the per-repo loop body):

```makefile
	    router_flag=""; \
	    if [[ $$gg -gt 0 && -d "$$farm" ]]; then \
	        for fp in $$(find "$$d" -name "*.gguf" 2>/dev/null); do \
	            if [[ -L "$$farm/$$(basename "$$fp")" ]]; then router_flag=" [router]"; break; fi; \
	        done; \
	    fi; \
	    if [[ $$gg -gt 0 ]]; then \
	        printf "  %-60s [%d GGUF — llama-cpp can load]%s\n" "$$repo" "$$gg" "$$router_flag"; \
	    else \
	        printf "  %-60s [%d safetensors — vllm only]\n" "$$repo" "$$st"; \
	    fi; \
```

Replace it with:

```makefile
	    router_flag=""; \
	    collision_flag=""; \
	    if [[ $$gg -gt 0 && -d "$$farm" ]]; then \
	        for fp in $$(find "$$d" -name "*.gguf" 2>/dev/null); do \
	            if [[ -L "$$farm/$$(basename "$$fp")" ]]; then router_flag=" [router]"; break; fi; \
	        done; \
	        if [[ -f "$$farm/config.ini" ]] && grep -q "^#.*$$repo" "$$farm/config.ini"; then \
	            collision_flag=" [⚠ collision]"; \
	        fi; \
	    fi; \
	    if [[ $$gg -gt 0 ]]; then \
	        printf "  %-60s [%d GGUF — llama-cpp can load]%s%s\n" "$$repo" "$$gg" "$$router_flag" "$$collision_flag"; \
	    else \
	        printf "  %-60s [%d safetensors — vllm only]\n" "$$repo" "$$st"; \
	    fi; \
```

- [ ] **Step 4: Modify `vllm/Makefile`**

Replace the `hf-cache:` target's recipe with:

```makefile
hf-cache:  ## List HF repos already downloaded in this host's HF cache.
	@dupes=$$(ls -d $(HF_CACHE)/hub/models--* 2>/dev/null | sed 's|.*/models--||; s|--|/|' | while read -r r; do [[ -z "$$r" ]] && continue; echo "$$r" | cut -d/ -f2 | tr 'A-Z' 'a-z'; done | sort | uniq -d); \
	ls -d $(HF_CACHE)/hub/models--* 2>/dev/null \
	    | sed 's|.*/models--||; s|--|/|' | sort \
	    | while read -r repo; do \
	        short=$$(echo "$$repo" | cut -d/ -f2 | tr 'A-Z' 'a-z'); \
	        if echo "$$dupes" | grep -qFx "$$short"; then \
	            echo "$$repo  [⚠ collision]"; \
	        else \
	            echo "$$repo"; \
	        fi; \
	    done
```

- [ ] **Step 5: Run both tests again, confirm they pass**

Run: `./llama-cpp/test-hf-cache.sh && ./vllm/test-hf-cache.sh`
Expected: both `PASS`.

- [ ] **Step 6: Commit**

```bash
git add llama-cpp/Makefile vllm/Makefile llama-cpp/test-hf-cache.sh vllm/test-hf-cache.sh
git commit -m "llama-cpp,vllm: annotate collisions in make hf-cache output"
```

---

### Task 5: README updates (both engines)

**Files:**
- Modify: `llama-cpp/README.md`
- Modify: `vllm/README.md`

**Interfaces:**
- Consumes: naming contracts from Tasks 2 and 3 (exact qualified-name formats).

- [ ] **Step 1: Add a "Model naming and collisions" section to `llama-cpp/README.md`**

Find the section documenting `make hf-sync` / the symlink farm (search for `hf-sync` in the file to locate it) and add a new subsection immediately after it:

```markdown
### Model naming and collisions

`make hf-sync` names each symlink in the farm after its GGUF's bare filename
(e.g. `Qwen3.6-27B-BF16-00001-of-00002.gguf`) — that's also where the short
`config.ini` alias (`qwen3.6-27b`) comes from. Vendors sometimes reuse the
same filename across different repos (e.g. a base model and its MTP/
speculative-decoding sibling). When that happens, **every** repo sharing
that filename gets a qualified name instead: `<org>-<repo>--<basename>`,
e.g. `unsloth-qwen3.6-27b-mtp-gguf--Qwen3.6-27B-BF16-00001-of-00002.gguf`.
This is deterministic — it doesn't depend on scan order, and a plain name
never silently starts pointing at a different repo just because a new
colliding sibling showed up later.

Every collision is listed in a `# COLLISIONS` block at the top of
`config.ini`, regenerated on every `hf-sync` run, and flagged with
`⚠ collision` in `make hf-cache` output.

If you want a nicer alias for a qualified name, hand-edit its section name
in `config.ini` — `make hf-sync` only ever rewrites a section's `model =`
line, and preserves any section (including a renamed one) as long as its
GGUF is still in the farm.

Note: llama.cpp's router also lists every standard-layout HF repo under its
full `<org>/<repo>:<quant>` ID directly from the HF cache (`"source": "cache"`
in `/v1/models`), independent of this symlink farm. That path is always
collision-proof — it's the symlink farm's *short alias* layer this section
is about.
```

- [ ] **Step 2: Add a "Model naming and collisions" section to `vllm/README.md`**

Find the section documenting `make hf-sync` and add:

```markdown
### Model naming and collisions

`make hf-sync` names each `envs/*.env` file after the HF repo's name with
its org stripped (e.g. `qwen3.6-27b.env` for `unsloth/Qwen3.6-27B`). Two
different orgs publishing a repo with the same name collide on that name.
When that happens, **every** repo sharing the name gets an org-qualified
file instead: `envs/<org>-<repo>.env`, e.g. `envs/orgb-qwen3.6-27b.env`.
`VLLM_SERVED_NAME` inside the file always matches its filename stem.

This is a discoverability fix, not an availability one — `VLLM_MODEL=<org>/<repo>`
is always the real, unique identity vLLM loads; the short filename is only
a `make up ENV=<name>` convenience. `make hf-cache` flags affected repos
with `⚠ collision`.
```

- [ ] **Step 3: Commit**

```bash
git add llama-cpp/README.md vllm/README.md
git commit -m "docs: document collision-safe model naming for llama-cpp and vllm"
```

---

### Task 6: Verify against the live `spark-1822` inventory

**Files:** none (verification only — no code changes).

**Interfaces:**
- Consumes: all prior tasks, deployed to `spark-1822.local`.

This task requires SSH access to `spark-1822.local` (confirmed working: `ssh spark-1822.local 'echo ok'`).

- [ ] **Step 1: Deploy the changed files**

Copy the modified files to the host (adjust for however this repo is normally deployed there — e.g. `git pull` on the host if it's a clone, or `scp` the four changed files):

```bash
ssh spark-1822.local 'cd /opt/sparky && git pull'   # if /opt is a clone of this repo
```

If `/opt/llama-cpp` and `/opt/vllm` are deployed separately from a `sparky` checkout (as the earlier investigation in this conversation found — `/opt/llama-cpp/scripts/sync-router.sh` was inspected directly), copy the four changed files to their live locations instead:

```bash
scp llama-cpp/scripts/sync-router.sh llama-cpp/scripts/regen-config-ini.py spark-1822.local:/opt/llama-cpp/scripts/
scp llama-cpp/Makefile spark-1822.local:/opt/llama-cpp/Makefile
scp vllm/Makefile spark-1822.local:/opt/vllm/Makefile
```

- [ ] **Step 2: Back up the live `config.ini` before touching it**

```bash
ssh spark-1822.local 'cp /opt/hf/.cache/llama-cpp-models/config.ini /opt/hf/.cache/llama-cpp-models/config.ini.pre-collision-fix.bak'
```

- [ ] **Step 3: Run `make hf-sync` on the live host**

```bash
ssh spark-1822.local 'cd /opt/llama-cpp && make hf-sync'
```

Expected in the output: a `collision:` line naming `Qwen3.6-27B-BF16-00001-of-00002.gguf` (and part 2) shared by `unsloth/Qwen3.6-27B-GGUF` and `unsloth/Qwen3.6-27B-MTP-GGUF`, and a nonzero collision-group count in the final summary.

- [ ] **Step 4: Confirm the previously-missing model is now present**

```bash
ssh spark-1822.local 'ls /opt/hf/.cache/llama-cpp-models/ | grep -i qwen3.6-27b'
ssh spark-1822.local 'grep -A2 "unsloth-qwen3.6-27b-mtp-gguf" /opt/hf/.cache/llama-cpp-models/config.ini'
```

Expected: both a plain-named entry (for whichever side isn't `unsloth/Qwen3.6-27B-GGUF` — check which one collided; both should now appear qualified per Task 2's design since this is a real collision group, so expect **both** `unsloth-qwen3.6-27b-gguf--...` and `unsloth-qwen3.6-27b-mtp-gguf--...` symlinks, not a plain `Qwen3.6-27B-BF16-...`) and a `config.ini` section for the MTP variant, which had neither before this fix.

- [ ] **Step 5: Confirm the non-colliding majority is unchanged**

```bash
ssh spark-1822.local 'ls /opt/hf/.cache/llama-cpp-models/*.gguf' > /tmp/after.txt
diff <(ssh spark-1822.local 'ls /opt/hf/.cache/llama-cpp-models/*.gguf' 2>/dev/null | grep -v -i qwen3.6-27b) <(echo "(compare manually against a pre-fix listing, or confirm by inspection that gpt-oss-120b-F16.gguf, DeepSeek-R1-0528-Qwen3-8B-BF16.gguf, Qwythos-*.gguf, Qwopus*.gguf, Qwen3.5-27B.Q8_0.gguf, Qwen3.6-35B-A3B-BF16-*.gguf all still exist under their exact pre-fix names)")
```

Cross-check against the live `/v1/models` output pulled earlier in this conversation — every ID in that list except the `Qwen3.6-27B` family and the `dspark-DeepSeek-V4-Flash-0731*` entries (unrelated, separate known issue) should be byte-identical.

- [ ] **Step 6: Restart the container and re-check `/v1/models`**

```bash
ssh spark-1822.local 'cd /opt/llama-cpp && docker compose up -d && sleep 5 && make models' | grep -i qwen3.6-27b
```

Expected: `unsloth/Qwen3.6-27B-MTP-GGUF:BF16` was already present before this fix (via the router's native cache-scan, per this conversation's earlier finding) — confirm it's still there, and confirm the new qualified-named `models_dir`-sourced entries (`unsloth-qwen3.6-27b-mtp-gguf--Qwen3.6-27B-BF16-00001-of-00002`, etc.) now also appear, which they didn't before.

- [ ] **Step 7: Report results back**

No commit for this task (verification only). Summarize pass/fail for each check above before considering Track A complete.

---

## Self-review notes

- **Spec coverage:** every "Decisions (locked in)" item in the design doc maps to a task — canonical identity via the router's existing native scan (no code change needed, already true, documented in Task 5) / no-silent-winners (Tasks 2, 3) / zero churn (regression-tested in Tasks 2, 3, 6) / persisted collision visibility (Tasks 1, 4) / both engines (Tasks 2 vs 3 in parallel).
- **Placeholder scan:** no TBD/TODO; every step has runnable code or exact commands.
- **Type/name consistency:** `regen-config-ini.py`'s 6-arg contract (Task 1) matches its invocation in `sync-router.sh` (Task 2) exactly. `link_name`'s qualified-name format (`<org>-<repo>--<basename>`, Task 2) matches what Task 4's `llama-cpp/test-hf-cache.sh` and README (Task 5) describe. `slug`'s qualified-name format (`<org>-<repo>`, Task 3) matches Task 4's vllm test and README.
- **Scope:** DeepSeek-V4-Flash's load failure and Makefile structural unification (Track B) are explicitly out of scope, called out in Tasks 5 and 6 so nobody conflates them with this fix.
