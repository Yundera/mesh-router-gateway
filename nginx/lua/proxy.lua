--[[
    proxy.lua - HTTP proxy with failover for mesh-router-gateway

    This module handles HTTP proxying using lua-resty-http with automatic
    failover between multiple routes. When a route fails with a retriable
    error (connection refused, timeout, SSL error), it automatically tries
    the next route.

    Features:
    - Automatic failover between routes on connection errors
    - Passive health tracking (marks routes unhealthy after failures)
    - WebSocket support via upgrade headers
    - Streaming for large responses
    - Request body handling (buffered and chunked)
]]

local http = require "resty.http"
local cjson = require "cjson.safe"

local _M = {}

-- Configuration (loaded at runtime)
local config = dofile("/etc/nginx/lua/config.lua")

-- Errors that should trigger failover to next route
local RETRIABLE_ERRORS = {
    ["connection refused"] = true,
    ["connection reset by peer"] = true,
    ["no route to host"] = true,
    ["network is unreachable"] = true,
    ["timeout"] = true,
    ["connection timed out"] = true,
    ["handshake failed"] = true,
    ["certificate verify failed"] = true,
    ["ssl handshake failed"] = true,
    ["bad ssl client hello"] = true,
}

-- Check if an error should trigger failover
local function is_retriable_error(err)
    if not err then
        return false
    end
    local err_lower = err:lower()
    for pattern, _ in pairs(RETRIABLE_ERRORS) do
        if err_lower:find(pattern, 1, true) then
            return true
        end
    end
    return false
end

-- Get passive health cache
local function get_passive_health_cache()
    return ngx.shared.passive_health
end

-- Generate cache key for passive health
local function get_passive_health_key(route)
    return "ph:" .. route.ip .. ":" .. (route.port or 443)
end

-- Check if route is passively unhealthy
function _M.is_passively_unhealthy(route)
    local cache = get_passive_health_cache()
    if not cache then
        return false
    end

    local key = get_passive_health_key(route)
    local failures = cache:get(key)

    if failures and failures >= config.passive_failure_threshold then
        return true
    end
    return false
end

-- Mark route as failed (increment failure counter)
function _M.mark_route_failed(route, req_id)
    local cache = get_passive_health_cache()
    if not cache then
        return
    end

    local key = get_passive_health_key(route)
    local failures, err = cache:incr(key, 1, 0, config.passive_unhealthy_ttl)

    if failures then
        ngx.log(ngx.WARN, "[", req_id or "------", "] passive_health_failure route=", route.ip, ":", route.port or 443,
            " failures=", failures, " threshold=", config.passive_failure_threshold)
    else
        ngx.log(ngx.ERR, "[", req_id or "------", "] passive_health_incr_failed err=", err)
    end
end

-- Mark route as healthy (clear failure counter)
function _M.mark_route_healthy(route, req_id)
    local cache = get_passive_health_cache()
    if not cache then
        return
    end

    local key = get_passive_health_key(route)
    local failures = cache:get(key)

    if failures and failures > 0 then
        cache:delete(key)
        ngx.log(ngx.INFO, "[", req_id or "------", "] passive_health_recovered route=", route.ip, ":", route.port or 443)
    end
end

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
    headers["Host"] = request.proxy_host or request.host

    -- Add forwarding headers
    headers["X-Real-IP"] = ngx.var.remote_addr
    headers["X-Forwarded-For"] = ngx.var.proxy_add_x_forwarded_for or ngx.var.remote_addr
    headers["X-Forwarded-Proto"] = ngx.var.scheme
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

-- Proxy with failover through multiple routes
function _M.proxy_with_failover(routes, request, req_id, trace_enabled)
    local max_retries = math.min(#routes, config.failover_max_retries)
    local tried_routes = {}
    local last_err = nil

    for i = 1, max_retries do
        local route = routes[i]
        if not route then
            break
        end

        table.insert(tried_routes, route.source or "unknown")

        -- Try to proxy to this route
        local res, err = proxy_to_route(route, request, req_id)

        if res then
            -- Success - mark route healthy and forward response
            _M.mark_route_healthy(route, req_id)

            -- Set mesh route header if tracing enabled
            if trace_enabled then
                local route_path = table.concat(tried_routes, ",") .. ",pcs"
                ngx.header["X-Mesh-Route"] = route_path
            end

            forward_response(res, req_id)
            return true
        end

        -- Failed - mark route as failed
        _M.mark_route_failed(route, req_id)
        last_err = err

        -- Check if we should failover
        if not is_retriable_error(err) then
            ngx.log(ngx.WARN, "[", req_id, "] proxy_non_retriable_error err=", err, " stopping_failover")
            break
        end

        if i < max_retries then
            ngx.log(ngx.INFO, "[", req_id, "] proxy_failover from=", route.ip, " to=", routes[i + 1].ip, " attempt=", i + 1)
        end
    end

    -- All routes failed
    ngx.log(ngx.ERR, "[", req_id, "] proxy_all_routes_failed tried=", #tried_routes, " last_err=", last_err or "unknown")

    -- Set mesh route header for failed requests too
    if trace_enabled then
        local route_path = table.concat(tried_routes, ",") .. ",failed"
        ngx.header["X-Mesh-Route"] = route_path
    end

    return false, last_err
end

return _M
