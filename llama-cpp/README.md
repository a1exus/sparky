# llama-cpp

[llama.cpp](https://github.com/ggml-org/llama.cpp) inference server, GPU-accelerated on the GB10 via CUDA. Serves an [OpenAI-compatible API](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) and a small web UI at `https://llama.spark-1822.local` (fronted by [`traefik/`](../traefik/); the router matches any `llama.<domain>`, so the same backend also answers on `llama.<tailnet>.ts.net` if the matching VIP service is set up — see [`tailscale/README.md`](../tailscale/README.md) — and on any Cloudflare Tunnel public hostname).

Set up as the workaround for Ollama not being able to pull `gpt-oss-safeguard:120b` (upstream issue: ollama/ollama#16121).

## Supported model formats

- **GGUF only.** The single input format llama.cpp's server can load directly. Single-file or multi-part split GGUF (the model in `envs/gpt-oss-safeguard-120b-hf.env` is a 2-file split — llama.cpp opens the first file and picks the second up by naming convention).
- **Not supported as direct inputs:** HuggingFace `safetensors`, PyTorch `.bin`, ONNX, ggml v1/v2 (legacy).
- **HF safetensors models can be converted to GGUF** with [`convert_hf_to_gguf.py`](https://github.com/ggml-org/llama.cpp/blob/master/convert_hf_to_gguf.py) shipped in the llama.cpp repo. The 4 safetensors models in this host's HF cache (`openai/gpt-oss-120b`, `openai/gpt-oss-20b`, `Qwen/Qwen3.6-27B`, `Jackrong/Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled`) are **not** loaded as-is — convert first, or pull a ready-made GGUF (look on HF for `<author>/<repo>-GGUF` published by `bartowski`, `lmstudio-community`, `unsloth`, etc.).
- **Quantization formats supported inside GGUF**: `Q2_K`–`Q8_0`, `F16`, `F32`, `IQ*`, OpenAI's `MXFP4`, and others. See <https://github.com/ggml-org/llama.cpp/blob/master/examples/quantize/README.md>.
- **Architecture support** is broad and tracked here: <https://github.com/ggml-org/llama.cpp#description> (search the README for the list of supported model families).

## Topology

`llama-cpp` runs as a single container on the shared `traefik` Docker network (defined by the `traefik/` stack). Traefik reaches the container over that network for external traffic. The container also publishes its port on the host's loopback at `127.0.0.1:8080` for direct host-side curl/benchmarks — not reachable from the LAN. Set `HOST_PORT=<n>` in the variant file if 8080 is taken.

`llama-server` serves **both** the OpenAI-compatible API (`/v1/...`, `/health`, `/props`, `/metrics`) and a built-in web UI (`/`) on the **same port** — there is no separate UI process or port. A single Traefik router (`HostRegexp(`llama.{x:.+}`)` → port 8080) covers both; clients hitting `https://llama.spark-1822.local/` get the UI, hitting `/v1/...` gets the API. When `LLAMA_API_KEY` is set, the same bearer protects both surfaces (the UI prompts for the key once and stores it in localStorage).

### GPU sharing

The GB10 has 124 GiB of VRAM. Three engines on this host want it; how they treat it differs:

| Engine | VRAM posture | Coexistence |
|---|---|---|
| **llama-cpp router mode** (default) | **lazy** — no model resident at start; loads on first request to that model ID, LRU evicts at `MODELS_MAX` | Coexists with anything else that's also lazy |
| **Ollama** | **lazy** — loads on chat request, unloads after `keep_alive` (5 min by default) | Coexists with router mode |
| **llama-cpp classic single-model mode** | **eager** — `-ngl 999` parks every layer at startup (~65 GiB for the default 120b) | Requires the rest of the GPU |
| **vLLM** | **eager** — `--gpu-memory-utilization 0.9` reserves ~90% of VRAM at start whether or not it's serving | Exclusive; can't coexist with anything else loading models |

Coexistence rule of thumb for two lazy engines: keep `MODELS_MAX × worst_case_resident_VRAM` + the other engine's typical resident set below the 124 GiB total. On a BF16-heavy inventory (every Qwen3.6/35B-A3B BF16 GGUF sits in the 55–70 GiB range) `MODELS_MAX=1` is the only setting that doesn't thrash — two such workers would OOM the GPU. Bump `MODELS_MAX` only after taking the big GGUFs out of the symlink farm.

Hence `restart: "no"` on llama-cpp's compose entry — manual start so you decide when it joins the pool. To force pure exclusivity (the safest mode if you're loading the 120b on both engines):

```bash
docker compose -f /opt/open-webui/docker-compose.yml stop ollama
cd /opt/llama-cpp && make up
```

Ollama has `restart: unless-stopped`, so a Docker daemon restart will bring it back. Use `docker compose ... stop` again or change its restart policy if you want hard exclusivity.

To swap back to Ollama-only:

```bash
docker compose -f /opt/llama-cpp/docker-compose.yml down
docker compose -f /opt/open-webui/docker-compose.yml up -d
```

Three model sources are wired into the container:

| In-container path | Source |
|---|---|
| `/root/.cache/llama.cpp/` | llama.cpp's own download cache (named volume `llama-cpp-cache`, filled via `MODEL_URL`) |
| `/ollama/models/blobs/sha256-<hex>` | Ollama-cached GGUF blobs (external volume `open-webui-ollama`, read-only) |
| `/root/.cache/huggingface/hub/...` | HuggingFace CLI cache on the host, bind-mounted read-only |

The entrypoint picks the model in this order: **`MODEL_PATH`** (any mounted file) → **`MODEL_OLLAMA`** (resolved against the `/ollama` manifest store at start, e.g. `gpt-oss-safeguard:20b`) → **`MODEL_URL`** (downloaded into the cache volume).

## Router mode (default)

When no `MODEL_*` env var is set, `llama-server` runs in **router mode**: it scans `/models` (a symlink farm populated by `make hf-sync`) and serves every GGUF it finds, loading on demand. Up to `MODELS_MAX` models stay resident in VRAM; LRU evicts the rest.

```bash
make up                       # router mode — all GGUFs available
make models                   # show /v1/models from the running container
curl -H "Authorization: Bearer $LLAMA_API_KEY" \
     https://llama.spark-1822.local/v1/models | jq .
```

A request specifies the model in the usual OpenAI-API way:

```bash
curl -k -H "Authorization: Bearer $LLAMA_API_KEY" \
     https://llama.spark-1822.local/v1/chat/completions \
     -H 'Content-Type: application/json' \
     -d '{"model":"gpt-oss-safeguard-120b","messages":[{"role":"user","content":"hi"}]}'
```

Each GGUF is reachable under **three IDs** that all point at the same file: the short alias from `config.ini` (`gpt-oss-safeguard-120b`), the bare filename without extension (`gpt-oss-safeguard-120b-MXFP4-00001-of-00002`), and an HF-style ID auto-derived by the router from the symlink target (`lmstudio-community/gpt-oss-safeguard-120b-GGUF:MXFP4`). All three work in the `model` field.

### Authentication

`LLAMA_API_KEY` in `.env` is required when the endpoint is reachable from anywhere other than `127.0.0.1`. Generate once at deploy:

```bash
echo "LLAMA_API_KEY=$(openssl rand -hex 32)" >> .env
```

Clients (OpenWebUI's `LITELLM_BASE_URL_API_KEY` or equivalent, curl scripts) must send `Authorization: Bearer $LLAMA_API_KEY`. If `LLAMA_API_KEY` is blank, the endpoint is open — useful for one-off local testing but **not** safe with the Cloudflare Tunnel path active.

### VRAM budget

The router has **no per-model VRAM accounting** — `MODELS_MAX` is a count, not a byte budget. Set it so the worst case fits:

```
MODELS_MAX × worst_case_resident_VRAM_GiB  ≤  device_VRAM_GiB − headroom
```

GB10 has 124 GiB; reserve ~8 GiB for headroom. On a BF16-heavy inventory keep `MODELS_MAX=1` — every Qwen3.6/35B-A3B BF16 sits in the 55–70 GiB range, so a second resident worker breaks the budget. The original `MODELS_MAX=2` only worked when the catalogue was a single big model (the 120b) plus everything else quantized small. With `MODELS_MAX=1`, switching models pays a full cold-load (~60–90s for 66 GiB BF16) each time — see the eviction-thrash quirk below for why hand-picking the model ID matters.

### Tuning per model

Per-model overrides live in `<symlink-farm>/config.ini`, regenerated by `make hf-sync` and **preserves your hand-edits** (only `model =` is rewritten on each sync). Edit a section to override:

```ini
[gpt-oss-safeguard-120b]
model = /models/gpt-oss-safeguard-120b-MXFP4-00001-of-00002.gguf
ctx-size = 8192            # default from .env; tune as needed
n-gpu-layers = 999
```

`hf-sync` does **not** emit an `alias =` line — the router auto-derives the HF-style ID from each symlink target, so explicitly setting one would collide with the auto-derived ID and crash startup. Hand-add `alias = …` only if you want an additional ID beyond the auto-derived one.

**Enabling MTP (Multi-Token Prediction)** for models that ship with an MTP draft head (e.g. `unsloth/Qwen3.6-35B-A3B-MTP-GGUF`): add three keys to the section. Each becomes a `--<key> <value>` flag on the worker:

```ini
[qwen3.6-35b-a3b]
model = /models/Qwen3.6-35B-A3B-BF16-00001-of-00002.gguf
ctx-size = 8192
n-gpu-layers = 999
spec-type = draft-mtp        # use the model's bundled MTP head as the draft
spec-draft-n-max = 2         # max speculative tokens per step
parallel = 1                 # MTP requires single-slot worker (-np 1)
```

Requires a llama.cpp build ≥ b9200 (MTP support landed upstream in commit `2555826`, PR #22673, 2026-05-16). Older `server-cuda` digests will fail to load the MTP GGUF with `missing tensor 'blk.<last>.ssm_conv1d.weight'`. Acceptance shows up in the logs as `draft acceptance = 1.000 (N accepted / N generated)` and a `draft-mtp` statistics line. The MTP flags only take effect on workers spawned from the matching `config.ini` section — auto-discovered HF-style aliases (`unsloth/...:BF16`) get no flags and silently fall back to non-speculative decoding.

### Symlink farm

`make hf-sync` builds `${SYMLINK_FARM_HOST}` (default `/opt/hf/.cache/llama-cpp-models/`) with one symlink per GGUF in the HF cache. Symlinks target **container-side absolute paths** (`/root/.cache/huggingface/hub/...`), so they only resolve **inside the container**:

```bash
ls -L /opt/hf/.cache/llama-cpp-models/    # symlinks appear "broken" on the host — this is expected
docker exec llama-cpp ls -L /models/      # resolves fine in the container
```

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

### Limitations

- **Safetensors-only HF repos are invisible.** The 4 such repos in this host's cache (`openai/gpt-oss-120b`, `openai/gpt-oss-20b`, `Qwen/Qwen3.6-27B`, `Jackrong/Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled`) are not loadable by llama.cpp. Pull a GGUF variant from HF (look for `<author>/<repo>-GGUF`) or convert with `convert_hf_to_gguf.py` to make them appear.
- **Ollama blobs not in the router.** Reachable only via classic mode (`MODEL_OLLAMA=<name>:<tag>`).
- **URL-downloaded GGUFs not in the router.** Reachable only via classic mode (`MODEL_URL=<url>`).
- **One `--models-dir` only.** The router can't combine the HF cache and other sources in one scan.

### Router quirks worth knowing

- **`/v1/models` is unauthenticated.** Only `/v1/chat/completions` (and the other expensive endpoints) require the bearer token. The model catalog is open by OpenAI-compat convention; mostly fine because the catalog itself doesn't trigger work, but worth knowing if you're auditing exposure.
- **Each part of a multi-part split GGUF appears as its own model ID.** For example, `Qwen3.6-27B-BF16-00001-of-00002` and `…-00002-of-00002` both show up in `/v1/models`. Only the first part is loadable; requesting the second is a footgun.
- **Loading the same physical GGUF under two IDs counts twice.** If a request uses the short alias and a subsequent request uses the auto-derived HF-style ID, the router treats them as two independent models and consumes VRAM for both — `MODELS_MAX=2` then effectively means "one model loaded". With `MODELS_MAX=1` (the right setting for BF16-heavy inventories — see "VRAM budget") the same misuse turns into **eviction thrash**: every flip between the short alias and the HF-style alias unloads one worker and cold-loads the other (~60–90s for 66 GiB BF16). Pick one ID per logical model in clients (favor the short config-section alias — that's the one MTP flags from `config.ini` attach to) and don't mix.
- **`gpt-oss-*` models need the harmony chat template** (not ChatML). With the default template, inference runs but the server returns `500 Failed to parse input` when extracting the response. Pull a non-gpt-oss model or wire up `--jinja` per llama.cpp's harmony docs.

## Files

```
llama-cpp/
├── docker-compose.yml
├── entrypoint.sh         # router branch + classic mode + --api-key passthrough
├── Makefile              # make up [ENV=…] / make hf-cache / make hf-sync / make models
├── scripts/
│   ├── regen-config-ini.py    # managed-fields config.ini regen
│   └── sync-router.sh         # builds symlink farm; invokes regen-config-ini.py
├── envs/                 # classic single-model mode only — see "Classic … (legacy)" below
│   ├── README.md
│   └── *.env             # auto-generated by `make hf-sync`
├── .env.example          # committed; copy to .env (`make up` auto-bootstraps)
└── .env                   # gitignored placeholder so raw `docker compose` works
```

Host-side, populated by `make hf-sync`:

```
${SYMLINK_FARM_HOST:-/opt/hf/.cache/llama-cpp-models}/
├── config.ini                                       # per-model overrides
├── config.ini.orphans                               # archive of removed GGUFs (restored if they return)
└── <model>.gguf → /root/.cache/huggingface/...      # symlinks
```

## Configure

Three layers in router mode (two in classic mode — the third doesn't apply):

- **`.env`** (host-wide) — shared across every variant. `LLAMACPP_TAG` (image pin), `HF_CACHE_HOST`, `HF_TOKEN`, `SYMLINK_FARM_HOST`, `MODELS_MAX`, `LLAMA_API_KEY`, default `MODEL_ALIAS` / `CTX_SIZE` / `N_GPU_LAYERS`. Bootstrapped from `.env.example` by `make up` on first run; gitignored thereafter.
- **`envs/<name>.env`** (per-variant, classic mode only) — just the model selection: `MODEL_PATH` (or `MODEL_OLLAMA` / `MODEL_URL`), `MODEL_ALIAS`, and any per-variant overrides.
- **`${SYMLINK_FARM_HOST}/config.ini`** (per-model, router mode only) — auto-generated by `make hf-sync`; hand-edits are preserved (only `model =` is managed by hf-sync).

`make up ENV=<name>` chains both via `docker compose --env-file .env --env-file envs/<name>.env up -d` — variant wins where it specifies a value, falls back to `.env` otherwise. Edit `HF_TOKEN` once in `.env` and every variant picks it up.

Raw `docker compose ps / logs / down` reads only `.env`:

```bash
docker compose ps
docker compose logs -f llama-cpp
docker compose down
```

### Pinning the image

Important quirk of `ggml-org/llama.cpp`'s registry: **only the floating `server-cuda` tag is multi-arch**. The per-build tags `server-cuda-b<NNNN>` exist but are **amd64-only single-arch** — pulling one on this aarch64 host will spit a `requested image's platform (linux/amd64) does not match the detected host platform (linux/arm64/v8)` warning and the container won't actually run.

The right pin shape is therefore the digest of the multi-arch `server-cuda` index — Docker picks the arm64 layer from inside it. Re-resolve when you want to bump:

```bash
TOK=$(curl -s 'https://ghcr.io/token?service=ghcr.io&scope=repository:ggml-org/llama.cpp:pull' | jq -r .token)
curl -sI -H "Authorization: Bearer $TOK" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    'https://ghcr.io/v2/ggml-org/llama.cpp/manifests/server-cuda' \
    | grep -i docker-content-digest
```

(The OCI accept is listed first — ghcr.io switched from Docker manifest list to OCI image index. Both are sent for compatibility with older registries.)

Set `LLAMACPP_TAG=server-cuda@<that-digest>` in `.env`. Browse builds at <https://github.com/ggml-org/llama.cpp/pkgs/container/llama.cpp> to see which upstream commit a given digest corresponds to.

Before committing the bump, sanity-check that the new image's binary actually runs. Some recent floating-tag rolls have shipped with broken `RPATH`/`RUNPATH` on the binary, leaving its sibling libraries unreachable at startup:

```bash
docker run --rm --gpus all ghcr.io/ggml-org/llama.cpp:server-cuda@<digest> --help | head -5
# Expect the help text. Failure mode:
#   /app/llama-server: error while loading shared libraries: libllama-common.so.0:
#   cannot open shared object file: No such file or directory
# If you see that, walk back to the previous known-good digest and file upstream.
```

## Deploy

Prereq: `traefik/` running on `:80`/`:443`. The shared `traefik` Docker network must exist (owned by `traefik/`).

Router mode (default):

```bash
make up                                    # no ENV → router; all GGUFs served on demand
docker logs -f llama-cpp                   # tail until "router server is listening"
```

Classic mode (one model at startup):

```bash
make list                                  # show available envs/<name>.env variants
make up ENV=gpt-oss-safeguard-120b-hf      # start that one
```

Once healthy, both the web UI and the OpenAI-compatible API are reachable on `https://llama.spark-1822.local` (same host, same port, different paths — see [Topology](#topology)). The bearer-token auth is enforced on `/v1/chat/completions`; `/v1/models` and the UI's root are open.

- **Web UI** — `/` in a browser. The UI prompts for `LLAMA_API_KEY` on first load and stashes it in localStorage; browser-side fetches then carry the bearer header automatically.
- **OpenAI-compatible API** — `/v1/models`, `/v1/chat/completions`, etc.:
  ```bash
  curl -k https://llama.spark-1822.local/v1/models | jq .
  curl -k -H "Authorization: Bearer $LLAMA_API_KEY" \
      https://llama.spark-1822.local/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{"model":"gpt-oss-safeguard-120b","messages":[{"role":"user","content":"hello"}]}'
  ```

## Classic single-model mode (legacy)

> Router mode (above) is the new default. This section documents the original workflow where one variant file picks exactly one model at start. Kept working during the trial; scheduled for removal once router mode is verified.

Switch to another variant with `make up ENV=<name>` (or `docker compose --env-file envs/<name>.env up -d`). The `llama-cpp-cache` volume preserves previously-downloaded URL-pulled models, so swapping back is fast.

### Adding a new variant from the HuggingFace CLI cache

The host's `/opt/hf/.cache/huggingface/` is mounted read-only at `/root/.cache/huggingface/`. Files downloaded via `huggingface-cli download <repo> <file>` or `hf download <repo> <file>` live at:

```
/root/.cache/huggingface/hub/models--<org>--<repo>/snapshots/<rev>/<file>
```

Create `envs/<name>.env`:

```
MODEL_PATH=/root/.cache/huggingface/hub/models--<org>--<repo>/snapshots/<rev>/<file>.gguf
MODEL_ALIAS=<friendly-name>
CTX_SIZE=8192
N_GPU_LAYERS=999
```

### Adding a new Ollama-backed variant

The mount + resolution stay wired up even though no variant file ships with one. `ollama pull <name>:<tag>` on the host puts the GGUF into the `open-webui-ollama` Docker volume; then drop:

```
MODEL_OLLAMA=<name>:<tag>
MODEL_ALIAS=<friendly-name>
CTX_SIZE=8192
N_GPU_LAYERS=999
```

into `envs/<name>-<tag>.env`. The entrypoint resolves the right blob path at start by reading the Ollama manifest at `/ollama/models/manifests/registry.ollama.ai/library/<name>/<tag>` — no hardcoded digests.

### Adding a URL-downloaded variant

Use `MODEL_URL=<https://…>` instead of `MODEL_PATH`. llama.cpp downloads the file into the `llama-cpp-cache` volume on first start and reuses it after.

## Upgrade

Re-resolve `server-cuda`'s manifest-list digest (snippet above), bump `LLAMACPP_TAG` in `.env`, then:

```bash
docker compose --env-file envs/<name>.env pull   # resolve image tag from the variant
make up ENV=<name>                                # restart on the new image
```

## Logs

```bash
docker compose logs -f llama-cpp
```

## Uninstall

```bash
docker compose down
docker volume rm llama-cpp-cache   # destroys cached model downloads
```

## See also

- Top-level [README](../README.md)
- [`traefik/`](../traefik/) — reverse proxy in front of this server
- llama.cpp server: <https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md>
- Compute capability 12.1 on GB10 is supported by the upstream image — confirmed with `ggml_cuda_init: found 1 CUDA devices`.
