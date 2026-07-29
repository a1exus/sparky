# sparky

<p align="center">
  <img src="sparky.svg" alt="sparky" width="220" height="260">
</p>

<p align="center"><a href="README.md">English</a> | <a href="README.es.md">Español</a> | <a href="README.ru.md">Русский</a> | <b>中文</b></p>

[NVIDIA DGX Spark](https://amzn.to/47ZeWqZ) 工作站 `spark-1822` 的配置 —— 一套单机自托管的 LLM 方案：

- **vLLM** 与 **llama.cpp** 负责推理（分别对应 HF safetensors 与 GGUF 格式，均在 GB10 上启用 GPU 加速）。
- **Open WebUI + Ollama** 提供聊天界面。
- **Traefik** 作为所有服务前置的 HTTPS 反向代理（由 docker 标签驱动，自签发内部 CA）。
- **Cloudflare Tunnel** 提供仅出站的公网入口（主机不开放任何入站端口）。
- **Tailscale** sidecar 提供仅限 tailnet 的入口（基于 WireGuard 的点对点连接；无公共 DNS、无公开端口）。
- **Netdata** 提供实时可观测性。
- **mDNS** 辅助服务在局域网内发布 `<sub>.spark-1822.local` 别名。
- **Trivy** + **Dependabot** 在 CI 中保障供应链安全。

## 拓扑结构

三条流量入口路径通向同一批后端：

```
局域网客户端  ──(mDNS *.spark-1822.local)──>  traefik :80/:443  ──>  后端
公网客户端    ──(DNS, Cloudflare 边缘节点)──>  cloudflared ──>  traefik :80  ──>  后端
tailnet 客户端 ──(MagicDNS, WireGuard)──>  tailscale :443  ──>  traefik :80  ──>  后端
```

后端服务（`vllm`、`llama-cpp`、`open-webui`、`ollama`）都位于同一个共享 Docker 网络 `traefik` 中 —— 该网络由 `traefik/` 这个 stack 定义，其余所有服务以 `external: true` 的方式加入。当前使用的代理以及两个隧道/sidecar 连接器都接入同一个网络，并直接通过容器名称互相访问。`netdata` 是例外：它以 `network_mode: host` 运行（用于获取主机级别的 PID/proc 遥测数据），因此在 `traefik` 网络中没有端点 —— Traefik 通过 `traefik/dynamic/services.yml` 中指向 `host.docker.internal:19999` 的静态路由访问它，而不是通过容器名 DNS。

TLS 证书来自三个不同的根：Traefik 自签发内部 CA（客户端只需安装一次 `traefik-root.crt`）；Cloudflare 在其边缘节点为隧道主机名提供公共信任证书；Tailscale 为 tailnet 主机名自动签发公共信任的 MagicDNS 证书。

## 目录结构

```
.
├── traefik/       # HTTPS 反向代理（由 docker 标签驱动）
├── cloudflare/    # Cloudflare Tunnel 连接器 —— 公网入口
├── tailscale/     # Tailscale sidecar —— tailnet 入口
├── vllm/          # vLLM 推理服务器（HF safetensors）
├── llama-cpp/     # llama.cpp 推理服务器（GGUF）
├── open-webui/    # Open WebUI + Ollama（聊天界面）
├── netdata/       # 实时可观测性
├── mdns/          # 主机侧 mDNS 别名辅助服务
├── docs/          # 设计/规划文档（例如 llama-cpp router 模式的规格说明）
├── .github/       # CI：Trivy workflow + Dependabot 配置
├── Makefile       # 顶层 LLM 引擎控制（up / down / list）
├── sparky.svg     # 项目 Logo（AI 自画像）
├── CHANGELOG.md
├── LICENSE
├── README.md
├── README.es.md   # 西班牙语翻译
├── README.ru.md   # 俄语翻译
└── README.zh.md   # 简体中文翻译
```

每个 stack 都有自己的 `README.md` —— 部署 / 配置 / 升级的详细说明请从那里开始。

## 组件一览

| Stack | 角色 | 局域网 URL |
|---|---|---|
| [`traefik/`](traefik/) | HTTPS 反向代理，由 docker 标签驱动，自签发内部 CA | 发布 `:80`/`:443` |
| [`cloudflare/`](cloudflare/) | Cloudflare Tunnel 连接器 —— 仅出站的公网入口 | 在 CF 控制台中按主机名配置 |
| [`tailscale/`](tailscale/) | Tailscale sidecar —— 基于 WireGuard 的 tailnet 专属入口，可选的 Serve overlay 前置 `traefik` | `https://spark-1822.<tailnet>.ts.net` |
| [`vllm/`](vllm/) | vLLM 推理服务器（HF safetensors），已启用工具调用（`qwen3_xml`） | `https://vllm.spark-1822.local` |
| [`llama-cpp/`](llama-cpp/) | GPU 加速的 llama.cpp 推理服务器（GGUF）。router 模式（默认）按需提供 HF 缓存中的任意 GGUF；同时支持经典单模型模式。兼容 OpenAI 的 API + Web 界面 | `https://llama.spark-1822.local` |
| [`open-webui/`](open-webui/) | Open WebUI + Ollama（仅 Ollama 使用 GPU） | `https://open-webui.spark-1822.local`、`https://ollama.spark-1822.local` |
| [`netdata/`](netdata/) | 主机 + 容器的实时遥测数据 | `https://netdata.spark-1822.local` |
| [`mdns/`](mdns/) | 主机 systemd 模板，用于发布 `<sub>.spark-1822.local` mDNS 别名 | 主机级别 |

## 主机信息

| | |
|---|---|
| 硬件 | [NVIDIA DGX Spark](https://amzn.to/47ZeWqZ) |
| 主机名 | `spark-1822.local` |
| 操作系统 | Ubuntu（内核 `6.17.0-nvidia`），aarch64 |
| GPU | NVIDIA GB10（计算能力 12.1，124 GiB 显存） |
| Docker | 29.x + Compose v2 |
| GPU runtime | `nvidia-container-toolkit` 1.19（CDI 模式） |

## 首次配置

在全新主机上，依次执行：

1. **安装 mDNS 辅助服务**（主机侧；发布 `<sub>.spark-1822.local` 别名）：

   ```bash
   cd /opt/mdns && make install
   ```

2. **启动反向代理** —— 这一步还会创建其余所有服务都会加入的共享 Docker 网络 `traefik`：

   ```bash
   cd /opt/traefik
   cp .env.example .env             # 然后设置 TRAEFIK_TAG
   make ca-cert                     # 一次性操作：签发 Traefik 的内部根 CA
   make wildcard-cert               # 签发由该根 CA 签名的通配符叶证书
   docker compose up -d
   ```

   在每个需要信任主机局域网 URL 的客户端上安装 `traefik/certs/traefik-root.crt`（各操作系统的安装步骤见 [`traefik/README.md`](traefik/README.md)）。

3. **为每个要暴露的子域名发布 mDNS 别名**：

   ```bash
   cd /opt/mdns
   for a in traefik vllm llama ollama open-webui netdata; do make add ALIAS=$a; done
   ```

4. **启动各项服务** —— 每个服务都会接入 `traefik` 网络，Traefik 会通过其 compose 文件中的 `traefik.*` 标签自动路由：

   ```bash
   cd /opt/open-webui && cp .env.example .env && docker compose up -d
   cd /opt/netdata    && cp .env.example .env && docker compose up -d
   cd /opt/vllm       && make up ENV=<variant>      # 参见 vllm/envs/
   cd /opt/llama-cpp  && make up ENV=<variant>      # 参见 llama-cpp/envs/
   ```

5. **（可选）通过 Cloudflare Tunnel 提供公网入口** —— 仅当你需要可从互联网访问的 URL 时才需要：

   ```bash
   cd /opt/cloudflare
   cp .env.example .env             # 从 CF 控制台粘贴 CLOUDFLARE_TUNNEL_TOKEN
   docker compose up -d
   ```

   然后在 Cloudflare 控制台配置 Public Hostnames，使其转发到 `http://traefik:80` 并带上对应的内部 Host 请求头（具体做法见 [`cloudflare/README.md`](cloudflare/README.md)）。

6. **（可选）通过 Tailscale 提供 tailnet 入口** —— 仅当你需要让此主机可从你的 tailnet 访问时才需要：

   ```bash
   cd /opt/tailscale
   cp .env.example .env             # 从 Tailscale 管理控制台粘贴 TS_AUTHKEY
   docker compose up -d
   ```

   该节点会以 `spark-1822.<tailnet>.ts.net` 的身份注册，并获得真实的公共信任 MagicDNS 证书；Tailscale Serve 会将 tailnet 上的 `:80`/`:443` 接入 Traefik。若需要为每个后端单独提供 tailnet URL（`https://vllm.<tailnet>.ts.net`、`https://traefik.<tailnet>.ts.net` 等），请为每个后端创建一个 [Tailscale VIP Service](https://tailscale.com/kb/1417/services) 并通过 `make -C /opt/tailscale services-apply` 应用 —— 完整流程见 [`tailscale/README.md`](tailscale/README.md)。

## 部署流程

主机上的 `/opt` **就是**本仓库的一个 checkout —— 每个 stack 都原地位于 `/opt/<name>/`。在本地编辑、commit、push；然后在主机上执行 pull：

```bash
ssh spark-1822.local 'sudo git -C /opt pull --ff-only'
```

pull 完成后，在对应的 stack 中应用变更（详情见各 stack 的 README）：

- **推理相关 stack**（`vllm/`、`llama-cpp/`） —— `cd /opt/<stack> && make up ENV=<variant>` 以指定变体（重新）启动。
- **Traefik** —— 通过 Docker 标签或 `dynamic/*.yml` 文件所做的路由变更会热重载；只有当 `traefik.yml` 本身发生变化时才需要 `docker compose restart traefik`。
- **其他 stack** —— `cd /opt/<name> && docker compose up -d`。

git 之外的主机本地文件在 pull 之间保持不变 —— 每个 stack 的 `.env`（密钥）、推理相关的 `envs/*.env` 变体文件、TLS 材料（`*.crt`/`*.key`）以及 `*.bak` 备份，全部都在 gitignore 中。

## 管理 LLM 引擎

顶层的 [`Makefile`](Makefile)（主机上位于 `/opt/Makefile`）是对四个 LLM 服务的一层简单封装 —— 它**一次只操作一个引擎，绝不会影响其他引擎**：

```bash
make up engine=vllm ENV=<variant>    # 启动一个引擎
make up engine=llama-cpp             # ENV 留空的 llama-cpp = router 模式
make down engine=ollama              # 只停止这一个；其余保持运行
make list                            # 列出 vllm / llama-cpp 的模型变体
```

引擎包括 `vllm`、`llama-cpp`、`ollama`、`open-webui`。`up engine=vllm|llama-cpp` 会委托给该 stack 自己的 `make up`（因此 `ENV=` 的变体分层依然生效）；`ollama`/`open-webui` 则通过共享的 open-webui compose 项目处理。查看正在运行的容器用 `docker ps -a`；查看真正占用 GPU 的进程用 `nvidia-smi`。

vLLM（`--gpu-memory-utilization 0.9`）和 llama-cpp 的经典单模型模式（`-ngl 999`）都会主动、提前占用显存，因此无法与 GB10 上另一个同样"抢占式"的引擎共存；ollama 和 llama-cpp 的 router 模式则是"懒加载"的。Makefile 有意**不**强制处理这种取舍 —— 当你需要整块 GPU 时，请先执行 `make down engine=<other>`（一个"运行中"的容器不一定正占用 GPU）。

## 约定

- **镜像标签默认使用浮动版本，生产环境需固定版本。** 已提交的 `.env.example` 文件使用浮动标签（`latest`，或者像 Traefik 的稳定大版本线 `v2`，又或者 `ggml-org/llama.cpp` 的多架构浮动标签 `server-cuda`），这样新执行 `cp .env.example .env` 即可直接得到一个可用状态，无需查找当前发布版本。**生产部署时，请在主机本地的 `.env` 中覆盖为具体的、可复现的固定版本** —— 当镜像仓库发布了不可变标签时使用（`v2.11.X`、`v0.20.2`），或者在只有浮动标签可用时使用内容摘要固定（`server-cuda@sha256:…`）。每个服务的 `.env.example` 都在文件内展示了固定版本的格式。
- **推理相关配置按作用域拆分。** `<stack>/.env` 携带主机级的通用值（镜像固定版本、HF 缓存路径、HF token、默认参数）；`<stack>/envs/<name>.env` 只携带模型选择以及针对该变体的覆盖项。`make up ENV=<name>` 通过 `docker compose --env-file .env --env-file envs/<name>.env up -d` 将两者串联起来。两个文件都在 gitignore 中 —— 对应的模板以 `.env.example` 的形式保留在旁边。
- **推理相关 stack 的回环端口。** `vllm/` 与 `llama-cpp/` 还会将其 API 绑定到主机的 `127.0.0.1`，用于直接 curl / 基准测试 —— 局域网流量仍然通过代理转发。
- **权限。** `/opt/<stack>/` 属于 `root:root`。`.env` 文件为 `root:docker 640`，以便 `docker` 组用户可以读取并在无需 sudo 的情况下运行 compose。编辑配置需要 `sudo`。
- **供应链安全。** 每个第三方 Docker 镜像都在 `.env.example` 中以标签形式引用（首次启动为浮动版本以求方便；生产环境请在主机本地 `.env` 中固定版本）。每个 GitHub Action 都以 commit SHA 固定。Trivy 会在 push / PR / 每周定时任务中扫描；Dependabot 通过每周一个合并 PR 保持 SHA 固定版本的更新。

## 仓库维护

- [`CHANGELOG.md`](CHANGELOG.md) —— 遵循 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) 格式，[SemVer](https://semver.org/spec/v2.0.0.html) 版本号规范。
- [`.github/workflows/trivy.yml`](.github/workflows/trivy.yml) —— 镜像 CVE 扫描（HIGH+CRITICAL，仅限已有修复的漏洞）、IaC 配置扫描、文件系统层面的密钥扫描。文档见 [`.github/workflows/trivy.md`](.github/workflows/trivy.md)。
- [`.github/dependabot.yml`](.github/dependabot.yml) —— 每周一个合并 PR，用于更新固定的 GitHub Action SHA。
- [`docs/`](docs/) —— 各功能的设计/规划文档（例如 `docs/superpowers/specs/`、`docs/superpowers/plans/`，对应 llama-cpp router 模式相关工作）。
- [`README.md`](README.md)、[`README.es.md`](README.es.md)、[`README.ru.md`](README.ru.md) —— 本 README 的英文、西班牙语和俄语版本，通过 Logo 下方的语言切换行保持同步。
- [`LICENSE`](LICENSE) —— MIT。
- [`sparky.svg`](sparky.svg) —— 项目吉祥物，由参与构建本仓库的 AI 绘制，作为自画像。
