--[[
    certlist.lua - the users this gateway holds a certificate for (certs.lua)

    certs.lua runs on every TLS handshake. Most SNIs are dash names behind Cloudflare
    (<app>-<user>.<zone>), whose last label before the zone looks like a user label but
    never has a certificate: asking the backend for each of them would cost a request
    per handshake miss, and up to the request timeout per handshake while the backend
    is slow or down. So one worker polls GET /gateway/certs ({labels: {<label>:
    <notAfter>}}, the delegated users that have a certificate) every REFRESH_SECONDS
    into a shared dict, and certs.lua only fetches certificates for labels listed there.
    The notAfter tells certs.lua when its cached certificate was renewed.

    Backend unreachable: the last list stays, each label for KEEP_SECONDS. Never loaded
    (backend down since start): no label is listed, every SNI gets the fallback.
]]

local http = require "resty.http"
local lrucache = require "resty.lrucache"
local cjson = require "cjson.safe"
local config = require "config"

local _M = {}

-- certs.lua's parsed certificates, per worker (cdata cannot go into a shared dict).
-- Here and not in certs.lua: ssl_certificate_by_lua_file runs that file's top level
-- on every handshake, while a required module is loaded once per worker.
_M.cache = lrucache.new(1000)

local REFRESH_SECONDS = 30
local KEEP_SECONDS = 3600

local function dict()
    return ngx.shared.gw_cert_labels
end

local function refresh(premature)
    if premature then
        return
    end
    local httpc = http.new()
    httpc:set_timeout(5000)
    local res, err = httpc:request_uri(config.backend_url .. "/gateway/certs", {
        method = "GET",
        headers = { ["Authorization"] = "Bearer " .. config.service_api_key },
    })
    if not res then
        ngx.log(ngx.WARN, "gateway cert list: backend: ", err)
        return
    end
    if res.status ~= 200 then
        ngx.log(ngx.WARN, "gateway cert list: backend status ", res.status)
        return
    end
    local data = cjson.decode(res.body)
    if not data or type(data.labels) ~= "table" then
        ngx.log(ngx.WARN, "gateway cert list: bad backend answer")
        return
    end
    local d = dict()
    for _, label in ipairs(d:get_keys(0)) do
        if data.labels[label] == nil then
            d:delete(label)
        end
    end
    for label, not_after in pairs(data.labels) do
        d:set(label, tostring(not_after), KEEP_SECONDS)
    end
end

-- init_worker: one poller per gateway (worker 0), right away and then every REFRESH_SECONDS.
function _M.start()
    if ngx.worker.id() ~= 0 then
        return
    end
    ngx.timer.at(0, refresh)
    local ok, err = ngx.timer.every(REFRESH_SECONDS, refresh)
    if not ok then
        ngx.log(ngx.ERR, "gateway cert list: cannot start the poller: ", err)
    end
end

-- The notAfter of <label>'s certificate, or nil when the backend lists none for it.
function _M.not_after(label)
    return dict():get(label)
end

return _M
