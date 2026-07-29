# sparky

<p align="center">
  <img src="sparky.svg" alt="sparky" width="220" height="260">
</p>

Configuración para la estación de trabajo [NVIDIA DGX Spark](https://amzn.to/47ZeWqZ) `spark-1822` — una configuración de LLM auto-alojada en una sola caja:

- **vLLM** y **llama.cpp** para inferencia (safetensors de HF y GGUF respectivamente, ambos acelerados por GPU en la GB10).
- **Open WebUI + Ollama** para la interfaz de chat.
- **Traefik** como proxy inverso HTTPS frente a todo (impulsado por etiquetas de docker, emite su propia CA interna).
- **Cloudflare Tunnel** para ingreso público solo saliente (sin puertos entrantes en el host).
- **Tailscale** sidecar para ingreso exclusivo de tailnet (peer-to-peer sobre WireGuard; sin DNS público, sin puertos públicos).
- **Netdata** para observabilidad en tiempo real.
- **mDNS** helper que publica alias `<sub>.spark-1822.local` en la LAN.
- **Trivy** + **Dependabot** mantienen la integridad de la cadena de suministro en la CI.

## Topología

Tres rutas de ingreso hacia los mismos backends:

```
cliente LAN      ──(mDNS *.spark-1822.local)──>  traefik :80/:443  ──>  backend
cliente público  ──(DNS, Cloudflare edge)──>  cloudflared ──>  traefik :80  ──>  backend
cliente tailnet  ──(MagicDNS, WireGuard)──>  tailscale :443  ──>  traefik :80  ──>  backend
```

Los backends (`vllm`, `llama-cpp`, `open-webui`, `ollama`, `netdata`) residen en una única red Docker compartida llamada `traefik` — definida por el stack `traefik/`, y unida como `external: true` por todos los demás. El proxy activo y los conectores de tunnel/sidecar se conectan a la misma red y marcan los nombres de los contenedores directamente.

El TLS proviene de tres raíces diferentes: Traefik emite su propia CA interna (los clientes instalan `traefik-root.crt` una vez); Cloudflare proporciona certificados de confianza pública en su edge para los hostnames del tunnel; Tailscale provisiona automáticamente certificados MagicDNS de confianza pública para el hostname de la tailnet.

## Estructura

```
.
├── traefik/       # Proxy inverso HTTPS (impulsado por etiquetas de docker)
├── cloudflare/    # Conector de Cloudflare Tunnel — ingreso público
├── tailscale/     # Sidecar de Tailscale — ingreso de tailnet
├── vllm/          # Servidor de inferencia vLLM (HF safetensors)
├── llama-cpp/     # Servidor de inferencia llama.cpp (GGUF)
├── open-webui/    # Open WebUI + Ollama (chat UI)
├── netdata/       # Observabilidad en tiempo real
├── mdns/          # Helper de alias mDNS del lado del host
├── .github/       # CI: Workflow de Trivy + config de Dependabot
├── Makefile       # Control de motores LLM de nivel superior (up / down / list)
├── sparky.svg     # Logo del proyecto (autorretrato de IA)
├── CHANGELOG.md
├── LICENSE
└── README.md
```

Cada stack tiene su propio `README.md` — comience por ahí para detalles de despliegue / configuración / actualización.

## Componentes

| Stack | Rol | URL en LAN |
|---|---|---|
| [`traefik/`](traefik/) | Proxy inverso HTTPS, impulsado por etiquetas de docker, emite su propia CA interna | publica `:80`/`:443` |
| [`cloudflare/`](cloudflare/) | Conector de Cloudflare Tunnel — ingreso público solo saliente | configurable por hostname en el panel de CF |
| [`tailscale/`](tailscale/) | Sidecar de Tailscale — ingreso exclusivo de tailnet sobre WireGuard, overlay Serve opcional frente a `traefik` | `https://spark-1822.<tailnet>.ts.net` |
| [`vllm/`](vllm/) | Servidor de inferencia vLLM (HF safetensors), tool-calling habilitado (`qwen3_xml`) | `https://vllm.spark-1822.local` |
| [`llama-cpp/`](llama-cpp/) | Servidor de inferencia llama.cpp acelerado por GPU (GGUF). El modo Router (por defecto) sirve cada GGUF en el caché de HF bajo demanda; también se soporta el modo clásico de modelo único. API compatible con OpenAI + web UI | `https://llama.spark-1822.local` |
| [`open-webui/`](open-webui/) | Open WebUI + Ollama (GPU solo en Ollama) | `https://open-webui.spark-1822.local`, `https://ollama.spark-1822.local` |
| [`netdata/`](netdata/) | Telemetría de host + contenedores en tiempo real | `https://netdata.spark-1822.local` |
| [`mdns/`](mdns/) | Plantilla de systemd del host que publica alias mDNS `<sub>.spark-1822.local` | nivel de host |

## Host

| | |
|---|---|
| Hardware | [NVIDIA DGX Spark](https://amzn.to/47ZeWqZ) |
| Hostname | `spark-1822.local` |
| SO | Ubuntu (kernel `6.17.0-nvidia`), aarch64 |
| GPU | NVIDIA GB10 (compute capability 12.1, 124 GiB VRAM) |
| Docker | 29.x + Compose v2 |
| GPU runtime | `nvidia-container-toolkit` 1.19 (modo CDI) |

## Configuración inicial

En un host nuevo, en orden:

1. **Instalar el helper de mDNS** (lado del host; publica alias `<sub>.spark-1822.local`):

   ```bash
   cd /opt/mdns && make install
   ```

2. **Levantar el proxy inverso** — esto también crea la red Docker compartida `traefik` a la que se unen todos los demás:

   ```bash
   cd /opt/traefik
   cp .env.example .env             # luego definir TRAEFIK_TAG
   make ca-cert                     # una sola vez: emitir la CA raíz interna de Traefik
   make wildcard-cert               # emitir el certificado wildcard firmado por esa raíz
   docker compose up -d
   ```

   Instale `traefik/certs/traefik-root.crt` en cada cliente que deba confiar en las URLs de la LAN del host (tabla de instalación por SO en [`traefik/README.md`](traefik/README.md)).

3. **Publicar un alias mDNS para cada subdominio** que vaya a exponer:

   ```bash
   cd /opt/mdns
   for a in traefik vllm llama ollama open-webui netdata; do make add ALIAS=$a; done
   ```

4. **Levantar los servicios** — cada uno se conecta a la red `traefik` y Traefik enruta automáticamente a través de las etiquetas `traefik.*` en su compose:

   ```bash
   cd /opt/open-webui && cp .env.example .env && docker compose up -d
   cd /opt/netdata    && cp .env.example .env && docker compose up -d
   cd /opt/vllm       && make up ENV=<variant>      # ver vllm/envs/
   cd /opt/llama-cpp  && make up ENV=<variant>      # ver llama-cpp/envs/
   ```

5. **(Opcional) Ingreso público vía Cloudflare Tunnel** — solo si desea URLs accesibles desde internet:

   ```bash
   cd /opt/cloudflare
   cp .env.example .env             # pegar CLOUDFLARE_TUNNEL_TOKEN desde el panel de CF
   docker compose up -d
   ```

   Luego configure los Hostnames Públicos en el panel de Cloudflare para que redirijan a `http://traefik:80` con el encabezado Host interno correspondiente (receta en [`cloudflare/README.md`](cloudflare/README.md)).

6. **(Opcional) Ingreso de Tailnet vía Tailscale** — solo si desea que este host sea accesible desde su tailnet:

   ```bash
   cd /opt/tailscale
   cp .env.example .env             # pegar TS_AUTHKEY desde la consola de administración de Tailscale
   docker compose up -d
   ```

   El nodo se registra como `spark-1822.<tailnet>.ts.net` con un certificado MagicDNS real de confianza pública; Tailscale Serve conecta `:80`/`:443` en la tailnet con Traefik. Para URLs de tailnet por backend (`https://vllm.<tailnet>.ts.net`, `https://traefik.<tailnet>.ts.net`, ...), cree un [Tailscale VIP Service](https://tailscale.com/kb/1417/services) por backend y aplíquelo vía `make -C /opt/tailscale services-apply` — vea [`tailscale/README.md`](tailscale/README.md) para la guía completa.

## Flujo de despliegue

`/opt` en el host **es** un checkout de este repositorio — cada stack reside en `/opt/<nombre>/`. Edite localmente, haga commit, push; luego haga pull en el host:

```bash
ssh spark-1822.local 'sudo git -C /opt pull --ff-only'
```

Después del pull, aplique el cambio en el stack correspondiente (el README de cada stack tiene los detalles):

- **Stacks de inferencia** (`vllm/`, `llama-cpp/`) — `cd /opt/<stack> && make up ENV=<variant>` para (re)iniciar con una variante.
- **Traefik** — los cambios de enrutamiento vía etiquetas de Docker o archivos `dynamic/*.yml` se recargan en caliente; `docker compose restart traefik` solo si el archivo `traefik.yml` cambió.
- **Otros stacks** — `cd /opt/<nombre> && docker compose up -d`.

Los archivos locales del host fuera de git permanecen intactos entre pulls — el archivo `.env` de cada stack (secretos), las variantes de inferencia `envs/*.env`, el material TLS (`*.crt`/`*.key`) y los respaldos `*.bak` están todos en el .gitignore.

## Gestión de los motores LLM

El [`Makefile`](Makefile) de nivel superior (en `/opt/Makefile` en el host) es un envoltorio ligero sobre los cuatro servicios LLM — actúa sobre **un motor a la vez y nunca toca los demás**:

```bash
make up engine=vllm ENV=<variant>    # iniciar un motor
make up engine=llama-cpp             # llama-cpp con ENV vacío = modo router
make down engine=ollama              # detener solo ese; el resto sigue ejecutándose
make list                            # variantes de modelos para vllm / llama-cpp
```

Los motores son `vllm`, `llama-cpp`, `ollama`, `open-webui`. `up engine=vllm|llama-cpp` delega en el `make up` de ese stack (por lo que el capas de variantes `ENV=` sigue aplicando); `ollama`/`open-webui` pasan por el proyecto compose compartido de open-webui. Para ver qué se está ejecutando use `docker ps -a`; para ver qué está realmente en la GPU use `nvidia-smi`.

vLLM (`--gpu-memory-utilization 0.9`) y llama-cpp en modo clásico de modelo único (`-ngl 999`) reclaman la VRAM ávidamente y no pueden coexistir con otro motor ávido en la GB10; ollama y llama-cpp en modo router son perezosos. El Makefile deliberadamente **no** impone ese compromiso — ejecute `make down engine=<otro>` primero cuando necesite toda la GPU (un contenedor "ejecutándose" no necesariamente está en la GPU).

## Convenciones

- **Las etiquetas de imagen flotan por defecto, fíjelas en producción.** Los archivos `.env.example` comprometidos usan etiquetas flotantes (`latest`, o una línea mayor estable como `v2` para Traefik, o la etiqueta flotante multi-arquitectura `server-cuda` para `ggml-org/llama.cpp`) para que un `cp .env.example .env` fresco arranque a un estado funcional sin tener que buscar la versión actual. **Para despliegues de producción, anule en su `.env` local del host con un anclaje específico y reproducible** — una etiqueta inmutable (`v2.11.X`, `v0.20.2`) cuando el registro publique una, o un anclaje por digest de contenido (`server-cuda@sha256:…`) cuando solo existan etiquetas flotantes. Cada `.env.example` por servicio muestra el formato de anclaje en línea.
- **Configuración de inferencia dividida** por alcance. `<stack>/.env` lleva valores globales del host (anclaje de imagen, ruta de caché de HF, token de HF, ajustes predeterminados); `<stack>/envs/<name>.env` lleva solo la selección del modelo más las anulaciones por variante. `make up ENV=<name>` encadena ambos vía `docker compose --env-file .env --env-file envs/<name>.env up -d`. Ambos archivos están en el .gitignore — las plantillas viven junto a ellos como `.env.example`.
- **Puertos de loopback en stacks de inferencia.** `vllm/` y `llama-cpp/` vinculan adicionalmente su API a `127.0.0.1` en el host para curl directos / benchmarking — el tráfico de la LAN sigue fluyendo a través del proxy.
- **Permisos.** `/opt/<stack>/` es `root:root`. Los archivos `.env` son `root:docker 640` para que el usuario del grupo `docker` los lea y ejecute compose sin sudo. Editar configuraciones requiere `sudo`.
- **Cadena de suministro.** Cada imagen de Docker de terceros se referencia por etiqueta en `.env.example` (flotante para conveniencia del primer arranque; fíjela en su `.env` local para producción). Cada GitHub Action está fijada por commit SHA. Trivy escanea en push / PR / cron semanal; Dependabot mantiene los anclajes SHA actualizados con un PR agrupado semanal.

## Mantenimiento del Repo

- [`CHANGELOG.md`](CHANGELOG.md) — formato [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versionado [SemVer](https://semver.org/spec/v2.0.0.html).
- [`.github/workflows/trivy.yml`](.github/workflows/trivy.yml) — escaneos de CVE de imagen (HIGH+CRITICAL, solo corregidos), escaneo de config IaC, escaneo de secretos en el sistema de archivos. Doc: [`.github/workflows/trivy.md`](.github/workflows/trivy.md).
- [`.github/dependabot.yml`](.github/dependabot.yml) — PR agrupado semanal para actualizar los SHAs fijados de GitHub Action.
- [`LICENSE`](LICENSE) — MIT.
- [`sparky.svg`](sparky.svg) — mascota del proyecto. Dibujada por la IA que ayudó a construir este repo, como un autorretrato.
