# vllm env variants

One **self-contained** file per model. `make up ENV=<name>` invokes `docker compose --env-file envs/<name>.env up -d` so the chosen variant's values reach the running container. Raw `docker compose ps / logs / down` afterwards reads the parent dir's `.env` (auto-bootstrapped by `make up` from `.env.example`) — placeholder values that satisfy compose's required-var checks but never reach a real container.

Each variant here corresponds to a model **already downloaded** on this host (under `/opt/hf/.cache/huggingface/`). Adding a new variant means first `hf download <repo>` (or letting vLLM pull on first start), then dropping a new `<name>.env` here — or run `make hf-sync` from the parent dir to do it automatically based on what's in the HF cache.

## Current variants

| File | HF repo |
|---|---|
| `gpt-oss-120b.env` | `openai/gpt-oss-120b` |
| `gpt-oss-20b.env` | `openai/gpt-oss-20b` |
| `qwen3.5-27b-reasoning.env` | `Jackrong/Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled` |
| `qwen3.6-27b.env` | `Qwen/Qwen3.6-27B` |

## What each file sets

- `VLLM_MODEL` — HuggingFace repo ID (vLLM resolves via the standard HF Hub cache).
- `VLLM_SERVED_NAME` — name surfaced via the OpenAI-compatible API.
- `VLLM_GPU_MEM` — fraction of VRAM vLLM may use (0.0–1.0).
- `VLLM_MAX_LEN` — max context length (optional; unset → vLLM derives it from the model's `config.json`).
- `VLLM_TOOL_PARSER` — vLLM `--tool-call-parser` (optional; default `qwen3_xml`, empty disables tool-calling).

Gated models need `HF_TOKEN` — set it once in the parent `.env`; every variant inherits it.

## Picking a variant

```bash
# from /opt/vllm:
make list                                  # show available variants
make up ENV=qwen3.5-27b-reasoning          # docker compose --env-file envs/<name>.env up -d
docker compose logs -f vllm                # tail (reads .env placeholder, fine for logs)
docker compose down
```

## Maintenance

Maintenance lives in the parent `Makefile` (`../Makefile`). It is **read-only against the cache** and **never downloads** anything itself — use `hf download <repo>` to populate the cache, then `make hf-sync` to materialize an env file.

```bash
make hf-cache   # HF repos already downloaded in the host's HF cache
make hf-sync    # reconcile envs/ against the cache:
                #   + create envs for newly cached models
                #   ↩ restore <name>.env from <name>.env.bak when a model returns
                #   → move <name>.env to <name>.env.bak when the model leaves
```

`*.env.bak` is gitignored — host-local artifact of the sync's orphaning path. A subsequent `make hf-sync` will restore the file if the corresponding model reappears in the cache, preserving any hand edits you'd made.

## See also

- [`../README.md`](../README.md) for the rest of the stack docs.
