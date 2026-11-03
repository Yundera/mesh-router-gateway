--[[
    handoff.lua - access phase of @mesh_handoff (gateway-common.conf)

    Hands the request to the gateway whose tunnel provider reaches the box
    ($mesh_handoff_peer, chosen by resolver.lua from the routes' `gateway` tag), verified by
    the mesh CA against its certificate name <ip-dashed>.gw.<zone> ($mesh_handoff_sni).

    Two ways in:
    - "direct" ($mesh_handoff_mode): this gateway has no route of its own to the box.
    - error_page 502/504 from `location /`: the box could not be reached. Handed over only
      when the connection to the box never opened ($upstream_connect_time holds no time),
      so the box cannot have seen the request and any method may be retried; otherwise the
      original error stands.

    The other gateway gets X-Mesh-Handoff: 1 and never hands the request on again.
]]

local _M = {}

-- The original upstream error (last try), 502 when there is none.
local function original_status()
    local last = (ngx.var.upstream_status or ""):match("(%d+)%s*$")
    local code = tonumber(last)
    if code == 502 or code == 504 then
        return code
    end
    return ngx.HTTP_BAD_GATEWAY
end

function _M.run()
    local req_id = ngx.ctx.req_id or ngx.var.http_x_request_id or "------"
    local peer = ngx.var.mesh_handoff_peer or ""
    local direct = ngx.var.mesh_handoff_mode == "direct"

    if peer == "" then
        return ngx.exit(original_status())
    end
    if not direct then
        local connect = ngx.var.upstream_connect_time or ""
        if connect:find("%d") then
            ngx.log(ngx.WARN, "[", req_id, "] handoff_skipped reason=box_reached status=", ngx.var.upstream_status or "-")
            return ngx.exit(original_status())
        end
        ngx.log(ngx.WARN, "[", req_id, "] handoff_retry peer=", peer, " upstream=", ngx.var.upstream_addr or "-",
            " status=", ngx.var.upstream_status or "-")
    else
        ngx.log(ngx.INFO, "[", req_id, "] handoff_direct peer=", peer)
    end

    ngx.var.backend = peer
    ngx.var.proxy_ssl_name = ngx.var.mesh_handoff_sni
    ngx.var.mesh_handoff_out = "1"
    if ngx.var.http_x_mesh_trace ~= nil then
        ngx.var.mesh_route = direct and "handoff," or "retry,handoff,"
    else
        ngx.var.mesh_route = ""
    end
end

return _M
