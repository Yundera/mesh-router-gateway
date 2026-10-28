# mesh-router-gateway
# Lightweight HTTP reverse proxy with dynamic domain resolution

ARG OPENRESTY_VERSION=1.29.2.5

# nginx rebuilt with ngx_stream_realip_module, which the official image does not compile:
# the TLS front (stream) takes the client address from the PROXY header of the proxy in
# front of it (README › TLS). Same sources and configure line as the official image, plus
# that one module; only the binary is copied, so it runs on the image's own OpenSSL, PCRE2
# and LuaJIT. The dynamic modules (geoip, image_filter, xslt) are left out: unused here.
FROM openresty/openresty:${OPENRESTY_VERSION}-alpine AS nginx-build
ARG OPENRESTY_VERSION
ARG OPENRESTY_SHA256=3195e665c97023419051dc51d195e9f774a3d00ed6e7cd8a3751c4722ea0a8c1
RUN apk add --no-cache build-base perl linux-headers zlib-dev curl
WORKDIR /build
RUN curl -fsSLo openresty.tar.gz "https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz" \
    && echo "${OPENRESTY_SHA256}  openresty.tar.gz" | sha256sum -c - \
    && tar xzf openresty.tar.gz
WORKDIR /build/openresty-${OPENRESTY_VERSION}
RUN ./configure -j"$(nproc)" \
        --prefix=/usr/local/openresty \
        --with-luajit=/usr/local/openresty/luajit \
        --with-cc-opt='-DNGX_LUA_ABORT_AT_PANIC -I/usr/local/openresty/pcre2/include -I/usr/local/openresty/openssl3/include' \
        --with-ld-opt='-L/usr/local/openresty/pcre2/lib -L/usr/local/openresty/openssl3/lib -Wl,-rpath,/usr/local/openresty/pcre2/lib:/usr/local/openresty/openssl3/lib' \
        --with-pcre --with-pcre-jit --with-compat --with-threads --with-ipv6 \
        --without-mail_pop3_module --without-mail_imap_module --without-mail_smtp_module \
        --with-http_addition_module --with-http_auth_request_module --with-http_dav_module \
        --with-http_flv_module --with-http_gunzip_module --with-http_gzip_static_module \
        --with-http_mp4_module --with-http_random_index_module --with-http_realip_module \
        --with-http_secure_link_module --with-http_slice_module --with-http_ssl_module \
        --with-http_stub_status_module --with-http_sub_module --with-http_v2_module \
        --with-http_v3_module --with-mail --with-mail_ssl_module --with-md5-asm --with-sha1-asm \
        --with-stream --with-stream_ssl_module --with-stream_ssl_preread_module \
        --with-stream_realip_module \
    && make -j"$(nproc)" \
    && cp build/nginx-*/objs/nginx /build/nginx

FROM openresty/openresty:${OPENRESTY_VERSION}-alpine

COPY --from=nginx-build /build/nginx /usr/local/openresty/nginx/sbin/nginx
RUN openresty -V 2>&1 | grep -q -- '--with-stream_realip_module'

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
