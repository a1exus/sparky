# tailscale

[Tailscale](https://tailscale.com/) sidecar that registers this host as a node on your tailnet and runs [Tailscale Serve](https://tailscale.com/kb/1242/tailscale-serve) to terminate TLS on tailnet `:443` and reverse-proxy all traffic to `http://traefik:80`. Every backend Traefik already routes becomes reachable over the tailnet without opening any host port.

Based on Tailscale's [Connect a Docker container](https://tailscale.com/docs/features/containers/docker/how-to/connect-docker-container) guide, adapted to this repo's conventions (pinned image tag in `.env`, named state volume, traefik network).

## Files

```
tailscale/
├── docker-compose.yml          # tailscale sidecar, joined to the traefik network, Serve config mounted
├── serve.json                  # Tailscale Serve config — TLS on :443, proxy / → http://traefik:80
├── .env.example                # committed; copy to .env and fill in
└── .env                        # not committed (gitignored)
```

## Configure

### 1. Mint an auth key

Tailscale admin console → **Settings → Keys → Generate auth key**. Recommended:

- **Reusable** — yes (re-creating the container doesn't burn the key)
- **Ephemeral** — no (node state persists across restarts)
- **Pre-approved** — yes (skip manual approval)
- **Tags** — e.g. `tag:server` (matches your ACL policy)

### 2. Drop secrets into `.env`

```bash
cp .env.example .env
# Edit .env:
#   TAILSCALE_TAG  — pin the image (see hub.docker.com/r/tailscale/tailscale/tags)
#   TS_AUTHKEY     — the key from step 1
#   TS_HOSTNAME    — tailnet hostname (default: spark-1822)
```

## Deploy

Prereq: the shared `traefik` Docker network exists. (Bring `traefik/` up at least once, or `docker network create traefik --attachable`.)

```bash
docker compose up -d
docker compose logs -f tailscale    # confirm "Success." and the node URL
```

The node appears in the admin console under **Machines**. MagicDNS publishes it at `https://<TS_HOSTNAME>.<tailnet>.ts.net` — any tailnet-connected device can reach it. TLS uses Tailscale's auto-provisioned MagicDNS cert; no client-side root install needed.

## How it works

```
tailnet client  ──(http  on :80 )──>  tailscale  ──(http  )──>  http://traefik:80
                                                                       │
                                                                       │ web entrypoint
                                                                       │ 308 → https
                                                                       ▼
tailnet client  ──(https on :443)──>  tailscale  ──(https-insecure)──> https://traefik:443
                                                                       │
                                                                       │ Host header routing
                                                                       ▼
                                                                   backend (vllm / open-webui / netdata / ...)
```

- The Tailscale daemon runs in userspace mode (no `/dev/net/tun`, no privileged caps) and registers as one node on your tailnet using `TS_AUTHKEY`.
- [Tailscale Serve](https://tailscale.com/kb/1242/tailscale-serve) is configured via the mounted `serve.json`. The container substitutes `${TS_CERT_DOMAIN}` with the node's MagicDNS hostname at startup, then exposes two listeners:
  - **`:80` plain HTTP**, proxied to `http://traefik:80`. Traefik's `web` entrypoint then 308-redirects to HTTPS. The redirect's `Location` header preserves the tailnet `Host`, so the client follows back to the `:443` listener below — one extra hop on first request, then HTTPS the rest of the way.
  - **`:443` HTTPS**, with TLS terminated using the publicly-trusted MagicDNS cert, proxied to `https-insecure://traefik:443`. The `-insecure` modifier skips Traefik's wildcard-cert verification (the inner connection is over the trusted `traefik` Docker network, container-to-container — no external attacker reachable). Traefik's `websecure` entrypoint terminates the inner TLS with its own wildcard and routes by Host header.
- Why not just proxy `:443` to `http://traefik:80`? Because Traefik would see plain HTTP on its `web` entrypoint and 308-redirect — sending the client back through Tailscale `:443` → http://traefik:80 → 308 again → infinite loop. `https-insecure://traefik:443` lands directly on `websecure` and avoids the redirect entirely.
- State (node key, machine identity) lives in a named docker volume `tailscale-state`, not under `/opt` — so the host's git working tree stays free of secrets.

### Host-header routing — applied

Each Traefik router uses a single `HostRegexp` matcher pinned to its per-service subdomain — `<svc>.{x:.+}` — which accepts the LAN form (`vllm.spark-1822.local`), the per-service tailnet form once you set up per-backend VIP services below (`vllm.<tailnet>.ts.net`), and any other `<svc>.<domain>` that gets pointed at Traefik.

```yaml
# example, open-webui/docker-compose.yml
- "traefik.http.routers.open-webui.rule=HostRegexp(`open-webui.{x:.+}`)"
```

Six routers, one per service — `ollama`, `open-webui`, `vllm`, `llama` (label-based in each app's compose), plus `netdata` and `traefik` (file-based in `traefik/dynamic/services.yml`).

### Per-backend VIP Services

A Tailscale [VIP Service](https://tailscale.com/kb/1417/services) is a separate tailnet entity from the node — it has its own MagicDNS name (e.g. `vllm.<tailnet>.ts.net`) and its own cert. One service per backend gives tailnet clients a per-service URL without running multiple Tailscale nodes (Tailscale doesn't support wildcard subdomains under a node's MagicDNS name, so this is the canonical multi-name pattern).

Six services map to the six Traefik backends:

| Service     | DNS                              | Lands on              |
|-------------|----------------------------------|-----------------------|
| `svc:traefik`     | `traefik.<tailnet>.ts.net`       | Traefik dashboard     |
| `svc:vllm`        | `vllm.<tailnet>.ts.net`          | vLLM                  |
| `svc:llama`       | `llama.<tailnet>.ts.net`         | llama.cpp             |
| `svc:ollama`      | `ollama.<tailnet>.ts.net`        | Ollama                |
| `svc:open-webui`  | `open-webui.<tailnet>.ts.net`    | Open WebUI            |
| `svc:netdata`     | `netdata.<tailnet>.ts.net`       | Netdata               |

All six share a single [`services.json`](services.json) — they're indistinguishable on the wire (each just proxies to the same `traefik` container, which routes by Host header). The file uses the **single-service** form (`ServiceDetailsFile` from `ipn/conffile/serveconf.go`), applied per service with `--service=svc:<name>`:

```json
{
  "version": "0.0.1",
  "endpoints": {
    "tcp:80":  "http://traefik:80",
    "tcp:443": "https+insecure://traefik:443"
  }
}
```

> The scheme is `https+insecure://` (plus, not hyphen) — different from the `https-insecure://` accepted in the Proxy field of `serve.json`. The two config surfaces grew up separately; the Services file matches the `ServiceProtocol` constants in `ipn/conffile/serveconf.go`.

**Setup is two phases.** Phase one (one-time, in the admin console): create each service at <https://login.tailscale.com/admin/services> with required ports `tcp/80` + `tcp/443`. Tailscale can't auto-create services from the CLI — they have to exist in the policy before a node can advertise them.

Phase two (on the host): use the `Makefile` to push the config and advertise:

```bash
cd /opt/tailscale
make services-apply     # set-config + advertise every service in $(SERVICES)
make services-status    # show the daemon's view of each service
make services-clear     # drain + clear all services from this node
```

State lives in the `tailscale-state` docker volume — survives restarts. The list of services is `$(SERVICES)` in the Makefile; override with `make services-apply SERVICES="svc:foo svc:bar"` for a subset.

Once all six advertise, Traefik routing accepts both `<svc>.spark-1822.local` (LAN) and `<svc>.<tailnet>.ts.net` (tailnet) on every router — the rules were relaxed from `<svc>.spark{x:.+}` to `<svc>.{x:.+}` to match either form.

### Troubleshooting: admin console shows "needs configuration"

If the Tailscale admin console flags every VIP service as **needs configuration** at once, the node has stopped advertising them — usually because the `tailscale` container was restarted or recreated (e.g. during host troubleshooting) without re-running phase two. Confirm with `make services-status`: each service prints an empty `{}` instead of the `endpoints` block. Fix is just re-running phase two:

```bash
cd /opt/tailscale
make services-apply
make services-status   # confirm every service now shows real endpoints, not {}
```

The service *definitions* (created in the admin console, phase one) aren't lost — only the node's advertisement of them, which isn't automatically restored by `docker compose up`/`restart` the way the base node identity is. Re-running `services-apply` after any tailscale container restart is the safe default if you're not sure whether it dropped.

### Legacy `svc:spark`

The first VIP service set up here was `svc:spark` — one service proxying everything to Traefik, with a special bare-host fallback on the Traefik dashboard router to catch the no-subdomain Host header. The per-backend setup above supersedes it: hit `traefik.<tailnet>.ts.net` for the dashboard instead.

`svc:spark` still works as long as the dashboard router carries the `|| HostRegexp(`spark{x:.+}`)` fallback in `traefik/dynamic/services.yml`. To retire it:

1. `make services-clear SERVICES="svc:spark"` on the host (drains + clears).
2. Delete the service in the admin console.
3. Drop the `|| HostRegexp(`spark{x:.+}`)` half from the `traefik` router in `dynamic/services.yml`.

## Logs

```bash
docker compose logs -f tailscale
```

The "Success." line confirms the node is logged in. `tailscale status` inside the container shows peers:

```bash
docker exec tailscale tailscale status
```

## Upgrade

Bump `TAILSCALE_TAG` in `.env`, then:

```bash
docker compose pull
docker compose up -d
```

## Uninstall

```bash
docker compose down
docker volume rm tailscale-state    # also discard the node key + machine state
```

Then delete the node from the Tailscale admin console under **Machines** if you're not reusing it.

## Hardening / industry-standard follow-ups

What's shipped is the minimum that works. Four deferred items move this from "homelab-grade" to what Tailscale's own production guides recommend. Each is independently applicable.

### 1. Auth secret via file mount (not env var)

Today `TS_AUTHKEY` is read from `.env` and exposed in the container's environment — visible to anyone who can `docker inspect` the container. Tailscale's `containerboot` supports a file indirection that keeps the secret off the process env: set `TS_AUTHKEY=file:/run/secrets/ts_authkey` (or `TS_AUTHKEY_FILE=/run/secrets/ts_authkey`) and mount the file via a compose `secrets:` block.

Migration sketch (base `docker-compose.yml`):

```yaml
services:
  tailscale:
    environment:
      - TS_AUTHKEY=file:/run/secrets/ts_authkey   # was: TS_AUTHKEY=${TS_AUTHKEY:?…}
    secrets:
      - ts_authkey

secrets:
  ts_authkey:
    file: ./ts_authkey                            # host-local file, mode 0600, gitignored
```

Tradeoff: one extra file on disk to manage (and rotate). Same threat model as `.env` in practice on this single-host setup, but it's the conventional pattern.

### 2. OAuth client credentials instead of a static auth key

Auth keys are accepted but discouraged for persistent nodes — they expire (90-day max), and rotation is manual toil. The recommended pattern for long-running infrastructure is OAuth client credentials: mint an OAuth client in the admin console (**Settings → OAuth clients**), give it the `devices:write` scope and the `tag:server` tag, and use the resulting `tskey-client-...` token. `containerboot` exchanges it for an ephemeral auth key on every restart — no rotation needed.

```bash
# .env
TS_AUTHKEY=tskey-client-<your-oauth-client-secret>?preauthorized=true&ephemeral=false
```

Tradeoff: one-time setup cost in the dashboard. Bigger lift than (1) — this is a real provisioning decision, not just a refactor.

### 3. Advertise an ACL tag

Without `--advertise-tags`, this node inherits the *minting user's* identity in the Tailscale ACL graph. That works, but it means ACL rules can't distinguish "Dmitry's laptop" from "the inference server" — every device under the same user is treated the same.

Idiomatic fix:

```bash
# .env
TS_EXTRA_ARGS=--advertise-tags=tag:server
```

And in the tailnet ACL JSON:

```json
{
  "tagOwners": {
    "tag:server": ["autogroup:admin"]
  }
}
```

Required if you later want rules like *"only `tag:client` may reach `tag:server:443`"*. OAuth clients (option 2) typically mint pre-tagged keys, so this combines naturally with (2).

### 4. Kernel networking mode

The base file runs in userspace mode (`TS_USERSPACE=true`). Works without elevated privileges, but every packet goes through a userspace TCP stack — meaningful throughput penalty on a busy node. For an inference host fronting LLM endpoints, kernel mode is the production setting.

```yaml
# docker-compose.yml diff
services:
  tailscale:
    environment:
      - TS_USERSPACE=false      # was: true
    devices:
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - net_admin
      - net_raw
```

Tradeoff: requires `/dev/net/tun` on the host (true on stock Ubuntu) and the two capabilities. Required to use this node as a subnet router or exit node, which userspace mode can't do either way.

### Priority

Recommended baseline: **1 + 3 + 4** as a single hardening pass. **2 (OAuth)** is the biggest improvement but it's a provisioning decision, not a config refactor — promote it whenever the next auth key would otherwise need renewing.

## See also

- Top-level [README](../README.md)
- [`traefik/`](../traefik/) — the proxy this sidecar fronts
- [`cloudflare/`](../cloudflare/) — the other edge-ingress stack in this repo, structurally analogous (also tunnels into traefik over an outbound-only connection)
- Tailscale Docker guide: <https://tailscale.com/docs/features/containers/docker/how-to/connect-docker-container>
- Tailscale Serve docs: <https://tailscale.com/kb/1242/tailscale-serve>
- Tailscale OAuth clients: <https://tailscale.com/kb/1215/oauth-clients>
- Tailscale ACL tags: <https://tailscale.com/kb/1068/acl-tags>
