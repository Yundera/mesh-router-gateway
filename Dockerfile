# mesh-router-gateway
# Lightweight HTTP reverse proxy with dynamic domain resolution

FROM openresty/openresty:alpine

# Install minimal dependencies
RUN apk add --no-cache \
    gettext \
    curl \
    ca-certificates

# Install lua-resty-http library
COPY ./nginx/lua-resty-http/* /usr/local/openresty/lualib/resty/

# Copy nginx configuration
COPY nginx/nginx.conf /etc/nginx/nginx.conf
RUN rm -f /etc/nginx/conf.d/default.conf

# Copy gateway configuration
COPY nginx/gateway.conf /etc/nginx/conf.d/gateway.conf

# Copy Lua scripts
COPY nginx/lua/resolver.lua /etc/nginx/lua/resolver.lua
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
EXPOSE 80 443

ENTRYPOINT ["/entrypoint.sh"]
