# mesh-router-gateway

A lightweight HTTP reverse proxy gateway for self-hosted infrastructure. Receives incoming requests for wildcard domains (e.g., `*.example.com`) and routes them to the appropriate backend host based on domain-to-IP mappings from a resolution API.

## Overview

```
                                   mesh-router-gateway
  ┌────────────────────────────────────────────────────────────────────────────┐
  │                                                                            │
  │   ┌────────────┐    ┌──────────────┐    ┌─────────────────┐                │
  │   │            │    │              │    │   Resolution    │                │
  │   │   Nginx    │───►│   Resolver   │───►│     Backend     │                │
  │   │  (entry)   │    │   (cache)    │    │  /resolve API   │                │
  │   │            │    │              │    │                 │                │
  │   └─────┬──────┘    └──────────────┘    └─────────────────┘                │
  │         │                                                                  │
  └─────────┼──────────────────────────────────────────────────────────────────┘
            │
            │ Proxy to resolved IP:port
            │
            ▼
    ┌───────────────────────────────────────────────────────────────────┐
    │                     Resolved destination                          │
    │                                                                   │
    │   ┌─────────────────────┐         ┌─────────────────────────┐     │
    │   │                     │         │                         │     │
    │   │   Direct: Public IP │         │  Tunnel: meta-mesh-     │     │
    │   │    (203.0.113.5)    │         │   tunnel hub IP         │     │
    │   │                     │         │    (10.77.0.x)          │     │
    │   └──────────┬──────────┘         └────────────┬────────────┘     │
    │              │                                 │                  │
    └──────────────┼─────────────────────────────────┼──────────────────┘
                   │                                 │
                   ▼                                 ▼
           ┌─────────────┐                ┌───────────────────┐
           │   Backend   │                │  mesh-router-tunnel │
           │   Server    │                │       (hub)       │
           │  (public)   │                │         │         │
           └─────────────┘                │    WireGuard      │
                                          │         │         │
                                          │         ▼         │
                                          │      (leaf)       │
                                          │   User's server   │
                                          └───────────────────┘
```

## How It Works

1. **Incoming Request**: A request arrives for `alice.example.com` or `app.alice.example.com`
2. **Domain Resolution**: Gateway extracts the subdomain and queries the resolution backend:
   ```
   GET /resolve/alice → { "hostIp": "203.0.113.5", "targetPort": 443 }
   ```
3. **Proxying**: Request is forwarded to the resolved `IP:port`
4. **Response**: Backend response is returned to the client

The gateway doesn't know or care whether the destination is a direct public IP or a tunnel hub - it simply proxies to whatever IP:port the resolution backend returns.

## Destination Types

### Direct Connection

When the backend server has a public IP, the resolution backend returns that IP directly.

```
Client → Gateway → 203.0.113.5:443 → Backend Server
```

### Via mesh-router-tunnel

When the backend server is behind NAT/CGNAT/firewall, the resolution backend returns the tunnel hub IP. The [mesh-router-tunnel](../mesh-router-tunnel) project handles the actual tunneling:

```
Client → Gateway → Hub (10.77.0.x) ──WireGuard──► Leaf → Backend Server
```

- **Hub**: Tunnel entrance, receives traffic from gateway
- **Leaf**: Tunnel exit on user's server, establishes outbound connection to hub

This separation keeps the gateway simple and stateless.

## Domain Structure

| Pattern | Example | Resolution |
|---------|---------|------------|
| `<user>.<domain>` | `alice.example.com` | Resolves `alice` → backend host |
| `<app>.<user>.<domain>` | `nextcloud.alice.example.com` | Resolves `alice` → backend (app routing handled by backend) |

## Features

- **Simple domain-to-IP resolution** via pluggable REST API backend
- **Resolution caching** to minimize backend calls (configurable TTL)
- **SSL/TLS termination** with automatic ACME certificates (ZeroSSL or Let's Encrypt, with a backup CA), including per-user fallback certificates for dot names
- **WebSocket support** for real-time applications
- **Large file uploads** (configurable, up to 20GB)
- **Health checks** and graceful degradation
- **Docker-native deployment**
- **Stateless design** - no knowledge of tunneling, just proxy to resolved IP

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `SERVER_DOMAIN` | Domain suffix (e.g., `example.com`) | Required |
| `BACKEND_URL` | Resolution API URL | `http://localhost:8192` |
| `CACHE_TTL` | Resolution cache TTL in seconds | `60` |
| `RESOLVE_STALE_TTL` | Serve-stale: how long the last resolution (HTTP routes and TLS passthrough decision) is kept for use while the backend cannot answer (timeout, refused, 5xx; never on a 404). An unreachable backend is then skipped for 30 s. `0` = off | `86400` |
| `DEFAULT_BACKEND` | Fallback URL for unclaimed domains (e.g., `http://landing-page:80`) | Empty (returns 404) |
| `GATEWAY_TLS_PORT` | TLS listener port (`off` disables it); plain HTTP stays on `80` | `8443` |
| `GATEWAY_TLS_PROXY_PROTOCOL` | `1` = the TLS listener expects PROXY protocol (behind a TCP passthrough) | `0` |
| `GATEWAY_FORWARDED_FOR` | `append` keeps the client's X-Forwarded-For (Cloudflare's Worker puts the client there); `replace` sends only the address the gateway saw (set it once the gateway is the edge) | `append` |
| `GATEWAY_TLS_REALIP_FROM` | Sources whose PROXY header gives the client address (with `GATEWAY_TLS_PROXY_PROTOCOL=1`), space-separated CIDRs | private ranges |
| `GATEWAY_STATE_DIR` | Where the gateway keeps state that must survive a recreate: the mesh CA from its last good fetch, and its gateway certificate. **Mount a volume here** (see below) | `/var/lib/mesh-gateway` |
| `GATEWAY_PUBLIC_IP` | This gateway's public IPv4, one of the backend's `DNS_GATEWAY_IPS`: names its gateway certificate (handoff, below) | Empty (takes no handoff) |
| `GATEWAY_CERT_TOKEN` | The backend's `GATEWAY_CERT_TOKEN`, to get the gateway certificate | Empty (takes no handoff) |
| `GATEWAY_ACME_DNS` | DNS provider for this gateway's public `*.<SERVER_DOMAIN>` certificate (see below): `cloudflare` while Cloudflare holds the zone, `mesh` once our nameservers do (the backend's `/acme-dns`, with `GATEWAY_CERT_TOKEN`), or any lego provider | Empty (self-signed fallback) |
| `GATEWAY_ACME_SERVER` | Primary ACME directory. Yundera's gateways: ZeroSSL, `https://acme.zerossl.com/v2/DV90` (with EAB below). Let's Encrypt staging for tests: `https://acme-staging-v02.api.letsencrypt.org/directory` | Let's Encrypt production |
| `GATEWAY_ACME_EAB_KID` / `GATEWAY_ACME_EAB_HMAC` | External Account Binding of the primary CA (ZeroSSL: one EAB credential per gateway, from its dashboard). Passed to lego through its environment, never on the command line | Empty (no EAB) |
| `GATEWAY_ACME_BACKUP_SERVER` | Backup ACME directory (Let's Encrypt on Yundera's gateways), asked only while the primary has no valid certificate for a name | Empty (no backup) |
| `GATEWAY_ACME_BACKUP_WEEKLY_MAX` | New certificates the backup may issue per 7 days, all names together: the zone's Let's Encrypt bucket belongs to the boxes | `10` |
| `GATEWAY_ACME_LEGO_ARGS` | Extra lego global options, e.g. `--dns.resolvers 9.9.9.9:53`. Passed after the gateway's own options, so they win | Empty |
| `GATEWAY_ACME_HTTP_TIMEOUT` | Seconds one ACME request may take (lego `--http-timeout`; lego's own default is none, and a CA that accepts the connection and never answers held a run for good) | `60` |
| `GATEWAY_ACME_RUN_TIMEOUT` | Seconds one lego run may take before it is killed (TERM, KILL 30 s later), so a stuck run can't hold the lock both certificate loops share. A killed run's Cloudflare challenge TXT is removed by the gateway (lego can't), since a leftover makes the next order fail | `900` |
| `GATEWAY_FALLBACK_CERTS` | `on`: hold a fallback `*.<user>.<zone>` per live user and terminate a user's dot names with it while the box has no trusted certificate (below). DNS-01 always through the backend's acme-dns (users' zones are ours, whatever `GATEWAY_ACME_DNS` says for the parent zone): needs `GATEWAY_CERT_TOKEN` | `off` |
| `FALLBACK_POLL` | Seconds between two reads of the live users (`/gateway/fallback-labels`) | `60` |
| `GATEWAY_ACME_EMAIL` | ACME account contact (lego requires one) | `admin@<SERVER_DOMAIN>` |
| `GATEWAY_ACME_RENEW_DAYS` | Renew when fewer days than this are left | `30` |
| `CLOUDFLARE_DNS_API_TOKEN` | With `GATEWAY_ACME_DNS=cloudflare`: a token with DNS edit on this zone only, IP-filtered to the gateways | — |

### Mesh CA and the state volume

At start the gateway fetches the mesh CA (`GET <BACKEND_URL>/ca-cert`), which verifies the
boxes' cert0 on the gateway → box hop. A good fetch (it must parse as a certificate) is
stored in `GATEWAY_STATE_DIR`. On the next start, if the backend cannot answer within
5 tries (~10 s), the gateway starts on that stored copy and logs a warning. With no stored
copy it waits for the backend (30 tries, ~60 s) and then exits, as before.

So mount a volume on `GATEWAY_STATE_DIR`: without it, a gateway **recreated** (new image,
changed env) while the backend is down cannot start. With serve-stale
(`RESOLVE_STALE_TTL`) the volume is what lets a gateway on another host keep serving through
a backend outage, restart included. The CA is refreshed on every start that reaches the
backend.

### Public certificate `*.<zone>`

With `GATEWAY_ACME_DNS` set, each gateway orders its own `*.<SERVER_DOMAIN>` by DNS-01 with
[lego](https://go-acme.github.io/lego/) (in the image): its own ACME account and key per CA,
kept in `GATEWAY_STATE_DIR/acme/<CA host>/`.

Two CAs (`scripts/acme-lib.sh`): the primary `GATEWAY_ACME_SERVER` (ZeroSSL with EAB on
Yundera's gateways), and the backup `GATEWAY_ACME_BACKUP_SERVER` (Let's Encrypt), asked only
while the primary has no valid certificate for the name, at most
`GATEWAY_ACME_BACKUP_WEEKLY_MAX` new certificates a week (the zone's Let's Encrypt bucket,
50 new certificates a week, is the boxes'). The primary's certificate is served whenever it
is valid, else the backup's. A CA that no longer knows the stored account (deactivated,
EAB revoked) gets a new one, once; the old account is kept as `accounts.lost-<time>`. The HTTP TLS server presents it for
every name it terminates; the handoff name keeps its mesh CA certificate, and dot names /
apexes passed through to boxes are untouched. The gateway never waits for an order: it
starts on the stored certificate (or the self-signed fallback), orders in the background
10 s after start, and swaps a new certificate in with an nginx reload. Checked twice a
day; hourly while there is no valid certificate. Cutoff gate G6 in
`mesh-router-nameserver/docs/cutoff-runbook.md`; design in `phase-1.1-gateway-tls.md` §6.

Before the NS switch the challenge TXT is written through Cloudflare's API
(`GATEWAY_ACME_DNS=cloudflare` + `CLOUDFLARE_DNS_API_TOKEN`); at the switch, set
`GATEWAY_ACME_DNS=mesh` and delete the token. `mesh` is lego's httpreq provider against
the backend (`BACKEND_URL/acme-dns/present|cleanup`), authenticated with the gateway's
`GATEWAY_CERT_TOKEN` (already there for the handoff certificate), which may write
`_acme-challenge.<zone>` in the apex zone (the backend needs `DNS_STATIC_ZONE_FILE`: the
apex zone is ours) and, from backend 2.0.62, live users' `_acme-challenge.<user>.<zone>`
(fallback certificates, below). The certificate already issued keeps
serving, so the switch needs no order at all; the next renewal goes through our nameservers.

### Fallback certificates for dot names

With `GATEWAY_FALLBACK_CERTS=on` (backend 2.0.62+), the gateway holds a fallback
`*.<user>.<zone>` for every live user, so a user's dot names never show a certificate error
while the box has no trusted certificate of its own (just created, rebuilt, its order
refused). `scripts/fallback-certs.sh`:

- reads the live users every `FALLBACK_POLL` seconds (`GET /gateway/fallback-labels`,
  `GATEWAY_CERT_TOKEN`); dormant zones are left out: they publish no challenge TXT and
  their dot names are asked by nobody;
- orders or renews each user's wildcard through the same two CAs as `*.<zone>`, one at a
  time; a failed order waits 10 min, doubling up to 6 h, before the next try;
- keeps the certificate to serve in `GATEWAY_STATE_DIR/fallback/<user>.pem` (chain + key,
  replaced atomically, readable by nginx's workers: `root:nobody` 0640);
- writes `fallback/index.json`, served at `/.well-known/mesh-gateway/fallback`
  (`{"labels":{"<user>":"<notAfter>"}}`): the backend reads it to judge the gateway's
  coverage, and with `DNS_GATEWAY_FALLBACK_REQUIRED=1` keeps a gateway that misses users out
  of the answers (never the last one).

A user no longer listed keeps its file until the certificate expires, then it is removed.
The HTTP TLS server picks the file by SNI (`nginx/lua/fallback_certs.lua`, cached per
worker for a minute, so a renewal is served without a reload). Transparency: the browser
shows which certificate a connection got, and mesh-console's Certificates page shows who
decrypts each address (`phase-1.1-gateway-tls.md` §7).

### Handoff between gateways

With several gateways, each reaches NAT boxes only through the tunnel provider on its own
host (`TUNNEL_SUBNET`), while DNS answers a dash name (`<app>-<user>.<zone>`) with every
healthy gateway. Backend 2.0.58+ tags each tunnel route with the gateway whose provider
holds it (`gateway`) and drops the routes of a provider that is down. A gateway then hands
a request to the gateway that reaches the box:

- **directly**, when it has no route of its own to the box (only routes through another
  host's provider): `x-mesh-route: handoff,…`;
- **as a retry**, when its own tunnel route fails to connect (provider down before the
  backend notices, or within `CACHE_TTL`): `x-mesh-route: retry,handoff,…`. Only when the
  connection never opened, so the box cannot have seen the request; the request body is
  sent again. A failure after connecting stays an error.

The hop is HTTPS to `<peer ip>:443`, SNI `<ip-dashed>.gw.<zone>`, verified against the mesh
CA: the receiving gateway presents its **gateway certificate**, which the backend signs
(`POST /gateway-cert/<ip>`, `GATEWAY_CERT_TOKEN`) for that name only. `gw` is a reserved
label, so no box can hold such a certificate, and the TLS front terminates the name. The
key and certificate (RSA, 30 days) are kept in `GATEWAY_STATE_DIR`, renewed when 10 days
are left (checked twice a day, then a reload), and used as they are while the backend is
down. Without `GATEWAY_PUBLIC_IP` and `GATEWAY_CERT_TOKEN` a gateway still hands requests
over but takes none.

The request carries `X-Mesh-Handoff: 1`; the receiving gateway never hands it on, and,
when the sender is one of the gateways (`gatewayIps` of `/resolve/v2`), keeps the client
address it passed on (`X-Real-IP`, and its `X-Forwarded-For` plus the sender, which boxes
trust as a gateway). The header never reaches a box.

### TLS

One key per name (mesh-router-nameserver `docs/phase-1.1-gateway-tls.md`). On
`GATEWAY_TLS_PORT` an SNI router (`nginx/lua/sni_router.lua`) reads the name only:

- a user's dot names and apex (`<anything>.<user>.<domain>`, `<user>.<domain>`) are
  **passed through** untouched to the box's best TLS-capable route (public IP, or the
  WireGuard address of a routed tunnel) while the box holds a trusted certificate: the box
  presents its own, and the gateway cannot read the traffic;
- **fallback:** "trusted" is the backend's last probe (`dns.certNotAfter` in
  `/resolve/v2`: the apex and the wildcard both verified). Without it, the apex is
  terminated here with `*.<domain>`, which matches it, and the dot names with this
  gateway's fallback `*.<user>.<domain>` when it holds one (previous section); without a
  fallback file they are passed through as before. No `dns` block = passthrough. The flag
  is part of the cached per-user decision: no extra lookup per connection;
- everything else (dash names through Cloudflare, `gateway.entrypoint.<domain>`, reserved
  labels, unknown users) is **terminated** here with a self-signed fallback generated at
  start. Cloudflare's "Full" SSL mode accepts it.

Towards a box, the gateway connects with SNI `<user>.box.<domain>` and accepts only a
certificate from the mesh CA carrying that name (the box's cert0), whatever IP or tunnel
the route goes through. No public CA is trusted on that hop.

Two ways to put it on the internet:

- **Gateway as the edge** (a host of its own): `GATEWAY_TLS_PORT=443`, publish `80` and `443`.
- **Behind Traefik** (a host shared with other sites): keep `8443`, set
  `GATEWAY_TLS_PROXY_PROTOCOL=1`, and pass the zone's TLS through with one generic TCP
  router (labels on the gateway container; the HTTP router keeps port 80):

  ```yaml
  - "traefik.tcp.routers.gateway-tls.rule=HostSNIRegexp(`^.+\\.example\\.com$$`)"
  - "traefik.tcp.routers.gateway-tls.entrypoints=websecure"
  - "traefik.tcp.routers.gateway-tls.tls.passthrough=true"
  - "traefik.tcp.services.gateway-tls.loadbalancer.server.port=8443"
  - "traefik.tcp.services.gateway-tls.loadbalancer.proxyProtocol.version=2"
  ```

  TCP routers are matched before HTTP routers, so the rule must cover only names the
  gateway serves (the zone's apex stays with its own routers).

**Client address.** The image's nginx is rebuilt with `ngx_stream_realip_module` (the
official OpenResty image does not compile it; see the Dockerfile): behind Traefik the
front takes the client address from Traefik's PROXY header, trusting
`GATEWAY_TLS_REALIP_FROM` (the port is not published, so only containers on the gateway's
networks can reach it). The front then sends its own PROXY v2 header on:

- to the HTTP TLS server (local socket, `real_ip_header proxy_protocol`): `$remote_addr`,
  `X-Real-IP` and the appended `X-Forwarded-For` carry the client;
- to a box whose `/resolve/v2` says `proxyProtocol: true` (its Caddy takes the header from
  the gateways, mesh-router-caddy 1.4.4+);
- any other box goes through a strip relay (`unix:/var/run/nginx-strip.sock`) that ends the
  header, so its TLS arrives exactly as before. The decision is cached per user with the
  route (`sni_routes`, 60 s).

The access log of the TLS front (`tls` format) shows the client first, then the address
the connection came from (Traefik's).

### Example Docker Compose

```yaml
version: '3.8'

services:
  mesh-router-gateway:
    image: mesh-router-gateway:latest
    ports:
      - "80:80"
      - "443:443"
    environment:
      - SERVER_DOMAIN=example.com
      - BACKEND_URL=http://resolution-backend:8192
      - CACHE_TTL=60
      - GATEWAY_TLS_PORT=443
    volumes:
      - gateway-state:/var/lib/mesh-gateway   # mesh CA kept across recreates
    restart: unless-stopped

volumes:
  gateway-state:
```

## DNS Resolver Configuration (Important!)

The gateway uses nginx's `resolver` directive to resolve the `BACKEND_URL` hostname. This is configured in `nginx/gateway.conf`.

### Docker Deployments (Default)

```nginx
resolver 127.0.0.11 valid=30s ipv6=off;
```

Docker provides an embedded DNS server at `127.0.0.11` that resolves container names to IPs. This is the default and works for all Docker/Docker Compose deployments.

### Non-Docker Deployments

If running outside Docker, change the resolver to your system DNS:

```nginx
resolver 8.8.8.8 1.1.1.1 valid=30s ipv6=off;
```

And set `BACKEND_URL` to a publicly resolvable hostname or IP address.

### ⚠️ Common Pitfall: Mixed DNS Servers

**Never mix Docker DNS with public DNS in the resolver:**

```nginx
# BAD - causes intermittent 502 errors!
resolver 127.0.0.11 8.8.8.8 1.1.1.1 valid=30s ipv6=off;
```

Why this fails:
1. `BACKEND_URL` uses Docker hostname (e.g., `mesh-router-backend-inojob`)
2. When DNS cache expires, nginx queries configured servers
3. Public DNS (8.8.8.8) returns NXDOMAIN ("host not found") for Docker hostnames
4. If public DNS responds before Docker DNS, nginx uses NXDOMAIN → **502 error**
5. Next request might hit Docker DNS first → works fine

This causes random, hard-to-debug 502 errors that only happen when DNS cache expires.

**Solution**: Use only one DNS source appropriate for your deployment.


## API Contract

### Resolution Endpoint

The gateway expects a resolution backend implementing:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/resolve/v2/:domain` | GET | Get routes for a domain (v2 API) |
| `/resolve/:domain` | GET | Get IP/port for a domain (v1 fallback) |

#### Response Schema (v2)

```json
{
  "userId": "abc123",
  "domainName": "alice",
  "serverDomain": "example.com",
  "routes": [
    {"ip": "203.0.113.5", "port": 443, "priority": 1, "source": "agent"},
    {"ip": "10.77.0.5", "port": 443, "priority": 2, "source": "tunnel"}
  ],
  "routesTtl": 580,
  "lastSeenOnline": "2024-01-15T10:30:00Z"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `userId` | string | User's Firebase UID |
| `domainName` | string | Resolved subdomain |
| `serverDomain` | string | Domain suffix |
| `routes` | array | Available routes sorted by priority |
| `routes[].ip` | string | Target IP address (direct or tunnel hub) |
| `routes[].port` | number | Target port |
| `routes[].priority` | number | Route priority (lower = higher priority) |
| `routes[].source` | string | Route source identifier |
| `routesTtl` | number | Seconds until routes expire |
| `lastSeenOnline` | string | Last heartbeat timestamp (informational) |

The gateway selects the highest-priority (lowest number) healthy route. All IPs are treated equally - whether it's a public IP or a tunnel hub IP is transparent to the gateway.

## Technology Stack

### OpenResty (Nginx + Lua)

Selected for:
- Battle-tested, high performance
- Lua scripting for dynamic routing
- Excellent caching capabilities (shared dict)
- Native proxy handling

## Project Structure

```
mesh-router-gateway/
├── nginx/
│   ├── nginx.conf              # Main Nginx configuration
│   ├── gateway.conf            # Server block for gateway
│   ├── gateway-common.conf     # Locations: /, @mesh_handoff, fallback coverage
│   ├── gateway-proxy.conf      # The proxy hop, shared by both locations
│   └── lua/
│       ├── resolver.lua        # Domain resolution logic
│       ├── handoff.lua         # Handoff to another gateway (direct or retry)
│       ├── request_log.lua     # Final status log line
│       ├── sni_router.lua      # TLS front: pass through or terminate
│       └── fallback_certs.lua  # Per-user fallback certificates by SNI + coverage endpoint
├── scripts/
│   ├── acme-lib.sh             # Two-CA ACME helpers (primary + capped backup), lego
│   └── fallback-certs.sh       # Fallback *.<user>.<zone> loop
├── src/                        # (Optional) Node.js health/metrics
│   └── index.ts
├── Dockerfile
├── docker-compose.yml
├── package.json
└── README.md
```

## Request Flow (Detailed)

```
1. Client Request
   ├── Host: app.alice.example.com
   └── → Gateway (nginx:443)

2. SSL Termination
   └── Let's Encrypt wildcard cert for *.example.com

3. Lua Resolver (access_by_lua_file)
   ├── Extract subdomain: "app.alice" from host
   ├── Parse username: "alice" (rightmost segment before domain)
   ├── Check cache: cache:get("alice")
   │   ├── HIT → Use cached {ip, port}
   │   └── MISS → Query backend API
   └── Backend query: GET /resolve/alice
       └── Response: {"hostIp": "10.77.0.5", "targetPort": 443}

4. Set Backend Variable
   └── ngx.var.backend = "https://10.77.0.5:443"

5. Proxy Pass
   ├── proxy_pass $backend
   ├── Preserve: Host, X-Real-IP, X-Forwarded-*
   └── WebSocket upgrade support

6. Response
   └── Return backend response to client
```

## Error Handling

| Scenario | Response | Action |
|----------|----------|--------|
| Domain not found | Landing page or 404 | If `DEFAULT_BACKEND` set, proxy to landing page; otherwise 404 |
| No routes registered | Landing page or 404 | If `DEFAULT_BACKEND` set, proxy to landing page; otherwise 404 |
| Backend API unavailable | 502 Bad Gateway | Retry with backoff, use stale cache |
| Destination unreachable | 504 Gateway Timeout | Return timeout error |
| Invalid domain format | 400 Bad Request | Return error with guidance |

## Monitoring & Observability

- **Health endpoint**: `GET /_health` → `{"status": "ok"}`
- **Metrics endpoint**: `GET /_metrics` (Prometheus format)
- **Access logs**: JSON format with request timing
- **Resolution cache stats**: Hit/miss ratio

## Security Considerations

- No authentication required (public gateway)
- Rate limiting recommended at edge (e.g., Cloudflare)
- Resolution backend should be internal network only
- SSL/TLS required for all external traffic

## Architecture: Gateway vs Tunnel

| Component | Responsibility |
|-----------|----------------|
| **mesh-router-gateway** (this) | HTTP reverse proxy, SSL termination, domain resolution |
| **mesh-router-tunnel** | WireGuard VPN hub/leaf for NAT traversal |
| **resolution backend** | Domain-to-IP mapping storage and API |

The gateway is intentionally simple and stateless. All tunneling complexity is delegated to mesh-router-tunnel, which the gateway interacts with like any other IP destination.

## Comparison with Similar Projects

| Feature | mesh-router-gateway | [selfhosted-gateway](https://github.com/hintjen/selfhosted-gateway) |
|---------|--------------------|--------------------|
| **Routing** | API-based resolution | Static per-tunnel config |
| **Multi-tenant** | Yes (shared gateway) | No (per-user tunnels) |
| **Tunnel awareness** | None (just an IP) | Built-in WireGuard |
| **SSL** | Wildcard cert | Per-tunnel certs |

## Related Projects

| Project | Purpose |
|---------|---------|
| [mesh-router-backend](../mesh-router-backend) | Domain registration & resolution API |
| [mesh-router-tunnel](../mesh-router-tunnel) | WireGuard VPN hub/leaf for NAT traversal |
| [selfhosted-gateway](https://github.com/hintjen/selfhosted-gateway) | Similar self-hosted tunneling solution |

## License

MIT
