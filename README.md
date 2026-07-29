# sparky

<p align="center">
  <img src="sparky.svg" alt="sparky" width="220" height="260">
</p>

<p align="center"><b>English</b> | <a href="README.es.md">Español</a> | <a href="README.ru.md">Русский</a> | <a href="README.zh.md">中文</a></p>

Configuration for the [NVIDIA DGX Spark](https://amzn.to/47ZeWqZ) workstation `spark-1822` — a single-box, self-hosted LLM setup:

- **vLLM** and **llama.cpp** for inference (HF safetensors and GGUF respectively, both GPU-accelerated on the GB10).
- **Open WebUI + Ollama** for the chat UI.
- **Traefik** as the HTTPS reverse proxy in front of everything (docker-label-driven, mints its own internal CA).
- **Cloudflare Tunnel** for outbound-only public ingress (no inbound ports on the host).
- **Tailscale** sidecar for tailnet-only ingress (peer-to-peer over WireGuard; no public DNS, no public ports).
- **Netdata** for real-time observability.
- **mDNS** helper publishing `<sub>.spark-1822.local` aliases on the LAN.
- **Trivy** + **Dependabot** keep the supply chain honest in CI.

## Topology

Three ingress paths into the same backends:

```
LAN client      ──(mDNS *.spark-1822.local)──>  traefik :80/:443  ──>  backend
public client   ──(DNS, Cloudflare edge)──>  cloudflared ──>  traefik :80  ──>  backend
tailnet client  ──(MagicDNS, WireGuard)──>  tailscale :443  ──>  traefik :80  ──>  backend
```

Backends (`vllm`, `llama-cpp`, `open-webui`, `ollama`) all sit on a single shared Docker network named `traefik` — defined by the `traefik/` stack, joined as `external: true` by everyone else. The active proxy and both tunnel/sidecar connectors each attach to the same network and dial container names directly. `netdata` is the exception: it runs with `network_mode: host` (needed for host-level PID/proc telemetry), so it has no endpoint on the `traefik` network — Traefik reaches it via a static route to `host.docker.internal:19999` in `traefik/dynamic/services.yml` instead of container-name DNS.

TLS comes from three different roots: Traefik mints its own internal CA (clients install `traefik-root.crt` once); Cloudflare provides publicly-trusted certs at its edge for the tunnel hostnames; Tailscale auto-provisions publicly-trusted MagicDNS certs for the tailnet hostname.

## Layout

```
.
├── traefik/       # HTTPS reverse proxy (docker-label-driven)
├── cloudflare/    # Cloudflare Tunnel connector — public ingress
├── tailscale/     # Tailscale sidecar — tailnet ingress
├── vllm/          # vLLM inference server (HF safetensors)
├── llama-cpp/     # llama.cpp inference server (GGUF)
├── open-webui/    # Open WebUI + Ollama (chat UI)
├── netdata/       # Real-time observability
├── mdns/          # Host-side mDNS aliases helper
├── docs/          # Design/planning docs (e.g. llama-cpp router-mode spec)
├── .github/       # CI: Trivy workflow + Dependabot config
├── Makefile       # top-level LLM-engine control (up / down / list)
├── sparky.svg     # Project logo (AI self-portrait)
├── CHANGELOG.md
├── LICENSE
├── README.md
├── README.es.md   # Spanish translation
├── README.ru.md   # Russian translation
└── README.zh.md   # Simplified Chinese translation
```

Each stack has its own `README.md` — start there for deploy / configure / upgrade details.

## Components

| Stack | Role | URL on LAN |
|---|---|---|
| [`traefik/`](traefik/) | HTTPS reverse proxy, docker-label-driven, mints its own internal CA | publishes `:80`/`:443` |
| [`cloudflare/`](cloudflare/) | Cloudflare Tunnel connector — outbound-only public ingress | configurable per-hostname in the CF dashboard |
| [`tailscale/`](tailscale/) | Tailscale sidecar — tailnet-only ingress over WireGuard, optional Serve overlay fronts `traefik` | `https://spark-1822.<tailnet>.ts.net` |
| [`vllm/`](vllm/) | vLLM inference server (HF safetensors), tool-calling enabled (`qwen3_xml`) | `https://vllm.spark-1822.local` |
| [`llama-cpp/`](llama-cpp/) | llama.cpp GPU-accelerated inference server (GGUF). Router mode (default) serves every GGUF in the HF cache on demand; classic single-model mode also supported. OpenAI-compatible API + web UI | `https://llama.spark-1822.local` |
| [`open-webui/`](open-webui/) | Open WebUI + Ollama (GPU on Ollama only) | `https://open-webui.spark-1822.local`, `https://ollama.spark-1822.local` |
| [`netdata/`](netdata/) | Real-time host + container telemetry | `https://netdata.spark-1822.local` |
| [`mdns/`](mdns/) | Host systemd template publishing `<sub>.spark-1822.local` mDNS aliases | host-level |

## Host

| | |
|---|---|
| Hardware | [NVIDIA DGX Spark](https://amzn.to/47ZeWqZ) |
| Hostname | `spark-1822.local` |
| OS | Ubuntu (kernel `6.17.0-nvidia`), aarch64 |
| GPU | NVIDIA GB10 (compute capability 12.1, 124 GiB VRAM) |
| Docker | 29.x + Compose v2 |
| GPU runtime | `nvidia-container-toolkit` 1.19 (CDI mode) |

## First-time setup

On a fresh host, in order:

1. **Install the mDNS helper** (host-side; publishes `<sub>.spark-1822.local` aliases):

   ```bash
   cd /opt/mdns && make install
   ```

2. **Bring up the reverse proxy** — this also creates the shared `traefik` Docker network everything else joins:

   ```bash
   cd /opt/traefik
   cp .env.example .env             # then set TRAEFIK_TAG
   make ca-cert                     # one-time: mint Traefik's internal root CA
   make wildcard-cert               # mint the wildcard leaf signed by that root
   docker compose up -d
   ```

   Install `traefik/certs/traefik-root.crt` on each client that should trust the host's LAN URLs (per-OS install table in [`traefik/README.md`](traefik/README.md)).

3. **Publish a mDNS alias for each subdomain** you'll expose:

   ```bash
   cd /opt/mdns
   for a in traefik vllm llama ollama open-webui netdata; do make add ALIAS=$a; done
   ```

4. **Bring up the services** — each one attaches to the `traefik` network and Traefik auto-routes via the `traefik.*` labels in its compose:

   ```bash
   cd /opt/open-webui && cp .env.example .env && docker compose up -d
   cd /opt/netdata    && cp .env.example .env && docker compose up -d
   cd /opt/vllm       && make up ENV=<variant>      # see vllm/envs/
   cd /opt/llama-cpp  && make up ENV=<variant>      # see llama-cpp/envs/
   ```

5. **(Optional) Public ingress via Cloudflare Tunnel** — only if you want internet-reachable URLs:

   ```bash
   cd /opt/cloudflare
   cp .env.example .env             # paste CLOUDFLARE_TUNNEL_TOKEN from the CF dashboard
   docker compose up -d
   ```

   Then configure Public Hostnames in the Cloudflare dashboard so they forward to `http://traefik:80` with the matching internal Host header (recipe in [`cloudflare/README.md`](cloudflare/README.md)).

6. **(Optional) Tailnet ingress via Tailscale** — only if you want this host reachable from your tailnet:

   ```bash
   cd /opt/tailscale
   cp .env.example .env             # paste TS_AUTHKEY from the Tailscale admin console
   docker compose up -d
   ```

   The node registers as `spark-1822.<tailnet>.ts.net` with a real publicly-trusted MagicDNS cert; Tailscale Serve wires `:80`/`:443` on the tailnet to Traefik. For per-backend tailnet URLs (`https://vllm.<tailnet>.ts.net`, `https://traefik.<tailnet>.ts.net`, …), create one [Tailscale VIP Service](https://tailscale.com/kb/1417/services) per backend and apply via `make -C /opt/tailscale services-apply` — see [`tailscale/README.md`](tailscale/README.md) for the full walk-through.

## Deploy workflow

`/opt` on the host **is** a checkout of this repo — every stack lives in place at `/opt/<name>/`. Edit locally, commit, push; then pull on the host:

```bash
ssh spark-1822.local 'sudo git -C /opt pull --ff-only'
```

After the pull, apply the change in the relevant stack (each stack's README has details):

- **Inference stacks** (`vllm/`, `llama-cpp/`) — `cd /opt/<stack> && make up ENV=<variant>` to (re)start with a variant.
- **Traefik** — routing changes via Docker labels or `dynamic/*.yml` files are hot-reloaded; `docker compose restart traefik` only if `traefik.yml` itself changed.
- **Other stacks** — `cd /opt/<name> && docker compose up -d`.

Host-local files outside git stay put across pulls — each stack's `.env` (secrets), inference `envs/*.env` variants, TLS material (`*.crt`/`*.key`), and `*.bak` backups are all gitignored.

## Managing the LLM engines

The top-level [`Makefile`](Makefile) (at `/opt/Makefile` on the host) is a thin wrapper over the four LLM services — it acts on **one engine at a time and never touches the others**:

```bash
make up engine=vllm ENV=<variant>    # start one engine
make up engine=llama-cpp             # llama-cpp with empty ENV = router mode
make down engine=ollama              # stop just that one; the rest keep running
make list                            # model variants for vllm / llama-cpp
```

Engines are `vllm`, `llama-cpp`, `ollama`, `open-webui`. `up engine=vllm|llama-cpp` delegates to that stack's own `make up` (so `ENV=` variant-layering still applies); `ollama`/`open-webui` go through the shared open-webui compose project. For what's running use `docker ps -a`; for what's actually on the GPU use `nvidia-smi`.

vLLM (`--gpu-memory-utilization 0.9`) and llama-cpp classic single-model mode (`-ngl 999`) claim VRAM eagerly and can't co-reside with another eager engine on the GB10; ollama and llama-cpp router mode are lazy. The Makefile deliberately **doesn't** enforce that trade-off — run `make down engine=<other>` first when you need the whole GPU (a "running" container isn't necessarily on the GPU).

## Conventions

- **Image tags float by default, pin in production.** The committed `.env.example` files use floating tags (`latest`, or a stable major-line like `v2` for Traefik, or the multi-arch floating tag `server-cuda` for `ggml-org/llama.cpp`) so a fresh `cp .env.example .env` bootstraps to a working state without anyone having to look up the current release. **For production deployments, override in your host-local `.env` with a specific, reproducible pin** — an immutable tag (`v2.11.X`, `v0.20.2`) when the registry publishes one, or a content-digest pin (`server-cuda@sha256:…`) when only floating tags exist. Each per-service `.env.example` shows the pin format inline.
- **Inference config split** by scope. `<stack>/.env` carries host-wide values (image pin, HF cache path, HF token, default knobs); `<stack>/envs/<name>.env` carries just the model selection plus per-variant overrides. `make up ENV=<name>` chains both via `docker compose --env-file .env --env-file envs/<name>.env up -d`. Both files are gitignored — the templates live next to them as `.env.example`.
- **Loopback ports on inference stacks.** `vllm/` and `llama-cpp/` additionally bind their API to `127.0.0.1` on the host for direct curl / benchmarking — LAN traffic still flows through the proxy.
- **Permissions.** `/opt/<stack>/` is `root:root`. The `.env` files are `root:docker 640` so the `docker`-group user reads them and runs compose without sudo. Editing configs requires `sudo`.
- **Supply chain.** Every third-party Docker image is referenced by tag in `.env.example` (floating for first-bootstrap convenience; pin in your host-local `.env` for production). Every GitHub Action is pinned by commit SHA. Trivy scans push / PR / weekly cron; Dependabot keeps the SHA pins fresh with a weekly grouped PR.

## Repo housekeeping

- [`CHANGELOG.md`](CHANGELOG.md) — [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format, [SemVer](https://semver.org/spec/v2.0.0.html) versioning.
- [`.github/workflows/trivy.yml`](.github/workflows/trivy.yml) — image CVE scans (HIGH+CRITICAL, fixed-only), IaC config scan, filesystem secret scan. Doc: [`.github/workflows/trivy.md`](.github/workflows/trivy.md).
- [`.github/dependabot.yml`](.github/dependabot.yml) — weekly grouped PR to bump pinned GitHub Action SHAs.
- [`docs/`](docs/) — design/planning docs for individual features (e.g. `docs/superpowers/specs/`, `docs/superpowers/plans/` for the llama-cpp router-mode work).
- [`README.es.md`](README.es.md), [`README.ru.md`](README.ru.md), [`README.zh.md`](README.zh.md) — Spanish, Russian, and Simplified Chinese translations of this README, kept in sync via the language-switcher line under the logo.
- [`LICENSE`](LICENSE) — MIT.
- [`sparky.svg`](sparky.svg) — project mascot. Drawn by the AI that helped build this repo, as a self-portrait.
