#!/bin/sh
# Watchdog: при обнаружении упавших контейнеров делает docker compose down && up
# Запускает docker compose через временный контейнер с правильными host-путями.

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

TRIGGERED=false

# Запуск docker compose через временный контейнер с правильными host-путями
run_compose() {
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$HOST_DIR:$HOST_DIR" \
    -w "$HOST_DIR" \
    docker:cli \
    docker compose -f "$COMPOSE_FILE" $PROJECT_FLAG "$@" 2>&1
}

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

    if [ "$TRIGGERED" = "true" ]; then
      echo "[watchdog] Already triggered restart, skipping this cycle"
      sleep "$INTERVAL"
      continue
    fi

    echo "[watchdog] ========================================"
    echo "[watchdog] Running: docker compose down && up -d"
    echo "[watchdog] ========================================"

    run_compose down --remove-orphans | while read -r line; do
      echo "[watchdog][down] $line"
    done

    echo "[watchdog] Waiting 10s..."
    sleep 10

    run_compose up -d --no-build | while read -r line; do
      echo "[watchdog][up] $line"
    done

    echo "[watchdog] Done! Waiting ${INITIAL_DELAY}s before next check..."
    TRIGGERED=true
    sleep "$INITIAL_DELAY"
    TRIGGERED=false
  else
    echo "[watchdog] $(date '+%Y-%m-%d %H:%M:%S') All containers healthy"
    TRIGGERED=false
  fi

  sleep "$INTERVAL"
done
