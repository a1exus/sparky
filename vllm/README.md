# vllm

[vLLM](https://github.com/vllm-project/vllm) inference server. Serves an [OpenAI-compatible API](https://docs.vllm.ai/en/latest/serving/openai_compatible_server.html) at `https://vllm.spark-1822.local` (fronted by [`traefik/`](../traefik/); the router matches any `vllm.<domain>`, so the same backend also answers on `vllm.<tailnet>.ts.net` if the matching VIP service is set up — see [`tailscale/README.md`](../tailscale/README.md) — and on any Cloudflare Tunnel public hostname).

vLLM complements [`llama-cpp/`](../llama-cpp/): use llama.cpp for GGUF files (smaller, CPU-friendly quantizations), vLLM for HF-native models (safetensors) and high-throughput serving with continuous batching + PagedAttention.

Smoke-tested on GB10 (compute capability 12.1) with `Qwen/Qwen3.6-27B` at `--max-model-len 65536`: model loads on the GPU, the OpenAI-compatible API serves `/v1/chat/completions`, and tool-calling (`--tool-call-parser qwen3_xml`) returns a populated `tool_calls` structure for a single-function request. `gpt-oss-*` variants still fail at startup because the bundled `openai-harmony` in `vllm/vllm-openai:v0.20.2` fetches a vocab file from a URL that 404s upstream — unrelated to GB10 / sm_120.

## Supported model formats

- **HuggingFace transformers format.** vLLM loads `safetensors` (preferred) and PyTorch `.bin` directly by repo ID. All 4 models cached on this host (`openai/gpt-oss-120b`, `openai/gpt-oss-20b`, `Qwen/Qwen3.6-27B`, `Jackrong/Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled`) are this format.
- **Not supported as direct inputs:** GGUF (use [`llama-cpp/`](../llama-cpp/) for those), ONNX, custom TensorRT engines.
- **Quantization formats supported on Hopper/Blackwell-class GPUs:** AWQ, GPTQ, FP8, INT4, BitsAndBytes, and a few more. Full hardware/format compatibility chart: <https://docs.vllm.ai/en/latest/quantization/supported_hardware.html>.
- **Supported architectures** (model families like Llama, Qwen, Mistral, GPT-OSS, DeepSeek, Phi, Gemma, …) are listed here: <https://docs.vllm.ai/en/latest/models/supported_models.html>.

## Topology

Single container on the shared `traefik` Docker network (defined by the `traefik/` stack). Traefik reaches the container over that network for external traffic. The container also publishes its API on the host's loopback interface at `127.0.0.1:8000` for direct host-side curl/benchmarks — not reachable from the LAN. Set `HOST_PORT=<n>` in the variant file if 8000 is taken. The host's HuggingFace cache is bind-mounted read-write so vLLM and the `hf` CLI share the same downloads. Models come from HuggingFace by repo ID — vLLM loads safetensors directly.

### GPU exclusivity

`--gpu-memory-utilization 0.9` (default) reserves ~90% of VRAM at startup. The GB10 has 124 GiB total; Ollama and `llama-cpp/` also want VRAM, so vLLM can't coexist with either of them active. Hence `restart: "no"` here — manual-start.

The top-level `Makefile` (at `/opt/Makefile`) makes the switch a one-liner per engine — it stops only what you name, so nothing else is disturbed:

```bash
# Switching from ollama to vllm (run from /opt):
make down engine=ollama
make up   engine=vllm ENV=<name>

# Going back:
make down engine=vllm
make up   engine=ollama
```

Equivalent by hand:

```bash
docker compose -f /opt/open-webui/docker-compose.yml stop ollama
cd /opt/vllm && make up ENV=<name>
# back: docker compose -f /opt/vllm/docker-compose.yml down
#       docker compose -f /opt/open-webui/docker-compose.yml up -d
```

## Files

```
vllm/
├── docker-compose.yml
├── entrypoint.sh        # builds `vllm serve` argv from env; hosts the tool-call parser choice
├── Makefile             # make list / make up ENV=<name> / make hf-cache / make hf-sync
├── envs/                # one .env per model variant
│   ├── README.md
│   ├── gpt-oss-120b.env
│   ├── gpt-oss-20b.env
│   ├── qwen3.5-27b-reasoning.env
│   └── qwen3.6-27b.env
├── .env.example         # committed; copy to .env (`make up` auto-bootstraps)
└── .env                  # gitignored placeholder so raw `docker compose` works
```

## Configure

Two layers:

- **`.env`** (host-wide) — shared across every variant. `VLLM_TAG` (image pin), `HF_CACHE_HOST`, `HF_TOKEN`, default `VLLM_GPU_MEM` / `VLLM_MAX_LEN`. Bootstrapped from `.env.example` by `make up` on first run; gitignored thereafter.
- **`envs/<name>.env`** (per-variant) — just the model selection: `VLLM_MODEL`, `VLLM_SERVED_NAME`, and any per-variant overrides (e.g. `VLLM_MAX_LEN=65536` for one model). A few lines.

`make up ENV=<name>` chains both via `docker compose --env-file .env --env-file envs/<name>.env up -d` — variant wins where it specifies a value, falls back to `.env` otherwise. Edit `HF_TOKEN` once in `.env` and every variant picks it up; no token-duplication across variant files.

Raw `docker compose ps / logs / down` reads only `.env`, which is enough to satisfy compose's `${VAR:?...}` checks:

```bash
docker compose ps
docker compose logs -f vllm
docker compose down
```

The `VLLM_MODEL=placeholder` in `.env.example` is a sentinel — it exists only to satisfy those `${VAR:?}` checks and must never reach a running container. `make up` always overrides it with a real model from `envs/<name>.env`. As a backstop, `entrypoint.sh` refuses to start (exit `78`, `EX_CONFIG`) when it sees `VLLM_MODEL=placeholder`, so a stray `docker compose up` (which skips the variant `--env-file` and would otherwise pass the placeholder through) fails fast with an actionable message instead of crash-looping on a 404 for the phantom HF repo `placeholder`. Start with `make up ENV=<name>` instead.

## Deploy

Prereq: `traefik/` running on `:80`/`:443`. The shared `traefik` Docker network must exist (owned by `traefik/`).

```bash
make list                                # show available variants
make up ENV=qwen3.5-27b-reasoning        # start that one
docker logs -f vllm                      # tail (first run downloads the model)
```

Equivalent without Make:

```bash
docker compose --env-file envs/<variant>.env up -d
docker compose logs -f vllm              # first run: HF download
```

Once healthy:

```bash
curl -k https://vllm.spark-1822.local/v1/models
curl -k https://vllm.spark-1822.local/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"qwen3.5-27b-reasoning","messages":[{"role":"user","content":"hello"}]}'
```

## Adding a new variant

vLLM works best with HF transformers-format models (safetensors). It does **not** load GGUF files like llama.cpp does — for GGUF, use the [`llama-cpp/`](../llama-cpp/) stack.

To add a model, download it into the host's HF cache first (so the first `make up` doesn't hang on a long download):

```bash
hf download <org>/<repo>            # lands in /opt/hf/.cache/huggingface/
```

Then drop a new file at `envs/<name>.env`:

```
VLLM_MODEL=<org>/<repo>
VLLM_SERVED_NAME=<friendly-name>
VLLM_GPU_MEM=0.9
VLLM_MAX_LEN=8192
```

For larger models, use a quantized variant (e.g. `Qwen/Qwen2.5-72B-Instruct-AWQ`) — vLLM supports AWQ, GPTQ, FP8, BitsAndBytes, and a few others. See <https://docs.vllm.ai/en/latest/quantization/supported_hardware.html>.

## Reusing existing HF downloads

The bind-mount at `${HF_CACHE_HOST}` is the standard HuggingFace cache. Anything you've downloaded via `huggingface-cli` / `hf download` on the host is already there and vLLM will use it without re-downloading. The reverse is also true: models vLLM downloads land in that directory and are usable by the `hf` CLI or any other tool that reads `~/.cache/huggingface/`.

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

## Upgrade

Bump `VLLM_TAG` in the variant file (`envs/<name>.env`), then:

```bash
docker compose --env-file envs/<name>.env pull   # resolve image tag from the variant
make up ENV=<name>                                # restart on the new image
```

## Logs

```bash
docker compose logs -f vllm
```

## Uninstall

```bash
docker compose down
# HF cache is on the host (not in a Docker volume) — leave it alone unless you
# also want to delete downloaded weights.
```

## See also

- Top-level [README](../README.md)
- [`traefik/`](../traefik/) — reverse proxy in front of this server
- [`llama-cpp/`](../llama-cpp/) — sibling inference stack for GGUF models
- vLLM docs: <https://docs.vllm.ai/>
