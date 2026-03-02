#!/bin/sh
# Watchdog: пересоздаёт только упавшие контейнеры через docker compose up --force-recreate
# Не трогает здоровые контейнеры и не убивает себя.

INTERVAL="${WATCHDOG_INTERVAL:-30}"
INITIAL_DELAY="${WATCHDOG_DELAY:-120}"
MAX_RETRIES="${WATCHDOG_MAX_RETRIES:-5}"
COMPOSE_FILE="${WATCHDOG_COMPOSE_FILE:-docker-compose.yml}"
COMPOSE_DIR="${WATCHDOG_COMPOSE_DIR:-/compose}"

echo "[watchdog] Starting watchdog service"
echo "[watchdog] Compose file: ${COMPOSE_DIR}/${COMPOSE_FILE}"
echo "[watchdog] Initial delay: ${INITIAL_DELAY}s, Check interval: ${INTERVAL}s, Max retries: ${MAX_RETRIES}"
sleep "$INITIAL_DELAY"

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

    cd "$COMPOSE_DIR"

    echo "$UNHEALTHY" | while read -r container_name; do
      [ -z "$container_name" ] && continue

      # Получаем имя сервиса из Docker Compose labels
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

      # force-recreate пересоздаёт контейнер + сеть, не трогая остальные сервисы
      if docker compose -f "$COMPOSE_FILE" up -d --force-recreate "$service_name" 2>&1 | \
          while read -r line; do echo "[watchdog][$service_name] $line"; done; then
        echo "[watchdog] OK: $service_name recreated"
      else
        echo "[watchdog] FAIL: could not recreate $service_name"
      fi

      increment_retry "$service_name"
      sleep 5
    done
  else
    # Все контейнеры здоровы — сбрасываем счётчики
    reset_all_retries
  fi

  sleep "$INTERVAL"
done
