#!/bin/sh
set -e

echo "Starting mesh-router-gateway v${BUILD_VERSION:-dev}"

# Set defaults
export SERVER_DOMAIN="${SERVER_DOMAIN:-localhost}"
export BACKEND_URL="${BACKEND_URL:-http://localhost:8192}"
export CACHE_TTL="${CACHE_TTL:-60}"
# No default: empty = unknown names get a 404 (a fallback nothing listened on gave a 502).
export DEFAULT_BACKEND="${DEFAULT_BACKEND:-}"
# Usage (DAU) ingest: defaults to the backend's internal endpoint; secret = SERVICE_API_KEY.
# Leave USAGE_INGEST_URL empty (or unset with no BACKEND_URL) to disable usage notifications.
export USAGE_INGEST_URL="${USAGE_INGEST_URL:-${BACKEND_URL}/internal/usage/ingest}"
export USAGE_INGEST_SECRET="${USAGE_INGEST_SECRET:-${SERVICE_API_KEY:-}}"
export SERVICE_API_KEY="${SERVICE_API_KEY:-}"
# TLS listener (SNI router, see nginx/lua/sni_router.lua): 8443 behind a TCP
# passthrough (GATEWAY_TLS_PROXY_PROTOCOL=1 carries the client address), 443 on a
# host where the gateway is the edge, "off" to disable.
GATEWAY_TLS_PORT="${GATEWAY_TLS_PORT:-8443}"
GATEWAY_TLS_PROXY_PROTOCOL="${GATEWAY_TLS_PROXY_PROTOCOL:-0}"

echo "  SERVER_DOMAIN: ${SERVER_DOMAIN}"
echo "  BACKEND_URL: ${BACKEND_URL}"
echo "  CACHE_TTL: ${CACHE_TTL}s"
echo "  USAGE_INGEST_URL: ${USAGE_INGEST_URL}"
echo "  GATEWAY_TLS_PORT: ${GATEWAY_TLS_PORT} (proxy protocol: ${GATEWAY_TLS_PROXY_PROTOCOL})"

# Routed tunnel: the WireGuard subnet (TUNNEL_SUBNET) is reached through the tunnel
# provider's container (TUNNEL_VIA), so a tunnel route with a tunnelIp is served over TLS
# to <tunnelIp>:443, straight to the box's Caddy. Needs NET_ADMIN, which only touches this
# container's own network namespace. Without it, tunnel routes keep the provider's HTTP path.
export TUNNEL_SUBNET="${TUNNEL_SUBNET:-}"
if [ -n "${TUNNEL_SUBNET}" ]; then
    if [ -n "${TUNNEL_VIA:-}" ] && ip route replace "${TUNNEL_SUBNET}" via "${TUNNEL_VIA}"; then
        echo "  Routed tunnel: ${TUNNEL_SUBNET} via ${TUNNEL_VIA}"
    else
        echo "WARNING: routed tunnel disabled, cannot route ${TUNNEL_SUBNET} via ${TUNNEL_VIA:-(TUNNEL_VIA unset)} (NET_ADMIN?)"
        TUNNEL_SUBNET=""
    fi
fi

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
envsubst '${SERVER_DOMAIN} ${BACKEND_URL} ${CACHE_TTL} ${DEFAULT_BACKEND} ${USAGE_INGEST_URL} ${USAGE_INGEST_SECRET} ${TUNNEL_SUBNET}' \
    < /etc/nginx/lua/config.lua.template \
    > /etc/nginx/lua/config.lua

echo "Config generated:"
# Redact the usage ingest secret so it never lands in container logs.
sed -e 's/\(usage_ingest_secret = "\)[^"]*\(".*\)/\1***REDACTED***\2/' /etc/nginx/lua/config.lua

# X-Forwarded-For towards the box. append (default): the client's own value is kept in
# front of the address this gateway saw, which is how Cloudflare's Worker hands over the
# client while it is in front of the zone. replace: only the address this gateway saw (the
# client, realip from the TLS front): set it once the gateway is the edge (cutoff), so a
# client cannot put a fake address first. The box's Caddy reads the chain right to left
# (trusted_proxies_strict) either way; this is for apps that read the leftmost value.
GATEWAY_FORWARDED_FOR="${GATEWAY_FORWARDED_FOR:-append}"
if [ "${GATEWAY_FORWARDED_FOR}" = "replace" ]; then
    FORWARDED_FOR_VALUE='$remote_addr'
else
    FORWARDED_FOR_VALUE='$proxy_add_x_forwarded_for'
fi
cat > /etc/nginx/conf.d/00-forwarded-for.conf <<EOF
map \$remote_addr \$mesh_forwarded_for {
    default ${FORWARDED_FOR_VALUE};
}
EOF
echo "  X-Forwarded-For: ${GATEWAY_FORWARDED_FOR}"

# TLS front + TLS server.
# The front (stream, sni_router.lua) listens on GATEWAY_TLS_PORT and passes a user's dot
# names and apex through to the box untouched; everything else goes to the HTTP TLS
# server on a local socket, which presents this self-signed fallback: what Cloudflare
# ("Full" SSL) accepts from the proxy in front of the gateway.
# Client address: behind a proxy (GATEWAY_TLS_PROXY_PROTOCOL=1) the front takes it from
# that proxy's PROXY header (stream realip, rebuilt into the image), trusting the sources in
# GATEWAY_TLS_REALIP_FROM. The front then sends its own PROXY header onwards: to the HTTP
# TLS server (http realip, so X-Real-IP / X-Forwarded-For carry the client) and to boxes
# that take one (`proxyProtocol` in /resolve/v2). A box that does not goes through the
# strip relay, which ends the header and passes the TLS bytes on as before.
TLS_CONF=/etc/nginx/conf.d/gateway-tls.conf
FRONT_CONF=/etc/nginx/stream.d/gateway-tls-front.conf
TLS_SOCKET=/var/run/nginx-tls.sock
STRIP_SOCKET=/var/run/nginx-strip.sock
GATEWAY_TLS_REALIP_FROM="${GATEWAY_TLS_REALIP_FROM:-10.0.0.0/8 172.16.0.0/12 192.168.0.0/16}"
if [ "${GATEWAY_TLS_PORT}" = "off" ]; then
    rm -f "${TLS_CONF}" "${FRONT_CONF}"
else
    mkdir -p /etc/nginx/certs
    if [ ! -s /etc/nginx/certs/fallback.crt ]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
            -subj "/CN=mesh-router-gateway" \
            -keyout /etc/nginx/certs/fallback.key -out /etc/nginx/certs/fallback.crt 2>/dev/null
    fi
    LISTEN_OPTS=""
    REALIP_CONF=""
    if [ "${GATEWAY_TLS_PROXY_PROTOCOL}" = "1" ]; then
        LISTEN_OPTS=" proxy_protocol"
        for net in ${GATEWAY_TLS_REALIP_FROM}; do
            REALIP_CONF="${REALIP_CONF}    set_real_ip_from ${net};
"
        done
    fi
    rm -f "${TLS_SOCKET}" "${STRIP_SOCKET}"
    cat > "${FRONT_CONF}" <<EOF
log_format tls '\$remote_addr \$realip_remote_addr [\$time_local] \$ssl_preread_server_name '
               '\$tls_mode \$upstream_addr \$status \$bytes_sent \$bytes_received \$session_time';

server {
    access_log /var/log/nginx/access.log tls;
    listen ${GATEWAY_TLS_PORT}${LISTEN_OPTS};
    listen [::]:${GATEWAY_TLS_PORT}${LISTEN_OPTS};
${REALIP_CONF}    ssl_preread on;
    resolver 127.0.0.11 valid=30s ipv6=off;
    resolver_timeout 3s;

    set \$tls_upstream "unix:${TLS_SOCKET}";
    set \$tls_mode "terminate";
    preread_by_lua_block {
        require("sni_router").route()
    }
    proxy_protocol on;
    proxy_pass \$tls_upstream;
    proxy_connect_timeout 5s;
    proxy_timeout 1h;
}

# Boxes that take no PROXY header: the front's header ends here, the TLS bytes go on.
server {
    listen unix:${STRIP_SOCKET} proxy_protocol;
    set_real_ip_from unix:;
    ssl_preread on;
    resolver 127.0.0.11 valid=30s ipv6=off;
    resolver_timeout 3s;

    set \$tls_upstream "";
    set \$tls_mode "strip";
    preread_by_lua_block {
        require("sni_router").route_strip()
    }
    proxy_pass \$tls_upstream;
    proxy_connect_timeout 5s;
    proxy_timeout 1h;
}
EOF
    cat > "${TLS_CONF}" <<EOF
server {
    listen unix:${TLS_SOCKET} ssl proxy_protocol;
    http2 on;
    server_name _;
    set_real_ip_from unix:;
    real_ip_header proxy_protocol;

    ssl_certificate /etc/nginx/certs/fallback.crt;
    ssl_certificate_key /etc/nginx/certs/fallback.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:gateway_tls:10m;

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
