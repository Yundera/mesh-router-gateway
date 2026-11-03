-- Log the final status after the request completes (both proxy locations).
local req_id = ngx.ctx.req_id or ngx.var.http_x_request_id or "unknown"
local status = ngx.status
local request_time = ngx.var.request_time or "nil"
local handoff = ngx.var.mesh_handoff_out == "1" and (" handoff=" .. (ngx.var.mesh_handoff_peer or "?")) or ""

if status >= 500 then
    ngx.log(ngx.ERR, "[", req_id, "] request_error status=", status, " time=", request_time, "s", handoff)
else
    ngx.log(ngx.INFO, "[", req_id, "] request_done status=", status, " time=", request_time, "s", handoff)
end
