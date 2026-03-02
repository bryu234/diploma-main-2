# Инструкция: добавление Watchdog-контейнера

## Описание

Watchdog — сервис-контейнер, который автоматически восстанавливает упавшие контейнеры после перезагрузки виртуальной машины.

**Проблема:** после ребута VM контейнеры стартуют с ошибками (firewall в бесконечном рестарте, рабочие станции exit 255) из-за неготовности Docker-сетей.

**Решение:** watchdog ждёт заданное время, проверяет статусы контейнеров, и при обнаружении упавших запускает `docker compose down && docker compose up -d` через отдельный helper-контейнер.

---

## Какие файлы изменены / добавлены

### 1. НОВЫЙ ФАЙЛ: `watchdog/watchdog.sh`

Создать файл `watchdog/watchdog.sh` с правами `chmod +x`:

```bash
#!/bin/sh
# Watchdog: при обнаружении упавших контейнеров делает docker compose down && up
# ВАЖНО: down и up выполняются в ОДНОМ helper-контейнере,
# который не является частью compose-проекта и поэтому переживёт down.

INTERVAL="${WATCHDOG_INTERVAL:-30}"
INITIAL_DELAY="${WATCHDOG_DELAY:-120}"
COMPOSE_FILE="${WATCHDOG_COMPOSE_FILE:-docker-compose.yml}"
HOST_DIR="${HOST_PROJECT_DIR:-}"

echo "[watchdog] Starting watchdog service"
echo "[watchdog] Initial delay: ${INITIAL_DELAY}s, Check interval: ${INTERVAL}s"

if [ -z "$HOST_DIR" ]; then
  echo "[watchdog] ERROR: HOST_PROJECT_DIR is not set. Set it in .env file."
  exit 1
fi

echo "[watchdog] Host project dir: ${HOST_DIR}"
echo "[watchdog] Compose file: ${COMPOSE_FILE}"

sleep "$INITIAL_DELAY"

# Определяем имя проекта из существующих контейнеров
PROJECT_NAME=$(docker ps -a --format '{{.Labels}}' 2>/dev/null | \
  grep -o 'com.docker.compose.project=[^,]*' | \
  head -1 | cut -d= -f2)

if [ -z "$PROJECT_NAME" ]; then
  echo "[watchdog] WARNING: Could not detect project name"
  PROJECT_FLAG=""
else
  echo "[watchdog] Detected project: ${PROJECT_NAME}"
  PROJECT_FLAG="-p ${PROJECT_NAME}"
fi

while true; do
  UNHEALTHY=$(docker ps -a \
    --filter "status=exited" \
    --filter "status=restarting" \
    --format '{{.Names}}' 2>/dev/null | \
    grep -v 'watchdog' | \
    grep -v 'nat_cleaner' || true)

  if [ -n "$UNHEALTHY" ]; then
    FAILED_COUNT=$(echo "$UNHEALTHY" | wc -l | tr -d ' ')
    echo "[watchdog] $(date '+%Y-%m-%d %H:%M:%S') Found $FAILED_COUNT unhealthy container(s):"
    echo "$UNHEALTHY"
    echo "[watchdog] Launching helper: down && sleep 10 && up"

    docker run --rm \
      --name watchdog_helper \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v "$HOST_DIR:$HOST_DIR" \
      -w "$HOST_DIR" \
      docker:cli \
      sh -c "
        echo '[helper] Running docker compose down...'
        docker compose -f $COMPOSE_FILE $PROJECT_FLAG down --remove-orphans
        echo '[helper] Waiting 10s...'
        sleep 10
        echo '[helper] Running docker compose up -d...'
        docker compose -f $COMPOSE_FILE $PROJECT_FLAG up -d --no-build
        echo '[helper] Done!'
      " 2>&1 | while read -r line; do echo "[watchdog] $line"; done

    echo "[watchdog] Helper finished. Waiting ${INITIAL_DELAY}s..."
    sleep "$INITIAL_DELAY"
  else
    echo "[watchdog] $(date '+%Y-%m-%d %H:%M:%S') All containers healthy"
  fi

  sleep "$INTERVAL"
done
```

---

### 2. ИЗМЕНЕНИЕ: `.env`

Добавить в конец файла:

```
HOST_PROJECT_DIR=/opt/diploma-main-2
WATCHDOG_DELAY=120
```

- `HOST_PROJECT_DIR` — абсолютный путь к проекту на хост-машине
- `WATCHDOG_DELAY` — задержка в секундах перед первой проверкой (можно уменьшить, например до 60)

---

### 3. ИЗМЕНЕНИЕ: `docker-compose.yml`

Добавить сервис `watchdog` **перед** сервисом `nat_cleaner`:

```yaml
  watchdog:
    image: docker:cli
    container_name: watchdog
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./watchdog/watchdog.sh:/watchdog.sh:ro
    environment:
      WATCHDOG_INTERVAL: 30
      WATCHDOG_DELAY: ${WATCHDOG_DELAY}
      WATCHDOG_MAX_RETRIES: 5
      WATCHDOG_COMPOSE_FILE: docker-compose.yml
      HOST_PROJECT_DIR: ${HOST_PROJECT_DIR}
    entrypoint: ["/bin/sh", "/watchdog.sh"]
    network_mode: none
```

---

### 4. ИЗМЕНЕНИЕ: `docker-compose-branch.yml`

Добавить сервис `branch_watchdog` **перед** сервисом `nat_cleaner`:

```yaml
  branch_watchdog:
    image: docker:cli
    container_name: branch_watchdog
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./watchdog/watchdog.sh:/watchdog.sh:ro
    environment:
      WATCHDOG_INTERVAL: 30
      WATCHDOG_DELAY: ${WATCHDOG_DELAY}
      WATCHDOG_MAX_RETRIES: 5
      WATCHDOG_COMPOSE_FILE: docker-compose-branch.yml
      HOST_PROJECT_DIR: ${HOST_PROJECT_DIR}
    entrypoint: ["/bin/sh", "/watchdog.sh"]
    network_mode: none
```

---

## Настройка параметров

| Параметр | Описание | Значение по умолчанию |
|----------|----------|-----------------------|
| `WATCHDOG_DELAY` | Задержка перед первой проверкой (сек) | `120` |
| `WATCHDOG_INTERVAL` | Интервал между проверками (сек) | `30` |
| `WATCHDOG_MAX_RETRIES` | Макс. попыток (не используется в down/up версии) | `5` |
| `HOST_PROJECT_DIR` | Абсолютный путь к проекту на хосте | `/opt/diploma-main-2` |

---

## Проверка работоспособности

```bash
# Логи watchdog
docker logs watchdog -f

# Статус всех контейнеров
docker ps -a --format 'table {{.Names}}\t{{.Status}}'

# Тест: остановить контейнер и подождать ~30 сек
docker stop fw && docker rm fw
# Watchdog должен обнаружить это и запустить down/up
```
