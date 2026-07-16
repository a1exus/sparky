.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash
.SHELLFLAGS := -e -o pipefail -c
.SUFFIXES:

# Top-level control for the LLM services. Acts on ONE engine at a time —
# it never stops the others, so e.g. bringing vLLM up leaves ollama alone.
#
# Run from the directory that holds the stack subdirs: the repo root, or
# /opt on the host (where vllm/, llama-cpp/, open-webui/, … are siblings).
# Override ROOT if they live elsewhere.
#
# GPU note: vLLM (--gpu-memory-utilization 0.9) and llama-cpp classic mode
# (-ngl 999) claim VRAM eagerly, so they can't share the GB10 with another
# eager engine. ollama and llama-cpp router mode are lazy. Managing that
# trade-off is left to you — `make down engine=<other>` first when needed.
ROOT ?= .

# LLM services this Makefile knows about. ollama + open-webui live together
# in the open-webui compose project (the UI depends_on ollama).
ENGINES := vllm llama-cpp ollama open-webui

.PHONY: help status list up down

help:  ## Show this help.
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/{printf "  \033[36m%-10s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Engines: $(ENGINES)"
	@echo "  make up engine=vllm ENV=<variant>   — start one engine"
	@echo "  make up engine=llama-cpp            — llama-cpp, empty ENV = router mode"
	@echo "  make down engine=vllm               — stop just that engine"
	@echo "  make status                         — state/health of the LLM services + GPU"
	@echo "  make list                           — model variants for vllm / llama-cpp"

status:  ## Show each LLM service's state/health and actual GPU residency.
	@echo "services:"
	@for c in $(ENGINES); do \
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

list:  ## List available model variants for vllm and llama-cpp.
	@echo "vllm:";      $(MAKE) -s -C $(ROOT)/vllm list      2>/dev/null | sed 's/^/  /' || echo "  (unavailable)"
	@echo "llama-cpp:"; $(MAKE) -s -C $(ROOT)/llama-cpp list 2>/dev/null | sed 's/^/  /' || echo "  (unavailable)"

up:  ## Start one engine. Usage: make up engine=<name> [ENV=<variant>]
	@case "$(engine)" in \
	    vllm|llama-cpp) \
	        $(MAKE) -C "$(ROOT)/$(engine)" up ENV="$(ENV)" ;; \
	    ollama) \
	        ( cd "$(ROOT)/open-webui" && docker compose up -d ollama ) ;; \
	    open-webui) \
	        ( cd "$(ROOT)/open-webui" && docker compose up -d ) ;; \
	    "") \
	        echo "usage: make up engine=<name> [ENV=<variant>]" >&2; \
	        echo "engines: $(ENGINES)" >&2; exit 64 ;; \
	    *) \
	        echo "unknown engine: $(engine)" >&2; \
	        echo "engines: $(ENGINES)" >&2; exit 64 ;; \
	esac

down:  ## Stop one engine (leaves the others running). Usage: make down engine=<name>
	@case "$(engine)" in \
	    vllm|llama-cpp|ollama|open-webui) \
	        if [[ "$$(docker inspect -f '{{.State.Running}}' "$(engine)" 2>/dev/null)" == "true" ]]; then \
	            echo "→ stopping $(engine)"; docker stop "$(engine)" >/dev/null; \
	            if [[ "$(engine)" == "ollama" ]]; then \
	                echo "  note: ollama has restart:unless-stopped — a Docker daemon"; \
	                echo "        restart will bring it back and it may contend for the GPU."; \
	            fi; \
	        else \
	            echo "$(engine) is not running"; \
	        fi ;; \
	    "") \
	        echo "usage: make down engine=<name>" >&2; \
	        echo "engines: $(ENGINES)" >&2; exit 64 ;; \
	    *) \
	        echo "unknown engine: $(engine)" >&2; \
	        echo "engines: $(ENGINES)" >&2; exit 64 ;; \
	esac
