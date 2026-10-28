--[[
    resolver.lua - Domain resolution for mesh-router-gateway

    Resolves incoming domain requests to backend IP:port by querying
    the mesh-router-backend API. Supports route selection by priority.
    Sets nginx variables for native proxy_pass handling.

    Flow:
    1. Extract subdomain from Host header
    2. Check local cache for routes
    3. If cache miss, query mesh-router-backend /resolve/v2/:domain
    4. Select best route by priority
    5. Set nginx variables ($backend, $proxy_host, $ws_upgrade, etc.)
    6. If domain not found/no routes, fall back to config.default (landing page)

    Nginx Variables Set:
    - $backend: Target URL (e.g., https://203.0.113.10:443)
    - $proxy_host: Host header for downstream routing
    - $proxy_ssl_name: SNI name for HTTPS backends
    - $ws_upgrade: "websocket" for WS requests, "" otherwise
    - $ws_connection: "upgrade" for WS requests, "" otherwise
    - $mesh_route: Route tracing info (when X-Mesh-Trace is set)

    Route Selection:
    - Routes sorted by priority (lower = better)
    - Best route selected (no failover - routes validated at registration)

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
    -- Check custom header from CF Worker (CF doesn't forward Upgrade header)
    if ngx.var.http_x_mesh_websocket == "1" then
        return true
    end
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

-- Serve-stale (a second gateway on another host must outlive the backend): every answer is
-- also kept under "stale:" for config.stale_ttl seconds, read only when the backend cannot
-- answer (transport error or 5xx, never a 404). After a failure the backend is skipped for
-- BACKEND_DOWN_HOLD seconds when it could not be reached at all (a 5xx is one name's
-- problem), so requests don't each wait out the connect timeouts.
local STALE_PREFIX = "stale:"
local BACKEND_DOWN_KEY = "backend:down"
local BACKEND_DOWN_HOLD = 30

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
    if host:sub(-#suffix) ~= suffix then
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

-- Helper: Extract the app label (everything before the username segment).
-- Mirrors the CF Worker's parseHost. Used for the usage (DAU) KPI.
-- e.g. "nextcloud.alice.example.com" -> "nextcloud"
--      "admin-alice.example.com"     -> "admin"
--      "alice.example.com"           -> "_root" (bare user domain, no app)
local function extract_app(host, server_domain)
    if not host or not server_domain then
        return "_root"
    end
    host = host:gsub(":%d+$", "")
    local suffix = "." .. server_domain
    local prefix = host:sub(1, #host - #suffix)
    if prefix == "" then
        return "_root"
    end

    local parts = {}
    for part in prefix:gmatch("[^.]+") do
        table.insert(parts, part)
    end

    -- Dot-separated: app is everything except the last (username) segment.
    if #parts > 1 then
        table.remove(parts)
        return table.concat(parts, ".")
    end

    -- Single segment: dash-separated "app-user" -> app is before the last dash.
    local seg = parts[1]
    local dash_pos = seg:match(".*()-")
    if dash_pos then
        local app = seg:sub(1, dash_pos - 1)
        if app ~= "" then
            return app
        end
    end

    return "_root"
end

-- Helper: Query mesh-router-backend for domain resolution (v2 API)
local function resolve_from_backend_v2(subdomain, req_id)
    local start_time = ngx.now()
    local url = config.backend_url .. "/resolve/v2/" .. subdomain
    ngx.log(ngx.INFO, "[", req_id, "] backend_query_start url=", url)

    local res, err
    for attempt = 1, BACKEND_MAX_RETRIES do
        local httpc = http.new()
        httpc:set_timeouts(2000, 5000, 5000)  -- connect fast: a dead host must not stall requests

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

    if res.status >= 500 then
        ngx.log(ngx.ERR, "[", req_id, "] backend_status_error status=", res.status, " subdomain=", subdomain)
        return nil, "status_" .. res.status
    end
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
        httpc:set_timeouts(2000, 5000, 5000)

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

-- Routed tunnel (config.tunnel_subnet): parsed once per worker.
local function ipv4_to_int(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then
        return nil
    end
    return ((tonumber(a) * 256 + tonumber(b)) * 256 + tonumber(c)) * 256 + tonumber(d)
end

local tunnel_block, tunnel_base
do
    local net, prefix = (config.tunnel_subnet or ""):match("^([%d.]+)/(%d+)$")
    local n = net and ipv4_to_int(net)
    prefix = tonumber(prefix)
    if n and prefix and prefix >= 8 and prefix <= 32 then
        tunnel_block = 2 ^ (32 - prefix)
        tunnel_base = math.floor(n / tunnel_block)
    end
end

-- Whether a tunnel route's WireGuard address lies in the subnet this gateway routes.
local function in_tunnel_subnet(route)
    if route.source ~= "tunnel" or not tunnel_base or type(route.tunnelIp) ~= "string" then
        return false
    end
    local n = ipv4_to_int(route.tunnelIp)
    return n ~= nil and math.floor(n / tunnel_block) == tunnel_base
end

-- The box's WireGuard address when this tunnel route can be served routed: the gateway
-- routes the tunnel subnet, the address the box registered lies inside it, and the route
-- takes HTTPS (the HTTP route carries tunnelIp only to name its provider).
local function routed_tunnel_ip(route)
    if (route.scheme or "https") == "https" and in_tunnel_subnet(route) then
        return route.tunnelIp
    end
    return nil
end

-- A tunnel route through another host's provider (several providers, one per gateway
-- host): its address and WireGuard subnet mean nothing here, so it is never used.
local function foreign_tunnel(route)
    return route.source == "tunnel" and tunnel_base ~= nil and type(route.tunnelIp) == "string"
        and not in_tunnel_subnet(route)
end

-- Protocol towards the box:
-- - routed tunnel: HTTPS to the box's Caddy through WireGuard (TLS ends on the box)
-- - provider tunnel: HTTP (the provider's nginx only speaks HTTP, TLS ended here)
-- - agent routes: the route scheme (direct connection to the PCS)
local function route_protocol(route)
    if routed_tunnel_ip(route) then
        return "https"
    end
    if route.source == "tunnel" then
        return "http"
    end
    return route.scheme or "https"
end

-- Helper: Build backend URL from route
-- Always connects via route.ip (no DNS needed), or the box's WireGuard address on a
-- routed tunnel. For domain-type routes, route.domain is used for SNI via proxy_ssl_name.
local function build_backend_url_from_route(route)
    local routed_ip = routed_tunnel_ip(route)
    if routed_ip then
        return "https://" .. routed_ip .. ":443"
    end

    local host_ip = route.ip
    local target_port = route.port or 443

    if not host_ip then
        return nil
    end

    local protocol = route_protocol(route)

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

    -- Tunnel routes through another host's provider are not ours to use
    local own = {}
    for _, route in ipairs(routes) do
        if not foreign_tunnel(route) then
            table.insert(own, route)
        end
    end
    routes = own

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
    local target = (best.type == "domain" and best.domain) and best.domain or best.ip
    ngx.log(ngx.INFO, "[", req_id, "] route_selected target=", target,
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

    -- Stash the app label for the usage (DAU) KPI, read in log_by_lua_block.
    ngx.ctx.app_name = extract_app(host, config.server_domain)

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

    -- Routes are cached unfiltered: each request filters by its own scheme
    -- (X-Forwarded-Proto or connection scheme)
    local original_scheme = ngx.var.http_x_forwarded_proto or ngx.var.scheme

    -- Check cache for routes data (JSON string)
    local best_route = nil
    local cached_routes_json = nil
    if cache then
        cached_routes_json = cache:get("routes:" .. subdomain)
        if cached_routes_json then
            local cached_routes = cjson.decode(cached_routes_json)
            if cached_routes and #cached_routes > 0 then
                ngx.log(ngx.INFO, "[", req_id, "] cache_hit subdomain=", subdomain, " routes_count=", #cached_routes, " elapsed=", elapsed_ms(start_time), "ms")
                -- Recover the uid cached alongside the routes so cache-hit requests
                -- still carry it into log_by_lua_block (the backend is not re-queried).
                local cached_uid = cache:get("uid:" .. subdomain)
                if cached_uid and cached_uid ~= "" then
                    ngx.ctx.user_id = cached_uid
                end
                -- Select best route by priority
                best_route = select_best_route(filter_routes_by_scheme(cached_routes, original_scheme), req_id)
                -- Continue to WebSocket check below (don't return early)
            end
        end
    end

    -- Only fetch from backend if no cache hit
    if not best_route then
        ngx.log(ngx.INFO, "[", req_id, "] cache_miss subdomain=", subdomain)

        -- Query backend (try v2 first, fall back to v1 when v2 does not know the name),
        -- unless it failed moments ago
        local data, err
        if cache and cache:get(BACKEND_DOWN_KEY) then
            err = "backend_down_hold"
        else
            data, err = resolve_from_backend_v2(subdomain, req_id)

            if not data and err == "not_found" then
                -- Try v1 API as fallback
                ngx.log(ngx.INFO, "[", req_id, "] trying_v1_fallback")
                data, err = resolve_from_backend_v1(subdomain, req_id)
            end

            if not data and err ~= "not_found" and err ~= "no_ip" and err ~= "invalid_response"
                and not err:find("^status_") and cache then
                cache:set(BACKEND_DOWN_KEY, true, BACKEND_DOWN_HOLD)
            end
        end

        -- Backend unreachable: the last answer it gave, if any
        local stale = false
        if not data and err ~= "not_found" and err ~= "no_ip" and cache and (config.stale_ttl or 0) > 0 then
            local stale_json = cache:get(STALE_PREFIX .. "routes:" .. subdomain)
            local stale_routes = stale_json and cjson.decode(stale_json)
            if stale_routes then
                ngx.log(ngx.WARN, "[", req_id, "] resolve_stale subdomain=", subdomain, " err=", err)
                data = { routes = stale_routes, userId = cache:get(STALE_PREFIX .. "uid:" .. subdomain) }
                stale = true
            end
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

        -- Capture uid for the usage (DAU) KPI (read in log_by_lua_block).
        ngx.ctx.user_id = data.userId

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

        -- Select best route by priority among those matching the request scheme
        best_route = select_best_route(filter_routes_by_scheme(routes, original_scheme), req_id)

        if not best_route then
            ngx.log(ngx.ERR, "[", req_id, "] resolve_error reason=no_route_selected subdomain=", subdomain, " elapsed=", elapsed_ms(start_time), "ms")
            ngx.exit(ngx.HTTP_BAD_GATEWAY)
            return
        end

        -- Log selected route for debugging
        local protocol = route_protocol(best_route)

        ngx.log(ngx.INFO, "[", req_id, "] route_selected ip=", best_route.ip, " port=", best_route.port or 443,
            " scheme=", protocol, " source=", best_route.source or "unknown",
            " priority=", best_route.priority or "nil")

        -- Cache routes for future requests (cache raw routes, not selected); a stale
        -- answer is not re-cached, so the backend is asked again once it is back
        if cache and not stale then
            local cache_ttl = config.cache_ttl or 60
            local routes_json = cjson.encode(routes)
            local ok, cache_err = cache:set("routes:" .. subdomain, routes_json, cache_ttl)
            if not ok then
                ngx.log(ngx.WARN, "[", req_id, "] cache_set_failed err=", cache_err)
            else
                ngx.log(ngx.INFO, "[", req_id, "] cache_set subdomain=", subdomain, " ttl=", cache_ttl)
            end
            -- Cache uid alongside routes so cache-hit requests keep it for usage tracking.
            if data.userId and data.userId ~= "" then
                cache:set("uid:" .. subdomain, data.userId, cache_ttl)
            end
            if (config.stale_ttl or 0) > 0 then
                cache:set(STALE_PREFIX .. "routes:" .. subdomain, routes_json, config.stale_ttl)
                if data.userId and data.userId ~= "" then
                    cache:set(STALE_PREFIX .. "uid:" .. subdomain, data.userId, config.stale_ttl)
                end
            end
        end
    end  -- end if not best_route

    ngx.log(ngx.INFO, "[", req_id, "] resolve_complete subdomain=", subdomain, " elapsed=", elapsed_ms(start_time), "ms")

    -- Set request ID header for correlation in logs
    ngx.req.set_header("X-Request-ID", req_id)

    -- Build backend URL from selected route
    local backend_url = build_backend_url_from_route(best_route)

    if not backend_url then
        ngx.log(ngx.ERR, "[", req_id, "] resolve_error reason=invalid_backend subdomain=", subdomain)
        ngx.exit(ngx.HTTP_BAD_GATEWAY)
        return
    end

    -- Set nginx variables for proxy_pass
    ngx.var.backend = backend_url

    -- Set proxy host for downstream routing (Caddy needs original Host header)
    -- CF Worker mode: use X-Mesh-Route-Host header
    -- Direct mode: use original Host header
    ngx.var.proxy_host = ngx.var.http_x_mesh_route_host or host

    -- SNI on HTTPS backends: the box's hop name <label>.box.<zone>, which its cert0 (mesh
    -- CA, the only CA trusted on this hop) carries. The connection is verified against
    -- that box, whatever IP or tunnel it goes through.
    if route_protocol(best_route) == "https" then
        ngx.var.proxy_ssl_name = subdomain:lower() .. ".box." .. (config.server_domain or ""):lower()
    end

    -- Set WebSocket upgrade headers if this is a WebSocket request
    -- CF Worker sends X-Mesh-WebSocket but not the actual Upgrade header
    -- For HTTP requests, set empty strings (preserves default behavior)
    if is_websocket_request() then
        ngx.var.ws_upgrade = ngx.var.http_upgrade or "websocket"
        ngx.var.ws_connection = "upgrade"
        ngx.log(ngx.INFO, "[", req_id, "] websocket_request backend=", backend_url)
    else
        ngx.var.ws_upgrade = ""
        ngx.var.ws_connection = ""
    end

    -- Set mesh route for tracing
    local trace_enabled = ngx.var.http_x_mesh_trace ~= nil
    if trace_enabled then
        local label = best_route.source or "unknown"
        if routed_tunnel_ip(best_route) then
            label = "tunnel-routed"
        end
        ngx.var.mesh_route = label .. ",pcs"
    else
        ngx.var.mesh_route = ""
    end

    ngx.log(ngx.INFO, "[", req_id, "] request_routing backend=", backend_url)
end

-- Execute resolution
resolve()
