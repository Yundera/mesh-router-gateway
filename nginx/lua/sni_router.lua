--[[
    sni_router.lua - TLS front (stream, ssl_preread): pass through or terminate

    One key per name: a user's dot-form names (<app>.<user>.<zone>) and apex
    (<user>.<zone>) are the box's, so their TLS goes to the box untouched over its best
    TLS-capable route (public IP, or the WireGuard address of a routed tunnel). The
    gateway cannot read that traffic.

    Everything else is terminated here (the HTTP TLS server on a local socket): dash names
    (<app>-<user>.<zone>), the gateway's own names (gateway.entrypoint.<zone>), reserved
    labels, unknown users, and boxes with no TLS-capable route (provider-only tunnel).

    Decision per user label, cached CACHE_TTL seconds in ngx.shared.sni_routes
    ("host:port" to pass through, "-" to terminate).
]]

local http = require "resty.http"
local cjson = require "cjson.safe"
local config = require "config"

local _M = {}

local CACHE_TTL = 60
local TERMINATE = "unix:/var/run/nginx-tls.sock"

-- Labels that are never users (architecture.md §3.4), plus the gateway's own entrypoint.
local RESERVED = {
    ip = true, box = true, acme = true, www = true, mail = true, router = true,
    gw = true, s1 = true, s2 = true, entrypoint = true, gateway = true,
}

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

-- The user label of a passthrough candidate, or nil (terminate).
local function candidate_label(name)
    local zone = (config.server_domain or ""):lower()
    local suffix = "." .. zone
    if zone == "" or #name <= #suffix or name:sub(-#suffix) ~= suffix then
        return nil
    end
    local prefix = name:sub(1, #name - #suffix)
    local label = prefix:match("([^.]+)$")
    if not label then
        return nil
    end
    if prefix == label and label:find("-", 1, true) then
        return nil -- dash form: the gateway's name
    end
    if RESERVED[label] then
        return nil
    end
    return label
end

-- "host:port" of the box's best TLS-capable route, or nil.
local function tls_target(routes)
    local best, best_prio
    for _, r in ipairs(routes or {}) do
        local target
        if r.source == "agent" and (r.scheme or "https") == "https" and r.ip and not r.ip:find(":", 1, true) then
            target = r.ip .. ":" .. (r.port or 443)
        elseif r.source == "tunnel" and type(r.tunnelIp) == "string" and tunnel_base then
            local n = ipv4_to_int(r.tunnelIp)
            if n and math.floor(n / tunnel_block) == tunnel_base then
                target = r.tunnelIp .. ":443"
            end
        end
        local prio = r.priority or 999
        if target and (not best or prio < best_prio) then
            best, best_prio = target, prio
        end
    end
    return best
end

local function lookup(label)
    local httpc = http.new()
    httpc:set_timeout(2000)
    local res, err = httpc:request_uri(config.backend_url .. "/resolve/v2/" .. label, { method = "GET" })
    if not res then
        return nil, "backend: " .. (err or "?")
    end
    if res.status ~= 200 then
        return "-" -- not a user (404) or no answer: terminate
    end
    local data = cjson.decode(res.body)
    if not data then
        return nil, "bad backend answer"
    end
    return tls_target(data.routes) or "-"
end

function _M.route()
    local name = ngx.var.ssl_preread_server_name
    if not name or name == "" then
        return
    end
    local label = candidate_label(name:lower())
    if not label then
        return
    end

    local cache = ngx.shared.sni_routes
    local target = cache:get(label)
    if not target then
        local err
        target, err = lookup(label)
        if not target then
            ngx.log(ngx.WARN, "sni_router: ", label, ": ", err, " (terminating)")
            return -- not cached: the next handshake asks again
        end
        cache:set(label, target, CACHE_TTL)
    end

    if target ~= "-" then
        ngx.var.tls_upstream = target
        ngx.var.tls_mode = "passthrough"
    end
end

_M.TERMINATE = TERMINATE

return _M
