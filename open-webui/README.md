# open-webui

Self-hosted [Open WebUI](https://github.com/open-webui/open-webui) backed by [Ollama](https://github.com/ollama/ollama). Two-container stack — `ollama` (GPU) and `open-webui` (UI). Both share the single `traefik` Docker network; open-webui resolves `ollama` by name over it. External access goes through [Traefik](../traefik/).

Adapted from NVIDIA's official playbook: <https://build.nvidia.com/spark/open-webui/instructions>. Diverges in four ways: services are split (instead of the bundled `:ollama` image), images are version-pinned via `.env`, secrets live in `.env`, and the UI is fronted by Traefik on HTTPS instead of being published directly on `:8080`.

## Files

```
open-webui/
├── docker-compose.yml
├── .env.example         # committed
└── .env                 # gitignored
```

## Configure

```bash
cp .env.example .env
# Edit .env:
#   OLLAMA_TAG         — Ollama image tag (e.g. 0.23.2)
#   OPEN_WEBUI_TAG     — Open WebUI image tag (e.g. v0.9.5)
#   WEBUI_SECRET_KEY   — generate with: openssl rand -hex 32  (REQUIRED)
#   WEBUI_AUTH         — true (require login) or false (open)
#   ENABLE_SIGNUP      — true initially; flip to false after admin registers
#   OLLAMA_KEEP_ALIVE  — "30m" (default) / "5m" / "-1" (forever) / "0" (unload now)
#   OLLAMA_FLASH_ATTENTION — 1 (default; required for a quantized KV cache)
#   OLLAMA_KV_CACHE_TYPE   — f16 (default) / q8_0 / q4_0
#   OLLAMA_CONTEXT_LENGTH  — 131072 (default); the only knob for /v1 clients
#   OLLAMA_NO_CLOUD        — 1 (default; local-only) / 0 (allow :cloud models + web search)
#   OLLAMA_GPU_OVERHEAD    — 8589934592 (default; 8 GiB kept free for OS + other stacks)
```

### DGX Spark tuning

The GB10 GPU has no dedicated VRAM — it shares the host's 128 GB of unified memory with every other stack (`vllm/`, `llama-cpp/`, `speaches`). Left alone, Ollama sees "lots of VRAM" and defaults to a **256k** context with an **f16** KV cache: about 23 GB of KV for `gemma4:31b` before a single token is generated, plus up to 32 context checkpoints (~800 MB each). The compose defaults trade that down:

| Setting | Ollama default on Spark | Here | Effect |
|---|---|---|---|
| `OLLAMA_FLASH_ATTENTION` | auto | `1` | Pinned on; quantized KV requires it |
| `OLLAMA_KV_CACHE_TYPE` | `f16` | `f16` | Kept at full precision on purpose — see below |
| `OLLAMA_CONTEXT_LENGTH` | 262144 | `131072` | Half the KV allocation; still above the largest client prompts (~100k) |
| `OLLAMA_KEEP_ALIVE` | 5m | `30m` | Agent clients pause 5–30 min between turns; an unload discards the prompt cache and the next turn re-prefills the whole prompt (55k tokens took 70 s at ~660 tok/s) |
| `OLLAMA_GPU_OVERHEAD` | 0 | 8 GiB | Scheduler never plans to fill unified memory; headroom for the OS, `speaches`, `vllm`/`llama-cpp` |

The overhead matters more on the Spark than on a discrete GPU. NVIDIA [documents](https://docs.nvidia.com/dgx/dgx-spark/known-issues.html) that `cudaMemGetInfo` — what Ollama's scheduler sizes against — doesn't count reclaimable memory, so it's an estimate, and when unified memory does run out the GB10 tends to hang rather than return a clean CUDA OOM (this host logged `NV_ERR_NO_MEMORY` before an unplanned reboot on 2026-10-16). Raise the reserve if you run `vllm/` alongside Ollama.

Net: KV for `gemma4:31b` drops from ~23 GB to ~11 GB; for `qwen3.8:27b` (the main agent model) from ~17 GB to ~8.5 GB.

**Sizing the context.** Ollama's main clients are agent/API tools over the OpenAI-compatible `/v1/chat/completions` endpoint, which has no way to pass `num_ctx` — `OLLAMA_CONTEXT_LENGTH` *is* their window, and a prompt longer than it is truncated silently. Size it from real traffic before lowering it:

```bash
docker logs ollama 2>&1 | grep -o 'task.n_tokens = [0-9]*' | grep -o '[0-9]*$' | sort -n | tail -3   # largest prompts
docker logs ollama 2>&1 | grep -c 'truncated = [1-9]'                                               # truncations (want 0)
```

Keep `OLLAMA_NUM_PARALLEL` at its default of 1 for agent workloads: each extra slot multiplies KV memory, and a single slot keeps the client's conversation prefix cached between turns (follow-up turns re-evaluate only the new tokens).

**Why not quantize the KV cache?** `q8_0` would halve KV memory again, but it's global (every model gets it) and per the [Ollama FAQ](https://docs.ollama.com/faq) the quality hit depends on model and task — models with a high GQA ratio, like the Qwen family, feel it most. The main client workload is long-context agent traffic on `qwen3.8:27b` (GQA 6), where tool calls are the first thing to degrade, and the saving there is only ~4 GB on a 128 GB box. Switch to `OLLAMA_KV_CACHE_TYPE=q8_0` only if memory becomes the constraint (e.g. running `vllm/` alongside).

Verify after a restart:

```bash
docker exec ollama ollama ps                  # CONTEXT 131072, UNTIL ~30 min out
docker logs ollama 2>&1 | grep "KV buffer"    # KV size per loaded model
```

### Hardening

On top of `no-new-privileges`, the `ollama` service runs with:

| Setting | Why |
|---|---|
| `cap_drop: [ALL]` | Ollama needs no Linux capabilities: it binds an unprivileged port and writes only to its volume. GPU access comes from the nvidia runtime, not from capabilities. |
| `read_only: true` + `/tmp` tmpfs | Immutable root filesystem. Models and keys live in the `open-webui-ollama` volume. |
| `init: true` | An init (tini) as PID 1 reaps the per-model `llama-server` runners and forwards signals, so `docker stop` frees their unified memory. |
| `pids_limit: 2048` | Bounds runaway forks/threads. Measured peak is ~130. |
| `OLLAMA_NO_CLOUD=1` | Local-only: no Ollama cloud models or web search. Model pulls still work. |

All five were verified together on the GB10: model pull, load at 100% GPU and generation all work.

**Restarts cut in-flight requests.** Ollama exits within ~1 s on SIGTERM and doesn't finish the requests it's serving, so `stop_grace_period` wouldn't help. Restart or upgrade while no agent is mid-turn; `docker exec ollama ollama ps` shows what's loaded.

## Deploy

Prereqs:

- [Traefik](../traefik/) must be running — it owns `:80`/`:443` and the shared `traefik` Docker network that this stack joins as external.
- The two persistent volumes — `open-webui` (WebUI data) and `open-webui-ollama` (Ollama blob store) — must exist. They're declared `external: true` in the compose so `docker compose down -v` never destroys them. First-time deploy:

  ```bash
  docker volume create open-webui
  docker volume create open-webui-ollama
  ```

Then:

```bash
docker compose up -d
docker compose ps
```

Open WebUI is then reachable at `https://open-webui.spark-1822.local` (LAN; also at `https://open-webui.<tailnet>.ts.net` if the `svc:open-webui` VIP service is set up — see [`tailscale/README.md`](../tailscale/README.md) — or any Cloudflare Tunnel public hostname pointed at it). The first user to register becomes admin; after that, set `ENABLE_SIGNUP=false` in `.env` and re-run `docker compose up -d` to lock it down.

The Ollama API is also exposed directly via Traefik at `https://ollama.spark-1822.local` so other tools (Aider, Continue, LiteLLM, the `ollama` CLI with `OLLAMA_HOST`, …) can use it without going through the WebUI:

```bash
curl -k https://ollama.spark-1822.local/api/version
curl -k https://ollama.spark-1822.local/api/tags
OLLAMA_HOST=https://ollama.spark-1822.local ollama list
```

No auth: trusted-LAN posture, same rationale as Netdata. Note that the Ollama REST API includes destructive endpoints (delete model, pull arbitrary model); anyone on the LAN can use them.

## Pull models

```bash
docker compose exec ollama ollama pull llama3.2
docker compose exec ollama ollama list
```

Browse the [Ollama library](https://ollama.com/library) for more.

## Upgrade

Bump `OLLAMA_TAG` / `OPEN_WEBUI_TAG` in `.env` (or leave them on `latest`), then:

```bash
docker compose pull
docker compose up -d
```

This restarts `ollama`, which cuts any in-flight generation (see [Hardening](#hardening)), so run it while no agent is mid-turn.

Hosts whose `.env` predates the DGX Spark tuning still have `OLLAMA_KEEP_ALIVE=5m` (copied from the old `.env.example`). It overrides the compose default, so change it to `30m` or delete the line.

## Logs

```bash
docker compose logs -f open-webui
docker compose logs -f ollama
```

## Uninstall

```bash
docker compose down
docker volume rm open-webui open-webui-ollama   # destroys data and models
```

## See also

- Top-level [README](../README.md)
- [`traefik/`](../traefik/) — TLS-terminating reverse proxy in front of this UI
- Open WebUI docs: <https://docs.openwebui.com/>
- Ollama docs: <https://github.com/ollama/ollama/blob/main/docs/README.md>
