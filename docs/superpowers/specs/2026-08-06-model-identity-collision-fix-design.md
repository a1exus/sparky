# Model identity collision fix — design

**Status:** implemented ([PR #23](https://github.com/a1exus/sparky/pull/23)). Two details below drifted from this doc during implementation — see the inline notes at the qualified-name format and the vllm collision-reporting mechanism.
**Date:** 2026-08-06.
**Services:** `llama-cpp/`, `vllm/`.

## Goal

Guarantee that no cached GGUF or HF repo ever becomes unreachable or loses its identity because another vendor's file happens to share the same basename (llama-cpp) or repo name (vllm). Restore alias/tuning parity for models currently affected. Make collisions persistently visible instead of a transient `hf-sync` stdout line.

## Background

`llama-cpp/scripts/sync-router.sh` builds a flat symlink farm (`/opt/hf/.cache/llama-cpp-models/`, mounted `/models` in the container) keyed on the bare GGUF basename. `vllm/Makefile`'s `hf-sync` target builds one `envs/<short>.env` per cached HF repo, keyed on `cut -d/ -f2` of the repo id (org discarded). Both assume the key is unique across the whole cache. It isn't.

**Confirmed live on `spark-1822`:** `unsloth/Qwen3.6-27B-GGUF` and `unsloth/Qwen3.6-27B-MTP-GGUF` both ship a file named `Qwen3.6-27B-BF16-00001-of-00002.gguf` (and part 2). `sync-router.sh`'s collision handling (`seen_has "$base"` → skip) links only the first one encountered; the second is dropped with a one-line warning to whichever terminal happened to be running `make hf-sync`. Scan order (`hf cache scan` / `find` fallback) is not guaranteed stable, so which repo "wins" is not even deterministic across runs.

**What this bug does *not* do, confirmed by inspecting the live `/v1/models` response:** llama.cpp's router performs its own independent recursive scan of the mounted HF cache and exposes every standard-layout repo under a `--hf-repo <org>/<repo>:<quant>` preset (`"source": "cache"` in the API response) — entirely independent of the `/models` symlink farm. This is why `unsloth/Qwen3.6-27B-MTP-GGUF:BF16` *is* listed and correctly resolvable today, with its own correct `--hf-repo` args. No model is being silently served under the wrong name.

**What the bug does do:**
1. The collision loser gets no short alias and no `config.ini` tuning (`ctx-size`, `n-gpu-layers`, speculative-decoding knobs) — reachable only via the full `org/repo:quant` ID with defaults.
2. For repos whose GGUF lives outside llama.cpp's native scan conventions (confirmed case: `unsloth/DeepSeek-V4-Flash-0731-GGUF`, file nested under a `dspark/` subfolder the native scanner doesn't recognize as a quant directory), the symlink farm is the *only* path in — and that's exactly where the silent-skip logic lives. A collision here means genuine, total loss of reachability.
3. vllm's analogous `hf-sync` collision path (`name clash: ... leave alone, rename manually if needed`) leaves the second repo without any discoverable `envs/*.env` entry at all, requiring manual intervention every time it recurs.

DeepSeek-V4-Flash's load failure (`dflash requires ctx_other to be set`) is a separate, confirmed-unrelated issue: the architecture isn't merged into upstream `ggml-org/llama.cpp` yet. Out of scope here.

## Decisions (locked in)

1. **Canonical identity is fully-qualified.** `<org>/<repo>:<quant>` (llama-cpp) / `<org>/<repo>` (vllm) is the collision-proof source of truth — same precedent as OCI image refs and HF's own repo IDs. The short/pretty alias is a best-effort convenience layer on top: great when unique, never allowed to drop or misrepresent a model when it collides.
2. **No silent winners.** When a basename/repo-name is shared by 2+ sources, *every* member of that group gets a qualified name — not just the "loser." This keeps naming deterministic regardless of scan order and means a previously-stable plain name can never silently start pointing at a different physical file just because a new colliding sibling appeared later.
3. **Zero churn for the non-colliding majority.** Unique basenames/repo-names keep today's exact plain naming. Only genuine collision groups change behavior.
4. **Collisions are persisted, not transient.** Written into `config.ini` (llama-cpp) and surfaced in `make hf-cache` (both engines), not just printed once to whichever terminal ran `hf-sync`.
5. **Both engines, same run.** Per user decision, this ships for llama-cpp and vllm together rather than staging vllm into the later Makefile-unification track.

## Detailed design

### `llama-cpp/scripts/sync-router.sh`

Current collision handling (`seen_has` → skip, first-wins) is replaced:

1. Enumerate GGUFs via the existing `list_ggufs` (unchanged — it already correctly finds nonstandard layouts like `dspark/`).
2. Group by basename. For a group of size 1: symlink named exactly as today (`ln -sfn <container_path> $SYMLINK_FARM/<basename>`).
3. For a group of size 2+: **every** member gets `ln -sfn <container_path> $SYMLINK_FARM/<org>--<repo-slug>--<basename>`, where `repo-slug` is the repo portion of the HF id, lowercased, `/` and spaces replaced with `-`. No first-wins branch; no `seen_has` skip. *(Shipped as `<org>-<repo>--<basename>` — a single dash joining org and repo, double dash before the basename — since `repo_slug` already folds `org/repo` into one lowercased, `-`-joined token. Equivalent in effect; noted so this isn't mistaken for drift.)*
4. Section-name derivation (today's quant-stripping regex) runs against the *qualified* name for collision members, against the plain basename otherwise. Collision-derived section names are uglier but unique and traceable back to `org/repo` by inspection.
5. A `collisions` accumulator (parallel to today's `created`/`unchanged`/`orphaned` counters) records `<basename> → [repo1, repo2, ...]` for every group of size 2+.

### `llama-cpp/scripts/regen-config-ini.py`

Two changes:

1. **New `--collisions` input** (or a second stdin block, tab-separated `<basename>\t<repo-list>`) rendered as a `# COLLISIONS` comment block at the top of `config.ini`, regenerated every run — same visibility tier as the file's existing managed-fields header, not a side file nobody checks.
2. **Preserve hand-added sections.** Today, any section in `existing` not present in the computed `current` set is unconditionally archived to `config.ini.orphans` — including a section a human added by hand for a model that's still genuinely present under `/models/`. Fix: before archiving, check whether the section's existing `model=` value still resolves to a file under `/models/`; if so, keep it in `new_config` verbatim (still not "managed" — `hf-sync` won't rewrite its `model=` line unless that exact section name reappears in `current`). This lets a user manually assign a nicer alias to a collision-loser and have it survive re-syncs.

### `vllm/Makefile` (`hf-sync` target)

Same grouping principle, applied inline (matching the target's existing style — no new script file needed, this loop is already self-contained):

- Group cached repos by `cut -d/ -f2 | lower` (today's `short`).
- Group size 1: `envs/<short>.env` as today.
- Group size 2+: **every** member gets `envs/<org>-<short>.env` (org included, lowercased, `/`→`-`). No "leave alone" branch for the second arrival — every repo in a collision group gets a working env file every run.
- Collision list printed in the existing summary line and, new, appended as a comment block at the top of any `.env` file affected (cheap persistence without inventing a new side-channel for this smaller surface). *(Superseded — see note below.)*

### `make hf-cache` (both engines)

Annotate affected repo lines with `⚠ collision` (llama-cpp already annotates with `[router]`; this is an additional independent tag, both can appear on the same line).

## Verification plan

1. **Synthetic collision, llama-cpp.** Two dummy GGUF repos in a scratch HF cache sharing a basename; run `sync-router.sh`; confirm both get qualified symlinks, both appear in `config.ini` under distinct sections, `# COLLISIONS` block lists the pair.
2. **Synthetic collision, vllm.** Two dummy cached repos sharing a repo-name across orgs; run `hf-sync`; confirm both get `envs/<org>-<name>.env`.
3. **Regression, live inventory.** Run the fixed `sync-router.sh` against `spark-1822`'s actual HF cache (dry run against a copy, or a real run since it's declarative/idempotent); confirm all ~20 non-colliding entries keep byte-identical symlink names and section names to today.
4. **Confirmed-fix check.** `unsloth/Qwen3.6-27B-MTP-GGUF` gets a real `/models` symlink and a `config.ini` section post-fix (currently has neither).
5. **Idempotency.** Run `hf-sync` twice; zero diff on the second run for both symlinks and `config.ini` (matches the existing router-mode spec's verification bar).
6. **`regen-config-ini.py` hand-edit survival.** Manually add a section pointing at a currently-collision-affected `/models/*.gguf` path not in the auto-computed set; run `hf-sync`; confirm it's preserved, not archived.

## Risks

- **Qualified names are ugly.** Accepted trade-off — correctness over prettiness for the rare collision case; hand-editable via the now-preserved manual-section path.
- **`config.ini` growing a second managed block (`# COLLISIONS`) alongside the existing header.** Keep it mechanically simple (plain comment lines, no nested parsing) so it doesn't become a second source of truth `regen-config-ini.py` has to reconcile against.
- **vllm's per-`.env`-file comment block drifts from `config.ini`'s single-block approach.** Acceptable asymmetry — the two engines' underlying mechanisms (symlink farm vs. plain env files) are different enough that forcing identical collision-reporting shapes now would fight Track B's upcoming unification rather than help it. *(Superseded: the per-file comment block described above was never implemented. What shipped instead — discovered mid-implementation, not anticipated by this doc — is more capable: `hf-sync` reports collisions in its stdout summary as planned, but also automatically renames a stale plain-named `.env` file to its qualified form when a collision appears after it was already synced, restoring correctly from `.bak` even when the archived name no longer matches, with a guard against ever overwriting an unrelated file at the destination. See `vllm/README.md`'s "Model naming and collisions" section for the shipped behavior.)*

## Out of scope

- DeepSeek-V4-Flash's `dflash` load failure (unrelated, upstream).
- `LLAMACPP_TAG` currently running the floating `server-cuda` tag instead of a pinned digest (real drift, noted during investigation, but a separate fix).
- Makefile structural unification between llama-cpp and vllm (Track B).
- Ollama-blob and `llama-cpp-cache`-volume model surfacing (already out of scope per the router-mode design doc).

## Implementation order

1. `regen-config-ini.py`: hand-added-section preservation + `# COLLISIONS` block rendering (self-contained, testable in isolation with synthetic stdin).
2. `sync-router.sh`: replace first-wins skip with always-qualify-the-group logic; wire collision list into the new `regen-config-ini.py` input.
3. `vllm/Makefile`: apply the same grouping rule to `hf-sync`'s env-file naming loop.
4. `make hf-cache` (both): add `⚠ collision` annotation.
5. Run verification plan items 1–6 on a scratch/synthetic cache first, then against the real `spark-1822` inventory.
6. Update `llama-cpp/README.md` and `vllm/README.md` model-naming sections to document the qualified-name fallback and the new `# COLLISIONS` block.
