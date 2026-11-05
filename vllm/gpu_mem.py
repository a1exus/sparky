#!/usr/bin/env python3
"""Pick vLLM's --gpu-memory-utilization for one model.

vLLM treats the value as a cap on the share of *total* GPU memory this
instance may claim (weights + activations + CUDA graphs + a pre-allocated KV
cache) and refuses to start unless that much is currently free. A fixed
host-wide number is therefore wrong for most models: 0.9 (~109 GiB on a
128 GB Spark) blocks a 1.6 GB Whisper whenever anything else holds memory,
while a value sized for Whisper would starve a 120B model.

So size it per model:

    need = weights * SCALE + BASE            (GiB)
    util = ceil(need / total_gpu_memory, 2 decimals), clamped to [MIN, MAX]

  weights  bytes of the model's weight files (top-level *.safetensors, else
           *.bin) in the local HF cache; falls back to the Hub's file
           metadata when the model is not downloaded yet.
  SCALE    multiplier on the weights for activations, graph capture and a
           KV cache that grows with model size.      VLLM_GPU_MEM_SCALE
  BASE     fixed GiB for the CUDA context, runtime and a minimum KV cache.
                                                     VLLM_GPU_MEM_BASE_GIB
  total    torch.cuda.mem_get_info(), the same figure vLLM checks against.
           (`nvidia-smi` reports N/A on unified-memory GPUs such as GB10.)

Scope: one GPU per instance (the Spark's single GB10). With tensor
parallelism the weights are split across GPUs, so pin VLLM_GPU_MEM there.
--model may also be a local directory holding the weight files.

stdout is the value only (the entrypoint captures it); the reasoning goes to
stderr so it lands in `docker compose logs`. Exit 0 with a value, 1 when it
cannot size the model (the entrypoint then falls back to vLLM's own default).
"""

from __future__ import annotations

import argparse
import math
import os
import sys
from pathlib import Path

GIB = 1024**3
MIN_UTIL, MAX_UTIL = 0.05, 0.95
WEIGHT_GLOBS = ("*.safetensors", "*.bin")


def positive_float(text: str) -> float:
    try:
        value = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{text!r} is not a number") from None
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError(f"{text!r} must be a positive number")
    return value


def non_negative_float(text: str) -> float:
    return 0.0 if text.strip() == "0" else positive_float(text)


def log(msg: str) -> None:
    print(f"gpu-mem: {msg}", file=sys.stderr)


def _weight_files(names_sizes: dict[str, int]) -> int:
    """Total bytes of the weight files among {top-level filename: size}."""
    for pattern in WEIGHT_GLOBS:
        suffix = pattern[1:]
        files = {n: s for n, s in names_sizes.items() if n.endswith(suffix)}
        # Some repos ship a consolidated copy next to the sharded one;
        # loading reads one, so counting both would double the estimate.
        if len(files) > 1:
            files = {n: s for n, s in files.items() if not n.startswith("consolidated")}
        if files:
            return sum(files.values())
    return 0


def dir_weight_bytes(path: Path) -> int:
    """Weight bytes of the top-level files in one model directory."""
    # is_file() follows the blob symlink; dangling links are skipped.
    return _weight_files({f.name: f.stat().st_size for f in path.iterdir() if f.is_file()})


def cached_weight_bytes(repo: str, hf_home: Path) -> int:
    """Weight bytes in the newest local snapshot, 0 when not cached."""
    snaps = hf_home / "hub" / f"models--{repo.replace('/', '--')}" / "snapshots"
    if not snaps.is_dir():
        return 0
    for snap in sorted(snaps.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True):
        # Top level only: repos such as gpt-oss ship original/ and metal/
        # copies of the same weights in subdirectories.
        total = dir_weight_bytes(snap)
        if total:
            return total
    return 0


def hub_weight_bytes(repo: str) -> int:
    """Weight bytes according to the Hub, 0 when unreachable/unknown."""
    try:
        from huggingface_hub import HfApi

        info = HfApi().model_info(repo, files_metadata=True)
    except Exception as exc:  # offline, gated, renamed, library missing …
        log(f"could not read {repo} metadata from the Hub ({type(exc).__name__})")
        return 0
    sizes = {
        s.rfilename: s.size
        for s in (info.siblings or [])
        if "/" not in s.rfilename and s.size
    }
    return _weight_files(sizes)


def plan(weights_gib: float, total_gib: float, scale: float, base_gib: float) -> tuple[float, float]:
    """Return (utilization, need_gib)."""
    need = weights_gib * scale + base_gib
    util = math.ceil(need / total_gib * 100) / 100
    return min(max(util, MIN_UTIL), MAX_UTIL), need


def gpu_memory_gib() -> tuple[float, float]:
    """(total, free) GiB as vLLM sees them."""
    import torch

    free, total = torch.cuda.mem_get_info()
    return total / GIB, free / GIB


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--model", required=True, help="HF repo id, e.g. openai/whisper-large-v3-turbo")
    ap.add_argument("--hf-home", default=os.environ.get("HF_HOME", "/root/.cache/huggingface"))
    # Unset or empty env var → built-in default (compose passes "" when unset).
    ap.add_argument("--scale", type=non_negative_float, default=os.environ.get("VLLM_GPU_MEM_SCALE") or "1.25")
    ap.add_argument("--base-gib", type=non_negative_float, default=os.environ.get("VLLM_GPU_MEM_BASE_GIB") or "8")
    # Test hooks: skip torch and use these figures instead.
    ap.add_argument("--total-gib", type=positive_float)
    ap.add_argument("--free-gib", type=non_negative_float)
    args = ap.parse_args()

    if Path(args.model).is_dir():
        weights, source = dir_weight_bytes(Path(args.model)), "local directory"
    else:
        weights, source = cached_weight_bytes(args.model, Path(args.hf_home)), "local HF cache"
    if not weights and not Path(args.model).is_dir():
        weights = hub_weight_bytes(args.model)
        source = "Hub metadata (not downloaded yet)"
    if not weights:
        log(f"cannot determine the size of {args.model}")
        return 1

    if args.total_gib is not None:
        total, free = args.total_gib, args.free_gib if args.free_gib is not None else args.total_gib
    else:
        try:
            total, free = gpu_memory_gib()
        except Exception as exc:
            log(f"cannot read GPU memory ({type(exc).__name__}: {exc})")
            return 1

    util, need = plan(weights / GIB, total, args.scale, args.base_gib)
    log(
        f"{args.model}: weights {weights / GIB:.1f} GiB ({source}) x {args.scale:g} + "
        f"{args.base_gib:g} GiB = {need:.1f} GiB of {total:.1f} GiB -> {util:.2f}"
    )
    if util * total > free:
        log(
            f"warning: {util * total:.1f} GiB requested but only {free:.1f} GiB is free; "
            "vLLM will refuse to start. Stop what else holds GPU memory "
            "(ollama stop <model>, other containers) or set VLLM_GPU_MEM."
        )
    print(f"{util:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
