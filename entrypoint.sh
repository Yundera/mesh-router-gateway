#!/bin/sh
set -e

echo "Starting mesh-router-gateway v${BUILD_VERSION:-dev}"

# Set defaults
export SERVER_DOMAIN="${SERVER_DOMAIN:-localhost}"
export BACKEND_URL="${BACKEND_URL:-http://localhost:8192}"
export CACHE_TTL="${CACHE_TTL:-60}"
export DEFAULT_BACKEND="${DEFAULT_BACKEND:-http://127.0.0.1:8080}"

echo "  SERVER_DOMAIN: ${SERVER_DOMAIN}"
echo "  BACKEND_URL: ${BACKEND_URL}"
echo "  CACHE_TTL: ${CACHE_TTL}s"

# Fetch CA certificate from backend API
echo "Fetching CA certificate from backend..."
MAX_RETRIES=30
RETRY_COUNT=0
CA_CERT_PATH="/etc/ssl/certs/mesh-ca.pem"

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -sf "${BACKEND_URL}/ca-cert" -o "${CA_CERT_PATH}"; then
        echo "CA certificate fetched successfully"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Backend not ready, retrying in 2s... ($RETRY_COUNT/$MAX_RETRIES)"
    sleep 2
done

if [ ! -f "${CA_CERT_PATH}" ]; then
    echo "ERROR: Could not fetch CA certificate after $MAX_RETRIES attempts"
    exit 1
fi

# Generate Lua config from template
envsubst '${SERVER_DOMAIN} ${BACKEND_URL} ${CACHE_TTL} ${DEFAULT_BACKEND}' \
    < /etc/nginx/lua/config.lua.template \
    > /etc/nginx/lua/config.lua

echo "Config generated:"
cat /etc/nginx/lua/config.lua

# Create log files
mkdir -p /var/log/nginx
touch /var/log/nginx/access.log
touch /var/log/nginx/error.log

# Start OpenResty (nginx) in foreground
exec openresty -g 'daemon off;'
