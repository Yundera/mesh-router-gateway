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
- **SSL/TLS termination** with automatic Let's Encrypt certificates
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
| `SSL_EMAIL` | Email for Let's Encrypt certificates | Required for SSL |
| `PORT` | Gateway listen port | `80` |
| `SSL_PORT` | Gateway SSL listen port | `443` |

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
      - SSL_EMAIL=admin@example.com
    volumes:
      - ./certs:/etc/letsencrypt
    restart: unless-stopped
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
│   └── lua/
│       ├── resolver.lua        # Domain resolution logic
│       └── cache.lua           # Resolution caching
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
| Domain not found | 404 Not Found | Log, return error page |
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
