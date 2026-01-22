--[[
    resolver.lua - Domain resolution for mesh-router-gateway

    Resolves incoming domain requests to backend IP:port by querying
    the mesh-router-backend API.

    Flow:
    1. Extract subdomain from Host header
    2. Check local cache (lua_shared_dict)
    3. If cache miss, query mesh-router-backend /resolve/:domain
    4. Cache result and set $backend variable for proxy_pass
]]

local http = require "resty.http"
local cjson = require "cjson.safe"

-- Configuration (from environment variables via config.lua)
local config = dofile("/etc/nginx/lua/config.lua")

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

-- Helper: Query mesh-router-backend for domain resolution
local function resolve_from_backend(subdomain)
    local httpc = http.new()
    httpc:set_timeout(5000)  -- 5 second timeout

    local url = config.backend_url .. "/resolve/" .. subdomain

    local res, err = httpc:request_uri(url, {
        method = "GET",
        headers = {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
        },
        ssl_verify = false,  -- TODO: Enable in production with proper CA bundle
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

-- Helper: Build backend URL from resolution data
local function build_backend_url(data)
    local host_ip = data.hostIp
    local target_port = data.targetPort or 443

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

-- Main resolution logic
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

    -- Check cache first
    local cache = get_cache()
    if cache then
        local cached = cache:get(subdomain)
        if cached then
            ngx.var.backend = cached
            return
        end
    end

    -- Query backend
    local data, err = resolve_from_backend(subdomain)

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

    -- Build backend URL
    local backend_url = build_backend_url(data)

    if not backend_url then
        ngx.log(ngx.ERR, "Could not build backend URL for: ", subdomain)
        ngx.exit(ngx.HTTP_BAD_GATEWAY)
        return
    end

    -- Cache the result
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
