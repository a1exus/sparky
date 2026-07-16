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
    --max-model-len          "${VLLM_MAX_LEN:-32768}"
    # Tool-calling: `qwen3_xml` parses the XML tool-call format that
    # Qwen3.x emits: <tool_call><function=NAME><parameter=PARAM>VAL
    # </parameter></function></tool_call>. The other Qwen parser,
    # `qwen3_coder`, is for a different (JSON-style) format. For non-
    # Qwen families the parser is a no-op (chat completions still
    # work). Switch to per-variant control if we ever serve multiple
    # families with active tool calls at the same time.
    --enable-auto-tool-choice
    --tool-call-parser       qwen3_xml
)

# vLLM's env scanner warns on any unrecognized var with the VLLM_ prefix
# (which it owns). Our launcher reads VLLM_MODEL / VLLM_SERVED_NAME /
# VLLM_GPU_MEM / VLLM_MAX_LEN purely to build the argv — drop them from
# the env before exec so vLLM's own scan stays quiet.
unset VLLM_MODEL VLLM_SERVED_NAME VLLM_GPU_MEM VLLM_MAX_LEN

echo "launching: vllm serve ${args[*]}"
exec vllm serve "${args[@]}"
