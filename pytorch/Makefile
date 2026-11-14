.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash
.SHELLFLAGS := -e -o pipefail -c
.SUFFIXES:

SERVICE := pytorch
COMPOSE := docker compose -f docker-compose.yml
CMD ?=

# GPU-heavy stacks that can't share the GB10 with this one. `up` warns about
# them; it never stops them.
GPU_PEERS := vllm llama-cpp

# Not UID: bash treats that as read-only. Compose reads these for `user:`.
export PYTORCH_UID ?= $(shell id -u)
export PYTORCH_GID ?= $(shell id -g)

define CHECK_PY
import sys, torch
ok = torch.cuda.is_available()
print("torch:", torch.__version__)
print("cuda build:", torch.version.cuda)
print("cuda available:", ok)
if ok:
    print("device:", torch.cuda.get_device_name(0))
    print("capability: %d.%d" % torch.cuda.get_device_capability(0))
sys.exit(0 if ok else 1)
endef
export CHECK_PY

.PHONY: help up down shell run check logs _env _gpu-busy-warn _require-up _require-cmd

help:  ## Show this help.
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/{printf "  \033[36m%-8s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Usage:"
	@echo "  make up                         — start the container (creates .env on first run)"
	@echo "  make check                      — confirm torch sees the GPU"
	@echo "  make run CMD=\"python train.py\"  — run a command in /workspace"

up: _env _gpu-busy-warn  ## Start the dev container (creates .env, workspace/ and cache/ on first run).
	@set -a; . ./.env; set +a; mkdir -p "$${WORKSPACE:-workspace}" "$${CACHE_HOST:-cache}/home"
	$(COMPOSE) up -d

down:  ## Stop and remove the container (workspace/ and cache/ are kept).
	$(COMPOSE) down

shell: _require-up  ## Open a bash shell in the container.
	$(COMPOSE) exec $(SERVICE) bash

run: _require-cmd _require-up  ## Run CMD in the container: make run CMD="python train.py".
	$(COMPOSE) exec $(SERVICE) bash -lc "$$CMD"

check: _require-up  ## Print torch / CUDA info; fails if CUDA is unavailable.
	$(COMPOSE) exec -T $(SERVICE) python -c "$$CHECK_PY"

logs:  ## Follow the container logs.
	$(COMPOSE) logs -f $(SERVICE)

_env:
	@[[ -f .env ]] || { cp .env.example .env; echo "created .env from .env.example"; }
	@tag=$$(sed -n 's/^PYTORCH_TAG=//p' .env | tail -1); \
	[[ -n "$$tag" ]] || { \
	    echo "PYTORCH_TAG is empty in .env — set it to an NGC tag: https://catalog.ngc.nvidia.com/orgs/nvidia/containers/pytorch/tags" >&2; \
	    exit 1; }

_gpu-busy-warn:
	@for name in $(GPU_PEERS); do \
	    if [[ -n "$$(docker ps --filter "name=^$$name$$" --filter status=running -q)" ]]; then \
	        echo "warning: $$name is running and holds GPU memory; stop it (make down in its stack) if torch runs out of memory" >&2; \
	    fi; \
	done

_require-up:
	@[[ -n "$$(docker ps --filter "name=^$(SERVICE)$$" --filter status=running -q)" ]] || { \
	    echo "$(SERVICE) container is not running — run \`make up\` first" >&2; exit 1; }

_require-cmd:
	@[[ -n "$$CMD" ]] || { echo "usage: make run CMD=\"python train.py\"" >&2; exit 2; }
