--[[
    resolver.lua - Domain resolution for mesh-router-gateway (v2)

    Resolves incoming domain requests to backend IP:port by querying
    the mesh-router-backend API. Supports multiple routes with priority,
    passive health checking, and automatic failover.

    Flow:
    1. Extract subdomain from Host header
    2. Check local cache for routes
    3. If cache miss, query mesh-router-backend /resolve/v2/:domain
    4. Sort routes by passive health status and priority
    5. Store routes in ngx.ctx for content_handler.lua to use with failover
    6. If domain not found/no routes, fall back to config.default (landing page)

    Route Selection (with failover support):
    - Routes sorted by priority (lower = better)
    - Passively unhealthy routes are deprioritized but kept as fallback
    - Content handler (content_handler.lua) tries routes in order with failover
    - Failed routes are marked unhealthy for future requests (passive health)

    Default Backend Fallback:
    - If config.default is set, unclaimed domains route to landing page
    - Applies to: no subdomain, domain not found, no routes registered
    - Set DEFAULT_BACKEND env var to enable (e.g., http://landing-page:80)
]]

local http = require "resty.http"
local cjson = require "cjson.safe"
local proxy = require "proxy"

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

-- Cache key prefixes
local CACHE_PREFIX_ROUTES = "routes:"
local CACHE_PREFIX_HEALTH = "health:"

-- Health check settings
local HEALTH_CHECK_TIMEOUT = 2000  -- 2 seconds
local HEALTH_CACHE_TTL = 300       -- 5 minutes

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

-- Helper: Generate cache key for route health
local function get_health_cache_key(route)
    return CACHE_PREFIX_HEALTH .. route.ip .. ":" .. (route.port or 443)
end

-- Helper: Check if route health is cached and healthy
local function get_cached_health(cache, route)
    if not cache then
        return nil
    end

    local key = get_health_cache_key(route)
    local cached = cache:get(key)

    if cached then
        local health = cjson.decode(cached)
        return health
    end

    return nil
end

-- Helper: Cache health status for a route
local function cache_health(cache, route, healthy)
    if not cache then
        return
    end

    local key = get_health_cache_key(route)
    local health = {
        healthy = healthy,
        checkedAt = ngx.now()
    }

    local ok, err = cache:set(key, cjson.encode(health), HEALTH_CACHE_TTL)
    if not ok then
        ngx.log(ngx.WARN, "Failed to cache health: ", err)
    end
end

-- Helper: Perform health check for a route (if configured)
local function check_route_health(route, user_domain)
    -- No health check configured = assume healthy
    if not route.healthCheck or not route.healthCheck.path then
        return true
    end

    local hc = route.healthCheck
    local host_header = hc.host or user_domain

    local httpc = http.new()
    httpc:set_timeout(HEALTH_CHECK_TIMEOUT)

    -- Build health check URL
    local target_port = route.port or 443
    local protocol = target_port == 443 and "https" or "http"
    local host_part = route.ip
    if route.ip:find(":") then
        host_part = "[" .. route.ip .. "]"
    end

    local url = protocol .. "://" .. host_part .. ":" .. target_port .. hc.path

    local res, err = httpc:request_uri(url, {
        method = "HEAD",
        headers = {
            ["Host"] = host_header,
            ["X-Health-Check"] = "1",
        },
        ssl_verify = true,
    })

    if not res then
        ngx.log(ngx.WARN, "Health check failed for ", route.ip, ":", target_port, " - ", err)
        return false
    end

    local healthy = res.status == 200
    if not healthy then
        ngx.log(ngx.WARN, "Health check returned ", res.status, " for ", route.ip, ":", target_port)
    end

    return healthy
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

-- Helper: Sort and prepare routes for failover
-- Filters by scheme, sorts by passive health status and priority
-- Returns all routes (healthy first, then unhealthy as fallback)
-- Supports force routing via X-Mesh-Force header
local function prepare_routes_for_failover(routes, user_domain, cache, req_id)
    if not routes or #routes == 0 then
        return nil
    end

    -- Check for force routing header
    local force_mode = ngx.var.http_x_mesh_force or ""

    -- Skip scheme filtering - let priority and failover handle route selection
    -- Tunnel routes always use HTTP internally regardless of client scheme
    -- The build_backend_url_from_route function handles protocol selection per route type
    local scheme_filtered_routes = routes

    if #scheme_filtered_routes == 0 then
        return routes
    end

    -- Handle forced routing (direct or tunnel) - return single route
    if force_mode == "direct" then
        for _, route in ipairs(scheme_filtered_routes) do
            if route.source == "agent" then
                ngx.log(ngx.INFO, "[", req_id, "] force_routing mode=direct source=agent ip=", route.ip)
                return {route}
            end
        end
        ngx.log(ngx.WARN, "[", req_id, "] force_routing mode=direct no_agent_route_found")
    elseif force_mode == "tunnel" then
        for _, route in ipairs(scheme_filtered_routes) do
            if route.source == "tunnel" then
                ngx.log(ngx.INFO, "[", req_id, "] force_routing mode=tunnel source=tunnel ip=", route.ip)
                return {route}
            end
        end
        ngx.log(ngx.WARN, "[", req_id, "] force_routing mode=tunnel no_tunnel_route_found")
    end

    -- Separate healthy and passively unhealthy routes
    local healthy_routes = {}
    local unhealthy_routes = {}

    for _, route in ipairs(scheme_filtered_routes) do
        if proxy.is_passively_unhealthy(route) then
            table.insert(unhealthy_routes, route)
            ngx.log(ngx.INFO, "[", req_id, "] route_passively_unhealthy ip=", route.ip, ":", route.port or 443)
        else
            table.insert(healthy_routes, route)
        end
    end

    -- Sort each group by priority (lower = better)
    local function by_priority(a, b)
        return (a.priority or 999) < (b.priority or 999)
    end
    table.sort(healthy_routes, by_priority)
    table.sort(unhealthy_routes, by_priority)

    -- Combine: healthy routes first, then unhealthy as fallback
    local sorted_routes = {}
    for _, route in ipairs(healthy_routes) do
        table.insert(sorted_routes, route)
    end
    for _, route in ipairs(unhealthy_routes) do
        table.insert(sorted_routes, route)
    end

    ngx.log(ngx.INFO, "[", req_id, "] routes_prepared total=", #sorted_routes, " healthy=", #healthy_routes, " unhealthy=", #unhealthy_routes)

    return sorted_routes
end

-- Helper: Select best healthy route (legacy - kept for compatibility)
-- Now wraps prepare_routes_for_failover and returns first route
local function select_best_route(routes, user_domain, cache, req_id)
    local sorted = prepare_routes_for_failover(routes, user_domain, cache, req_id)
    if sorted and #sorted > 0 then
        return sorted[1]
    end
    return nil
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
    local cached_routes_json = nil
    if cache then
        cached_routes_json = cache:get("routes:" .. subdomain)
        if cached_routes_json then
            local cached_routes = cjson.decode(cached_routes_json)
            if cached_routes and #cached_routes > 0 then
                ngx.log(ngx.INFO, "[", req_id, "] cache_hit subdomain=", subdomain, " routes_count=", #cached_routes, " elapsed=", elapsed_ms(start_time), "ms")
                -- Prepare routes with passive health filtering
                local sorted_routes = prepare_routes_for_failover(cached_routes, host, cache, req_id)
                ngx.ctx.routes = sorted_routes
                ngx.req.set_header("X-Request-ID", req_id)
                return
            end
        end
    end

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

    -- Build user domain for health checks
    local user_domain = (data.domainName or subdomain) .. "." .. (data.serverDomain or config.server_domain)

    -- Prepare routes for failover (sorted by passive health and priority)
    local sorted_routes = prepare_routes_for_failover(routes, user_domain, cache, req_id)

    if not sorted_routes or #sorted_routes == 0 then
        ngx.log(ngx.ERR, "[", req_id, "] resolve_error reason=no_healthy_routes subdomain=", subdomain, " elapsed=", elapsed_ms(start_time), "ms")
        ngx.exit(ngx.HTTP_BAD_GATEWAY)
        return
    end

    -- Log first (primary) route for debugging
    local primary_route = sorted_routes[1]
    local protocol = primary_route.scheme or "https"
    if primary_route.source == "tunnel" then
        protocol = "http"
    end

    ngx.log(ngx.INFO, "[", req_id, "] primary_route ip=", primary_route.ip, " port=", primary_route.port or 443,
        " scheme=", protocol, " source=", primary_route.source or "unknown",
        " priority=", primary_route.priority or "nil", " total_routes=", #sorted_routes)

    -- Cache routes for future requests (cache raw routes, not sorted)
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

    ngx.log(ngx.INFO, "[", req_id, "] resolve_complete subdomain=", subdomain, " routes=", #sorted_routes, " elapsed=", elapsed_ms(start_time), "ms")

    -- Set request ID header for correlation in logs
    ngx.req.set_header("X-Request-ID", req_id)

    -- Check if this is a WebSocket request
    -- WebSocket requests use proxy_pass (no failover) because lua-resty-http
    -- doesn't support WebSocket protocol upgrades
    if is_websocket_request() then
        local best_route = sorted_routes[1]
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

    -- Store routes in context for content_handler (regular HTTP requests)
    ngx.ctx.routes = sorted_routes
end

-- Execute resolution
resolve()
