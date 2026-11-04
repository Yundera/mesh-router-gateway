--[[
    sni_router.lua - TLS front (stream, ssl_preread): pass through or terminate

    One key per name: a user's dot-form names (<app>.<user>.<zone>) and apex
    (<user>.<zone>) are the box's, so their TLS goes to the box untouched over its best
    TLS-capable route (public IP, or the WireGuard address of a routed tunnel). The
    gateway cannot read that traffic.

    Everything else is terminated here (the HTTP TLS server on a local socket): dash names
    (<app>-<user>.<zone>), the gateway's own names (gateway.entrypoint.<zone>), reserved
    labels, unknown users, and boxes with no TLS-capable route (provider-only tunnel).

    Apex fallback: the user apex is passed through only while the backend's last probe
    found a browser-trusted certificate on the box (`dns.certNotAfter` in /resolve/v2).
    Otherwise (not probed, mesh CA cert only, unreachable) it is terminated here with the
    gateway's *.<zone>, which matches the apex, so the box's dashboard stays reachable.
    Dot names cannot fall back (*.<zone> is one label deep) and are always passed through.
    No `dns` block (deployment without our nameservers) = passthrough, as before. The flag
    rides on the cached decision: no per-connection lookup beyond the existing cache.

    Decision per user label, cached CACHE_TTL seconds in ngx.shared.sni_routes
    ("host:port" to pass through, "host:port pp" when the box takes a PROXY header,
    "-" to terminate; a trailing " apex" = terminate the apex, pass the dot names). The decision is also kept STALE_TTL seconds under "stale:<label>" and
    used while the backend cannot answer (transport error or 5xx), so a gateway on another
    host keeps passing through when the backend's host is down.

    The front sends a PROXY v2 header on every connection (the client's address). A box
    that reported it takes one (`proxyProtocol` in /resolve/v2) gets it straight; any
    other box is reached through the strip relay (STRIP), which ends the header and runs
    route_strip() for the same decision.
]]

local http = require "resty.http"
local cjson = require "cjson.safe"
local config = require "config"

local _M = {}

local CACHE_TTL = 60
local STALE_TTL = tonumber(config.stale_ttl) or 0
local BACKEND_DOWN_KEY = "backend:down"
local BACKEND_DOWN_HOLD = 30
local TERMINATE = "unix:/var/run/nginx-tls.sock"
local STRIP = "unix:/var/run/nginx-strip.sock"

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

-- The user label of a passthrough candidate and whether the name is that user's apex,
-- or nil (terminate).
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
    return label, prefix == label
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
    httpc:set_timeouts(1000, 2000, 2000)
    local res, err = httpc:request_uri(config.backend_url .. "/resolve/v2/" .. label, { method = "GET" })
    if not res then
        return nil, "backend: " .. (err or "?"), true
    end
    if res.status >= 500 then
        return nil, "backend: status " .. res.status
    end
    if res.status ~= 200 then
        return "-" -- not a user (404): terminate
    end
    local data = cjson.decode(res.body)
    if not data then
        return nil, "bad backend answer"
    end
    local target = tls_target(data.routes)
    if not target then
        return "-"
    end
    if data.proxyProtocol == true then
        target = target .. " pp"
    end
    -- apex fallback: our nameservers serve this user, and no trusted box certificate is known
    if type(data.dns) == "table" and type(data.dns.certNotAfter) ~= "string" then
        target = target .. " apex"
    end
    return target
end

-- The cached decision for a user label: "host:port[ pp][ apex]", "-", or nil (terminate).
local function lookup_cached(label)
    local cache = ngx.shared.sni_routes
    local target = cache:get(label)
    if not target then
        local err
        if cache:get(BACKEND_DOWN_KEY) then
            err = "backend down (hold)"
        else
            local unreachable
            target, err, unreachable = lookup(label)
            if unreachable then
                cache:set(BACKEND_DOWN_KEY, true, BACKEND_DOWN_HOLD)
            end
        end
        if not target then
            local stale = STALE_TTL > 0 and cache:get("stale:" .. label)
            if stale then
                ngx.log(ngx.WARN, "sni_router: ", label, ": ", err, " (stale decision)")
                return stale -- not re-cached: the next handshake asks again
            end
            ngx.log(ngx.WARN, "sni_router: ", label, ": ", err, " (terminating)")
            return nil -- not cached: the next handshake asks again
        end
        cache:set(label, target, CACHE_TTL)
        if STALE_TTL > 0 then
            cache:set("stale:" .. label, target, STALE_TTL)
        end
    end
    return target
end

-- The passthrough for the connection's SNI: the box address and whether it takes a PROXY
-- header, or nil (terminate).
local function passthrough()
    local name = ngx.var.ssl_preread_server_name
    if not name or name == "" then
        return nil
    end
    local label, is_apex = candidate_label(name:lower())
    if not label then
        return nil
    end
    local target = lookup_cached(label)
    if not target or target == "-" then
        return nil
    end
    local addr, flags = target:match("^(%S+)(.*)$")
    if is_apex and flags:find(" apex", 1, true) then
        return nil -- apex fallback: no trusted box certificate, terminate with *.<zone>
    end
    return addr, flags:find(" pp", 1, true) ~= nil
end

-- The front: pass through (straight, or through the strip relay), or terminate.
function _M.route()
    local addr, pp = passthrough()
    if not addr then
        return
    end
    if pp then
        ngx.var.tls_upstream = addr
        ngx.var.tls_mode = "passthrough"
    else
        ngx.var.tls_upstream = STRIP
        ngx.var.tls_mode = "passthrough-strip"
    end
end

-- The strip relay: the box without its PROXY header. The front only sends a connection
-- here for a passthrough; if the decision changed in between (cache expiry), close it:
-- the HTTP server would expect a header this relay no longer sends.
function _M.route_strip()
    local addr = passthrough()
    if not addr then
        ngx.log(ngx.WARN, "sni_router: strip relay without a passthrough decision, closing")
        return ngx.exit(ngx.ERROR)
    end
    ngx.var.tls_upstream = addr
end

_M.TERMINATE = TERMINATE

return _M
