#!/usr/bin/env python3
"""Ask vLLM what kind of model a repo is, so nothing here keeps a list.

    model_kind.py --model <repo-or-path>   →  chat | transcription | pooling

Run by entrypoint.sh when VLLM_TOOL_PARSER is unset. Tool calling only makes
sense for chat models: speech-to-text (Whisper, …) and pooling models
(embeddings, rerankers) have no tool-call API, and passing a parser to them
is wrong. vLLM's own model registry already knows which is which for every
architecture it supports — including ones added after this was written — so
the answer comes from the same vLLM that is about to serve the model.

stdout is the bare kind. Exit 1 when it cannot tell (config needs
trust_remote_code, vLLM too old for the registry helpers, …); the entrypoint
then keeps the chat default rather than guessing.
"""

from __future__ import annotations

import argparse
import logging
import sys
import warnings


def classify(is_transcription: bool, is_pooling: bool) -> str:
    # Transcription wins: Whisper-style models are also "generate" runners.
    if is_transcription:
        return "transcription"
    if is_pooling:
        return "pooling"
    return "chat"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--model", required=True)
    args = ap.parse_args()

    warnings.filterwarnings("ignore")
    logging.disable(logging.CRITICAL)  # vLLM's import-time INFO would hit stdout/stderr
    try:
        from vllm.config import ModelConfig
        from vllm.model_executor.models.registry import ModelRegistry

        cfg = ModelConfig(model=args.model)
        archs = cfg.architectures
        kind = classify(
            bool(ModelRegistry.is_transcription_model(archs, cfg)),
            bool(ModelRegistry.is_pooling_model(archs, cfg)),
        )
    except Exception as exc:
        print(f"model-kind: cannot classify {args.model} ({type(exc).__name__})", file=sys.stderr)
        return 1
    print(f"model-kind: {args.model} → {kind} (architectures: {', '.join(archs)})", file=sys.stderr)
    print(kind)
    return 0


if __name__ == "__main__":
    sys.exit(main())
