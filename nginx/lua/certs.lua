--[[
    certs.lua - certificate per SNI for the TLS listener (ssl_certificate_by_lua)

    A user whose zone is delegated to our nameservers is reached directly when the
    nameserver answers the gateway (box offline, forced, or before the box's own cert):
    no Cloudflare in front, so the browser needs a real certificate for
    <user>.<zone> and *.<user>.<zone>. The backend issues those (GatewayCerts) and
    serves them on GET /gateway/cert/<user>.

    SNI <anything>.<user>.<zone> or <user>.<zone> -> that user's certificate.
    Anything else (dash names through Cloudflare, unknown users, backend down) keeps
    the server's self-signed fallback: what Cloudflare (SSL "Full") accepted from
    Traefik before.
]]

local ssl = require "ngx.ssl"
local http = require "resty.http"
local cjson = require "cjson.safe"
local lrucache = require "resty.lrucache"
local config = require "config"

-- Parsed certificates per worker: cdata cannot go into a shared dict.
local CACHE_TTL = 600         -- a renewal reaches the gateways within 10 min
local MISS_TTL = 60           -- no certificate for this user (or backend down)
local cache = lrucache.new(1000)

local function user_label(name)
    local suffix = "." .. config.server_domain:lower()
    if #name <= #suffix or name:sub(-#suffix) ~= suffix then
        return nil
    end
    local prefix = name:sub(1, #name - #suffix)
    return prefix:match("([^.]+)$")
end

local function fetch(label)
    local httpc = http.new()
    httpc:set_timeout(3000)
    local res, err = httpc:request_uri(config.backend_url .. "/gateway/cert/" .. label, {
        method = "GET",
        headers = { ["Authorization"] = "Bearer " .. config.service_api_key },
    })
    if not res then
        return nil, "backend: " .. (err or "?")
    end
    if res.status == 404 then
        return nil
    end
    if res.status ~= 200 then
        return nil, "backend status " .. res.status
    end
    local data = cjson.decode(res.body)
    if not data or not data.cert or not data.key then
        return nil, "bad backend answer"
    end
    local cert, cerr = ssl.parse_pem_cert(data.cert)
    local key, kerr = ssl.parse_pem_priv_key(data.key)
    if not cert or not key then
        return nil, "unparsable certificate: " .. (cerr or kerr or "?")
    end
    return { cert = cert, key = key }
end

local name = ssl.server_name()
if not name then
    return
end
local label = user_label(name:lower())
if not label then
    return
end

local entry = cache:get(label)
if entry == nil then
    local found, err = fetch(label)
    if err then
        ngx.log(ngx.WARN, "gateway cert for ", label, ": ", err)
    end
    entry = found or false
    cache:set(label, entry, found and CACHE_TTL or MISS_TTL)
end
if not entry then
    return
end

local ok, err = ssl.clear_certs()
if ok then
    ok, err = ssl.set_cert(entry.cert)
end
if ok then
    ok, err = ssl.set_priv_key(entry.key)
end
if not ok then
    ngx.log(ngx.ERR, "gateway cert for ", label, " not applied: ", err)
end
