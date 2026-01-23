# Mesh Router: Multi-Route Failover Architecture

## Overview

The mesh-router system supports multiple simultaneous routes (direct + tunnel) with automatic failover, high scalability, and proper data separation between persistent identity data and transient routing state.

## Design Goals

1. **Multi-route support**: Both direct IP and tunnel routes active simultaneously
2. **Automatic failover**: If primary route fails, traffic flows through secondary
3. **Scalability**: Handle 100k+ clients without expensive database operations
4. **Resilience**: Self-healing after Redis/Gateway/Backend restarts

---

## Data Model

### Firestore (Identity Layer)

Stores persistent user identity data that rarely changes.

```typescript
// Collection: nsl-router/{userId}
{
  domainName: string;      // "alice"
  serverDomain: string;    // "nsl.sh"
  publicKey: string;       // Ed25519 for signature verification
}
```

### Redis (Route Layer)

Stores transient routing data that is frequently updated.

**Route Registry**
```
Key: routes:{userId}
TTL: 600 seconds (10 min)
Value: JSON array of routes

[
  {
    "ip": "203.0.113.5",
    "port": 443,
    "priority": 1,
    "healthCheck": {                    // Optional
      "path": "/.well-known/health",    // HTTP path to probe
      "host": "alice.nsl.sh"            // Host header (defaults to user domain)
    }
  },
  {
    "ip": "10.77.0.5",
    "port": 80,
    "priority": 2,
    "healthCheck": null                 // No probe - relies on TTL only
  }
]
```

**Health Check Behavior:**
- If `healthCheck` is set: Gateway probes the endpoint, caches result, uses for routing decisions
- If `healthCheck` is null: Route assumed healthy while TTL is valid, expires naturally when client stops refreshing
- Both mechanisms work correctly - health check provides faster failover detection

**Health Status Cache**
```
Key: health:{userId}:{routeHash}
TTL: 300 seconds (5 min)
Value: JSON health status

{ "healthy": true, "checkedAt": 1706012345, "failures": 0 }
```

**Domain Resolution Cache (Optional Optimization)**
```
Key: domain:{domainName}
TTL: 3600 seconds (1 hour)
Value: userId

"abc123"
```

---

## Component Architecture

### 1. mesh-router-backend

Central API service for domain management and route registration.

**API Endpoints:**

```
POST /router/api/routes/:userid/:sig
Body: [{ ip, port, priority, healthCheck? }]
  - healthCheck (optional): { path: string, host?: string }
→ Verify signature
→ Redis SET routes:{userId} with TTL 600
→ Return: { success: true }

GET /router/api/resolve/:domain
→ Firestore: get userId from domainName (cached)
→ Redis: get routes:{userId}
→ Return: { userId, domainName, serverDomain, routes: [...] }

DELETE /router/api/routes/:userid/:sig
→ Verify signature
→ Redis DEL routes:{userId}
→ Return: { success: true }
```

**Dependencies:**
- Redis client (ioredis)
- Firestore client
- Ed25519 signature verification

---

### 2. mesh-router-agent

Local agent running on PCS instances to register direct routes.

**Behavior:**
- Registers route with priority 1 (direct preferred)
- Refreshes registration every 5 minutes
- Optionally registers health check endpoint

**Registration Flow:**
```typescript
async function registerRoute() {
  const publicIp = await detectPublicIp();  // STUN-based detection

  await api.post(`/routes/${userId}/${signature}`, {
    routes: [{
      ip: publicIp,
      port: 443,
      priority: 1,
      healthCheck: config.healthCheckPath ? {
        path: config.healthCheckPath,
        host: config.healthCheckHost
      } : undefined
    }]
  });
}

// On startup
await registerRoute();

// Refresh loop (every 5 min)
setInterval(registerRoute, 5 * 60 * 1000);
```

**Configuration:**
- `HEALTH_CHECK_PATH` - Optional HTTP path for health probe (e.g., `/.well-known/health`)
- `HEALTH_CHECK_HOST` - Optional Host header override (defaults to user's domain)

---

### 3. mesh-router-tunnel (Requester)

Tunnel client that registers fallback routes through VPN providers.

**Behavior:**
- Registers tunnel route after WireGuard connection is established
- Uses priority 2 (tunnel is fallback to direct)
- Refreshes registration every 5 minutes

**Registration Flow:**
```typescript
async function registerTunnelRoute(providerIp: string, vpnPort: number) {
  await api.post(`/routes/${userId}/${signature}`, {
    routes: [{
      ip: providerIp,
      port: vpnPort,
      priority: 2,
      healthCheck: config.healthCheckPath ? {
        path: config.healthCheckPath,
        host: config.healthCheckHost
      } : undefined
    }]
  });
}

// After WireGuard tunnel established
await registerTunnelRoute(provider.publicIp, 443);

// Refresh loop (every 5 min)
setInterval(() => registerTunnelRoute(provider.publicIp, 443), 5 * 60 * 1000);
```

**Note:** The IP registered is the tunnel provider's public IP, not the VPN internal IP. The provider handles routing to the correct peer internally via the Host header.

---

### 4. mesh-router-gateway

Edge gateway that resolves domains and routes traffic with failover support.

**Resolution Logic (Lua):**

```lua
function resolve_and_route(subdomain, user_domain)
    -- 1. Get routes from backend (cached)
    local routes = get_routes(subdomain)
    if not routes or #routes == 0 then
        return nil, "no routes registered"
    end

    -- 2. Sort by priority
    table.sort(routes, function(a, b) return a.priority < b.priority end)

    -- 3. Find first healthy route
    for _, route in ipairs(routes) do
        local is_healthy = route_is_healthy(route, user_domain)
        if is_healthy then
            return build_backend_url(route)
        end
    end

    -- 4. All routes with health checks failed - try first one anyway
    return build_backend_url(routes[1]), "all_routes_unhealthy"
end

function route_is_healthy(route, user_domain)
    -- No health check configured = assume healthy (TTL-based expiry only)
    if not route.healthCheck then
        return true
    end

    -- Check cache first
    local health = get_health_cache(route)
    if health and not is_stale(health, 300) then
        return health.healthy
    end

    -- Lazy probe
    health = probe_health(route, user_domain)
    set_health_cache(route, health)
    return health.healthy
end

function probe_health(route, user_domain)
    local hc = route.healthCheck
    local host = hc.host or user_domain

    -- HTTP probe with Host header (exercises full routing path)
    local res = http_request({
        method = "HEAD",
        ip = route.ip,
        port = route.port,
        path = hc.path,
        headers = { Host = host },
        timeout = 2000
    })

    return {
        healthy = res.status == 200,
        checkedAt = ngx.now()
    }
end
```

**Passive Failure Tracking:**
```lua
-- After proxy attempt fails (in log_by_lua or error handler)
if upstream_failed then
    increment_failure_count(route)
    if failure_count > 3 then
        mark_unhealthy(route, ttl=60)  -- Skip this route for 1 min
    end
end
```

**Configuration:**
- `REDIS_URL` - Redis connection string
- `HEALTH_CHECK_TIMEOUT` - Probe timeout (default: 2000ms)
- `HEALTH_CACHE_TTL` - How long to cache health (default: 300s)
- `FAILURE_THRESHOLD` - Failures before marking unhealthy (default: 3)

---

## Request Flow

```
1. Request arrives: app.alice.nsl.sh

2. Gateway extracts subdomain: "alice"

3. Gateway calls backend: GET /resolve/alice
   └→ Backend: Firestore lookup (cached) → userId
   └→ Backend: Redis GET routes:{userId} → routes array
   └→ Returns: { userId, routes: [{ip, port, priority, healthCheck?}, ...] }

4. Gateway sorts routes by priority

5. For each route (in priority order):
   └→ If no healthCheck configured → assume healthy, use this route
   └→ If healthCheck configured:
       └→ Check health cache (fresh within 5 min?)
       └→ Cache hit → use cached result
       └→ Cache miss/stale → HTTP probe to healthCheck.path with Host header
       └→ Cache the result
   └→ If healthy → use this route
   └→ If unhealthy → try next route

6. Gateway proxies to selected route

7. If proxy fails:
   └→ Increment failure counter for this route
   └→ If threshold exceeded, mark unhealthy in cache
   └→ Try next route (within same request if fast enough)
```

---

## Recovery Behavior

| Scenario | Impact | Recovery |
|----------|--------|----------|
| Redis restart | All routes lost | Clients re-register within 5 min |
| Backend restart | Stateless, no impact | Immediate |
| Gateway restart | Health cache lost | Re-probes on first request (if healthCheck configured) |
| Client disconnect | Stops refreshing | Route expires in 10 min (TTL) |
| Route unreachable | Traffic fails | If healthCheck: failover within seconds. If no healthCheck: waits for TTL |
| Network partition | Health probes fail | Automatic failover to other route (if healthCheck configured) |

**Note:** Health checks are an optimization for faster failover. Without them, the system still works correctly via TTL expiry - just with slower recovery (up to 10 min instead of seconds).

---

## Design Decisions

1. **Health endpoint configuration**: Users optionally register a health check path/host when registering routes. If not configured, route relies on TTL expiry only. Health checks provide faster failover but are not mandatory.

2. **Tunnel provider routing**: Tunnel requester registers the provider's public IP with priority 2. The provider handles internal routing to the correct peer via the Host header.

3. **Multiple routes support**: The generic IP/port/priority model supports multiple routes naturally, enabling flexible multi-path configurations.

4. **WebSocket/long-lived connections**: Nginx (gateway + tunnel) and Caddy configurations handle connection persistence correctly without additional changes.

5. **Backward compatibility**: Both legacy (Firestore-based) and current (Redis-based) APIs operate simultaneously, allowing gradual migration.
