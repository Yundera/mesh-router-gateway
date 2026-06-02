--[[
    usage.lua - fire-and-forget app-usage (DAU) notifications

    Called from log_by_lua_block. Reports distinct (uid, app, day) tuples to the
    backend ingest endpoint for the Daily Active Users KPI. Covers the tunnel /
    gateway-fallback traffic the CF Worker delegates to OpenResty.

    Two important constraints:
    - Cosockets (lua-resty-http) are DISABLED in the log phase, so the actual POST
      is deferred to an ngx.timer.at(0, ...) callback, where cosockets work.
    - The metric is DAU only, so we dedup per (uid, app, day) in a shared dict and
      notify at most once per pair/day per instance. The backend SADD is idempotent,
      so any duplicate that slips through is harmless.
]]

local http = require "resty.http"
local cjson = require "cjson.safe"

-- Config is generated from config.lua.template at container start; dofile runs
-- once when this module is first require()'d (LuaJIT caches package.loaded).
local config = dofile("/etc/nginx/lua/config.lua")

local _M = {}

-- Dedup sentinel TTL (~25h). The key embeds the day, so this is only for GC —
-- correctness does not depend on it expiring exactly at midnight.
local USAGE_SEEN_TTL = 90000

-- Timer callback: perform the POST (cosockets allowed here, unlike the log phase).
local function send(premature, uid, app)
    if premature then
        return
    end
    if not config.usage_ingest_url or config.usage_ingest_url == "" then
        return
    end

    local httpc = http.new()
    httpc:set_timeout(2000)

    local res, err = httpc:request_uri(config.usage_ingest_url, {
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. (config.usage_ingest_secret or ""),
        },
        body = cjson.encode({ events = { { uid = uid, app = app } } }),
        ssl_verify = true,
    })

    if not res then
        ngx.log(ngx.WARN, "usage_notify_failed err=", err)
    end
end

-- Entry point from log_by_lua_block. Filters to HTML navigations (≈ app opens),
-- dedups per (uid, app, day), then schedules a fire-and-forget POST.
function _M.maybe_notify()
    local uid = ngx.ctx.user_id
    local app = ngx.ctx.app_name
    if not uid or uid == "" or not app or app == "" then
        return
    end

    local status = ngx.status
    if status < 200 or status >= 400 then
        return
    end

    local accept = ngx.var.http_accept or ""
    if not string.find(accept, "text/html", 1, true) then
        return
    end

    local seen = ngx.shared.usage_seen
    if not seen then
        return
    end

    -- add() returns true only on first insert → notify once per pair/day/instance.
    local key = uid .. "|" .. app .. "|" .. ngx.today()
    if not seen:add(key, 1, USAGE_SEEN_TTL) then
        return
    end

    local ok, terr = ngx.timer.at(0, send, uid, app)
    if not ok then
        ngx.log(ngx.WARN, "usage_timer_failed err=", terr)
    end
end

return _M
