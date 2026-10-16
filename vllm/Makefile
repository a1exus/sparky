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

# Lines .env.example used to ship as active defaults but no longer does.
# `make env-sync` (run by `make up` and `make hf-sync`) deletes exact
# matches from the host's .env — a value you customized doesn't match, so
# it's left alone. Hosts bootstrapped .env once from an older .env.example
# and `git pull` never touches it (gitignored), so without this a retired
# default keeps applying forever.
#   VLLM_MAX_LEN=32768 / 8192 — retired once vLLM derives the context
#   length from each model's config.json (a fixed host-wide value broke
#   e.g. Whisper, whose limit is 448).
RETIRED_DEFAULTS := VLLM_MAX_LEN=32768 VLLM_MAX_LEN=8192

# Model architectures (config.json "architectures") with no chat/tool API —
# `make hf-sync` writes VLLM_TOOL_PARSER= (tool-calling off) into their env
# files. Matched exactly; extend as new non-chat families are added.
NON_CHAT_ARCHS := WhisperForConditionalGeneration

.PHONY: help list up env-sync hf-cache hf-sync

help:  ## Show this help.
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Usage:"
	@echo "  make list                       — show available env variants"
	@echo "  make up ENV=<name>              — start $(SERVICE) with that env"
	@echo
	@echo "HF-cache maintenance:"
	@echo "  make hf-cache                   — list HF repos already downloaded in $(HF_CACHE)"
	@echo "  make hf-sync                    — reconcile envs against the cache (create / restore / update / orphan to .bak)"
	@echo "  make env-sync                   — drop retired defaults from .env (also run by up / hf-sync)"
	@echo
	@echo "For management, raw docker compose works once .env exists"
	@echo "(make up creates it on first run from .env.example):"
	@echo "  docker compose logs -f $(SERVICE)"
	@echo "  docker compose ps"
	@echo "  docker compose down"

list:  ## List available env variants under envs/.
	@ls envs/*.env 2>/dev/null | sed 's|envs/||; s|\.env$$||' | sort

up: env-sync  ## Start with the given variant. Usage: make up ENV=<name>
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

env-sync:  ## Drop retired shipped defaults from .env (backup: .env.bak).
	@if [[ ! -f .env ]]; then exit 0; fi; \
	retired=$$(printf '%s\n' $(RETIRED_DEFAULTS) | grep -Fx -f - .env || true); \
	if [[ -n "$$retired" ]]; then \
	    cp -p .env .env.bak; \
	    { printf '%s\n' $(RETIRED_DEFAULTS) | grep -vFx -f - .env.bak || true; } > .env; \
	    while read -r line; do \
	        printf -- '- env     .env: removed retired default %s (backup: .env.bak)\n' "$$line"; \
	    done <<<"$$retired"; \
	fi

hf-cache:  ## List HF repos already downloaded in this host's HF cache.
	@dupes=$$(ls -d $(HF_CACHE)/hub/models--* 2>/dev/null | sed 's|.*/models--||; s|--|/|' | while read -r r; do [[ -z "$$r" ]] && continue; echo "$$r" | cut -d/ -f2 | tr 'A-Z' 'a-z'; done | sort | uniq -d); \
	ls -d $(HF_CACHE)/hub/models--* 2>/dev/null \
	    | sed 's|.*/models--||; s|--|/|' | sort \
	    | while read -r repo; do \
	        short=$$(echo "$$repo" | cut -d/ -f2 | tr 'A-Z' 'a-z'); \
	        if echo "$$dupes" | grep -qFx "$$short"; then \
	            echo "$$repo  [⚠ collision]"; \
	        else \
	            echo "$$repo"; \
	        fi; \
	    done

hf-sync: env-sync  ## Reconcile envs against the HF cache: create new, restore from .bak, update, orphan to .bak.
	@hub="$(HF_CACHE)/hub"; \
	is_non_chat() { \
	    local repo="$$1" snap arch; \
	    for snap in "$$hub/models--$${repo/\//--}"/snapshots/*/; do \
	        [[ -f "$$snap/config.json" ]] || continue; \
	        for arch in $(NON_CHAT_ARCHS); do \
	            grep -qE "\"$$arch\"" "$$snap/config.json" && return 0; \
	        done; \
	    done; \
	    return 1; \
	}; \
	cached=$$(ls -d $(HF_CACHE)/hub/models--* 2>/dev/null | sed 's|.*/models--||; s|--|/|'); \
	if [[ -z "$$cached" ]]; then echo "no models in $(HF_CACHE)/hub/"; exit 0; fi; \
	cd envs; \
	created=0; restored=0; renamed=0; updated=0; orphaned=0; collisions=0; \
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
	    existing=$$(grep -lE "^VLLM_MODEL=$$repo[[:space:]]*\$$" *.env 2>/dev/null | head -1 || true); \
	    existing_bak=$$(grep -lE "^VLLM_MODEL=$$repo[[:space:]]*\$$" *.env.bak 2>/dev/null | head -1 || true); \
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
	    elif [[ -n "$$existing_bak" ]]; then \
	        if [[ -f "$$file" ]]; then \
	            echo "  restore blocked: $$file already exists — leaving $$existing_bak as-is, resolve manually"; \
	        else \
	            printf '↩ restore %s ← %s (was archived under a different name)\n' "$$file" "$$existing_bak"; \
	            mv "$$existing_bak" "$$file"; \
	            sed -i.rntmp "s|^VLLM_SERVED_NAME=.*|VLLM_SERVED_NAME=$$slug|" "$$file"; rm -f "$$file.rntmp"; \
	            restored=$$((restored + 1)); \
	        fi; \
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
	            echo "# Context length; unset → derived from the model's config.json."; \
	            echo "# VLLM_MAX_LEN=32768"; \
	            echo "# Tool-call parser; empty disables tool-calling (non-chat models)."; \
	            echo "# VLLM_TOOL_PARSER="; \
	        } > "$$file"; \
	        created=$$((created + 1)); \
	    fi; \
	    if [[ -f "$$file" ]] && grep -qE "^VLLM_MODEL=$$repo[[:space:]]*\$$" "$$file" \
	       && ! grep -qE '^VLLM_TOOL_PARSER=' "$$file" && is_non_chat "$$repo"; then \
	        { \
	            echo ""; \
	            echo "# Set by hf-sync: architecture is in NON_CHAT_ARCHS (no chat/tool"; \
	            echo "# API, e.g. speech-to-text) — tool-calling flags omitted."; \
	            echo "VLLM_TOOL_PARSER="; \
	        } >> "$$file"; \
	        printf '~ update  %s — non-chat model: VLLM_TOOL_PARSER= (tool-calling off)\n' "$$file"; \
	        updated=$$((updated + 1)); \
	    fi; \
	done <<<"$$cached"; \
	for f in *.env; do \
	    [[ -f "$$f" ]] || continue; \
	    repo=$$(grep -E '^VLLM_MODEL=' "$$f" | head -1 | cut -d= -f2- || true); \
	    [[ -z "$$repo" ]] && continue; \
	    if ! grep -qFx "$$repo" <<<"$$cached"; then \
	        printf '→ orphan  %s → %s.bak\n' "$$f" "$$f"; \
	        mv "$$f" "$$f.bak"; \
	        orphaned=$$((orphaned + 1)); \
	    fi; \
	done; \
	echo "summary — $$created created, $$restored restored, $$renamed renamed, $$updated updated, $$orphaned orphaned, $$collisions collisions"
