#!/bin/sh
set -e

echo "Starting mesh-router-gateway v${BUILD_VERSION:-dev}"

# Set defaults
export SERVER_DOMAIN="${SERVER_DOMAIN:-localhost}"
export BACKEND_URL="${BACKEND_URL:-http://localhost:8192}"
export CACHE_TTL="${CACHE_TTL:-60}"
export DEFAULT_BACKEND="${DEFAULT_BACKEND:-http://127.0.0.1:8080}"
# Usage (DAU) ingest: defaults to the backend's internal endpoint; secret = SERVICE_API_KEY.
# Leave USAGE_INGEST_URL empty (or unset with no BACKEND_URL) to disable usage notifications.
export USAGE_INGEST_URL="${USAGE_INGEST_URL:-${BACKEND_URL}/internal/usage/ingest}"
export USAGE_INGEST_SECRET="${USAGE_INGEST_SECRET:-${SERVICE_API_KEY:-}}"
export SERVICE_API_KEY="${SERVICE_API_KEY:-}"
# TLS listener (certificate per SNI, see nginx/lua/certs.lua): 8443 behind a TCP
# passthrough (GATEWAY_TLS_PROXY_PROTOCOL=1 carries the client address), 443 on a
# host where the gateway is the edge, "off" to disable.
GATEWAY_TLS_PORT="${GATEWAY_TLS_PORT:-8443}"
GATEWAY_TLS_PROXY_PROTOCOL="${GATEWAY_TLS_PROXY_PROTOCOL:-0}"

echo "  SERVER_DOMAIN: ${SERVER_DOMAIN}"
echo "  BACKEND_URL: ${BACKEND_URL}"
echo "  CACHE_TTL: ${CACHE_TTL}s"
echo "  USAGE_INGEST_URL: ${USAGE_INGEST_URL}"
echo "  GATEWAY_TLS_PORT: ${GATEWAY_TLS_PORT} (proxy protocol: ${GATEWAY_TLS_PROXY_PROTOCOL})"

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

# Append mesh CA to system CA bundle so proxy_ssl_verify trusts our certs
cat "${CA_CERT_PATH}" >> /etc/ssl/certs/ca-certificates.crt

# Generate Lua config from template
envsubst '${SERVER_DOMAIN} ${BACKEND_URL} ${CACHE_TTL} ${DEFAULT_BACKEND} ${USAGE_INGEST_URL} ${USAGE_INGEST_SECRET} ${SERVICE_API_KEY}' \
    < /etc/nginx/lua/config.lua.template \
    > /etc/nginx/lua/config.lua

echo "Config generated:"
# Redact the usage ingest secret so it never lands in container logs.
sed -e 's/\(usage_ingest_secret = "\)[^"]*\(".*\)/\1***REDACTED***\2/' \
    -e 's/\(service_api_key = "\)[^"]*\(".*\)/\1***REDACTED***\2/' /etc/nginx/lua/config.lua

# TLS server. A user's certificate comes from the backend per SNI; anything else gets
# this self-signed fallback, which is what Cloudflare ("Full" SSL) accepted from the
# proxy in front of the gateway before.
TLS_CONF=/etc/nginx/conf.d/gateway-tls.conf
if [ "${GATEWAY_TLS_PORT}" = "off" ]; then
    rm -f "${TLS_CONF}"
else
    mkdir -p /etc/nginx/certs
    if [ ! -s /etc/nginx/certs/fallback.crt ]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
            -subj "/CN=mesh-router-gateway" \
            -keyout /etc/nginx/certs/fallback.key -out /etc/nginx/certs/fallback.crt 2>/dev/null
    fi
    if [ "${GATEWAY_TLS_PROXY_PROTOCOL}" = "1" ]; then
        LISTEN_OPTS=" proxy_protocol"
        # the listener only accepts PROXY protocol, so the header is the client address
        REAL_IP="    set_real_ip_from 0.0.0.0/0;
    set_real_ip_from ::/0;
    real_ip_header proxy_protocol;"
    else
        LISTEN_OPTS=""
        REAL_IP=""
    fi
    cat > "${TLS_CONF}" <<EOF
server {
    listen ${GATEWAY_TLS_PORT} ssl${LISTEN_OPTS};
    listen [::]:${GATEWAY_TLS_PORT} ssl${LISTEN_OPTS};
    http2 on;
    server_name _;

    ssl_certificate /etc/nginx/certs/fallback.crt;
    ssl_certificate_key /etc/nginx/certs/fallback.key;
    ssl_certificate_by_lua_file /etc/nginx/lua/certs.lua;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:gateway_tls:10m;
${REAL_IP}

    include /etc/nginx/gateway-common.conf;
}
EOF
fi

# Create log files
mkdir -p /var/log/nginx
touch /var/log/nginx/access.log
touch /var/log/nginx/error.log

# Start OpenResty (nginx) in foreground
exec openresty -g 'daemon off;'
