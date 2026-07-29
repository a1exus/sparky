# sparky

<p align="center">
  <img src="sparky.svg" alt="sparky" width="220" height="260">
</p>

<p align="center"><a href="README.md">English</a> | <b>Español</b></p>

Configuración para la estación de trabajo [NVIDIA DGX Spark](https://amzn.to/47ZeWqZ) `spark-1822` — un entorno LLM autoalojado en una sola máquina:

- **vLLM** y **llama.cpp** para inferencia (safetensors de HF y GGUF respectivamente, ambos acelerados por GPU en la GB10).
- **Open WebUI + Ollama** para la interfaz de chat.
- **Traefik** como proxy inverso HTTPS delante de todo (controlado por etiquetas de Docker, emite su propia CA interna).
- **Cloudflare Tunnel** para ingreso público solo de salida (sin puertos entrantes en el host).
- **Tailscale** como sidecar para ingreso exclusivo a la tailnet (peer-to-peer sobre WireGuard; sin DNS público, sin puertos públicos).
- **Netdata** para observabilidad en tiempo real.
- Ayudante **mDNS** que publica alias `<sub>.spark-1822.local` en la LAN.
- **Trivy** + **Dependabot** mantienen la cadena de suministro bajo control en CI.

## Topología

Tres rutas de ingreso hacia los mismos backends:

```
cliente LAN      ──(mDNS *.spark-1822.local)──>  traefik :80/:443  ──>  backend
cliente público  ──(DNS, borde de Cloudflare)──>  cloudflared ──>  traefik :80  ──>  backend
cliente tailnet  ──(MagicDNS, WireGuard)──>  tailscale :443  ──>  traefik :80  ──>  backend
```

Los backends (`vllm`, `llama-cpp`, `open-webui`, `ollama`) están todos en una única red Docker compartida llamada `traefik` — definida por el stack `traefik/`, a la que todos los demás se unen como `external: true`. El proxy activo y ambos conectores de túnel/sidecar se conectan a esa misma red y llaman directamente a los contenedores por nombre. `netdata` es la excepción: se ejecuta con `network_mode: host` (necesario para la telemetría a nivel de PID/proc del host), por lo que no tiene un endpoint en la red `traefik` — Traefik lo alcanza mediante una ruta estática a `host.docker.internal:19999` en `traefik/dynamic/services.yml` en lugar de DNS por nombre de contenedor.

El TLS proviene de tres raíces distintas: Traefik emite su propia CA interna (los clientes instalan `traefik-root.crt` una sola vez); Cloudflare provee certificados de confianza pública en su borde para los hostnames del túnel; Tailscale aprovisiona automáticamente certificados MagicDNS de confianza pública para el hostname de la tailnet.

## Estructura

```
.
├── traefik/       # Proxy inverso HTTPS (controlado por etiquetas de Docker)
├── cloudflare/    # Conector de Cloudflare Tunnel — ingreso público
├── tailscale/     # Sidecar de Tailscale — ingreso a la tailnet
├── vllm/          # Servidor de inferencia vLLM (safetensors de HF)
├── llama-cpp/     # Servidor de inferencia llama.cpp (GGUF)
├── open-webui/    # Open WebUI + Ollama (interfaz de chat)
├── netdata/       # Observabilidad en tiempo real
├── mdns/          # Ayudante de alias mDNS del lado del host
├── docs/          # Documentos de diseño/planificación (p. ej. la spec del modo router de llama-cpp)
├── .github/       # CI: workflow de Trivy + configuración de Dependabot
├── Makefile       # Control de motores LLM de nivel superior (up / down / list)
├── sparky.svg     # Logo del proyecto (autorretrato de la IA)
├── CHANGELOG.md
├── LICENSE
└── README.md
```

Cada stack tiene su propio `README.md` — empieza ahí para detalles de despliegue / configuración / actualización.

## Componentes

| Stack | Rol | URL en la LAN |
|---|---|---|
| [`traefik/`](traefik/) | Proxy inverso HTTPS, controlado por etiquetas de Docker, emite su propia CA interna | publica `:80`/`:443` |
| [`cloudflare/`](cloudflare/) | Conector de Cloudflare Tunnel — ingreso público solo de salida | configurable por hostname en el panel de CF |
| [`tailscale/`](tailscale/) | Sidecar de Tailscale — ingreso exclusivo a la tailnet sobre WireGuard, overlay opcional de Serve delante de `traefik` | `https://spark-1822.<tailnet>.ts.net` |
| [`vllm/`](vllm/) | Servidor de inferencia vLLM (safetensors de HF), con tool-calling habilitado (`qwen3_xml`) | `https://vllm.spark-1822.local` |
| [`llama-cpp/`](llama-cpp/) | Servidor de inferencia llama.cpp acelerado por GPU (GGUF). El modo router (por defecto) sirve bajo demanda cada GGUF de la caché de HF; también se admite el modo clásico de un solo modelo. API compatible con OpenAI + interfaz web | `https://llama.spark-1822.local` |
| [`open-webui/`](open-webui/) | Open WebUI + Ollama (GPU solo en Ollama) | `https://open-webui.spark-1822.local`, `https://ollama.spark-1822.local` |
| [`netdata/`](netdata/) | Telemetría en tiempo real de host + contenedores | `https://netdata.spark-1822.local` |
| [`mdns/`](mdns/) | Plantilla systemd del host que publica alias mDNS `<sub>.spark-1822.local` | a nivel de host |

## Host

| | |
|---|---|
| Hardware | [NVIDIA DGX Spark](https://amzn.to/47ZeWqZ) |
| Hostname | `spark-1822.local` |
| SO | Ubuntu (kernel `6.17.0-nvidia`), aarch64 |
| GPU | NVIDIA GB10 (capacidad de cómputo 12.1, 124 GiB de VRAM) |
| Docker | 29.x + Compose v2 |
| Runtime de GPU | `nvidia-container-toolkit` 1.19 (modo CDI) |

## Configuración inicial

En un host nuevo, en este orden:

1. **Instala el ayudante mDNS** (del lado del host; publica alias `<sub>.spark-1822.local`):

   ```bash
   cd /opt/mdns && make install
   ```

2. **Levanta el proxy inverso** — esto también crea la red Docker `traefik` compartida a la que se unen todos los demás:

   ```bash
   cd /opt/traefik
   cp .env.example .env             # luego define TRAEFIK_TAG
   make ca-cert                     # una sola vez: emite la CA raíz interna de Traefik
   make wildcard-cert               # emite el certificado hoja wildcard firmado por esa raíz
   docker compose up -d
   ```

   Instala `traefik/certs/traefik-root.crt` en cada cliente que deba confiar en las URLs LAN del host (tabla de instalación por SO en [`traefik/README.md`](traefik/README.md)).

3. **Publica un alias mDNS para cada subdominio** que vayas a exponer:

   ```bash
   cd /opt/mdns
   for a in traefik vllm llama ollama open-webui netdata; do make add ALIAS=$a; done
   ```

4. **Levanta los servicios** — cada uno se conecta a la red `traefik` y Traefik enruta automáticamente vía las etiquetas `traefik.*` de su compose:

   ```bash
   cd /opt/open-webui && cp .env.example .env && docker compose up -d
   cd /opt/netdata    && cp .env.example .env && docker compose up -d
   cd /opt/vllm       && make up ENV=<variante>      # ver vllm/envs/
   cd /opt/llama-cpp  && make up ENV=<variante>      # ver llama-cpp/envs/
   ```

5. **(Opcional) Ingreso público vía Cloudflare Tunnel** — solo si quieres URLs alcanzables desde internet:

   ```bash
   cd /opt/cloudflare
   cp .env.example .env             # pega CLOUDFLARE_TUNNEL_TOKEN desde el panel de CF
   docker compose up -d
   ```

   Luego configura los Public Hostnames en el panel de Cloudflare para que reenvíen a `http://traefik:80` con el encabezado Host interno correspondiente (receta en [`cloudflare/README.md`](cloudflare/README.md)).

6. **(Opcional) Ingreso a la tailnet vía Tailscale** — solo si quieres que este host sea alcanzable desde tu tailnet:

   ```bash
   cd /opt/tailscale
   cp .env.example .env             # pega TS_AUTHKEY desde la consola de administración de Tailscale
   docker compose up -d
   ```

   El nodo se registra como `spark-1822.<tailnet>.ts.net` con un certificado MagicDNS real de confianza pública; Tailscale Serve conecta `:80`/`:443` en la tailnet con Traefik. Para URLs de tailnet por backend (`https://vllm.<tailnet>.ts.net`, `https://traefik.<tailnet>.ts.net`, …), crea un [Tailscale VIP Service](https://tailscale.com/kb/1417/services) por backend y aplícalo con `make -C /opt/tailscale services-apply` — ver [`tailscale/README.md`](tailscale/README.md) para la guía completa.

## Flujo de despliegue

`/opt` en el host **es** un checkout de este repo — cada stack vive en su lugar en `/opt/<nombre>/`. Edita localmente, haz commit, push; luego haz pull en el host:

```bash
ssh spark-1822.local 'sudo git -C /opt pull --ff-only'
```

Después del pull, aplica el cambio en el stack correspondiente (cada README de stack tiene los detalles):

- **Stacks de inferencia** (`vllm/`, `llama-cpp/`) — `cd /opt/<stack> && make up ENV=<variante>` para (re)iniciar con una variante.
- **Traefik** — los cambios de enrutamiento vía etiquetas de Docker o archivos `dynamic/*.yml` se recargan en caliente; `docker compose restart traefik` solo si cambió `traefik.yml` en sí.
- **Otros stacks** — `cd /opt/<nombre> && docker compose up -d`.

Los archivos locales del host fuera de git se mantienen intactos entre pulls — el `.env` de cada stack (secretos), las variantes `envs/*.env` de inferencia, el material TLS (`*.crt`/`*.key`) y las copias de seguridad `*.bak` están todos en gitignore.

## Gestión de los motores LLM

El [`Makefile`](Makefile) de nivel superior (en `/opt/Makefile` en el host) es un envoltorio simple sobre los cuatro servicios LLM — actúa sobre **un motor a la vez y nunca toca a los demás**:

```bash
make up engine=vllm ENV=<variante>   # inicia un motor
make up engine=llama-cpp             # llama-cpp con ENV vacío = modo router
make down engine=ollama              # detiene solo ese; los demás siguen corriendo
make list                            # variantes de modelo para vllm / llama-cpp
```

Los motores son `vllm`, `llama-cpp`, `ollama`, `open-webui`. `up engine=vllm|llama-cpp` delega en el `make up` propio de ese stack (así que la capa de variantes `ENV=` sigue aplicando); `ollama`/`open-webui` pasan por el proyecto compose compartido de open-webui. Para ver qué está corriendo usa `docker ps -a`; para ver qué está realmente en la GPU usa `nvidia-smi`.

vLLM (`--gpu-memory-utilization 0.9`) y el modo clásico de un solo modelo de llama-cpp (`-ngl 999`) reclaman VRAM de forma anticipada y no pueden coexistir con otro motor anticipado en la GB10; ollama y el modo router de llama-cpp son perezosos (lazy). El Makefile deliberadamente **no** impone ese compromiso — ejecuta `make down engine=<otro>` primero cuando necesites toda la GPU (un contenedor "en ejecución" no está necesariamente en la GPU).

## Convenciones

- **Las etiquetas de imagen flotan por defecto, se fijan en producción.** Los archivos `.env.example` versionados usan etiquetas flotantes (`latest`, o una línea mayor estable como `v2` para Traefik, o la etiqueta flotante multi-arquitectura `server-cuda` para `ggml-org/llama.cpp`) para que un `cp .env.example .env` recién hecho arranque en un estado funcional sin que nadie tenga que buscar la versión actual. **Para despliegues en producción, sobrescribe en tu `.env` local del host con un pin específico y reproducible** — una etiqueta inmutable (`v2.11.X`, `v0.20.2`) cuando el registro la publica, o un pin por digest de contenido (`server-cuda@sha256:…`) cuando solo existen etiquetas flotantes. Cada `.env.example` por servicio muestra el formato del pin en línea.
- **La configuración de inferencia se divide** por alcance. `<stack>/.env` lleva los valores generales del host (pin de imagen, ruta de caché de HF, token de HF, parámetros por defecto); `<stack>/envs/<nombre>.env` lleva solo la selección de modelo más los overrides por variante. `make up ENV=<nombre>` encadena ambos vía `docker compose --env-file .env --env-file envs/<nombre>.env up -d`. Ambos archivos están en gitignore — las plantillas viven junto a ellos como `.env.example`.
- **Puertos loopback en los stacks de inferencia.** `vllm/` y `llama-cpp/` además exponen su API en `127.0.0.1` en el host para curl / benchmarking directo — el tráfico de la LAN sigue pasando por el proxy.
- **Permisos.** `/opt/<stack>/` es `root:root`. Los archivos `.env` son `root:docker 640` para que el usuario del grupo `docker` pueda leerlos y ejecutar compose sin sudo. Editar configuraciones requiere `sudo`.
- **Cadena de suministro.** Cada imagen Docker de terceros se referencia por etiqueta en `.env.example` (flotante para conveniencia del primer arranque; fijada en tu `.env` local del host para producción). Cada GitHub Action está fijada por SHA de commit. Trivy escanea en push / PR / cron semanal; Dependabot mantiene los pines de SHA actualizados con un PR agrupado semanal.

## Mantenimiento del repositorio

- [`CHANGELOG.md`](CHANGELOG.md) — formato [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versionado [SemVer](https://semver.org/spec/v2.0.0.html).
- [`.github/workflows/trivy.yml`](.github/workflows/trivy.yml) — escaneo de CVEs de imágenes (HIGH+CRITICAL, solo con fix disponible), escaneo de configuración IaC, escaneo de secretos del filesystem. Doc: [`.github/workflows/trivy.md`](.github/workflows/trivy.md).
- [`.github/dependabot.yml`](.github/dependabot.yml) — PR agrupado semanal para actualizar los pines de SHA de GitHub Actions.
- [`docs/`](docs/) — documentos de diseño/planificación para funcionalidades concretas (p. ej. `docs/superpowers/specs/`, `docs/superpowers/plans/` para el trabajo del modo router de llama-cpp).
- [`LICENSE`](LICENSE) — MIT.
- [`sparky.svg`](sparky.svg) — mascota del proyecto. Dibujada por la IA que ayudó a construir este repo, como autorretrato.

---

Gracias a [@webbrain-one](https://github.com/webbrain-one) por proponer una versión en español de este README ([PR #21](https://github.com/a1exus/sparky/pull/21)).
