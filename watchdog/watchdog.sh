#!/bin/sh
# Watchdog: пересоздаёт только упавшие контейнеры.
# Запускает docker compose через временный контейнер с правильными host-путями.

INTERVAL="${WATCHDOG_INTERVAL:-30}"
INITIAL_DELAY="${WATCHDOG_DELAY:-120}"
MAX_RETRIES="${WATCHDOG_MAX_RETRIES:-5}"
COMPOSE_FILE="${WATCHDOG_COMPOSE_FILE:-docker-compose.yml}"
HOST_DIR="${HOST_PROJECT_DIR:-}"

echo "[watchdog] Starting watchdog service"
echo "[watchdog] Initial delay: ${INITIAL_DELAY}s, Check interval: ${INTERVAL}s, Max retries: ${MAX_RETRIES}"

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

# Счётчик попыток перезапуска
RETRY_DIR="/tmp/watchdog_retries"
mkdir -p "$RETRY_DIR"

get_retry_count() {
  file="$RETRY_DIR/$1"
  if [ -f "$file" ]; then cat "$file"; else echo "0"; fi
}

increment_retry() {
  file="$RETRY_DIR/$1"
  count=$(get_retry_count "$1")
  echo $((count + 1)) > "$file"
}

reset_all_retries() {
  rm -f "$RETRY_DIR"/* 2>/dev/null
}

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
    echo "[watchdog] $(date '+%Y-%m-%d %H:%M:%S') Found unhealthy containers:"
    echo "$UNHEALTHY"

    echo "$UNHEALTHY" | while read -r container_name; do
      [ -z "$container_name" ] && continue

      service_name=$(docker inspect "$container_name" \
        --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null || true)

      if [ -z "$service_name" ]; then
        echo "[watchdog] SKIP $container_name — not a compose service"
        continue
      fi

      retries=$(get_retry_count "$service_name")
      if [ "$retries" -ge "$MAX_RETRIES" ]; then
        echo "[watchdog] SKIP $service_name — exceeded max retries ($MAX_RETRIES)"
        continue
      fi

      echo "[watchdog] Recreating: $service_name (attempt $((retries + 1))/$MAX_RETRIES)"

      # Удаляем старый контейнер
      docker rm -f "$container_name" 2>/dev/null || true

      # Пересоздаём через временный контейнер с правильными путями
      run_compose up -d --no-build --no-deps "$service_name" | \
        while read -r line; do echo "[watchdog][$service_name] $line"; done

      echo "[watchdog] Done: $service_name"
      increment_retry "$service_name"
      sleep 5
    done
  else
    reset_all_retries
  fi

  sleep "$INTERVAL"
done
