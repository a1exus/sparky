#!/usr/bin/env bash
# llama-server launcher. Two modes:
#
#   Router mode (DEFAULT when no MODEL_* env var is set):
#     Serves every GGUF under /models (symlink farm populated by `make sync`).
#     Per-model overrides live in /models/config.ini.
#
#   Classic single-model mode (one of these picks the model):
#     1. MODEL_PATH   — local file inside the container (any mounted dir).
#     2. MODEL_OLLAMA — Ollama model:tag — resolved against the mounted
#                       /ollama manifest store to the right blob path.
#     3. MODEL_URL    — remote URL (llama.cpp downloads + caches it).
#
# If LLAMA_API_KEY is non-empty (both modes): clients must send
#   Authorization: Bearer $LLAMA_API_KEY

set -euo pipefail

args=(
    --host "${LISTEN_HOST:-0.0.0.0}"
    --port "${LISTEN_PORT:-8080}"
)

# Resolve MODEL_OLLAMA → MODEL_PATH if set (and MODEL_PATH not already set).
if [[ -n "${MODEL_OLLAMA:-}" && -z "${MODEL_PATH:-}" ]]; then
    name="${MODEL_OLLAMA%:*}"
    tag="${MODEL_OLLAMA##*:}"
    manifest="/ollama/models/manifests/registry.ollama.ai/library/${name}/${tag}"
    if [[ ! -f "${manifest}" ]]; then
        echo "MODEL_OLLAMA=${MODEL_OLLAMA}: manifest not found at ${manifest}" >&2
        echo "available models:" >&2
        find /ollama/models/manifests/registry.ollama.ai/library -mindepth 2 -type f -printf '  %P\n' 2>/dev/null >&2 || true
        exit 1
    fi
    # Minified JSON; split records on '}' so each layer becomes its own
    # record. Pick the model-layer record (mediaType ends in image.model)
    # and pull its sha256 digest.
    digest=$(awk -v RS='}' '
        /application\/vnd\.ollama\.image\.model/ {
            if (match($0, /sha256:[a-f0-9]+/)) {
                print substr($0, RSTART, RLENGTH); exit
            }
        }' "${manifest}")
    if [[ -z "${digest}" ]]; then
        echo "MODEL_OLLAMA=${MODEL_OLLAMA}: no model layer in manifest" >&2
        exit 1
    fi
    MODEL_PATH="/ollama/models/blobs/${digest/:/-}"
    echo "resolved MODEL_OLLAMA=${MODEL_OLLAMA} → MODEL_PATH=${MODEL_PATH}"
fi

if [[ -n "${MODEL_PATH:-}" ]]; then
    # ---- Classic: explicit local file ----
    if [[ ! -e "${MODEL_PATH}" ]]; then
        echo "MODEL_PATH=${MODEL_PATH} does not exist inside the container" >&2
        echo "available roots:" >&2
        echo "  /ollama/models/blobs/             — Ollama-cached GGUF blobs (sha256-named)" >&2
        echo "  /root/.cache/huggingface/hub/     — HuggingFace Hub cache snapshots" >&2
        echo "  /root/.cache/llama.cpp/           — llama.cpp's own download cache" >&2
        echo "  /models/                          — router-mode symlink farm" >&2
        exit 1
    fi
    args+=(
        --model "${MODEL_PATH}"
        --ctx-size "${CTX_SIZE:-32768}"
        --n-gpu-layers "${N_GPU_LAYERS:-999}"
        --alias "${MODEL_ALIAS:-llama-cpp}"
    )
elif [[ -n "${MODEL_URL:-}" ]]; then
    # ---- Classic: URL download ----
    args+=(
        --model-url "${MODEL_URL}"
        --ctx-size "${CTX_SIZE:-32768}"
        --n-gpu-layers "${N_GPU_LAYERS:-999}"
        --alias "${MODEL_ALIAS:-llama-cpp}"
    )
else
    # ---- Router mode (new default) ----
    if [[ ! -d /models ]]; then
        echo "router mode: /models bind mount missing — check SYMLINK_FARM_HOST in .env" >&2
        exit 1
    fi
    gguf_count=$(find /models -maxdepth 1 -name '*.gguf' 2>/dev/null | wc -l)
    if [[ "${gguf_count}" -eq 0 ]]; then
        echo "router mode warning: /models has no *.gguf entries — run \`make sync\` on the host" >&2
    fi
    args+=(
        --models-dir /models
        --models-max "${MODELS_MAX:-2}"
    )
    if [[ -f /models/config.ini ]]; then
        args+=( --models-preset /models/config.ini )
    else
        echo "router mode warning: /models/config.ini missing — proceeding with built-in defaults" >&2
    fi
fi

# Auth (both modes). Treat blank as "no auth" so transition + local testing work.
if [[ -n "${LLAMA_API_KEY:-}" ]]; then
    args+=( --api-key "${LLAMA_API_KEY}" )
fi

echo "launching: llama-server ${args[*]}"
exec /app/llama-server "${args[@]}"
