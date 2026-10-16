> **Note:** `envs/` is for **classic single-model mode** only. Router mode (the default) discovers models from the HF cache via the symlink farm at `${SYMLINK_FARM_HOST}/`. See [../README.md → Router mode](../README.md#router-mode-default). The contents below are kept working during the router-mode trial; they'll be removed (moved to `.bak`) once router mode is verified.

---

# llama-cpp env variants

One **self-contained** file per model. `make up ENV=<name>` invokes `docker compose --env-file envs/<name>.env up -d` so the chosen variant's values reach the running container. Raw `docker compose ps / logs / down` afterwards reads the parent dir's `.env` (auto-bootstrapped by `make up` from `.env.example`) — placeholder values that satisfy compose's required-var checks but never reach a real container.

Each variant chooses **how to find the model**:

- `MODEL_PATH=<absolute path inside the container>` — point at any mounted file (e.g. `/root/.cache/huggingface/hub/.../<file>.gguf`, or an Ollama blob under `/ollama/models/blobs/`).
- `MODEL_OLLAMA=<name>:<tag>` — point at an Ollama-cached blob by name; resolved against the mounted `/ollama` manifest store at start (no hardcoded digests).
- `MODEL_URL=<https://…>` — remote download, cached in the `llama-cpp-cache` Docker volume thereafter.

Plus `MODEL_ALIAS`, `CTX_SIZE`, and `N_GPU_LAYERS` tuned per model.

## Current variants

| File | Source |
|---|---|
| `gpt-oss-safeguard-120b-hf.env` | `MODEL_URL` → `lmstudio-community/gpt-oss-safeguard-120b-GGUF` (already in `llama-cpp-cache`, ~59 GiB) |

## Picking a variant

```bash
# from /opt/llama-cpp:
make list                                       # variants + every cached model
make up ENV=gpt-oss-safeguard-120b-hf           # docker compose --env-file envs/<name>.env up -d
docker compose logs -f llama-cpp                # tail (reads .env placeholder, fine for logs)
docker compose down
```

## Maintenance

Maintenance lives in the parent `Makefile` (`../Makefile`). It is **read-only against the caches** and **never downloads** anything itself.

```bash
make list      # classic-mode variants, then every cached model (llama-cpp-cache
               #   volume + HF cache) flagged GGUF / vllm-only / [router] / ⚠ collision
make sync      # reconcile envs/ against the caches, then rebuild the router farm:
               #   + create envs for newly cached GGUFs (one per cache location)
               #   ↩ restore <name>.env from <name>.env.bak when a GGUF returns
               #   → move <name>.env to <name>.env.bak when its GGUF leaves
               #   + symlink farm + config.ini for router mode
```

The old names `make hf-cache` / `make hf-sync` still work but print a rename note; they'll be removed in a future release.

`make sync` only orphans envs whose `MODEL_PATH=` points at a GGUF file (it can check existence). `MODEL_URL=` and `MODEL_OLLAMA=` envs are not validated and are never orphaned automatically — leave them alone or remove them manually.

`*.env.bak` is gitignored — host-local artifact of the sync's orphaning path. A subsequent `make sync` will restore the file if the corresponding GGUF reappears in the cache, preserving any hand edits you'd made.

## See also

- [`../README.md`](../README.md) for the rest of the stack docs.
