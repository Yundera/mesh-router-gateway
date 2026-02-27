# Gateway Stack Benchmarking Guide

## Overview

This guide covers how to benchmark the mesh-router gateway stack to measure throughput, latency, and identify performance bottlenecks.

## Architecture & Test Points

```
                        ┌─────────────────────────────────────────────────┐
                        │              YUNDERA GATEWAY                    │
   ┌──────────┐         │  ┌─────────────────────────────────────────┐   │
   │  Client  │────────►│  │  OpenResty (Nginx + Lua)                │   │
   │          │  HTTPS  │  │  ├── SSL termination                    │   │
   └──────────┘         │  │  ├── Lua resolver (resolver.lua)        │   │
        │               │  │  │   ├── Cache lookup (10MB shared dict)│   │
        │               │  │  │   └── Backend API call (cache miss)  │   │
        │               │  │  └── Proxy to PCS                       │   │
        │               │  └─────────────────┬───────────────────────┘   │
        │               └───────────────────┬┼────────────────────────────┘
        │                                   ││
        │               ┌───────────────────┼┼────────────────────────────┐
        │               │                   ││    PERSONAL CLOUD SERVER   │
        │               │                   ▼▼                            │
        │               │  ┌─────────────────────────────────────────┐   │
        │               │  │  Caddy (Docker Proxy)                   │   │
        │   Direct      │  │  ├── Label-based container discovery    │   │
        │   Access      │  │  ├── TLS termination (local certs)      │   │
        └──────────────►│  │  └── Reverse proxy to containers        │   │
                        │  └─────────────────┬───────────────────────┘   │
                        │                    │                            │
                        │                    ▼                            │
                        │  ┌─────────────────────────────────────────┐   │
                        │  │  Target Container (e.g., nginx)         │   │
                        │  │  └── Application response               │   │
                        │  └─────────────────────────────────────────┘   │
                        └─────────────────────────────────────────────────┘
```

## Test Points

You can benchmark at different layers to isolate latency:

| Test Point | URL Pattern | What It Tests |
|------------|-------------|---------------|
| **A. CF Worker → nip.io** | `https://app-user.domain.com/` | CF Worker + nip.io direct to PCS (fastest) |
| **B. CF Worker → Gateway** | Same URL + `X-Mesh-Force: gateway` | CF Worker + OpenResty gateway + PCS |
| **C. Gateway Direct** | Gateway IP + `Host` header | OpenResty gateway only (bypasses CF Worker) |
| **D. Caddy Direct** | `https://[pcs-ipv6]:10443/` + Host header | Caddy + TLS + container (bypasses gateway) |
| **E. Container Direct** | `http://[pcs-ipv6]:80/` | Container only (no proxy, no TLS) |

### Example Test Endpoints

```bash
# A. CF Worker → nip.io (default, fastest path)
curl -H "X-Mesh-Trace: 1" https://admin-wisera.inojob.com/
# Response: x-mesh-route: cf-worker,nip.io,direct,pcs

# B. CF Worker → Gateway (force gateway fallback)
curl -H "X-Mesh-Trace: 1" -H "X-Mesh-Force: gateway" https://admin-wisera.inojob.com/
# Response: x-mesh-route: cf-worker,gateway-fallback,pcs

# C. Gateway direct (from staging server, bypasses CF Worker)
curl -H "X-Mesh-Trace: 1" -H "X-Mesh-Force: direct" \
     -H "Host: admin-wisera.inojob.com" http://172.30.0.2:80/
# Response: x-mesh-route: agent,pcs

# D. Caddy direct (HTTPS, requires Host header)
curl -k -H "Host: nginx-holyhorse.nsl.sh" \
     https://[2001:bc8:3021:201:be24:11ff:fef0:41b4]:10443/

# E. Container direct (HTTP, no TLS)
curl http://[2001:bc8:3021:201:be24:11ff:fef0:41b4]/
```

## Benchmarking Tools

### Recommended: `hey`

Simple HTTP load generator written in Go.

**Installation:**
```bash
# Via goblin.run (no root required)
curl -sf https://goblin.run/github.com/rakyll/hey | sh

# Via Go
go install github.com/rakyll/hey@latest
```

**Usage:**
```bash
# Basic benchmark: 1000 requests, 50 concurrent
hey -n 1000 -c 50 https://your-endpoint/

# With custom Host header (for direct Caddy testing)
hey -n 1000 -c 50 -host "nginx-holyhorse.nsl.sh" "https://[ipv6]:10443/"

# Longer duration test
hey -z 60s -c 100 https://your-endpoint/
```

### Alternatives

| Tool | Install | Best For |
|------|---------|----------|
| **wrk** | `apt install wrk` | High throughput, Lua scripting |
| **ab** | `apt install apache2-utils` | Quick tests, widely available |
| **k6** | [k6.io](https://k6.io) | CI/CD, scripted scenarios |
| **vegeta** | Go binary | Constant rate testing |

### Latency Isolation with curl

Use curl timing to break down each phase:

```bash
curl -w "DNS: %{time_namelookup}s
Connect: %{time_connect}s
TLS: %{time_appconnect}s
First byte: %{time_starttransfer}s
Total: %{time_total}s
" -o /dev/null -s https://your-endpoint/
```

For self-signed certs (Caddy direct):
```bash
curl -k -H "Host: nginx-holyhorse.nsl.sh" \
     -w "DNS: %{time_namelookup}s\nConnect: %{time_connect}s\nTLS: %{time_appconnect}s\nFirst byte: %{time_starttransfer}s\n" \
     -o /dev/null -s "https://[2001:bc8:3021:201:be24:11ff:fef0:41b4]:10443/"
```

## Setting Up a Benchmark Target

Use a minimal nginx container behind Caddy:

```yaml
# docker-compose.yml
services:
  nginx:
    image: nginx:alpine
    labels:
      - "caddy=nginx-${PCS_DOMAIN}"
      - "caddy.reverse_proxy={{upstreams 80}}"
    networks:
      - mesh

networks:
  mesh:
    external: true
```

This creates an endpoint at `nginx-<subdomain>.<server-domain>`.

## Interpreting Results

### Key Metrics

| Metric | Description | Target |
|--------|-------------|--------|
| **Requests/sec** | Throughput | Higher is better |
| **p50 latency** | Median response time | <100ms for good UX |
| **p95 latency** | 95th percentile | <300ms acceptable |
| **p99 latency** | Tail latency | Watch for spikes |
| **Error rate** | Non-2xx responses | Should be 0% |

### Reference Baseline

Measured from external client to Scaleway Paris PCS:

| Test Point | Requests/sec | p50 | p95 |
|------------|-------------|-----|-----|
| Container direct (HTTP) | ~520 | ~97ms | ~200ms |
| Caddy direct (HTTPS) | ~475 | ~97ms | ~200ms |
| Full stack (Gateway) | ~42 | ~162ms | ~354ms |

### Routing Path Benchmarks

Measured with `hey -n 100 -c 10` to inojob.com staging (Feb 2026):

| Route Path | Avg Latency | Req/sec | X-Mesh-Route |
|------------|-------------|---------|--------------|
| CF Worker → nip.io → PCS | **~42ms** | 185 | `cf-worker,nip.io,direct,pcs` |
| CF Worker → Gateway → PCS | ~182ms | 52 | `cf-worker,gateway-fallback,pcs` |
| Gateway → agent (direct) | ~445ms | 21 | `agent,pcs` |

**Key findings:**
- **nip.io direct path is ~4x faster** than gateway fallback (42ms vs 182ms)
- Gateway adds significant latency when accessed from staging server (~445ms)
- The nip.io path bypasses OpenResty entirely, going directly to PCS via Cloudflare

**Benchmark commands:**

```bash
# 1. CF Worker default path (nip.io direct)
hey -n 100 -c 10 -H "X-Mesh-Trace: 1" "https://admin-wisera.inojob.com/"

# 2. CF Worker with forced gateway fallback
hey -n 100 -c 10 -H "X-Mesh-Trace: 1" -H "X-Mesh-Force: gateway" "https://admin-wisera.inojob.com/"

# 3. Gateway direct (from staging server)
hey -n 100 -c 10 -H "X-Mesh-Trace: 1" -H "X-Mesh-Force: direct" \
    -H "X-Forwarded-Proto: http" -H "Host: admin-wisera.inojob.com" \
    "http://172.30.0.2:80/"
```

## Troubleshooting

### Cache Hit vs Miss

The gateway Lua resolver caches domain resolutions (default TTL: 60s).

```bash
# First request may be slower (cache miss)
# Subsequent requests should be faster (cache hit)
for i in 1 2 3 4 5; do
  curl -w "Request $i: %{time_starttransfer}s\n" -o /dev/null -s https://your-endpoint/
done
```

### Check Active Route with Trace Headers

Use the `X-Mesh-Trace` header to see the exact routing path taken:

```bash
# Add X-Mesh-Trace header to see route path in response
curl -s -D- -o /dev/null -H "X-Mesh-Trace: 1" https://admin-wisera.inojob.com/ | grep x-mesh-route
# Output: x-mesh-route: cf-worker,nip.io,direct,pcs
```

The `X-Mesh-Route` response header shows the path taken:
- `cf-worker` - Request went through Cloudflare Worker
- `nip.io` - Used nip.io direct routing (not gateway fallback)
- `gateway-fallback` - Used OpenResty gateway (when nip.io fails or forced)
- `direct` / `agent` - Route was from mesh-router-agent (direct IP)
- `tunnel` - Route was from mesh-router-tunnel (WireGuard)
- `pcs` - Final destination is Personal Cloud Server

### Force Specific Routes

Use `X-Mesh-Force` header to force a specific routing path for testing:

```bash
# Force gateway fallback (bypass nip.io direct path)
curl -H "X-Mesh-Force: gateway" https://admin-wisera.inojob.com/

# Force direct (agent) route in gateway
curl -H "X-Mesh-Force: direct" -H "Host: admin-wisera.inojob.com" https://gateway.entrypoint.inojob.com/

# Force tunnel route in gateway
curl -H "X-Mesh-Force: tunnel" -H "Host: admin-wisera.inojob.com" https://gateway.entrypoint.inojob.com/
```

| X-Mesh-Force Value | Effect |
|--------------------|--------|
| `gateway` | CF Worker skips nip.io, uses gateway fallback |
| `direct` | OpenResty gateway prefers route with source="agent" |
| `tunnel` | OpenResty gateway prefers route with source="tunnel" |

### Common Issues

| Symptom | Possible Cause | Check |
|---------|---------------|-------|
| Consistent high latency | Gateway routing overhead | Compare with Caddy direct |
| Intermittent 502 errors | Mixed DNS resolvers | See gateway README |
| First request slow | Cache miss | Check cache TTL |
| Timeouts under load | Connection limits | Check worker_connections |
