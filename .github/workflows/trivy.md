# Trivy

Workflow: [`trivy.yml`](trivy.yml). Scans every container image we deploy plus the repo itself for vulnerabilities, misconfigurations, and leaked secrets, using [Aqua Security Trivy](https://aquasecurity.github.io/trivy/).

## Triggers

- `push` to `main`
- `pull_request` targeting `main`
- Weekly schedule — Mondays 06:00 UTC. Re-scans the image tags as committed in each stack's `.env.example` (floating by default, so this also picks up upstream rebuilds).
- Manual `workflow_dispatch`

## Jobs

| Job | What it scans |
|---|---|
| `extract-tags` | Reads the image tag from each stack's `.env.example` (`*_TAG=` line) and exposes the values as job outputs. Tags are floating by repo convention (`latest`, `v2`, `server-cuda`, etc.); operators pin in their host-local `.env`. |
| `image-scan` (matrix) | CVE scan of each image at the committed `.env.example` tag: `ollama/ollama`, `ghcr.io/open-webui/open-webui`, `netdata/netdata`, `ghcr.io/ggml-org/llama.cpp`, `vllm/vllm-openai`, `traefik`, `cloudflare/cloudflared`, `tailscale/tailscale`. Severity HIGH+CRITICAL, fixed-only. **Gate-only** — printed to the run log and gated on CRITICAL; **not** uploaded to Code Scanning (see below). |
| `config-scan` | Trivy IaC config check across the whole repo (compose misconfig, etc.). |
| `secret-scan` | Filesystem scan for accidentally-committed secrets. |

Only `config-scan` and `secret-scan` upload SARIF to the repo's [Security tab](https://github.com/a1exus/sparky/security/code-scanning) — they scan the repo filesystem, so their results map to real source files. `image-scan` is deliberately **not** uploaded: container-image CVEs carry image-filesystem locations (`usr/bin/…`, `site-packages/…`) that don't exist in the repo, and Code Scanning (a source-analysis tool) reports a configuration error when asked to map them. Image CVEs are a supply-chain **gate**, not source findings — they block the build and appear in the job log.

## Gating

- **Push / PR** — fails on any CRITICAL CVE or any leaked secret. Blocks merges on real regressions.
- **Scheduled** — never fails. Upstream CVEs against today's tag resolution shouldn't break the green badge; new findings still surface in the Security tab so we (and any operator pinning to a specific version in their `.env`) know when to upgrade.
- **Allowlist** — Trivy auto-reads [`.trivyignore`](../../.trivyignore) from the repo root; the CRITICAL image gate honors it. Use it only for CRITICAL, fixed-only findings in base layers of upstream images we consume but don't build — see [Accepted findings](#accepted-findings) for the rationale and per-entry provenance.

## Hardening

- All third-party actions are pinned by commit SHA (not tag). [`.github/dependabot.yml`](../dependabot.yml) opens a grouped PR each Monday with any updates so the pins don't go stale.
- Top-level `permissions: contents: read`; jobs declare `security-events: write` only where needed.
- Every job has `timeout-minutes` set (5/20/10/10 for `extract-tags` / `image-scan` / `config-scan` / `secret-scan`) so a stuck step can't burn the runner's 6-hour default.
- `extract-tags` parses `.env.example` with `grep` + a strict regex `^[A-Za-z0-9._@:+-]+$` (no `source`-ing of user-controlled files — protects against workflow injection via PR-modified env values). The regex accepts OCI digest pins like `server-cuda@sha256:…` while excluding every shell-meaningful character.
- Concurrency: `cancel-in-progress` per ref to avoid wasted runs.

## Maintenance

- Bumping a stack's image tag in `<stack>/.env.example` is picked up automatically by the next run.
- Adding a new stack: extend `extract-tags` to read the new `<stack>/.env.example`, then add an entry to the `image-scan` matrix referencing the new tag output.
- Bumping `aquasecurity/trivy-action` itself: resolve the new tag to a commit SHA and update all three `uses:` lines together.

## Accepted findings

Suppressed via [`.trivyignore`](../../.trivyignore) — each CVE is a base-OS Debian package in an upstream image we consume but don't build, so it clears only when upstream rebases its base layer. The file itself carries the full rationale (what, where discovered, exposure analysis, how to revisit); the table below is the summary. Remove an entry once the weekly scheduled run stops surfacing it.

| Image | CVE | Package | Fixed in (Debian) | Why accepted |
|---|---|---|---|---|
| `ghcr.io/open-webui/open-webui:latest` | [CVE-2026-40393](https://avd.aquasec.com/nvd/cve-2026-40393) | `libgbm1` (Mesa) | 22.3.6-1+deb12u2 | Out-of-bounds write; no Mesa GPU render path in this container. |
| `ghcr.io/open-webui/open-webui:latest` | [CVE-2026-44172](https://avd.aquasec.com/nvd/cve-2026-44172) | `libmariadb*` / `mariadb-common` | 1:10.11.18-0+deb12u1 | MariaDB **server** SQL injection; only client libs present, no server runs. |
| `ghcr.io/open-webui/open-webui:latest` | [CVE-2026-49261](https://avd.aquasec.com/nvd/cve-2026-49261) | `mariadb` libs | 1:10.11.18-0+deb12u1 | MariaDB **server** RCE; same no-server rationale. |
| `ghcr.io/open-webui/open-webui:latest` | [CVE-2026-53215](https://avd.aquasec.com/nvd/cve-2026-53215) | `linux-libc-dev` | 6.1.176-1 | Kernel net/mvpp2 fix in a **headers** package, not a running kernel. |

All four were surfaced by the `image-scan (open-webui, …)` CRITICAL gate on 2026-07-16 ([run 29466589985](https://github.com/a1exus/sparky/actions/runs/29466589985)).

## Local equivalent

To reproduce a single scan locally:

```bash
docker run --rm -v "$PWD:/repo" aquasec/trivy:latest \
    image --severity HIGH,CRITICAL --ignore-unfixed ollama/ollama:0.23.2

docker run --rm -v "$PWD:/repo" aquasec/trivy:latest \
    config /repo
```

## See also

- [`.github/README.md`](../README.md) — workflow index
- Top-level [README](../../README.md)
- Trivy: <https://aquasecurity.github.io/trivy/>
