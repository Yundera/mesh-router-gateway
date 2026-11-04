#!/bin/sh
set -e

echo "Starting mesh-router-gateway v${BUILD_VERSION:-dev}"

# Set defaults
export SERVER_DOMAIN="${SERVER_DOMAIN:-localhost}"
export BACKEND_URL="${BACKEND_URL:-http://localhost:8192}"
export CACHE_TTL="${CACHE_TTL:-60}"
# Serve-stale: how long the last resolution is used while the backend cannot answer (0 = off)
export RESOLVE_STALE_TTL="${RESOLVE_STALE_TTL:-86400}"
# No default: empty = unknown names get a 404 (a fallback nothing listened on gave a 502).
export DEFAULT_BACKEND="${DEFAULT_BACKEND:-}"
# TLS listener (SNI router, see nginx/lua/sni_router.lua): 8443 behind a TCP
# passthrough (GATEWAY_TLS_PROXY_PROTOCOL=1 carries the client address), 443 on a
# host where the gateway is the edge, "off" to disable.
GATEWAY_TLS_PORT="${GATEWAY_TLS_PORT:-8443}"
GATEWAY_TLS_PROXY_PROTOCOL="${GATEWAY_TLS_PROXY_PROTOCOL:-0}"

echo "  SERVER_DOMAIN: ${SERVER_DOMAIN}"
echo "  BACKEND_URL: ${BACKEND_URL}"
echo "  CACHE_TTL: ${CACHE_TTL}s (stale: ${RESOLVE_STALE_TTL}s)"
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

# Mesh CA (verifies the boxes' cert0 on the gateway → box hop): fetched from the backend,
# kept in GATEWAY_STATE_DIR. Mount a volume there so a gateway *recreated* while the
# backend is down still starts, on the copy from its last good fetch. Without a stored
# copy the backend must answer (30 tries, 2 s apart); with one, 5 tries, then the copy.
GATEWAY_STATE_DIR="${GATEWAY_STATE_DIR:-/var/lib/mesh-gateway}"
mkdir -p "${GATEWAY_STATE_DIR}"
CA_STORED="${GATEWAY_STATE_DIR}/mesh-ca.pem"
CA_FETCHED="${GATEWAY_STATE_DIR}/.mesh-ca.pem.new"
CA_CERT_PATH="/etc/ssl/certs/mesh-ca.pem"

if [ -s "${CA_STORED}" ]; then
    MAX_RETRIES=5
else
    MAX_RETRIES=30
fi
echo "Fetching CA certificate from backend..."
RETRY_COUNT=0
CA_FRESH=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    # into a temp file, accepted only if it parses as a certificate: an interrupted
    # download or an error page never replaces the stored copy
    # --connect-timeout bounds the name lookup too (a stopped backend container is an
    # unknown name on the Docker network, which hangs rather than failing)
    if curl -sf --connect-timeout 3 --max-time 10 "${BACKEND_URL}/ca-cert" -o "${CA_FETCHED}" \
        && openssl x509 -noout -in "${CA_FETCHED}" 2>/dev/null; then
        mv -f "${CA_FETCHED}" "${CA_STORED}"
        CA_FRESH=1
        echo "CA certificate fetched successfully (stored in ${CA_STORED})"
        break
    fi
    rm -f "${CA_FETCHED}"
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "No valid CA certificate from the backend yet, retrying in 2s... ($RETRY_COUNT/$MAX_RETRIES)"
    sleep 2
done

if [ "${CA_FRESH}" != "1" ]; then
    if openssl x509 -noout -in "${CA_STORED}" 2>/dev/null; then
        echo "WARNING: no valid CA certificate from the backend, starting on the stored copy (${CA_STORED}, $(date -r "${CA_STORED}" -u '+%Y-%m-%dT%H:%MZ' 2>/dev/null || echo 'date unknown'))"
    else
        echo "ERROR: no valid CA certificate from the backend after $MAX_RETRIES attempts, and no stored copy in ${GATEWAY_STATE_DIR} (mount a volume there)"
        exit 1
    fi
fi
cp "${CA_STORED}" "${CA_CERT_PATH}"

# What Lua's HTTP client trusts: the public roots (an https BACKEND_URL, e.g. a gateway on
# another host) and the mesh CA
cat /etc/ssl/certs/ca-certificates.crt "${CA_CERT_PATH}" > /etc/ssl/certs/lua-trust.pem

# Generate Lua config from template
envsubst '${SERVER_DOMAIN} ${BACKEND_URL} ${CACHE_TTL} ${RESOLVE_STALE_TTL} ${DEFAULT_BACKEND} ${TUNNEL_SUBNET}' \
    < /etc/nginx/lua/config.lua.template \
    > /etc/nginx/lua/config.lua

echo "Config generated:"
cat /etc/nginx/lua/config.lua

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
# A request another gateway handed over ($mesh_handoff_in, resolver.lua, only from a known
# gateway) keeps the client that gateway saw: its X-Real-IP, and its X-Forwarded-For with
# that gateway appended (boxes trust every gateway, so they read past it to the client).
cat > /etc/nginx/conf.d/00-forwarded-for.conf <<EOF
map \$mesh_handoff_in \$mesh_forwarded_for {
    default ${FORWARDED_FOR_VALUE};
    "1" \$proxy_add_x_forwarded_for;
}
map \$mesh_handoff_in \$mesh_real_ip {
    default \$remote_addr;
    "1" \$http_x_real_ip;
}
EOF
echo "  X-Forwarded-For: ${GATEWAY_FORWARDED_FOR}"

# Gateway certificate (handoff between gateways, docs/multi-gateway.md in
# mesh-router-nameserver): signed by the mesh CA for <ip-dashed>.gw.<zone>, which another
# gateway verifies when it hands this one a request for a box it cannot reach. Needs
# GATEWAY_PUBLIC_IP (this gateway's address, one of the backend's DNS_GATEWAY_IPS) and
# GATEWAY_CERT_TOKEN (the backend's). Key and certificate live in GATEWAY_STATE_DIR, so a
# restart while the backend is down keeps the last one; renewed when 10 days are left.
GATEWAY_PUBLIC_IP="${GATEWAY_PUBLIC_IP:-}"
GATEWAY_CERT_TOKEN="${GATEWAY_CERT_TOKEN:-}"
GW_KEY="${GATEWAY_STATE_DIR}/gateway.key"
GW_CERT="${GATEWAY_STATE_DIR}/gateway.crt"
GW_NAME=""
if [ -n "${GATEWAY_PUBLIC_IP}" ]; then
    GW_NAME="$(echo "${GATEWAY_PUBLIC_IP}" | tr . -).gw.$(echo "${SERVER_DOMAIN}" | tr 'A-Z' 'a-z')"
fi

# Writes a fresh certificate into GW_CERT; 0 on success.
gateway_cert_fetch() {
    [ -s "${GW_KEY}" ] || openssl genrsa -out "${GW_KEY}" 2048 2>/dev/null || return 1
    chmod 600 "${GW_KEY}"
    openssl req -new -key "${GW_KEY}" -subj "/CN=${GW_NAME}" -out "${GATEWAY_STATE_DIR}/gateway.csr" 2>/dev/null || return 1
    curl -sf --connect-timeout 3 --max-time 15 -X POST \
        -H "Authorization: Bearer ${GATEWAY_CERT_TOKEN}" -H "Content-Type: text/plain" \
        --data-binary "@${GATEWAY_STATE_DIR}/gateway.csr" \
        "${BACKEND_URL}/gateway-cert/${GATEWAY_PUBLIC_IP}" -o "${GW_CERT}.new" \
        && openssl x509 -noout -in "${GW_CERT}.new" 2>/dev/null \
        && mv -f "${GW_CERT}.new" "${GW_CERT}" && return 0
    rm -f "${GW_CERT}.new"
    return 1
}

# 0 when GW_CERT exists and is valid for at least $1 more seconds.
gateway_cert_valid() {
    [ -s "${GW_CERT}" ] && openssl x509 -noout -checkend "$1" -in "${GW_CERT}" >/dev/null 2>&1
}

GW_CERT_READY=0
if [ -n "${GW_NAME}" ] && [ -n "${GATEWAY_CERT_TOKEN}" ] && [ "${GATEWAY_TLS_PORT}" != "off" ]; then
    if gateway_cert_valid 864000 || gateway_cert_fetch; then
        GW_CERT_READY=1
        echo "  Gateway certificate: ${GW_NAME} (handoff), until $(openssl x509 -noout -enddate -in "${GW_CERT}" | cut -d= -f2)"
    elif gateway_cert_valid 0; then
        GW_CERT_READY=1
        echo "WARNING: gateway certificate not renewed (backend?), using the stored one until $(openssl x509 -noout -enddate -in "${GW_CERT}" | cut -d= -f2)"
    else
        echo "WARNING: no gateway certificate (backend refused or unreachable): other gateways cannot hand requests to this one"
    fi
else
    echo "  Gateway certificate: off (GATEWAY_PUBLIC_IP / GATEWAY_CERT_TOKEN unset): this gateway hands requests over but takes none"
fi

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
    # The certificate the HTTP TLS server presents: the public *.<zone> when there is a
    # valid one (below), the self-signed fallback otherwise
    cp -f /etc/nginx/certs/fallback.crt /etc/nginx/certs/default.crt
    cp -f /etc/nginx/certs/fallback.key /etc/nginx/certs/default.key
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

    ssl_certificate /etc/nginx/certs/default.crt;
    ssl_certificate_key /etc/nginx/certs/default.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:gateway_tls:10m;

    include /etc/nginx/gateway-common.conf;
}
EOF
    # Handoff from another gateway: the same server under this gateway's own certificate,
    # picked by SNI <ip-dashed>.gw.<zone> (the front terminates it: `gw` is reserved)
    if [ "${GW_CERT_READY}" = "1" ]; then
        cat >> "${TLS_CONF}" <<EOF

server {
    listen unix:${TLS_SOCKET} ssl proxy_protocol;
    http2 on;
    server_name ${GW_NAME};
    set_real_ip_from unix:;
    real_ip_header proxy_protocol;

    ssl_certificate ${GW_CERT};
    ssl_certificate_key ${GW_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:gateway_tls:10m;

    include /etc/nginx/gateway-common.conf;
}
EOF
    fi
fi

# Create log files
mkdir -p /var/log/nginx
touch /var/log/nginx/access.log
touch /var/log/nginx/error.log

# Gateway certificate renewal: twice a day, a new one once 10 days are left, then a reload
if [ "${GW_CERT_READY}" = "1" ]; then
    (
        while sleep 43200; do
            if ! gateway_cert_valid 864000; then
                if gateway_cert_fetch; then
                    echo "Gateway certificate renewed, until $(openssl x509 -noout -enddate -in "${GW_CERT}" | cut -d= -f2)"
                    openresty -s reload
                else
                    echo "WARNING: gateway certificate renewal failed, retrying in 12 h"
                fi
            fi
        done
    ) &
fi

# Public certificate *.<SERVER_DOMAIN> (cutoff gate G6, phase-1.1-gateway-tls.md §6.1 in
# mesh-router-nameserver): each gateway orders its own from Let's Encrypt by DNS-01 with
# lego, one ACME account and one key per gateway, kept in GATEWAY_STATE_DIR/acme. The
# HTTP TLS server presents it for every name it terminates; the handoff name keeps its
# mesh CA certificate. GATEWAY_ACME_DNS is lego's DNS provider: "cloudflare" while
# Cloudflare holds the zone (CLOUDFLARE_DNS_API_TOKEN, DNS edit on this zone only),
# "acme-dns" once our nameservers do (ACME_DNS_API_BASE, ACME_DNS_STORAGE_PATH). Empty =
# off: the self-signed fallback, as before. The gateway never waits for an order: it
# starts on the stored certificate or the fallback, and swaps in a new one with a reload.
GATEWAY_ACME_DNS="${GATEWAY_ACME_DNS:-}"
# the ACME account's contact (lego requires one): an alias of the zone by default
GATEWAY_ACME_EMAIL="${GATEWAY_ACME_EMAIL:-admin@$(echo "${SERVER_DOMAIN}" | tr 'A-Z' 'a-z')}"
GATEWAY_ACME_SERVER="${GATEWAY_ACME_SERVER:-https://acme-v02.api.letsencrypt.org/directory}"
# renew once fewer than this many days are left (Let's Encrypt certificates last 90)
GATEWAY_ACME_RENEW_DAYS="${GATEWAY_ACME_RENEW_DAYS:-30}"
# one directory per CA (acme/<directory host>): a certificate from another CA, e.g. Let's
# Encrypt's staging one while testing, is never picked up after GATEWAY_ACME_SERVER changes
ACME_DIR="${GATEWAY_STATE_DIR}/acme/$(echo "${GATEWAY_ACME_SERVER}" | sed -e 's|^[a-z]*://||' -e 's|[/:].*$||')"
ACME_DOMAIN="$(echo "${SERVER_DOMAIN}" | tr 'A-Z' 'a-z')"
ACME_CERT="${ACME_DIR}/certificates/_.${ACME_DOMAIN}.crt"
ACME_KEY="${ACME_DIR}/certificates/_.${ACME_DOMAIN}.key"

# 0 when the stored public certificate is valid for at least $1 more seconds and names
# *.<zone> (a stored one from another SERVER_DOMAIN or CA directory is not used).
public_cert_valid() {
    [ -s "${ACME_CERT}" ] && [ -s "${ACME_KEY}" ] \
        && openssl x509 -noout -checkend "$1" -in "${ACME_CERT}" >/dev/null 2>&1 \
        && openssl x509 -noout -ext subjectAltName -in "${ACME_CERT}" 2>/dev/null | grep -q "DNS:\*\.${ACME_DOMAIN}"
}

# Puts the stored public certificate in front; $1 = 1 to reload nginx afterwards.
public_cert_install() {
    cp -f "${ACME_KEY}" /etc/nginx/certs/default.key.new \
        && cp -f "${ACME_CERT}" /etc/nginx/certs/default.crt.new \
        && mv -f /etc/nginx/certs/default.key.new /etc/nginx/certs/default.key \
        && mv -f /etc/nginx/certs/default.crt.new /etc/nginx/certs/default.crt \
        || return 1
    echo "Public certificate *.${ACME_DOMAIN} in use, until $(openssl x509 -noout -enddate -in "${ACME_CERT}" | cut -d= -f2) (issuer: $(openssl x509 -noout -issuer -in "${ACME_CERT}" | sed 's/^issuer=//'))"
    if [ "$1" = "1" ]; then
        openresty -s reload
    fi
}

# lego run (no certificate yet) or renew (one exists); 0 on success.
public_cert_order() {
    set -- --accept-tos --path "${ACME_DIR}" --server "${GATEWAY_ACME_SERVER}" \
        --dns "${GATEWAY_ACME_DNS}" --domains "*.${ACME_DOMAIN}" --email "${GATEWAY_ACME_EMAIL}"
    if [ -s "${ACME_CERT}" ]; then
        lego "$@" renew --days "${GATEWAY_ACME_RENEW_DAYS}"
    else
        lego "$@" run
    fi
}

if [ -n "${GATEWAY_ACME_DNS}" ] && [ "${GATEWAY_TLS_PORT}" != "off" ]; then
    mkdir -p "${ACME_DIR}"
    chmod 700 "${GATEWAY_STATE_DIR}/acme" "${ACME_DIR}"
    echo "  Public certificate: *.${ACME_DOMAIN} by DNS-01 (${GATEWAY_ACME_DNS}, ${GATEWAY_ACME_SERVER})"
    if public_cert_valid 0; then
        public_cert_install 0 || echo "WARNING: stored public certificate not installed, self-signed fallback"
    else
        echo "  No valid public certificate stored yet: self-signed fallback until the order succeeds"
    fi
    # Order or renew in the background: after 10 s (nginx up), then twice a day; while
    # there is no valid certificate, every hour (Let's Encrypt allows 5 failed
    # validations per account and name per hour).
    (
        sleep 10
        while :; do
            BEFORE="$(openssl x509 -noout -fingerprint -sha256 -in "${ACME_CERT}" 2>/dev/null || true)"
            if public_cert_order; then
                AFTER="$(openssl x509 -noout -fingerprint -sha256 -in "${ACME_CERT}" 2>/dev/null || true)"
                if [ "${AFTER}" != "${BEFORE}" ] && public_cert_valid 0; then
                    public_cert_install 1 || echo "WARNING: public certificate obtained but not installed"
                fi
            else
                echo "WARNING: public certificate order/renewal failed (lego output above)"
            fi
            if public_cert_valid 0; then
                sleep 43200
            else
                sleep 3600
            fi
        done
    ) &
else
    echo "  Public certificate: off (GATEWAY_ACME_DNS unset): self-signed fallback"
fi

# Start OpenResty (nginx) in foreground
exec openresty -g 'daemon off;'
