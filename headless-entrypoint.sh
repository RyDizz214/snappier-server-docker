#!/usr/bin/env bash
# headless-entrypoint.sh

set -euo pipefail

# Cleanup function for graceful shutdown
cleanup() {
  echo "🛑 Shutting down all services..."
  kill "${PUSH_SERVICE_PID}" 2>/dev/null || true
  kill "${SNAPPIER_PID}"      2>/dev/null || true
}

# Trap signals and script exit
trap cleanup SIGINT SIGTERM EXIT

echo "🚀 Starting Snappier Server with Push Notifications..."

# Start Push Notification Service
echo "📱 Starting push notification service..."
cd /opt/notification-service
node push-service.js &
PUSH_SERVICE_PID=$!

# Wait for it to be ready
for i in {1..10}; do
  if curl -s "http://localhost:${NOTIFICATION_HTTP_PORT}/health" >/dev/null; then
    echo "✅ Push notification service is ready!"
    break
  fi
  sleep 1
done

# Send startup notification
echo "📤 Sending startup notification..."
curl -s -X POST "http://localhost:${NOTIFICATION_HTTP_PORT}/notify" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "🎬 Snappier Server",
    "body": "Server starting with push notification support",
    "options": {"urgency": "low", "tags": "startup"}
  }' || echo "⚠️ Could not send startup notification"
  echo ""

# Start the webhook & Snappier server
echo "🔗 Starting webhook integration and Snappier server..."
cd /root/SnappierServer
node snappier-webhook.js &
SNAPPIER_PID=$!

echo "📊 Snappier Server: http://localhost:${PORT}"
echo "📱 Notification API: http://localhost:${NOTIFICATION_HTTP_PORT}"
echo "📡 Notification WS: ws://localhost:${NOTIFICATION_WS_PORT}"
echo "✅ All services started!"

# Notify ready
sleep 2
curl -s -X POST "http://localhost:${NOTIFICATION_HTTP_PORT}/notify" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "✅ Snappier Server Ready",
    "body": "All services are running",
    "options": {"urgency": "normal", "tags": "ready"}
  }' || echo "⚠️ Could not send ready notification"
echo ""
echo "🎯 All services running. Press Ctrl+C to stop."
wait
