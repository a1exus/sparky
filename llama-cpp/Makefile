.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash
.SHELLFLAGS := -e -o pipefail -c
.SUFFIXES:
.DELETE_ON_ERROR:

ENV ?=
ENV := $(strip $(ENV))
SERVICE := llama-cpp
COMPOSE := docker compose -f docker-compose.yml
HF_CACHE ?= /opt/hf/.cache/huggingface
LLAMACPP_CACHE_VOL ?= llama-cpp-cache
.PHONY: help list up hf-cache hf-sync models

help:  ## Show this help.
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Usage:"
	@echo "  make list                       — show available env variants"
	@echo "  make up                         — start in router mode (all GGUFs available)"
	@echo "  make up ENV=<name>              — start in classic single-model mode"
	@echo
	@echo "GGUF-cache maintenance (llama-cpp-cache vol + HF cache):"
	@echo "  make hf-cache                   — list GGUF files in this host's caches"
	@echo "  make hf-sync                    — reconcile envs + router artifacts against the caches"
	@echo "  make models                     — show /v1/models from a running router-mode container"
	@echo
	@echo "For management, raw docker compose works once .env exists"
	@echo "(make up creates it on first run from .env.example):"
	@echo "  docker compose logs -f $(SERVICE)"
	@echo "  docker compose ps"
	@echo "  docker compose down"

list:  ## List available env variants under envs/.
	@ls envs/*.env 2>/dev/null | sed 's|envs/||; s|\.env$$||' | sort

up:  ## Start. With ENV=<name>: classic single-model mode. Without: router mode (all GGUFs available).
	@if [[ -n "$(ENV)" && ! -f "envs/$(ENV).env" ]]; then \
	    echo "variant not found: envs/$(ENV).env" >&2; \
	    echo "available:" >&2; $(MAKE) -s list | sed 's/^/  /' >&2; \
	    exit 1; \
	fi
	@if [[ ! -f .env ]]; then \
	    echo "→ first-time setup: copying .env.example → .env (placeholder values"; \
	    echo "  so raw \`docker compose ps/logs/down\` work without --env-file)"; \
	    cp .env.example .env; \
	fi
	@if [[ -z "$(ENV)" ]]; then \
	    echo "→ router mode (no ENV): all GGUFs in /models will be served on demand"; \
	    $(COMPOSE) --env-file .env up -d; \
	else \
	    echo "→ classic mode: loading $(ENV) at startup"; \
	    $(COMPOSE) --env-file .env --env-file "envs/$(ENV).env" up -d; \
	fi

hf-cache:  ## List cached models — GGUFs in llama-cpp-cache vol + every HF repo in HF cache (annotated by format + router visibility).
	@echo "# in docker volume $(LLAMACPP_CACHE_VOL) — usable by llama-cpp:"
	@docker run --rm -v $(LLAMACPP_CACHE_VOL):/d alpine sh -c 'ls /d/*.gguf 2>/dev/null' \
	    | sed 's|.*/||; s|^|  |' || true
	@echo
	@echo "# in $(HF_CACHE) — populated by \`hf download\` / vllm; usable by llama-cpp only when GGUF is present:"
	@farm="$${SYMLINK_FARM_HOST:-/opt/hf/.cache/llama-cpp-models}"; \
	shopt -s nullglob; \
	for d in $(HF_CACHE)/hub/models--*/; do \
	    repo=$$(basename "$$d" | sed 's|^models--||; s|--|/|'); \
	    gg=$$(find "$$d" -name "*.gguf" 2>/dev/null | wc -l); \
	    st=$$(find "$$d" -name "*.safetensors" 2>/dev/null | wc -l); \
	    router_flag=""; \
	    collision_flag=""; \
	    if [[ $$gg -gt 0 && -d "$$farm" ]]; then \
	        for fp in $$(find "$$d" -name "*.gguf" 2>/dev/null); do \
	            if [[ -L "$$farm/$$(basename "$$fp")" ]]; then router_flag=" [router]"; break; fi; \
	        done; \
	        if [[ -f "$$farm/config.ini" ]] && \
	           awk '/^# COLLISIONS/,0' "$$farm/config.ini" | grep '^#   ' | sed 's/^#   [^:]*: //' | tr ',' '\n' | grep -qFx "$$repo"; then \
	            collision_flag=" [⚠ collision]"; \
	        fi; \
	    fi; \
	    if [[ $$gg -gt 0 ]]; then \
	        printf "  %-60s [%d GGUF — llama-cpp can load]%s%s\n" "$$repo" "$$gg" "$$router_flag" "$$collision_flag"; \
	    else \
	        printf "  %-60s [%d safetensors — vllm only]\n" "$$repo" "$$st"; \
	    fi; \
	done

models:  ## Show /v1/models from the running container (router mode). Reads LLAMA_API_KEY from .env.
	@key=$$(grep -E '^LLAMA_API_KEY=' .env 2>/dev/null | head -1 | cut -d= -f2- || true); \
	if [[ -n "$$key" ]]; then \
	    auth_args=( -H "Authorization: Bearer $$key" ); \
	else \
	    auth_args=(); \
	fi; \
	curl -fsS "$${auth_args[@]}" http://127.0.0.1:8080/v1/models 2>/dev/null \
	    | jq . \
	    || { echo "could not reach http://127.0.0.1:8080/v1/models — is the container running and the key correct?" >&2; exit 1; }

hf-sync:  ## Reconcile envs against this host's GGUF inventory: create new, restore from .bak, orphan to .bak.
	@gguf_vol=$$(docker run --rm -v $(LLAMACPP_CACHE_VOL):/d alpine sh -c 'ls /d/*.gguf 2>/dev/null' 2>/dev/null | sed 's|.*/||' | sort -u || true); \
	gguf_hf=$$(find $(HF_CACHE) -name "*.gguf" 2>/dev/null | sort -u || true); \
	cd envs; \
	created=0; restored=0; orphaned=0; \
	for gguf in $$gguf_vol; do \
	    part=$$(echo "$$gguf" | sed -nE 's/.*-0*([0-9]+)-of-[0-9]+\.gguf$$/\1/p'); \
	    if [[ -n "$$part" && "$$part" != "1" ]]; then continue; fi; \
	    short=$$(echo "$$gguf" | sed -e 's/\.gguf$$//' -e 's/-MXFP4.*//' -e 's/-Q[0-9].*//' -e 's/-IQ[0-9].*//' | tr 'A-Z' 'a-z'); \
	    file="$$short-hf.env"; \
	    in_container="/root/.cache/llama.cpp/$$gguf"; \
	    if grep -lE "^MODEL_(PATH|URL)=.*$$gguf" *.env 2>/dev/null | head -1 >/dev/null; then \
	        :; \
	    elif [[ -f "$$file.bak" ]] && grep -qE "^MODEL_(PATH|URL)=.*$$gguf" "$$file.bak"; then \
	        printf '↩ restore %s ← %s.bak\n' "$$file" "$$file"; \
	        mv "$$file.bak" "$$file"; \
	        restored=$$((restored + 1)); \
	    elif [[ -f "$$file" ]]; then \
	        echo "  name clash: $$file already exists but points elsewhere — leave alone, rename manually if needed"; \
	    else \
	        printf '+ create  %s — MODEL_PATH=%s\n' "$$file" "$$in_container"; \
	        { \
	            echo "# $$gguf · in docker volume $(LLAMACPP_CACHE_VOL) on this host."; \
	            echo "# Layered on top of ../.env by \`make up ENV=$$short-hf\`."; \
	            echo "# Host-wide values (LLAMACPP_TAG, HF_CACHE_HOST, HF_TOKEN, defaults)"; \
	            echo "# live in ../.env."; \
	            echo ""; \
	            echo "MODEL_PATH=$$in_container"; \
	            echo "MODEL_ALIAS=$$short"; \
	            echo ""; \
	            echo "# Optional per-variant overrides — uncomment to use."; \
	            echo "# CTX_SIZE=32768"; \
	            echo "# N_GPU_LAYERS=999"; \
	        } > "$$file"; \
	        created=$$((created + 1)); \
	    fi; \
	done; \
	for fp in $$gguf_hf; do \
	    base=$$(basename "$$fp"); \
	    part=$$(echo "$$base" | sed -nE 's/.*-0*([0-9]+)-of-[0-9]+\.gguf$$/\1/p'); \
	    if [[ -n "$$part" && "$$part" != "1" ]]; then continue; fi; \
	    short=$$(echo "$$base" | sed -e 's/\.gguf$$//' -e 's/-MXFP4.*//' -e 's/-Q[0-9].*//' -e 's/-IQ[0-9].*//' | tr 'A-Z' 'a-z'); \
	    file="$$short-hfcache.env"; \
	    in_container=$$(echo "$$fp" | sed 's|^$(HF_CACHE)|/root/.cache/huggingface|'); \
	    if grep -lE "^MODEL_PATH=.*$$base" *.env 2>/dev/null | head -1 >/dev/null; then \
	        :; \
	    elif [[ -f "$$file.bak" ]] && grep -qE "^MODEL_PATH=.*$$base" "$$file.bak"; then \
	        printf '↩ restore %s ← %s.bak\n' "$$file" "$$file"; \
	        mv "$$file.bak" "$$file"; \
	        restored=$$((restored + 1)); \
	    elif [[ -f "$$file" ]]; then \
	        echo "  name clash: $$file already exists but points elsewhere"; \
	    else \
	        printf '+ create  %s — MODEL_PATH=%s\n' "$$file" "$$in_container"; \
	        { \
	            echo "# $$base · in $(HF_CACHE) on this host."; \
	            echo "# Layered on top of ../.env by \`make up ENV=$$short-hfcache\`."; \
	            echo "# Host-wide values live in ../.env."; \
	            echo ""; \
	            echo "MODEL_PATH=$$in_container"; \
	            echo "MODEL_ALIAS=$$short"; \
	            echo ""; \
	            echo "# Optional per-variant overrides — uncomment to use."; \
	            echo "# CTX_SIZE=32768"; \
	            echo "# N_GPU_LAYERS=999"; \
	        } > "$$file"; \
	        created=$$((created + 1)); \
	    fi; \
	done; \
	for f in *.env; do \
	    [[ -f "$$f" ]] || continue; \
	    p=$$(grep -E '^MODEL_PATH=' "$$f" | head -1 | cut -d= -f2- || true); \
	    [[ -z "$$p" ]] && continue; \
	    case "$$p" in \
	        /root/.cache/llama.cpp/*) \
	            name=$$(basename "$$p"); \
	            if ! grep -qFx "$$name" <<<"$$gguf_vol"; then \
	                printf '→ orphan  %s → %s.bak\n' "$$f" "$$f"; \
	                mv "$$f" "$$f.bak"; \
	                orphaned=$$((orphaned + 1)); \
	            fi;; \
	        /root/.cache/huggingface/*) \
	            host_path=$$(echo "$$p" | sed 's|^/root/.cache/huggingface|$(HF_CACHE)|'); \
	            if ! grep -qFx "$$host_path" <<<"$$gguf_hf"; then \
	                printf '→ orphan  %s → %s.bak\n' "$$f" "$$f"; \
	                mv "$$f" "$$f.bak"; \
	                orphaned=$$((orphaned + 1)); \
	            fi;; \
	    esac; \
	done; \
	echo "summary — $$created created, $$restored restored, $$orphaned orphaned"; \
	shopt -s nullglob; \
	st_only=0; \
	for d in $(HF_CACHE)/hub/models--*/; do \
	    gg=$$(find "$$d" -name "*.gguf" 2>/dev/null | wc -l); \
	    st=$$(find "$$d" -name "*.safetensors" 2>/dev/null | wc -l); \
	    if [[ $$gg -eq 0 && $$st -gt 0 ]]; then st_only=$$((st_only + 1)); fi; \
	done; \
	if [[ $$st_only -gt 0 ]]; then \
	    echo; \
	    echo "note: $$st_only HF repo(s) in $(HF_CACHE)/hub/ have only safetensors — not"; \
	    echo "      usable by llama.cpp directly (they're vllm-format). To make one of"; \
	    echo "      them work here, either pull a GGUF variant from HF (e.g."; \
	    echo "      \`hf download bartowski/<model>-GGUF\`) or convert locally with"; \
	    echo "      llama.cpp's convert_hf_to_gguf.py. \`make hf-cache\` shows which."; \
	fi
	@echo
	@echo "# router artifacts — symlink farm + config.ini"
	@HF_CACHE="$(HF_CACHE)" \
	    SYMLINK_FARM="$${SYMLINK_FARM_HOST:-/opt/hf/.cache/llama-cpp-models}" \
	    CTX_DEFAULT="$${CTX_SIZE:-8192}" \
	    NGL_DEFAULT="$${N_GPU_LAYERS:-999}" \
	    ./scripts/sync-router.sh
