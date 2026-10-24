.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash
.SHELLFLAGS := -e -o pipefail -c
.SUFFIXES:
.DELETE_ON_ERROR:

# VIP services are declared in serve.json (the `Services` block). containerboot
# applies serve.json on every start and auto-advertises each declared service,
# so there is no apply step — edit serve.json and `docker compose up -d`.
# Each service must already exist in the Tailscale admin console
# (https://login.tailscale.com/admin/services) with required ports tcp/80 + tcp/443.
CONTAINER ?= tailscale

.PHONY: help status

help:  ## Show this help.
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/{printf "  \033[36m%-20s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

status:  ## Show the live serve config and which services this node advertises.
	@docker exec $(CONTAINER) tailscale serve status --json
	@echo
	@echo "Advertised services:"
	@docker exec $(CONTAINER) tailscale debug prefs | grep -A10 '"AdvertiseServices"'
