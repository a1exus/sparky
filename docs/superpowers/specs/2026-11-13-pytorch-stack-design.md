# PyTorch stack — design

**Status:** implemented on `feat/pytorch-stack`; the GB10 tag check is pending (see the plan's Task 3, step 4).
**Date:** 2026-11-13.
**Services:** new `pytorch/`.

## Intent

A `pytorch/` stack for running PyTorch work (experiments, training, fine-tuning, one-off scripts) on the GB10, packaged like every other stack here: compose file, `.env.example`, `Makefile`, `README.md`. The requester asked for "best practices and industry standards" and left the specifics to the builder, so every choice below is a call, not something agreed in conversation.

## Goals

- Reproducible: image pinned by tag in `.env`, no `latest`.
- GPU works on the GB10 (aarch64, Blackwell) out of the box; `make check` proves it.
- Same conventions as `vllm/`: `restart: "no"`, `ipc: host`, `shm_size`, NVIDIA device reservation, `no-new-privileges`, capped json-file logs, shared HF cache mount.
- Safe defaults: non-root user, loopback-only or no ports, no secrets baked in.
- Wrapped in `make` targets so common commands are one-liners.

## Non-goals

- No JupyterLab / web UI, no Traefik route (nothing serves HTTP). Possible later addition.
- Not added to `ENGINES` in the top-level Makefile; it is not an inference engine.
- No custom image build or extra Python dependencies baked in; users `pip install` into the cache volume.
- No multi-node or distributed training setup.

## Anti-goals

- A stack that works only for the author's UID or paths.
- Silently competing for the GPU with vLLM / llama.cpp without saying so.

## Approaches considered

1. **Makefile `docker run` wrappers, no compose.** Lightest, but breaks the repo's one-compose-per-stack pattern and the request for compose.
2. **Compose dev container (chosen).** Long-lived on-demand container, `make shell` / `make run`.
3. **Compose plus JupyterLab behind Traefik.** Nicer for notebooks; adds auth and attack surface. Deferred.

## Design

```
pytorch/
├── docker-compose.yml   # service `pytorch`, command: sleep infinity
├── .env.example         # PYTORCH_TAG, HF_CACHE_HOST, WORKSPACE, SHM_SIZE, HF_TOKEN
├── Makefile             # up / down / shell / run / check / logs
└── README.md
```

- **Image:** `nvcr.io/nvidia/pytorch:${PYTORCH_TAG}` (NGC; built for Blackwell/aarch64). Tag required (`:?`) like `VLLM_TAG`.
- **Compose:** `container_name: pytorch`, `restart: "no"`, `ipc: host`, `shm_size`, GPU reservation `count: all`, `security_opt: no-new-privileges`, logging caps, `init: true` (reaps zombies), `command: ["sleep","infinity"]`. `ulimits` memlock/stack as NGC recommends.
- **User:** `user: "${UID}:${GID}"` so workspace files aren't root-owned; `HOME` points into a writable cache volume.
- **Mounts:** `${WORKSPACE:-./workspace}:/workspace` (code, checkpoints); `${HF_CACHE_HOST:-/opt/hf/.cache/huggingface}:/hf` with `HF_HOME=/hf`; a bind-mounted `./cache` at `/cache` for `HOME` and the pip / torch hub caches (a named volume would be root-owned, and the container runs non-root).
- **Network:** none published; no `traefik` network join.
- **Makefile:** `up`, `down`, `shell` (`exec -it bash`), `run CMD="python train.py"`, `check` (prints torch version, `torch.cuda.is_available()`, device name, capability), `logs`. `up` warns if another GPU-heavy container (`vllm`, `llama-cpp`) is running; it warns, never stops it.
- **Secrets:** `HF_TOKEN` via `.env` only, never printed or baked.
- **Docs:** `pytorch/README.md`, a row in the root README layout and components, a CHANGELOG entry.

## Open questions for the builder

- Which NGC tag to pin: must be verified to run on the GB10 (`make check` is the acceptance test). Prefer the newest tag that passes.
- Whether `UID`/`GID` need `id -u` defaults in the Makefile (`UID` is not exported by bash by default). Likely yes.
- Exact `shm_size` default (start at `16gb`, matching typical dataloader needs; `ipc: host` already covers most cases).

## Delivery

Branch `feat/pytorch-stack` off `origin/main`, PR for review. No push or merge without explicit ask.
