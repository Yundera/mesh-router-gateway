--[[
    content_handler.lua - Content phase handler for mesh-router-gateway

    This module handles the content phase of request processing. It receives
    resolved routes from the access phase (resolver.lua) and proxies the
    request with automatic failover between routes.

    Flow:
    1. Retrieve routes and request context from ngx.ctx (set by resolver.lua)
    2. If use_default flag set, proxy to default backend (no failover)
    3. Otherwise, proxy with failover through sorted routes
    4. On complete failure, return 502 Bad Gateway
]]

local http = require "resty.http"
local cjson = require "cjson.safe"
local proxy = require "proxy"

-- Configuration
local config = dofile("/etc/nginx/lua/config.lua")

-- Helper: Get elapsed time in ms
local function elapsed_ms(start_time)
    return string.format("%.1f", (ngx.now() - start_time) * 1000)
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

-- Proxy to default backend (simple, no failover)
local function proxy_to_default(backend_url, request, req_id)
    local httpc = http.new()
    httpc:set_timeout(config.proxy_connect_timeout or 5000)

    ngx.log(ngx.INFO, "[", req_id, "] proxy_to_default url=", backend_url)

    -- Build headers
    local headers = {}
    for k, v in pairs(request.headers) do
        headers[k] = v
    end
    headers["Host"] = request.proxy_host or request.host
    headers["X-Real-IP"] = ngx.var.remote_addr
    headers["X-Forwarded-For"] = ngx.var.proxy_add_x_forwarded_for or ngx.var.remote_addr
    headers["X-Forwarded-Proto"] = ngx.var.scheme
    headers["X-Forwarded-Host"] = request.host
    headers["X-Request-ID"] = req_id

    local res, err = httpc:request_uri(backend_url .. request.uri, {
        method = request.method,
        headers = headers,
        body = request.body,
        ssl_verify = false,  -- Default backend is usually local
    })

    if not res then
        ngx.log(ngx.ERR, "[", req_id, "] proxy_to_default_failed err=", err)
        return nil, err
    end

    return res, nil
end

-- Main handler
local function handle()
    local ctx = ngx.ctx
    local req_id = ctx.req_id or "------"
    local start_time = ngx.now()

    -- Read request body first (needed for both paths)
    ngx.req.read_body()
    local body = ngx.req.get_body_data()

    -- If body is in a file (large body), read it
    if not body then
        local body_file = ngx.req.get_body_file()
        if body_file then
            local f = io.open(body_file, "rb")
            if f then
                body = f:read("*all")
                f:close()
            end
        end
    end

    -- Build request object
    local request = {
        method = ngx.req.get_method(),
        uri = ngx.var.request_uri,
        host = ctx.original_host or ngx.var.host,
        proxy_host = ctx.proxy_host or ngx.var.host,
        headers = ngx.req.get_headers(),
        body = body,
    }

    -- Check if resolver set use_default flag (no routes, using default backend)
    if ctx.use_default then
        ngx.log(ngx.INFO, "[", req_id, "] content_handler using_default_backend")

        local backend_url = ngx.var.backend
        if not backend_url or backend_url == "" then
            backend_url = config.default
        end

        if not backend_url or backend_url == "" then
            ngx.log(ngx.ERR, "[", req_id, "] content_handler no_default_backend_configured")
            ngx.status = 502
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"error":"No backend configured","code":"NO_BACKEND"}')
            return ngx.exit(502)
        end

        local res, err = proxy_to_default(backend_url, request, req_id)
        if res then
            forward_response(res, req_id)
            ngx.log(ngx.INFO, "[", req_id, "] content_handler default_complete elapsed=", elapsed_ms(start_time), "ms")
            return ngx.exit(ngx.OK)
        end

        ngx.log(ngx.ERR, "[", req_id, "] content_handler default_failed elapsed=", elapsed_ms(start_time), "ms err=", err or "unknown")
        ngx.status = 502
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"error":"Default backend failed","code":"DEFAULT_BACKEND_FAILED"}')
        return ngx.exit(502)
    end

    -- Get routes from context
    local routes = ctx.routes
    if not routes or #routes == 0 then
        ngx.log(ngx.ERR, "[", req_id, "] content_handler no_routes_in_context")
        ngx.status = 502
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"error":"No routes available","code":"NO_ROUTES"}')
        return ngx.exit(502)
    end

    ngx.log(ngx.INFO, "[", req_id, "] content_handler start routes_count=", #routes)

    -- Check if tracing is enabled
    local trace_enabled = ngx.var.http_x_mesh_trace ~= nil

    -- Proxy with failover
    local success, err = proxy.proxy_with_failover(routes, request, req_id, trace_enabled)

    if success then
        ngx.log(ngx.INFO, "[", req_id, "] content_handler complete elapsed=", elapsed_ms(start_time), "ms")
        return ngx.exit(ngx.OK)
    end

    -- All routes failed
    ngx.log(ngx.ERR, "[", req_id, "] content_handler all_routes_failed elapsed=", elapsed_ms(start_time), "ms err=", err or "unknown")

    ngx.status = 502
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"All backend routes failed","code":"ROUTES_EXHAUSTED"}')
    return ngx.exit(502)
end

-- Execute handler
handle()
