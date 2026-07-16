.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash
.SHELLFLAGS := -e -o pipefail -c
.SUFFIXES:

# Top-level orchestration for the single-GB10 inference engines.
#
# Run from the directory that holds the stack subdirs: the repo root, or
# /opt on the host (where traefik/, vllm/, llama-cpp/, open-webui/, … are
# siblings). Override ROOT if they live elsewhere.
#
# GPU exclusivity: vLLM (--gpu-memory-utilization 0.9) and llama-cpp classic
# single-model mode (-ngl 999) claim VRAM eagerly at startup; ollama and
# llama-cpp router mode are lazy. The engine targets below bring one engine
# up after stopping the others, so the eager claimants never collide.
ROOT ?= .

# ollama lives in the open-webui compose project (shared with the UI, which
# depends_on it) — so it is (re)started via that project, not a dir of its own.
COMPOSE_OLLAMA := docker compose -f $(ROOT)/open-webui/docker-compose.yml

# Backend container names (== compose service names in this project).
INFER_ENGINES := vllm llama-cpp ollama
ALL_BACKENDS  := traefik cloudflare tailscale vllm llama-cpp ollama open-webui netdata

.PHONY: help status list vllm llama ollama stop-infer

help:  ## Show this help.
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Engines are GPU-exclusive — each target stops the others first:"
	@echo "  make vllm ENV=<name>    — start vLLM with that variant"
	@echo "  make llama [ENV=<name>] — start llama-cpp (empty ENV = router mode)"
	@echo "  make ollama             — start ollama"
	@echo "  make stop-infer         — stop every inference engine (free the GPU)"
	@echo "  make status             — health of every backend + GPU residency"
	@echo "  make list               — available model variants per engine"

status:  ## Show every backend's state/health and actual GPU residency.
	@echo "backends:"
	@for c in $(ALL_BACKENDS); do \
	    if state=$$(docker inspect -f '{{.State.Status}}' "$$c" 2>/dev/null); then \
	        health=$$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$$c" 2>/dev/null); \
	        printf '  %-12s %-9s %s\n' "$$c" "$$state" "$$health"; \
	    else \
	        printf '  %-12s %s\n' "$$c" "absent"; \
	    fi; \
	done
	@echo
	@echo "GPU residency (source of truth — ollama/router are lazy, so 'running' != 'on GPU'):"
	@if command -v nvidia-smi >/dev/null 2>&1; then \
	    apps=$$(nvidia-smi --query-compute-apps=pid,used_memory,process_name --format=csv,noheader 2>/dev/null); \
	    if [[ -n "$$apps" ]]; then echo "$$apps" | sed 's/^/  /'; else echo "  (no compute processes)"; fi; \
	else \
	    echo "  nvidia-smi unavailable"; \
	fi

list:  ## List available model variants for each engine.
	@echo "vllm:";      $(MAKE) -s -C $(ROOT)/vllm list      2>/dev/null | sed 's/^/  /' || echo "  (unavailable)"
	@echo "llama-cpp:"; $(MAKE) -s -C $(ROOT)/llama-cpp list 2>/dev/null | sed 's/^/  /' || echo "  (unavailable)"

vllm:  ## Start vLLM (stops llama-cpp + ollama first). Usage: make vllm ENV=<name>
	@$(MAKE) -s stop-infer
	$(MAKE) -C $(ROOT)/vllm up ENV=$(ENV)

llama:  ## Start llama-cpp (stops vLLM + ollama first). Usage: make llama [ENV=<name>]
	@$(MAKE) -s stop-infer
	$(MAKE) -C $(ROOT)/llama-cpp up ENV=$(ENV)

ollama:  ## Start ollama (stops vLLM + llama-cpp first).
	@$(MAKE) -s stop-infer
	@docker start ollama >/dev/null 2>&1 \
	    && echo "→ started ollama" \
	    || $(COMPOSE_OLLAMA) up -d ollama

stop-infer:  ## Stop every inference engine to free the GPU.
	@for c in $(INFER_ENGINES); do \
	    if [[ "$$(docker inspect -f '{{.State.Running}}' "$$c" 2>/dev/null)" == "true" ]]; then \
	        echo "→ stopping $$c"; docker stop "$$c" >/dev/null; \
	        if [[ "$$c" == "ollama" ]]; then \
	            echo "  note: ollama has restart:unless-stopped — a Docker daemon"; \
	            echo "        restart will bring it back and it may contend for the GPU."; \
	        fi; \
	    fi; \
	done
