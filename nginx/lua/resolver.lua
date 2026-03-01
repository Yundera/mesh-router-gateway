--[[
    resolver.lua - Domain resolution for mesh-router-gateway (v2)

    Resolves incoming domain requests to backend IP:port by querying
    the mesh-router-backend API. Supports route selection by priority.

    Flow:
    1. Extract subdomain from Host header
    2. Check local cache for routes
    3. If cache miss, query mesh-router-backend /resolve/v2/:domain
    4. Select best route by priority
    5. Store route in ngx.ctx for content_handler.lua to use
    6. If domain not found/no routes, fall back to config.default (landing page)

    Route Selection:
    - Routes sorted by priority (lower = better)
    - Best route selected and passed to content_handler
    - No failover - routes are validated at registration time (backend)

    Default Backend Fallback:
    - If config.default is set, unclaimed domains route to landing page
    - Applies to: no subdomain, domain not found, no routes registered
    - Set DEFAULT_BACKEND env var to enable (e.g., http://landing-page:80)
]]

local http = require "resty.http"
local cjson = require "cjson.safe"

-- Configuration (from environment variables via config.lua)
local config = dofile("/etc/nginx/lua/config.lua")

-- Helper: Generate short request ID for tracing
local function get_request_id()
    return string.format("%06x", math.random(0, 0xFFFFFF))
end

-- Helper: Check if request is a WebSocket upgrade
local function is_websocket_request()
    local upgrade = ngx.var.http_upgrade
    if not upgrade then
        return false
    end
    upgrade = upgrade:lower()
    return upgrade == "websocket" or upgrade == "mqtt" or upgrade == "wss"
end

-- Helper: Get elapsed time in ms
local function elapsed_ms(start_time)
    return string.format("%.1f", (ngx.now() - start_time) * 1000)
end

-- Helper: Use default backend as fallback
-- Returns true if fallback was set, false if no default configured
local function use_default_backend(reason, req_id)
    if config.default and config.default ~= "" then
        ngx.log(ngx.INFO, "[", req_id or "------", "] using_default_backend reason=", reason, " backend=", config.default)
        ngx.var.backend = config.default
        -- Signal to content_handler that we're using default backend
        ngx.ctx.use_default = true
        return true
    end
    return false
end

-- Cache key prefix
local CACHE_PREFIX_ROUTES = "routes:"

-- Retry settings for backend queries (handles transient DNS failures)
-- DNS failures seem to recover within ~110ms based on logs, so use 150ms delay
local BACKEND_MAX_RETRIES = 3
local BACKEND_RETRY_DELAY = 0.15  -- 150ms

-- Helper: Get cache instance (accessed at request time, not module load)
local function get_cache()
    return ngx.shared.resolve_cache
end

-- Helper: Extract subdomain from host
-- e.g., "app.alice.example.com" with SERVER_DOMAIN="example.com" -> "alice"
-- e.g., "alice.example.com" with SERVER_DOMAIN="example.com" -> "alice"
local function extract_subdomain(host, server_domain)
    if not host or not server_domain then
        return nil
    end

    -- Remove port if present
    host = host:gsub(":%d+$", "")

    -- Check if host ends with server_domain
    local suffix = "." .. server_domain
    if not host:sub(-#suffix) == suffix then
        return nil
    end

    -- Extract subdomain part (everything before server_domain)
    local subdomain = host:sub(1, #host - #suffix)
    if subdomain == "" then
        return nil
    end

    -- Get the rightmost segment (username)
    -- Supports both dot and dash separators:
    -- "app.alice" -> "alice"
    -- "app-alice" -> "alice"
    -- "alice" -> "alice"
    local parts = {}
    for part in subdomain:gmatch("[^.]+") do
        table.insert(parts, part)
    end

    if #parts == 0 then
        return nil
    end

    -- Get the last dot-separated segment
    local last_segment = parts[#parts]

    -- If it contains a dash, extract the part after the last dash (username)
    -- e.g., "filebrowser-painfulurial" -> "painfulurial"
    local dash_pos = last_segment:match(".*()-")
    if dash_pos then
        local username = last_segment:sub(dash_pos + 1)
        if username ~= "" then
            return username
        end
    end

    -- Return the rightmost part (username)
    return last_segment
end

-- Helper: Query mesh-router-backend for domain resolution (v2 API)
local function resolve_from_backend_v2(subdomain, req_id)
    local start_time = ngx.now()
    local url = config.backend_url .. "/resolve/v2/" .. subdomain
    ngx.log(ngx.INFO, "[", req_id, "] backend_query_start url=", url)

    local res, err
    for attempt = 1, BACKEND_MAX_RETRIES do
        local httpc = http.new()
        httpc:set_timeout(5000)  -- 5 second timeout

        res, err = httpc:request_uri(url, {
            method = "GET",
            headers = {
                ["Content-Type"] = "application/json",
                ["Accept"] = "application/json",
            },
            ssl_verify = true,  -- TODO: Enable in production with proper CA bundle
        })

        if res then
            break  -- Success, exit retry loop
        end

        -- Log retry attempt
        if attempt < BACKEND_MAX_RETRIES then
            ngx.log(ngx.WARN, "[", req_id, "] backend_query_retry attempt=", attempt, " err=", err, " elapsed=", elapsed_ms(start_time), "ms")
            ngx.sleep(BACKEND_RETRY_DELAY)
        end
    end

    if not res then
        ngx.log(ngx.ERR, "[", req_id, "] backend_query_failed err=", err, " attempts=", BACKEND_MAX_RETRIES, " elapsed=", elapsed_ms(start_time), "ms")
        return nil, err
    end

    ngx.log(ngx.INFO, "[", req_id, "] backend_query_done status=", res.status, " elapsed=", elapsed_ms(start_time), "ms")

    if res.status ~= 200 then
        ngx.log(ngx.WARN, "[", req_id, "] backend_status_error status=", res.status, " subdomain=", subdomain)
        return nil, "not_found"
    end

    local data, decode_err = cjson.decode(res.body)
    if not data then
        ngx.log(ngx.ERR, "[", req_id, "] backend_decode_failed err=", decode_err)
        return nil, "invalid_response"
    end

    return data, nil
end

-- Helper: Fallback to v1 API for backward compatibility
local function resolve_from_backend_v1(subdomain, req_id)
    local start_time = ngx.now()
    local url = config.backend_url .. "/resolve/" .. subdomain
    ngx.log(ngx.INFO, "[", req_id, "] backend_v1_query_start url=", url)

    local res, err
    for attempt = 1, BACKEND_MAX_RETRIES do
        local httpc = http.new()
        httpc:set_timeout(5000)

        res, err = httpc:request_uri(url, {
            method = "GET",
            headers = {
                ["Content-Type"] = "application/json",
                ["Accept"] = "application/json",
            },
            ssl_verify = true,
        })

        if res then
            break  -- Success, exit retry loop
        end

        -- Log retry attempt
        if attempt < BACKEND_MAX_RETRIES then
            ngx.log(ngx.WARN, "[", req_id, "] backend_v1_query_retry attempt=", attempt, " err=", err, " elapsed=", elapsed_ms(start_time), "ms")
            ngx.sleep(BACKEND_RETRY_DELAY)
        end
    end

    if not res then
        ngx.log(ngx.ERR, "[", req_id, "] backend_v1_query_failed err=", err, " attempts=", BACKEND_MAX_RETRIES, " elapsed=", elapsed_ms(start_time), "ms")
        return nil, err
    end

    ngx.log(ngx.INFO, "[", req_id, "] backend_v1_query_done status=", res.status, " elapsed=", elapsed_ms(start_time), "ms")

    if res.status ~= 200 then
        return nil, "not_found"
    end

    local data, decode_err = cjson.decode(res.body)
    if not data then
        return nil, "invalid_response"
    end

    -- Convert v1 response to v2 format
    if data.hostIp then
        return {
            userId = data.userId or subdomain,
            domainName = data.domainName or subdomain,
            serverDomain = data.serverDomain,
            routes = {{
                ip = data.hostIp,
                port = data.targetPort or 443,
                priority = 1
            }}
        }, nil
    end

    return nil, "no_ip"
end

-- Helper: Build backend URL from route
local function build_backend_url_from_route(route)
    local host_ip = route.ip
    local target_port = route.port or 443

    if not host_ip then
        return nil
    end

    -- Determine connection protocol:
    -- - Tunnel routes: always use HTTP (tunnel entrance only speaks HTTP, TLS already terminated)
    -- - Agent routes: use route scheme (direct connection to PCS which may speak HTTPS)
    local protocol
    if route.source == "tunnel" then
        protocol = "http"
    else
        protocol = route.scheme or "https"
    end

    -- Build host part with brackets for IPv6
    local host_part
    if host_ip:find(":") then
        host_part = "[" .. host_ip .. "]"
    else
        host_part = host_ip
    end

    return protocol .. "://" .. host_part .. ":" .. target_port
end

-- Helper: Filter routes by scheme (http or https)
-- Returns routes matching the requested scheme, or all routes if no match found
local function filter_routes_by_scheme(routes, required_scheme)
    if not routes or #routes == 0 then
        return routes
    end

    -- If no scheme required, return all routes
    if not required_scheme or required_scheme == "" then
        return routes
    end

    -- Filter routes by scheme
    local filtered = {}
    for _, route in ipairs(routes) do
        -- Route scheme defaults to "https" for backward compatibility
        local route_scheme = route.scheme or "https"
        if route_scheme == required_scheme then
            table.insert(filtered, route)
        end
    end

    -- If no routes match the scheme, fall back to all routes
    -- This maintains backward compatibility with routes that don't have scheme set
    if #filtered == 0 then
        ngx.log(ngx.INFO, "no_routes_for_scheme scheme=", required_scheme, " falling_back_to_all count=", #routes)
        return routes
    end

    return filtered
end

-- Helper: Select best route by priority
-- Supports force routing via X-Mesh-Force header
local function select_best_route(routes, req_id)
    if not routes or #routes == 0 then
        return nil
    end

    -- Check for force routing header
    local force_mode = ngx.var.http_x_mesh_force or ""

    if force_mode == "direct" then
        for _, route in ipairs(routes) do
            if route.source == "agent" then
                ngx.log(ngx.INFO, "[", req_id, "] force_routing mode=direct")
                return route
            end
        end
        ngx.log(ngx.WARN, "[", req_id, "] force_routing mode=direct no_agent_route_found")
    elseif force_mode == "tunnel" then
        for _, route in ipairs(routes) do
            if route.source == "tunnel" then
                ngx.log(ngx.INFO, "[", req_id, "] force_routing mode=tunnel")
                return route
            end
        end
        ngx.log(ngx.WARN, "[", req_id, "] force_routing mode=tunnel no_tunnel_route_found")
    end

    -- Sort by priority (lower = better)
    table.sort(routes, function(a, b)
        return (a.priority or 999) < (b.priority or 999)
    end)

    local best = routes[1]
    ngx.log(ngx.INFO, "[", req_id, "] route_selected ip=", best.ip,
        " port=", best.port, " source=", best.source or "unknown")

    return best
end

-- Main resolution logic (v2)
local function resolve()
    local req_id = get_request_id()
    local start_time = ngx.now()

    -- Store request ID in context for content_handler
    ngx.ctx.req_id = req_id

    -- Host extraction modes:
    -- - X-Mesh-Route-Host present: CF Worker fallback mode → use it for routing
    -- - X-Mesh-Route-Host absent: Direct mode → use Host header
    local host = ngx.var.http_x_mesh_route_host or ngx.var.host

    ngx.log(ngx.INFO, "[", req_id, "] resolve_start host=", host or "nil", " x_mesh_route_host=", ngx.var.http_x_mesh_route_host or "nil")

    if not host then
        ngx.log(ngx.ERR, "[", req_id, "] resolve_error reason=no_host_header")
        ngx.exit(ngx.HTTP_BAD_REQUEST)
        return
    end

    -- Store host info in context for content_handler
    ngx.ctx.original_host = host
    ngx.ctx.proxy_host = host

    -- Set proxy_host for nginx (used by default backend path)
    ngx.var.proxy_host = host

    -- Extract subdomain (username)
    local subdomain = extract_subdomain(host, config.server_domain)

    if not subdomain then
        ngx.log(ngx.WARN, "[", req_id, "] resolve_error reason=invalid_subdomain host=", host)
        if use_default_backend("no_subdomain host=" .. host, req_id) then
            return
        end
        ngx.exit(ngx.HTTP_NOT_FOUND)
        return
    end

    local cache = get_cache()

    -- Check cache for routes data (JSON string)
    local best_route = nil
    local cached_routes_json = nil
    if cache then
        cached_routes_json = cache:get("routes:" .. subdomain)
        if cached_routes_json then
            local cached_routes = cjson.decode(cached_routes_json)
            if cached_routes and #cached_routes > 0 then
                ngx.log(ngx.INFO, "[", req_id, "] cache_hit subdomain=", subdomain, " routes_count=", #cached_routes, " elapsed=", elapsed_ms(start_time), "ms")
                -- Select best route by priority
                best_route = select_best_route(cached_routes, req_id)
                -- Continue to WebSocket check below (don't return early)
            end
        end
    end

    -- Only fetch from backend if no cache hit
    if not best_route then
        ngx.log(ngx.INFO, "[", req_id, "] cache_miss subdomain=", subdomain)

        -- Query backend (try v2 first, fall back to v1)
        local data, err = resolve_from_backend_v2(subdomain, req_id)

        if not data then
            -- Try v1 API as fallback
            ngx.log(ngx.INFO, "[", req_id, "] trying_v1_fallback")
            data, err = resolve_from_backend_v1(subdomain, req_id)
        end

        if not data then
            if err == "not_found" then
                ngx.log(ngx.WARN, "[", req_id, "] resolve_error reason=domain_not_found subdomain=", subdomain, " elapsed=", elapsed_ms(start_time), "ms")
                if use_default_backend("domain_not_found subdomain=" .. subdomain, req_id) then
                    return
                end
                ngx.exit(ngx.HTTP_NOT_FOUND)
            else
                ngx.log(ngx.ERR, "[", req_id, "] resolve_error reason=backend_failed subdomain=", subdomain, " err=", err, " elapsed=", elapsed_ms(start_time), "ms")
                ngx.exit(ngx.HTTP_BAD_GATEWAY)
            end
            return
        end

        -- Check if we have routes
        local routes = data.routes
        if not routes or #routes == 0 then
            ngx.log(ngx.WARN, "[", req_id, "] resolve_error reason=no_routes subdomain=", subdomain, " elapsed=", elapsed_ms(start_time), "ms")
            if use_default_backend("no_routes subdomain=" .. subdomain, req_id) then
                return
            end
            ngx.exit(ngx.HTTP_NOT_FOUND)
            return
        end

        ngx.log(ngx.INFO, "[", req_id, "] routes_found count=", #routes)

        -- Select best route by priority
        best_route = select_best_route(routes, req_id)

        if not best_route then
            ngx.log(ngx.ERR, "[", req_id, "] resolve_error reason=no_route_selected subdomain=", subdomain, " elapsed=", elapsed_ms(start_time), "ms")
            ngx.exit(ngx.HTTP_BAD_GATEWAY)
            return
        end

        -- Log selected route for debugging
        local protocol = best_route.scheme or "https"
        if best_route.source == "tunnel" then
            protocol = "http"
        end

        ngx.log(ngx.INFO, "[", req_id, "] route_selected ip=", best_route.ip, " port=", best_route.port or 443,
            " scheme=", protocol, " source=", best_route.source or "unknown",
            " priority=", best_route.priority or "nil")

        -- Cache routes for future requests (cache raw routes, not selected)
        if cache then
            local cache_ttl = config.cache_ttl or 60
            local routes_json = cjson.encode(routes)
            local ok, cache_err = cache:set("routes:" .. subdomain, routes_json, cache_ttl)
            if not ok then
                ngx.log(ngx.WARN, "[", req_id, "] cache_set_failed err=", cache_err)
            else
                ngx.log(ngx.INFO, "[", req_id, "] cache_set subdomain=", subdomain, " ttl=", cache_ttl)
            end
        end
    end  -- end if not best_route

    ngx.log(ngx.INFO, "[", req_id, "] resolve_complete subdomain=", subdomain, " elapsed=", elapsed_ms(start_time), "ms")

    -- Set request ID header for correlation in logs
    ngx.req.set_header("X-Request-ID", req_id)

    -- Check if this is a WebSocket request
    -- WebSocket requests use proxy_pass (no failover) because lua-resty-http
    -- doesn't support WebSocket protocol upgrades
    if is_websocket_request() then
        local backend_url = build_backend_url_from_route(best_route)

        if not backend_url then
            ngx.log(ngx.ERR, "[", req_id, "] resolve_error reason=invalid_websocket_backend subdomain=", subdomain)
            ngx.exit(ngx.HTTP_BAD_GATEWAY)
            return
        end

        -- Set nginx variables for proxy_pass
        ngx.var.backend = backend_url

        -- Set SSL name for SNI
        local protocol = best_route.scheme or "https"
        if best_route.source == "tunnel" then
            protocol = "http"
        end
        if protocol == "https" then
            ngx.var.proxy_ssl_name = host
        end

        -- Set mesh route for tracing
        local trace_enabled = ngx.var.http_x_mesh_trace ~= nil
        if trace_enabled then
            ngx.var.mesh_route = (best_route.source or "unknown") .. ",pcs"
        else
            ngx.var.mesh_route = ""
        end

        ngx.log(ngx.INFO, "[", req_id, "] websocket_request redirecting to @websocket backend=", backend_url)

        -- Redirect to @websocket internal location
        return ngx.exec("@websocket")
    end

    -- Store route in context for content_handler (regular HTTP requests)
    ngx.ctx.route = best_route
end

-- Execute resolution
resolve()
