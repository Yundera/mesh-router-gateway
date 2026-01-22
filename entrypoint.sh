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
