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
  # Ищем проблемные контейнеры (кроме watchdog и nat_cleaner)
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
    echo "[watchdog] ========================================"
    echo "[watchdog] Launching helper: down && sleep 10 && up"
    echo "[watchdog] ========================================"

    # Запускаем down+up в ОДНОМ helper-контейнере.
    # Helper НЕ часть compose-проекта → переживёт docker compose down.
    # Даже после того как watchdog будет убит, helper доведёт up до конца,
    # и watchdog поднимется снова вместе с остальными контейнерами.
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

    # Если мы дошли сюда — значит watchdog не был убит (маловероятно).
    # На всякий случай ждём перед следующей проверкой.
    echo "[watchdog] Helper finished. Waiting ${INITIAL_DELAY}s..."
    sleep "$INITIAL_DELAY"
  else
    echo "[watchdog] $(date '+%Y-%m-%d %H:%M:%S') All containers healthy"
  fi

  sleep "$INTERVAL"
done
