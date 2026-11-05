--[[
    fallback_certs.lua - per-user fallback certificates on the HTTP TLS server

    A user's dot names (<app>.<user>.<zone>) normally go to the box untouched: the front
    (sni_router.lua) passes them through. While the box has no trusted certificate, the
    front terminates them here instead, and this module presents the gateway's fallback
    *.<user>.<zone> (scripts/fallback-certs.sh keeps GATEWAY_STATE_DIR/fallback/<label>.pem:
    the chain, then the key). Any other name, or a user without a file, keeps the server's
    default certificate (*.<zone> or the self-signed fallback).

    serve() runs in ssl_certificate_by_lua. Parsed certificates are cached per worker for
    CACHE_TTL seconds (cdata cannot go into a shared dict), so a renewed file is picked up
    within a minute without a reload. has(label) is what the front asks (stream context,
    its own copy of this module): whether a usable file exists.

    index() answers /.well-known/mesh-gateway/fallback with fallback/index.json, the labels
    held and their notAfter: the coverage the backend reads (GatewayHealth.ts).
]]

local config = require "config"

local _M = {}

local CACHE_TTL = 60
local dir = config.fallback_dir or ""

local lrucache = require "resty.lrucache"
local cache = lrucache.new(2000)

-- The user label of a dot-form name <app>.<user>.<zone> (at least one label before the
-- user), or nil: the apex, dash names and foreign names keep the default certificate.
function _M.dot_label(name)
    local zone = (config.server_domain or ""):lower()
    local suffix = "." .. zone
    if zone == "" or not name or #name <= #suffix or name:sub(-#suffix) ~= suffix then
        return nil
    end
    local prefix = name:sub(1, #name - #suffix)
    local label = prefix:match("%.([^.]+)$")
    if not label or not label:match("^[a-z0-9-]+$") then
        return nil
    end
    return label
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

-- {cert, key} parsed from <dir>/<label>.pem, or false.
local function load(label)
    local pem = read_file(dir .. "/" .. label .. ".pem")
    if not pem or pem == "" then
        return false
    end
    local key_pem = pem:match("(%-%-%-%-%-BEGIN [A-Z ]*PRIVATE KEY%-%-%-%-%-.-%-%-%-%-%-END [A-Z ]*PRIVATE KEY%-%-%-%-%-)")
    if not key_pem then
        ngx.log(ngx.ERR, "fallback_certs: ", label, ": no private key in the file")
        return false
    end
    local ssl = require "ngx.ssl"
    local chain_pem = pem:gsub("%-%-%-%-%-BEGIN [A-Z ]*PRIVATE KEY%-%-%-%-%-.-%-%-%-%-%-END [A-Z ]*PRIVATE KEY%-%-%-%-%-", "")
    local cert, err = ssl.parse_pem_cert(chain_pem)
    if not cert then
        ngx.log(ngx.ERR, "fallback_certs: ", label, ": certificate: ", err)
        return false
    end
    local key
    key, err = ssl.parse_pem_priv_key(key_pem)
    if not key then
        ngx.log(ngx.ERR, "fallback_certs: ", label, ": key: ", err)
        return false
    end
    return { cert = cert, key = key }
end

-- ssl_certificate_by_lua: the fallback certificate for a dot name, when there is one.
function _M.serve()
    if dir == "" then
        return
    end
    local ssl = require "ngx.ssl"
    local name = ssl.server_name()
    local label = name and _M.dot_label(name:lower())
    if not label then
        return
    end
    local entry = cache:get(label)
    if entry == nil then
        entry = load(label)
        cache:set(label, entry, CACHE_TTL)
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
        ngx.log(ngx.ERR, "fallback_certs: ", label, ": ", err)
    end
end

-- True when a fallback file exists for the label (the front's check; cached by the caller).
function _M.has(label)
    if dir == "" or not label then
        return false
    end
    local f = io.open(dir .. "/" .. label .. ".pem", "rb")
    if not f then
        return false
    end
    f:close()
    return true
end

-- content_by_lua for /.well-known/mesh-gateway/fallback.
function _M.index()
    ngx.header["Content-Type"] = "application/json"
    ngx.header["Cache-Control"] = "no-store"
    local body = dir ~= "" and read_file(dir .. "/index.json")
    if not body then
        ngx.status = 404
        ngx.say('{"error":"fallback certificates off or not listed yet"}')
        return
    end
    ngx.print(body)
end

return _M
