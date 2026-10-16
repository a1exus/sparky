#!/usr/bin/env bash
# vllm-openai launcher. Mirrors llama-cpp/entrypoint.sh — keeps the
# server-shape decisions (tool-calling parser, etc.) in one readable
# place instead of a long YAML command list.

set -euo pipefail

# Fail fast on the placeholder sentinel. vllm/.env.example ships
# VLLM_MODEL=placeholder purely to satisfy the compose file's ${VAR:?}
# required-check so raw `docker compose ps/logs/down` work without an
# --env-file. It must never reach a real container: vLLM would try to pull
# the HF repo "placeholder", 404, and crash-loop behind an opaque traceback.
# That happens when the stack is started with raw `docker compose up` instead
# of `make up ENV=<name>` (which layers envs/<name>.env with the real model
# on top of .env).
if [[ "${VLLM_MODEL:-}" == "placeholder" ]]; then
    echo "refusing to start: VLLM_MODEL is still the 'placeholder' sentinel." >&2
    echo "raw \`docker compose up\` reads only .env, whose placeholder is never" >&2
    echo "overridden. start with a real model instead:" >&2
    echo "    make list             # show available variants" >&2
    echo "    make up ENV=<name>    # layers envs/<name>.env on top of .env" >&2
    exit 78   # EX_CONFIG (sysexits.h) — configuration error
fi

args=(
    --model                  "${VLLM_MODEL:?VLLM_MODEL must be set}"
    --served-model-name      "${VLLM_SERVED_NAME:-${VLLM_MODEL}}"
    --host                   "${LISTEN_HOST:-0.0.0.0}"
    --port                   "${LISTEN_PORT:-8000}"
    --gpu-memory-utilization "${VLLM_GPU_MEM:-0.9}"
)

# Context length: only passed when VLLM_MAX_LEN is set. Unset → vLLM
# derives it from the model's config.json (max_position_embeddings,
# max_target_positions, …), which is always valid for that model. A
# hard-coded default can't be: 32768 is fine for chat LLMs but vLLM
# refuses to start e.g. Whisper (448). Set it per variant to cap the
# KV-cache footprint of long-context models.
if [[ -n "${VLLM_MAX_LEN:-}" ]]; then
    args+=(--max-model-len "${VLLM_MAX_LEN}")
fi

# Tool-calling: VLLM_TOOL_PARSER names vLLM's --tool-call-parser.
# docker-compose.yml defaults it to `qwen3_xml`, which parses the XML
# tool-call format Qwen3.x emits: <tool_call><function=NAME>
# <parameter=PARAM>VAL</parameter></function></tool_call>. (The other
# Qwen parser, `qwen3_coder`, is for a different JSON-style format.)
# Set another parser per variant for other families, or set it empty
# (`VLLM_TOOL_PARSER=`) for models with no chat/tool API at all — e.g.
# speech-to-text like Whisper.
if [[ -n "${VLLM_TOOL_PARSER:-}" ]]; then
    args+=(--enable-auto-tool-choice --tool-call-parser "${VLLM_TOOL_PARSER}")
fi

# vLLM's env scanner warns on any unrecognized var with the VLLM_ prefix
# (which it owns). Our launcher reads VLLM_MODEL / VLLM_SERVED_NAME /
# VLLM_GPU_MEM / VLLM_MAX_LEN / VLLM_TOOL_PARSER purely to build the
# argv — drop them from the env before exec so vLLM's own scan stays quiet.
unset VLLM_MODEL VLLM_SERVED_NAME VLLM_GPU_MEM VLLM_MAX_LEN VLLM_TOOL_PARSER

echo "launching: vllm serve ${args[*]}"
exec vllm serve "${args[@]}"
