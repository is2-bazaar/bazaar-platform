#!/usr/bin/env bash
# keep-render-awake.sh — Loops forever pinging the Render free-tier services on
# /readyz so they don't spin down (~15 min idle) while you're testing.
#
# Why: notifications-service is a RabbitMQ *consumer* with no inbound HTTP
# traffic, so Render sleeps it and it stops sending push events. The HTTP
# services wake on request anyway, but pinging keeps them warm (no cold start).
#
# Usage:
#   ./keep-render-awake.sh                     # default: every 300s (5 min)
#   KEEP_AWAKE_INTERVAL=120 ./keep-render-awake.sh
#   nohup ./keep-render-awake.sh > keep-render-awake.log 2>&1 &   # background
#
# Stop:  Ctrl-C (foreground)  |  pkill -f keep-render-awake  (background)
#
# NOTE: dies if the machine sleeps or the terminal closes. For durable 24/7
# keep-alive use an external pinger (cron-job.org / UptimeRobot).
set -uo pipefail

INTERVAL="${KEEP_AWAKE_INTERVAL:-300}"   # seconds between rounds (Render sleeps at ~15 min)
TIMEOUT=30                               # per-request timeout; cold starts are slow

# notification-service first: it's the consumer that never wakes on its own.
SERVICES=(
  "https://bazaar-backend-notification-service.onrender.com"
  "https://bazaar-backend-auth-service.onrender.com"
  "https://bazaar-backend-user-service.onrender.com"
  "https://bazaar-backend-catalog-service.onrender.com"
  "https://bazaar-backend-cart-service.onrender.com"
  "https://bazaar-backend-order-service.onrender.com"
  "https://bazaar-backend-payment-service.onrender.com"
  "https://bazaar-backend-recommendation-service.onrender.com"
  "https://bazaar-backend-api-gateway.onrender.com"
)

ts() { date '+%Y-%m-%d %H:%M:%S'; }

echo "[$(ts)] keep-render-awake started — interval=${INTERVAL}s, ${#SERVICES[@]} services"
while true; do
  for svc in "${SERVICES[@]}"; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "${TIMEOUT}" "${svc}/readyz" 2>/dev/null || echo "ERR")
    echo "[$(ts)] ${code}  ${svc}/readyz"
  done
  echo "[$(ts)] --- sleeping ${INTERVAL}s ---"
  sleep "${INTERVAL}"
done
