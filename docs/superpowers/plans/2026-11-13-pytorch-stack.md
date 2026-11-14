# PyTorch Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `pytorch/` compose stack: an on-demand NGC PyTorch dev container on the GB10, driven by `make` targets.

**Architecture:** One compose service (`pytorch`) running `sleep infinity` as the host user, with the GPU reserved, no published ports, the HF cache shared with the host and a writable cache dir. A Makefile wraps `docker compose` (`up`, `down`, `shell`, `run`, `check`, `logs`). Shell tests (the repo's idiom: `vllm/test-*.sh`) assert on `docker compose config` output and `make -n` dry runs, so they run on a laptop with no GPU.

**Tech Stack:** Docker Compose v2, GNU Make, bash, NVIDIA NGC `nvcr.io/nvidia/pytorch`.

**Spec:** `docs/superpowers/specs/2026-11-13-pytorch-stack-design.md`

## Global Constraints

- Image is `nvcr.io/nvidia/pytorch:${PYTORCH_TAG}`; tag required via `:?`, never `latest`.
- Service/container name `pytorch`; `restart: "no"`; `ipc: host`; `shm_size` default `16gb`; GPU reservation `driver: nvidia`, `count: all`, `capabilities: [gpu]`; `security_opt: [no-new-privileges:true]`; `init: true`; json-file logging `max-size: 10m`, `max-file: 3`.
- No `ports:`, no Traefik labels, no `traefik` network.
- Runs as the host user (`PYTORCH_UID:PYTORCH_GID`), never root.
- HF cache default `/opt/hf/.cache/huggingface` (same as `vllm/`); `HF_TOKEN` only via `.env`.
- Not added to the top-level Makefile `ENGINES`.
- Never commit to `main`; never push unless asked. Commit subject: imperative, max 72 chars, ending with the `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` trailer.
- Deviation from the spec (a builder's call): the cache is a bind-mounted host dir `./cache` (gitignored, created by `make up` as the host user), not a named volume. A fresh named volume is root-owned, so the non-root user could not write to it. Update the spec's Mounts bullet to match in Task 3.

## Review Focus

1. `make up` on a host with no `.env` and no `PYTORCH_TAG`: fails loudly naming `PYTORCH_TAG`, not a bare compose error.
2. `make run` with no `CMD`: exits non-zero with a usage line, does not start a shell.
3. `make run CMD="python -c 'print(1 + 1)'"`: quotes and spaces reach the container intact.
4. `make shell` / `run` / `check` while the container is down: say "run `make up` first", not a raw docker error.
5. `make up` while `vllm` or `llama-cpp` is running: warns and still starts; never stops the other container.

---

### Task 1: Compose file and env template

**Files:**
- Create: `pytorch/docker-compose.yml`, `pytorch/.env.example`, `pytorch/test-compose.sh`
- Modify: `.gitignore` (add `pytorch/workspace/` and `pytorch/cache/`)

**Interfaces:**
- Produces: compose project `pytorch`, service `pytorch`; env vars `PYTORCH_TAG` (required), `PYTORCH_UID`, `PYTORCH_GID` (default `1000`), `HF_CACHE_HOST`, `HF_TOKEN`, `WORKSPACE`, `CACHE_HOST`, `SHM_SIZE`. Task 2 relies on exactly these names and on the container being named `pytorch`.

- [ ] **Step 0: Branch and commit the docs.** `git switch -c feat/pytorch-stack` (carries the uncommitted spec and plan), then commit both with message `docs(pytorch): add stack design and plan`.

- [ ] **Step 1: Write `pytorch/test-compose.sh`.** Executable bash, `set -euo pipefail`, runs from its own directory with `PYTORCH_TAG=test` and a temp `--env-file`, renders `docker compose config --format json` and checks with `jq`. Cases, each printing `ok`/`FAIL name` and exiting non-zero on any failure:
  - `tag_required`: with `PYTORCH_TAG` unset, `docker compose config` fails and stderr contains `PYTORCH_TAG`.
  - `image`: `.services.pytorch.image == "nvcr.io/nvidia/pytorch:test"`.
  - `hardening`: `.restart == "no"`, `.ipc == "host"`, `.init == true`, `.security_opt == ["no-new-privileges:true"]`, `.shm_size` is 16 GiB in bytes (17179869184).
  - `gpu`: `.deploy.resources.reservations.devices[0]` has `driver "nvidia"`, `count "all"`, capabilities `["gpu"]`.
  - `no_ingress`: `.ports` and `.labels` absent or empty, and `.networks` has no `traefik`.
  - `user`: with `PYTORCH_UID=1234 PYTORCH_GID=5678`, `.user == "1234:5678"`; with neither set it is `"1000:1000"`.
  - `mounts`: targets include `/workspace` and the HF cache mount, and `HF_HOME` env points at that HF mount target.

- [ ] **Step 2: Run it to see it fail.** `cd pytorch && ./test-compose.sh` → FAIL (no compose file).

- [ ] **Step 3: Write `pytorch/docker-compose.yml` and `pytorch/.env.example`.** Follow `vllm/docker-compose.yml` for structure and comment style. `command: ["sleep", "infinity"]`; `working_dir: /workspace`; `ulimits` memlock `-1` and stack `67108864` (NGC's documented flags); env `HOME`, `PIP_CACHE_DIR`, `TORCH_HOME`, `HF_HOME` pointing under the mounted dirs, `HF_TOKEN: ${HF_TOKEN:-}`. `.env.example` documents each variable in the style of `vllm/.env.example`, with `PYTORCH_TAG=` left empty and a comment linking the NGC catalog and telling the user to pick the newest tag that passes `make check`.

- [ ] **Step 4: Add the two `.gitignore` entries** under a short comment, following the file's existing style.

- [ ] **Step 5: Run the test.** `cd pytorch && ./test-compose.sh` → every case `ok`, exit 0.

- [ ] **Step 6: Commit** `feat(pytorch): add compose stack and env template`.

---

### Task 2: Makefile

**Files:**
- Create: `pytorch/Makefile`, `pytorch/test-make.sh`

**Interfaces:**
- Consumes: Task 1's service/container name `pytorch`, `.env.example`, and env var names.
- Produces: targets `help` (default), `up`, `down`, `shell`, `run` (`CMD=` required), `check`, `logs`. Internal `_require-up` (fails with "run `make up` first" unless the `pytorch` container is running), `_gpu-busy-warn`.

- [ ] **Step 1: Write `pytorch/test-make.sh`.** Bash, `set -euo pipefail`; builds a temp dir with copies of the Makefile, compose file and `.env.example`, and a stub `docker` first on `PATH` that logs its argv to a file and returns canned output (`ps` output controlled by an env var). Cases:
  - `up_creates_env_and_demands_tag`: no `.env`, `make up` creates `.env` from the example, then exits non-zero with output containing `PYTORCH_TAG`; the stub was never asked to `compose up`.
  - `up_creates_dirs`: with `PYTORCH_TAG=x` in `.env`, `make up` creates `workspace/` and `cache/` and calls `docker compose ... up -d`.
  - `up_warns_when_gpu_busy`: stub reports `vllm` running → output contains `vllm`, exit 0, and the stub log has no `stop` or `down`.
  - `run_requires_cmd`: `make run` exits non-zero with `usage: make run CMD=` and no `exec` in the stub log.
  - `run_passes_cmd_intact`: `make run CMD="python -c 'print(1 + 1)'"` → stub log shows `exec` with the command as a single `bash -lc` argument, unmodified.
  - `needs_up`: stub reports `pytorch` not running → `make shell`, `make run CMD=x` and `make check` each exit non-zero with `make up`.
  - `uid_gid_exported`: `make -n up` shows `PYTORCH_UID`/`PYTORCH_GID` set from `id -u`/`id -g`.

- [ ] **Step 2: Run it to see it fail.** `cd pytorch && ./test-make.sh` → FAIL (no Makefile).

- [ ] **Step 3: Write `pytorch/Makefile`.** Same header idiom as `vllm/Makefile` (`SHELL`, `.SHELLFLAGS`, `.DEFAULT_GOAL := help`, `.PHONY`, awk `## ` help). Export `PYTORCH_UID ?= $(shell id -u)` and `PYTORCH_GID ?= $(shell id -g)` (not `UID`, which bash treats as read-only). `up`: create `.env` from `.env.example` if missing, fail with a `PYTORCH_TAG` message if it is empty, `mkdir -p workspace cache`, run `_gpu-busy-warn` (checks `docker ps --filter name=^vllm$ --filter name=^llama-cpp$ -q`; warn only), then `docker compose up -d`. `shell`: `docker compose exec pytorch bash`. `run`: `docker compose exec pytorch bash -lc "$(CMD)"`. `check`: `exec -T` a `python -c` that prints torch version, `torch.version.cuda`, `torch.cuda.is_available()`, device name and capability, and exits 1 if CUDA is unavailable. `down`, `logs` as plain wrappers. Use the container name `pytorch` from Task 1; confirm the `llama-cpp` container name against `llama-cpp/docker-compose.yml`.

- [ ] **Step 4: Run the tests.** `cd pytorch && ./test-make.sh && ./test-compose.sh` → all `ok`, exit 0.

- [ ] **Step 5: Commit** `feat(pytorch): add Makefile with up, shell, run and check`.

---

### Task 3: Docs and GB10 verification

**Files:**
- Create: `pytorch/README.md`
- Modify: root `README.md` (Layout block and Components table), `CHANGELOG.md` (`[Unreleased]` → `### Added`), `docs/superpowers/specs/2026-11-13-pytorch-stack-design.md` (Mounts bullet: bind-mounted `./cache`, status → implemented)

**Interfaces:**
- Consumes: Tasks 1–2's variable and target names, verbatim.

- [ ] **Step 1: Write `pytorch/README.md`** in the style of `vllm/README.md`: what it is, first-time setup (`cp .env.example .env`, set `PYTORCH_TAG`, `make up`, `make check`), the target table, mounts, the GPU-exclusivity note (stop `vllm` / `llama-cpp` first; `make up` warns), the root-owned-HF-cache note (readable, but downloads made by vLLM's root container can't be modified), and how to add packages (`pip install` lands in `cache/`).

- [ ] **Step 2: Update root `README.md`** (add `pytorch/` to the Layout tree and a Components row with URL `none (no ingress)`) and add a `CHANGELOG.md` entry under `### Added`.

- [ ] **Step 3: Update the spec** Mounts bullet and set its status to implemented.

- [ ] **Step 4: Verify on spark-1822 (manual, the real acceptance test).** On the host: pick the newest NGC tag from the catalog, set it in `pytorch/.env`, `docker compose pull`, `make up`, `make check`. Expected: exit 0 with `cuda available: True` and a GB10 device name. If the tag fails on the GB10, try the next newest. Record the passing tag in `.env.example`'s comment and the README. If no tag works, stop and report the exact error to the user instead of guessing.

- [ ] **Step 5: Run all tests** (`cd pytorch && ./test-compose.sh && ./test-make.sh`) → exit 0.

- [ ] **Step 6: Commit** `docs(pytorch): document the stack and record the verified tag`, then open a PR from `feat/pytorch-stack` (do not push without being asked).
