#!/usr/bin/env bash
# Can vLLM load this cached HF repo at all?
#
#   model-format.sh <hf-hub-dir> <org/repo>
#
# Exit 0, no output  → loadable by vLLM (or not cached yet, so unknown: let
#                      vLLM try and download it).
# Exit 1 + one line  → not loadable, with the reason and where it belongs.
#
# Purely structural — what files the checkpoint ships — so new models need no
# list to be maintained. vLLM serves Transformers checkpoints: a config.json
# naming the model (`architectures` / `model_type`) plus safetensors or
# PyTorch weights. Repos for other runtimes fail that test:
#   GGUF          *.gguf, no safetensors      → llama-cpp/
#   CTranslate2   model.bin + a config.json   → faster-whisper / speaches
#                 with no architectures/model_type
#   NeMo / other  a training-style config.json, same missing keys
# Whether a loadable model is chat, speech-to-text, … is not decided here;
# entrypoint.sh asks vLLM itself at container start.
#
# `make up ENV=<name> FORCE=1` bypasses the check (e.g. vLLM's experimental
# GGUF loading, or a repo this heuristic misjudges).
set -euo pipefail

hub="${1:?usage: model-format.sh <hf-hub-dir> <org/repo>}"
repo="${2:?usage: model-format.sh <hf-hub-dir> <org/repo>}"

snaps="$hub/models--${repo//\//--}/snapshots"
[[ -d "$snaps" ]] || exit 0

# Newest snapshot that has any content.
snap=""
while IFS= read -r d; do
    [[ -n "$(ls -A "$d" 2>/dev/null)" ]] && { snap="$d"; break; }
done < <(ls -1dt "$snaps"/*/ 2>/dev/null)
[[ -n "$snap" ]] || exit 0

has() { compgen -G "$snap/$1" >/dev/null; }
# -L: snapshot files are symlinks into blobs/.
has_gguf() { [[ -n "$(find -L "$snap" -name '*.gguf' -print -quit 2>/dev/null)" ]]; }

if ! has '*.safetensors' && ! has 'pytorch_model*.bin' && has_gguf; then
    echo "GGUF checkpoint — use llama-cpp/"
    exit 1
fi
if [[ ! -f "$snap/config.json" ]] || ! grep -qE '"(architectures|model_type)"' "$snap/config.json"; then
    echo "not a Transformers checkpoint (no model_type/architectures in config.json; e.g. CTranslate2 for faster-whisper/speaches, or a NeMo checkpoint)"
    exit 1
fi
if ! has '*.safetensors' && ! has 'pytorch_model*.bin'; then
    echo "no safetensors or pytorch_model*.bin weights"
    exit 1
fi
exit 0
