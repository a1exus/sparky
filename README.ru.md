# sparky

<p align="center">
  <img src="sparky.svg" alt="sparky" width="220" height="260">
</p>

<p align="center"><a href="README.md">English</a> | <a href="README.es.md">Español</a> | <b>Русский</b> | <a href="README.zh.md">中文</a></p>

Конфигурация для рабочей станции [NVIDIA DGX Spark](https://amzn.to/47ZeWqZ) `spark-1822` — самостоятельно размещённая LLM-инфраструктура на одной машине:

- **vLLM** и **llama.cpp** для инференса (safetensors от HF и GGUF соответственно, оба с ускорением на GPU GB10).
- **Open WebUI + Ollama** для интерфейса чата.
- **Traefik** в качестве HTTPS-реверс-прокси перед всем остальным (управляется метками Docker, выпускает собственный внутренний CA).
- **Cloudflare Tunnel** для публичного входящего трафика только через исходящее соединение (никаких открытых портов на хосте).
- **Tailscale**-сайдкар для входа только через tailnet (peer-to-peer поверх WireGuard; без публичного DNS, без публичных портов).
- **Netdata** для наблюдаемости в реальном времени.
- Помощник **mDNS**, публикующий алиасы `<sub>.spark-1822.local` в локальной сети.
- **Trivy** + **Dependabot** следят за цепочкой поставок в CI.

## Топология

Три пути входящего трафика к одним и тем же бэкендам:

```
клиент LAN      ──(mDNS *.spark-1822.local)──>  traefik :80/:443  ──>  бэкенд
публичный клиент ──(DNS, edge Cloudflare)──>  cloudflared ──>  traefik :80  ──>  бэкенд
клиент tailnet  ──(MagicDNS, WireGuard)──>  tailscale :443  ──>  traefik :80  ──>  бэкенд
```

Бэкенды (`vllm`, `llama-cpp`, `open-webui`, `ollama`) находятся в единой общей Docker-сети `traefik` — определённой стеком `traefik/`, к которой все остальные подключаются как `external: true`. Активный прокси и оба коннектора туннеля/сайдкара подключаются к той же сети и обращаются к контейнерам напрямую по имени. `netdata` — исключение: он работает с `network_mode: host` (необходимо для телеметрии на уровне PID/proc хоста), поэтому у него нет endpoint'а в сети `traefik` — Traefik обращается к нему через статический маршрут на `host.docker.internal:19999` в `traefik/dynamic/services.yml`, а не через DNS по имени контейнера.

TLS происходит из трёх разных корней: Traefik выпускает собственный внутренний CA (клиенты один раз устанавливают `traefik-root.crt`); Cloudflare предоставляет публично доверенные сертификаты на своём edge для хостнеймов туннеля; Tailscale автоматически выпускает публично доверенные сертификаты MagicDNS для хостнейма tailnet.

## Структура

```
.
├── traefik/       # HTTPS реверс-прокси (управляется метками Docker)
├── cloudflare/    # Коннектор Cloudflare Tunnel — публичный вход
├── tailscale/     # Сайдкар Tailscale — вход через tailnet
├── vllm/          # Сервер инференса vLLM (safetensors от HF)
├── llama-cpp/     # Сервер инференса llama.cpp (GGUF)
├── open-webui/    # Open WebUI + Ollama (интерфейс чата)
├── netdata/       # Наблюдаемость в реальном времени
├── mdns/          # Помощник алиасов mDNS на стороне хоста
├── docs/          # Документы по дизайну/планированию (напр. спецификация режима router для llama-cpp)
├── .github/       # CI: workflow Trivy + конфигурация Dependabot
├── Makefile       # Управление LLM-движками верхнего уровня (up / down / list)
├── sparky.svg     # Логотип проекта (автопортрет ИИ)
├── CHANGELOG.md
├── LICENSE
├── README.md
├── README.es.md   # Перевод на испанский
├── README.ru.md   # Перевод на русский
└── README.zh.md   # Перевод на упрощённый китайский
```

У каждого стека есть свой `README.md` — начните оттуда для деталей развёртывания / настройки / обновления.

## Компоненты

| Стек | Роль | URL в локальной сети |
|---|---|---|
| [`traefik/`](traefik/) | HTTPS реверс-прокси, управляется метками Docker, выпускает собственный внутренний CA | публикует `:80`/`:443` |
| [`cloudflare/`](cloudflare/) | Коннектор Cloudflare Tunnel — публичный вход только через исходящее соединение | настраивается по хостнейму в панели CF |
| [`tailscale/`](tailscale/) | Сайдкар Tailscale — вход только через tailnet поверх WireGuard, опциональный оверлей Serve перед `traefik` | `https://spark-1822.<tailnet>.ts.net` |
| [`vllm/`](vllm/) | Сервер инференса vLLM (safetensors от HF), с поддержкой вызова инструментов (`qwen3_xml`) | `https://vllm.spark-1822.local` |
| [`llama-cpp/`](llama-cpp/) | Сервер инференса llama.cpp с ускорением GPU (GGUF). Режим router (по умолчанию) отдаёт по запросу любой GGUF из кэша HF; также поддерживается классический режим с одной моделью. API, совместимый с OpenAI, + веб-интерфейс | `https://llama.spark-1822.local` |
| [`open-webui/`](open-webui/) | Open WebUI + Ollama (GPU только у Ollama) | `https://open-webui.spark-1822.local`, `https://ollama.spark-1822.local` |
| [`netdata/`](netdata/) | Телеметрия хоста и контейнеров в реальном времени | `https://netdata.spark-1822.local` |
| [`mdns/`](mdns/) | Шаблон systemd на хосте, публикующий алиасы mDNS `<sub>.spark-1822.local` | уровень хоста |

## Хост

| | |
|---|---|
| Оборудование | [NVIDIA DGX Spark](https://amzn.to/47ZeWqZ) |
| Hostname | `spark-1822.local` |
| ОС | Ubuntu (ядро `6.17.0-nvidia`), aarch64 |
| GPU | NVIDIA GB10 (compute capability 12.1, 124 ГиБ VRAM) |
| Docker | 29.x + Compose v2 |
| GPU runtime | `nvidia-container-toolkit` 1.19 (режим CDI) |

## Первоначальная настройка

На новом хосте, по порядку:

1. **Установите помощник mDNS** (на стороне хоста; публикует алиасы `<sub>.spark-1822.local`):

   ```bash
   cd /opt/mdns && make install
   ```

2. **Поднимите реверс-прокси** — это также создаёт общую Docker-сеть `traefik`, к которой подключается всё остальное:

   ```bash
   cd /opt/traefik
   cp .env.example .env             # затем задайте TRAEFIK_TAG
   make ca-cert                     # один раз: выпустить внутренний корневой CA Traefik
   make wildcard-cert               # выпустить wildcard-сертификат, подписанный этим корнем
   docker compose up -d
   ```

   Установите `traefik/certs/traefik-root.crt` на каждом клиенте, который должен доверять LAN-URL хоста (таблица установки по ОС в [`traefik/README.md`](traefik/README.md)).

3. **Опубликуйте алиас mDNS для каждого поддомена**, который вы хотите открыть:

   ```bash
   cd /opt/mdns
   for a in traefik vllm llama ollama open-webui netdata; do make add ALIAS=$a; done
   ```

4. **Поднимите сервисы** — каждый подключается к сети `traefik`, а Traefik автоматически маршрутизирует через метки `traefik.*` в его compose-файле:

   ```bash
   cd /opt/open-webui && cp .env.example .env && docker compose up -d
   cd /opt/netdata    && cp .env.example .env && docker compose up -d
   cd /opt/vllm       && make up ENV=<вариант>      # см. vllm/envs/
   cd /opt/llama-cpp  && make up ENV=<вариант>      # см. llama-cpp/envs/
   ```

5. **(Опционально) Публичный вход через Cloudflare Tunnel** — только если нужны URL, доступные из интернета:

   ```bash
   cd /opt/cloudflare
   cp .env.example .env             # вставьте CLOUDFLARE_TUNNEL_TOKEN из панели CF
   docker compose up -d
   ```

   Затем настройте Public Hostnames в панели Cloudflare так, чтобы они перенаправляли на `http://traefik:80` с соответствующим внутренним заголовком Host (рецепт в [`cloudflare/README.md`](cloudflare/README.md)).

6. **(Опционально) Вход через tailnet с Tailscale** — только если нужно, чтобы этот хост был доступен из вашей tailnet:

   ```bash
   cd /opt/tailscale
   cp .env.example .env             # вставьте TS_AUTHKEY из консоли администрирования Tailscale
   docker compose up -d
   ```

   Узел регистрируется как `spark-1822.<tailnet>.ts.net` с настоящим публично доверенным сертификатом MagicDNS; Tailscale Serve связывает `:80`/`:443` в tailnet с Traefik. Для URL по каждому бэкенду в tailnet (`https://vllm.<tailnet>.ts.net`, `https://traefik.<tailnet>.ts.net`, …) создайте по одному [Tailscale VIP Service](https://tailscale.com/kb/1417/services) на бэкенд и примените через `make -C /opt/tailscale services-apply` — полное руководство в [`tailscale/README.md`](tailscale/README.md).

## Процесс развёртывания

`/opt` на хосте **является** копией этого репозитория — каждый стек находится на своём месте в `/opt/<имя>/`. Редактируйте локально, делайте commit, push; затем делайте pull на хосте:

```bash
ssh spark-1822.local 'sudo git -C /opt pull --ff-only'
```

После pull примените изменение в соответствующем стеке (детали в README каждого стека):

- **Стеки инференса** (`vllm/`, `llama-cpp/`) — `cd /opt/<стек> && make up ENV=<вариант>` для (пере)запуска с вариантом.
- **Traefik** — изменения маршрутизации через метки Docker или файлы `dynamic/*.yml` подхватываются на лету; `docker compose restart traefik` нужен только если изменился сам `traefik.yml`.
- **Остальные стеки** — `cd /opt/<имя> && docker compose up -d`.

Локальные файлы хоста вне git остаются на месте между pull — `.env` каждого стека (секреты), варианты инференса `envs/*.env`, материал TLS (`*.crt`/`*.key`) и резервные копии `*.bak` — всё в gitignore.

## Управление LLM-движками

Верхнеуровневый [`Makefile`](Makefile) (на хосте — `/opt/Makefile`) — это тонкая обёртка над четырьмя LLM-сервисами — он действует **на одном движке за раз и никогда не трогает остальные**:

```bash
make up engine=vllm ENV=<вариант>    # запустить один движок
make up engine=llama-cpp             # llama-cpp с пустым ENV = режим router
make down engine=ollama              # остановить только его; остальные продолжают работать
make list                            # варианты моделей для vllm / llama-cpp
```

Движки: `vllm`, `llama-cpp`, `ollama`, `open-webui`. `up engine=vllm|llama-cpp` делегирует собственному `make up` этого стека (так что слои вариантов `ENV=` по-прежнему применяются); `ollama`/`open-webui` идут через общий compose-проект open-webui. Чтобы узнать, что запущено, используйте `docker ps -a`; чтобы узнать, что реально на GPU — `nvidia-smi`.

vLLM (`--gpu-memory-utilization 0.9`) и классический однмодельный режим llama-cpp (`-ngl 999`) захватывают VRAM заранее и не могут сосуществовать с другим таким же "жадным" движком на GB10; ollama и режим router llama-cpp — "ленивые" (lazy). Makefile намеренно **не** навязывает этот компромисс — сначала выполните `make down engine=<другой>`, когда вам нужен весь GPU (контейнер в статусе "running" не обязательно находится на GPU).

## Соглашения

- **Теги образов по умолчанию плавающие, в продакшене фиксируются.** Закоммиченные файлы `.env.example` используют плавающие теги (`latest`, либо стабильную мажорную линию вроде `v2` для Traefik, либо мультиархитектурный плавающий тег `server-cuda` для `ggml-org/llama.cpp`), чтобы свежий `cp .env.example .env` сразу давал рабочее состояние без необходимости искать текущий релиз. **Для продакшен-развёртываний переопределите в локальном `.env` хоста конкретным, воспроизводимым пином** — неизменяемым тегом (`v2.11.X`, `v0.20.2`), когда реестр его публикует, либо пином по дайджесту содержимого (`server-cuda@sha256:…`), когда существуют только плавающие теги. Каждый `.env.example` по сервису показывает формат пина прямо в файле.
- **Конфигурация инференса разделена** по области действия. `<стек>/.env` несёт общехостовые значения (пин образа, путь кэша HF, токен HF, параметры по умолчанию); `<стек>/envs/<имя>.env` несёт только выбор модели плюс переопределения для варианта. `make up ENV=<имя>` объединяет оба через `docker compose --env-file .env --env-file envs/<имя>.env up -d`. Оба файла в gitignore — шаблоны лежат рядом как `.env.example`.
- **Loopback-порты в стеках инференса.** `vllm/` и `llama-cpp/` дополнительно привязывают свой API к `127.0.0.1` на хосте для прямого curl / бенчмаркинга — трафик LAN по-прежнему идёт через прокси.
- **Права доступа.** `/opt/<стек>/` принадлежит `root:root`. Файлы `.env` — `root:docker 640`, чтобы пользователь группы `docker` мог их читать и запускать compose без sudo. Редактирование конфигураций требует `sudo`.
- **Цепочка поставок.** Каждый сторонний Docker-образ указан по тегу в `.env.example` (плавающий для удобства первого запуска; фиксируется в локальном `.env` хоста для продакшена). Каждый GitHub Action зафиксирован по commit SHA. Trivy сканирует при push / PR / еженедельно по cron; Dependabot поддерживает актуальность пинов SHA еженедельным сгруппированным PR.

## Обслуживание репозитория

- [`CHANGELOG.md`](CHANGELOG.md) — формат [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), версионирование [SemVer](https://semver.org/spec/v2.0.0.html).
- [`.github/workflows/trivy.yml`](.github/workflows/trivy.yml) — сканирование CVE образов (HIGH+CRITICAL, только с доступным фиксом), сканирование конфигурации IaC, сканирование секретов файловой системы. Документация: [`.github/workflows/trivy.md`](.github/workflows/trivy.md).
- [`.github/dependabot.yml`](.github/dependabot.yml) — еженедельный сгруппированный PR для обновления зафиксированных SHA GitHub Actions.
- [`docs/`](docs/) — документы по дизайну/планированию для отдельных функций (напр. `docs/superpowers/specs/`, `docs/superpowers/plans/` для работы над режимом router у llama-cpp).
- [`README.md`](README.md), [`README.es.md`](README.es.md), [`README.zh.md`](README.zh.md) — версии этого README на английском, испанском и упрощённом китайском, синхронизируемые через строку переключения языков под логотипом.
- [`LICENSE`](LICENSE) — MIT.
- [`sparky.svg`](sparky.svg) — талисман проекта. Нарисован ИИ, который помогал создавать этот репозиторий, как автопортрет.
