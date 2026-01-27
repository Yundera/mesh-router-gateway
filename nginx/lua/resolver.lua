--[[
    resolver.lua - Domain resolution for mesh-router-gateway (v2)

    Resolves incoming domain requests to backend IP:port by querying
    the mesh-router-backend API. Supports multiple routes with priority
    and optional health checking.

    Flow:
    1. Extract subdomain from Host header
    2. Check local cache (routes + health status)
    3. If cache miss, query mesh-router-backend /resolve/v2/:domain
    4. Select best healthy route by priority
    5. Optional: Perform lazy health check if configured
    6. Cache result and set $backend variable for proxy_pass

    Route Selection:
    - Routes sorted by priority (lower = better)
    - If route has healthCheck configured, verify health before using
    - If no healthCheck, assume route is healthy
    - Fallback to first route if all health checks fail
]]

local http = require "resty.http"
local cjson = require "cjson.safe"

-- Configuration (from environment variables via config.lua)
local config = dofile("/etc/nginx/lua/config.lua")

-- Cache key prefixes
local CACHE_PREFIX_ROUTES = "routes:"
local CACHE_PREFIX_HEALTH = "health:"

-- Health check settings
local HEALTH_CHECK_TIMEOUT = 2000  -- 2 seconds
local HEALTH_CACHE_TTL = 300       -- 5 minutes

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
    -- "app.alice" -> "alice"
    -- "alice" -> "alice"
    local parts = {}
    for part in subdomain:gmatch("[^.]+") do
        table.insert(parts, part)
    end

    if #parts == 0 then
        return nil
    end

    -- Return the rightmost part (username)
    return parts[#parts]
end

-- Helper: Query mesh-router-backend for domain resolution (v2 API)
local function resolve_from_backend_v2(subdomain)
    local httpc = http.new()
    httpc:set_timeout(5000)  -- 5 second timeout

    local url = config.backend_url .. "/resolve/v2/" .. subdomain

    local res, err = httpc:request_uri(url, {
        method = "GET",
        headers = {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
        },
        ssl_verify = true,  -- TODO: Enable in production with proper CA bundle
    })

    if not res then
        ngx.log(ngx.ERR, "Failed to query backend: ", err)
        return nil, err
    end

    if res.status ~= 200 then
        ngx.log(ngx.WARN, "Backend returned status ", res.status, " for subdomain: ", subdomain)
        return nil, "not_found"
    end

    local data, decode_err = cjson.decode(res.body)
    if not data then
        ngx.log(ngx.ERR, "Failed to decode backend response: ", decode_err)
        return nil, "invalid_response"
    end

    return data, nil
end

-- Helper: Fallback to v1 API for backward compatibility
local function resolve_from_backend_v1(subdomain)
    local httpc = http.new()
    httpc:set_timeout(5000)

    local url = config.backend_url .. "/resolve/" .. subdomain

    local res, err = httpc:request_uri(url, {
        method = "GET",
        headers = {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
        },
        ssl_verify = true,
    })

    if not res then
        return nil, err
    end

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

    -- Determine protocol based on port
    local protocol = "http"
    if target_port == 443 then
        protocol = "https"
    end

    -- Handle IPv6 addresses (need brackets)
    local host_part = host_ip
    if host_ip:find(":") then
        host_part = "[" .. host_ip .. "]"
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

-- Helper: Select best healthy route
local function select_best_route(routes, user_domain, cache)
    if not routes or #routes == 0 then
        return nil
    end

    -- Sort routes by priority (lower = better)
    table.sort(routes, function(a, b)
        return (a.priority or 999) < (b.priority or 999)
    end)

    -- Find first healthy route
    for _, route in ipairs(routes) do
        -- No health check = assume healthy
        if not route.healthCheck or not route.healthCheck.path then
            return route
        end

        -- Check cached health status
        local cached_health = get_cached_health(cache, route)

        if cached_health then
            -- Use cached result if fresh
            if cached_health.healthy then
                return route
            end
            -- Cached as unhealthy, skip
        else
            -- No cached health, perform lazy health check
            local healthy = check_route_health(route, user_domain)
            cache_health(cache, route, healthy)

            if healthy then
                return route
            end
        end
    end

    -- All routes with health checks failed, return first route as fallback
    ngx.log(ngx.WARN, "All routes unhealthy, using first route as fallback")
    return routes[1]
end

-- Main resolution logic (v2)
local function resolve()
    local host = ngx.var.host

    if not host then
        ngx.log(ngx.ERR, "No host header present")
        ngx.exit(ngx.HTTP_BAD_REQUEST)
        return
    end

    -- Extract subdomain (username)
    local subdomain = extract_subdomain(host, config.server_domain)

    if not subdomain then
        ngx.log(ngx.WARN, "Could not extract subdomain from host: ", host)
        ngx.exit(ngx.HTTP_NOT_FOUND)
        return
    end

    local cache = get_cache()

    -- Check cache for resolved backend URL
    if cache then
        local cached = cache:get(subdomain)
        if cached then
            ngx.var.backend = cached
            return
        end
    end

    -- Query backend (try v2 first, fall back to v1)
    local data, err = resolve_from_backend_v2(subdomain)

    if not data then
        -- Try v1 API as fallback
        data, err = resolve_from_backend_v1(subdomain)
    end

    if not data then
        if err == "not_found" then
            ngx.log(ngx.WARN, "Domain not found: ", subdomain)
            ngx.exit(ngx.HTTP_NOT_FOUND)
        else
            ngx.log(ngx.ERR, "Resolution failed for ", subdomain, ": ", err)
            ngx.exit(ngx.HTTP_BAD_GATEWAY)
        end
        return
    end

    -- Check if we have routes
    local routes = data.routes
    if not routes or #routes == 0 then
        ngx.log(ngx.WARN, "No routes registered for: ", subdomain)
        ngx.exit(ngx.HTTP_NOT_FOUND)
        return
    end

    -- Build user domain for health checks
    local user_domain = (data.domainName or subdomain) .. "." .. (data.serverDomain or config.server_domain)

    -- Select best healthy route
    local selected_route = select_best_route(routes, user_domain, cache)

    if not selected_route then
        ngx.log(ngx.ERR, "No healthy routes for: ", subdomain)
        ngx.exit(ngx.HTTP_BAD_GATEWAY)
        return
    end

    -- Build backend URL
    local backend_url = build_backend_url_from_route(selected_route)

    if not backend_url then
        ngx.log(ngx.ERR, "Could not build backend URL for: ", subdomain)
        ngx.exit(ngx.HTTP_BAD_GATEWAY)
        return
    end

    -- Cache the result (shorter TTL since routes can change)
    if cache then
        local cache_ttl = config.cache_ttl or 60
        local ok, cache_err = cache:set(subdomain, backend_url, cache_ttl)
        if not ok then
            ngx.log(ngx.WARN, "Failed to cache resolution: ", cache_err)
        end
    end

    -- Set backend variable for proxy_pass
    ngx.var.backend = backend_url
end

-- Execute resolution
resolve()
