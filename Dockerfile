# mesh-router-gateway
# Lightweight HTTP reverse proxy with dynamic domain resolution

FROM openresty/openresty:1.29.2.5-alpine

# Install minimal dependencies
RUN apk add --no-cache \
    gettext \
    curl \
    openssl \
    ca-certificates

# Install lua-resty-http library
COPY ./nginx/lua-resty-http/* /usr/local/openresty/lualib/resty/

# Copy nginx configuration to OpenResty's expected location
# This overrides the default OpenResty nginx.conf
COPY nginx/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
RUN rm -f /etc/nginx/conf.d/default.conf

# Copy gateway configuration
COPY nginx/gateway.conf /etc/nginx/conf.d/gateway.conf
COPY nginx/gateway-common.conf /etc/nginx/gateway-common.conf

# Copy Lua scripts to nginx lua dir
COPY nginx/lua/resolver.lua /etc/nginx/lua/resolver.lua
COPY nginx/lua/usage.lua /etc/nginx/lua/usage.lua
COPY nginx/lua/certs.lua /etc/nginx/lua/certs.lua
COPY nginx/lua/certlist.lua /etc/nginx/lua/certlist.lua
COPY nginx/lua/sni_router.lua /etc/nginx/lua/sni_router.lua
RUN mkdir -p /etc/nginx/stream.d
COPY nginx/lua/config.lua.template /etc/nginx/lua/config.lua.template

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Create temp directories
RUN mkdir -p /tmp/nginx/client_temp && \
    chmod 700 /tmp/nginx/client_temp && \
    mkdir -p /var/log/nginx

# Build version argument
ARG BUILD_VERSION=dev
ENV BUILD_VERSION=${BUILD_VERSION}

# Expose ports
EXPOSE 80 8443

ENTRYPOINT ["/entrypoint.sh"]
