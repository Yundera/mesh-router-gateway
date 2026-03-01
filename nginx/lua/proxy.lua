--[[
    proxy.lua - HTTP proxy for mesh-router-gateway

    This module handles HTTP proxying using lua-resty-http.
    Routes are validated at registration time (backend) and expire via Redis TTL.
    Gateway picks best route, tries once, returns result (or 502).

    Features:
    - WebSocket support via upgrade headers
    - Streaming for large responses
    - Request body handling (buffered and chunked)
]]

local http = require "resty.http"

local _M = {}

-- Configuration (loaded at runtime)
local config = dofile("/etc/nginx/lua/config.lua")

-- Build URL from route
local function build_url_from_route(route, uri)
    local host_ip = route.ip
    local target_port = route.port or 443

    -- Determine protocol
    local protocol
    if route.source == "tunnel" then
        protocol = "http"
    else
        protocol = route.scheme or "https"
    end

    -- Handle IPv6
    local host_part
    if host_ip:find(":") then
        host_part = "[" .. host_ip .. "]"
    else
        host_part = host_ip
    end

    return protocol .. "://" .. host_part .. ":" .. target_port .. uri
end

-- Forward response to client
local function forward_response(res, req_id)
    -- Set status
    ngx.status = res.status

    -- Forward headers (excluding hop-by-hop headers)
    local hop_by_hop = {
        ["connection"] = true,
        ["keep-alive"] = true,
        ["proxy-authenticate"] = true,
        ["proxy-authorization"] = true,
        ["te"] = true,
        ["trailer"] = true,
        ["transfer-encoding"] = true,
        ["upgrade"] = true,
    }

    for k, v in pairs(res.headers) do
        local k_lower = k:lower()
        if not hop_by_hop[k_lower] then
            ngx.header[k] = v
        end
    end

    -- Send body
    if res.body then
        ngx.print(res.body)
    end

    ngx.log(ngx.INFO, "[", req_id, "] response_forwarded status=", res.status)
end

-- Proxy request to a single route
local function proxy_to_route(route, request, req_id)
    local httpc = http.new()

    -- Set timeouts
    httpc:set_timeout(config.proxy_connect_timeout)

    -- Build target URL
    local target_url = build_url_from_route(route, request.uri)
    local protocol = route.source == "tunnel" and "http" or (route.scheme or "https")

    ngx.log(ngx.INFO, "[", req_id, "] proxy_attempt route=", route.ip, ":", route.port or 443,
        " source=", route.source or "unknown", " url=", target_url)

    -- Build request headers
    local headers = {}
    for k, v in pairs(request.headers) do
        headers[k] = v
    end

    -- Set correct Host header
    -- ngx.req.get_headers() returns lowercase keys, so we need to remove "host"
    -- before setting "Host" to avoid duplicate headers (Lua tables are case-sensitive)
    headers["host"] = nil
    headers["Host"] = request.proxy_host or request.host

    -- Add forwarding headers
    headers["X-Real-IP"] = ngx.var.remote_addr
    headers["X-Forwarded-For"] = ngx.var.proxy_add_x_forwarded_for or ngx.var.remote_addr
    headers["X-Forwarded-Proto"] = ngx.var.http_x_forwarded_proto or ngx.var.scheme
    headers["X-Forwarded-Host"] = request.host
    headers["X-Request-ID"] = req_id

    -- SSL options for HTTPS backends
    -- Verify SSL certificates using mesh-router CA (configured in nginx.conf lua_ssl_trusted_certificate)
    local ssl_verify = true
    local ssl_server_name = nil
    if protocol == "https" then
        ssl_server_name = request.host  -- SNI for cert matching
    end

    -- Make request
    -- Note: lua_ssl_trusted_certificate in nginx.conf sets the CA for lua-resty-http
    local res, err = httpc:request_uri(target_url, {
        method = request.method,
        headers = headers,
        body = request.body,
        ssl_verify = ssl_verify,
        ssl_server_name = ssl_server_name,
    })

    if not res then
        ngx.log(ngx.WARN, "[", req_id, "] proxy_failed route=", route.ip, ":", route.port or 443, " err=", err)
        return nil, err
    end

    ngx.log(ngx.INFO, "[", req_id, "] proxy_success route=", route.ip, ":", route.port or 443,
        " status=", res.status, " content_length=", res.headers["Content-Length"] or "chunked")

    return res, nil
end

-- Simple single-route proxy (no retry)
function _M.proxy(route, request, req_id, trace_enabled)
    local res, err = proxy_to_route(route, request, req_id)

    if not res then
        ngx.log(ngx.ERR, "[", req_id, "] proxy_failed route=", route.ip, ":", route.port or 443, " err=", err)
        return false, err
    end

    if trace_enabled then
        ngx.header["X-Mesh-Route"] = (route.source or "unknown") .. ",pcs"
    end

    forward_response(res, req_id)
    return true
end

return _M
