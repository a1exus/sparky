# pytorch

On-demand [NGC PyTorch](https://catalog.ngc.nvidia.com/orgs/nvidia/containers/pytorch) dev container for the GB10. It idles (`sleep infinity`) until you `make shell` or `make run` into it. It publishes no ports and has no Traefik route, because nothing in it serves HTTP.

- **NGC image, not Docker Hub.** The GB10 is aarch64 with compute capability 12.1; NVIDIA's build is the one made for it. `PYTORCH_TAG` is required and has no default.
- **Runs as you, not root.** `PYTORCH_UID` / `PYTORCH_GID` come from `id -u` / `id -g`, so files in `workspace/` are yours.
- **GPU is exclusive in practice.** vLLM and llama.cpp claim GPU memory eagerly. `make up` warns when either is running and never stops them; `make down` in their stack first if torch runs out of memory.

## First-time setup

```bash
cd /opt/pytorch
cp .env.example .env     # then set PYTORCH_TAG (newest NGC tag that passes `make check`)
make up                  # creates workspace/ and cache/
make check               # torch version, CUDA build, device name; exits 1 if CUDA is unavailable
```

## Targets

| Target | Does |
|---|---|
| `make up` | Start the container (creates `.env`, `workspace/`, `cache/` on first run) |
| `make down` | Stop and remove it; `workspace/` and `cache/` are kept |
| `make shell` | Interactive bash in `/workspace` |
| `make run CMD="python train.py"` | Run one command in the container |
| `make check` | Prove torch sees the GPU |
| `make logs` | Follow container logs |

## Mounts

| Host | Container | Holds |
|---|---|---|
| `./workspace` (`WORKSPACE`) | `/workspace` | your code, data, checkpoints |
| `/opt/hf/.cache/huggingface` (`HF_CACHE_HOST`) | `/hf` (`HF_HOME`) | HuggingFace downloads, shared with vllm / llama-cpp |
| `./cache` (`CACHE_HOST`) | `/cache` | `HOME`, pip and torch-hub caches |

`cache/` is a bind-mounted host directory rather than a named volume: a fresh named volume is root-owned and the non-root user couldn't write to it. `pip install` lands there and survives `make down`.

vLLM's container runs as root, so the shared HF cache may be root-owned: cached repos are readable here, but downloading a new model or `hf auth login` from this container can fail with a permission error. Download with the host's `hf` CLI, or point `HF_CACHE_HOST` at a directory you own.

## Configuration

See [`.env.example`](.env.example): `PYTORCH_TAG` (required), `HF_TOKEN`, `HF_CACHE_HOST`, `WORKSPACE`, `CACHE_HOST`, `SHM_SIZE` (default `16gb`).

## Tests

```bash
./test-compose.sh   # asserts on the rendered compose config
./test-make.sh      # drives the Makefile against a stub docker
```

Neither needs a GPU, a daemon or an image pull.
