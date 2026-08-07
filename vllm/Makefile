.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash
.SHELLFLAGS := -e -o pipefail -c
.SUFFIXES:
.DELETE_ON_ERROR:

ENV ?=
ENV := $(strip $(ENV))
SERVICE := vllm
COMPOSE := docker compose -f docker-compose.yml
HF_CACHE ?= /opt/hf/.cache/huggingface

.PHONY: help list up hf-cache hf-sync

help:  ## Show this help.
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Usage:"
	@echo "  make list                       — show available env variants"
	@echo "  make up ENV=<name>              — start $(SERVICE) with that env"
	@echo
	@echo "HF-cache maintenance:"
	@echo "  make hf-cache                   — list HF repos already downloaded in $(HF_CACHE)"
	@echo "  make hf-sync                    — reconcile envs against the cache (create / restore / orphan to .bak)"
	@echo
	@echo "For management, raw docker compose works once .env exists"
	@echo "(make up creates it on first run from .env.example):"
	@echo "  docker compose logs -f $(SERVICE)"
	@echo "  docker compose ps"
	@echo "  docker compose down"

list:  ## List available env variants under envs/.
	@ls envs/*.env 2>/dev/null | sed 's|envs/||; s|\.env$$||' | sort

up:  ## Start with the given variant. Usage: make up ENV=<name>
	@if [[ -z "$(ENV)" ]]; then \
	    echo "usage: make up ENV=<name>" >&2; \
	    echo "available:" >&2; $(MAKE) -s list | sed 's/^/  /' >&2; \
	    exit 64; \
	fi
	@if [[ ! -f "envs/$(ENV).env" ]]; then \
	    echo "variant not found: envs/$(ENV).env" >&2; \
	    echo "available:" >&2; $(MAKE) -s list | sed 's/^/  /' >&2; \
	    exit 1; \
	fi
	@if [[ ! -f .env ]]; then \
	    echo "→ first-time setup: copying .env.example → .env (placeholder values"; \
	    echo "  so raw \`docker compose ps/logs/down\` work without --env-file)"; \
	    cp .env.example .env; \
	fi
	$(COMPOSE) --env-file .env --env-file "envs/$(ENV).env" up -d

hf-cache:  ## List HF repos already downloaded in this host's HF cache.
	@ls -d $(HF_CACHE)/hub/models--* 2>/dev/null \
	    | sed 's|.*/models--||; s|--|/|' | sort

hf-sync:  ## Reconcile envs against the HF cache: create new, restore from .bak, orphan to .bak.
	@cached=$$(ls -d $(HF_CACHE)/hub/models--* 2>/dev/null | sed 's|.*/models--||; s|--|/|'); \
	if [[ -z "$$cached" ]]; then echo "no models in $(HF_CACHE)/hub/"; exit 0; fi; \
	cd envs; \
	created=0; restored=0; renamed=0; orphaned=0; collisions=0; \
	dupes=$$(echo "$$cached" | while read -r r; do [[ -z "$$r" ]] && continue; echo "$$r" | cut -d/ -f2 | tr 'A-Z' 'a-z'; done | sort | uniq -d); \
	if [[ -n "$$dupes" ]]; then \
	    while read -r d; do \
	        [[ -z "$$d" ]] && continue; \
	        echo "  collision: $$d shared by multiple orgs — every repo gets an org-qualified name"; \
	        collisions=$$((collisions + 1)); \
	    done <<<"$$dupes"; \
	fi; \
	while read -r repo; do \
	    [[ -z "$$repo" ]] && continue; \
	    short=$$(echo "$$repo" | cut -d/ -f2 | tr 'A-Z' 'a-z'); \
	    if echo "$$dupes" | grep -qFx "$$short"; then \
	        org=$$(echo "$$repo" | cut -d/ -f1 | tr 'A-Z' 'a-z'); \
	        slug="$$org-$$short"; \
	    else \
	        slug="$$short"; \
	    fi; \
	    file="$$slug.env"; \
	    existing=$$(grep -lE "^VLLM_MODEL=$$repo[[:space:]]*\$$" *.env 2>/dev/null | head -1); \
	    if [[ -n "$$existing" && "$$existing" == "$$file" ]]; then \
	        :; \
	    elif [[ -n "$$existing" ]]; then \
	        if [[ -f "$$file" ]]; then \
	            echo "  rename blocked: $$file already exists — leaving $$existing as-is, resolve manually"; \
	        else \
	            printf '↺ rename  %s → %s (content already tracked; name now qualified)\n' "$$existing" "$$file"; \
	            mv "$$existing" "$$file"; \
	            sed -i.rntmp "s|^VLLM_SERVED_NAME=.*|VLLM_SERVED_NAME=$$slug|" "$$file"; rm -f "$$file.rntmp"; \
	            renamed=$$((renamed + 1)); \
	        fi; \
	    elif [[ -f "$$file.bak" ]] && grep -qE "^VLLM_MODEL=$$repo[[:space:]]*\$$" "$$file.bak"; then \
	        printf '↩ restore %s ← %s.bak\n' "$$file" "$$file"; \
	        mv "$$file.bak" "$$file"; \
	        restored=$$((restored + 1)); \
	    elif [[ -f "$$file" ]]; then \
	        echo "  name clash: $$file already exists but points elsewhere — leave alone, rename manually if needed"; \
	    else \
	        printf '+ create  %s — %s\n' "$$file" "$$repo"; \
	        { \
	            echo "# $$repo. Layered on top of ../.env by \`make up ENV=$$slug\`."; \
	            echo "# Host-wide values (VLLM_TAG, HF_CACHE_HOST, HF_TOKEN, defaults)"; \
	            echo "# live in ../.env."; \
	            echo ""; \
	            echo "VLLM_MODEL=$$repo"; \
	            echo "VLLM_SERVED_NAME=$$slug"; \
	            echo ""; \
	            echo "# Optional per-variant overrides — uncomment to use."; \
	            echo "# VLLM_GPU_MEM=0.9"; \
	            echo "# VLLM_MAX_LEN=32768"; \
	        } > "$$file"; \
	        created=$$((created + 1)); \
	    fi; \
	done <<<"$$cached"; \
	for f in *.env; do \
	    [[ -f "$$f" ]] || continue; \
	    repo=$$(grep -E '^VLLM_MODEL=' "$$f" | head -1 | cut -d= -f2-); \
	    [[ -z "$$repo" ]] && continue; \
	    if ! grep -qFx "$$repo" <<<"$$cached"; then \
	        printf '→ orphan  %s → %s.bak\n' "$$f" "$$f"; \
	        mv "$$f" "$$f.bak"; \
	        orphaned=$$((orphaned + 1)); \
	    fi; \
	done; \
	echo "summary — $$created created, $$restored restored, $$renamed renamed, $$orphaned orphaned, $$collisions collisions"
