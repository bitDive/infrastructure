#!/bin/sh
set -e

COMPOSE="docker compose --env-file /app/docker-compose/.env -f /app/docker-compose/compose.yml"

cleanup() {
  echo "[launcher] Shutting down services..."
  $COMPOSE down --timeout 30 2>/dev/null || true
  echo "[launcher] Stopped"
  exit 0
}
trap cleanup TERM INT

echo "[launcher] Starting Docker daemon..."
dockerd-entrypoint.sh dockerd --storage-driver=overlay2 > /var/log/dockerd.log 2>&1 &

echo "[launcher] Waiting for Docker daemon..."
for i in $(seq 1 60); do
  if docker info >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! docker info >/dev/null 2>&1; then
  echo "[launcher] ERROR: Docker daemon failed to start. Logs:"
  cat /var/log/dockerd.log
  exit 1
fi

echo "[launcher] Docker daemon ready"
cd /app

echo "[launcher] [1/3] Starting vault..."
$COMPOSE up -d vault
$COMPOSE logs --no-log-prefix vault 2>&1 &
echo "[launcher] Waiting 20s for vault initialization..."
sleep 20

echo "[launcher] [2/3] Starting init-db-ssl (+ postgres, clickhouse)..."
$COMPOSE up -d init-db-ssl
echo "[launcher] Waiting 20s for DB init..."
sleep 20

echo "[launcher] [3/3] Starting all remaining services..."
$COMPOSE up -d init-container-ssl

echo "============================================"
echo "[launcher] All services launched"
echo "============================================"
$COMPOSE ps
echo "============================================"

echo "[launcher] Streaming all service logs (Ctrl+C to stop)..."
$COMPOSE logs --follow --tail 50
