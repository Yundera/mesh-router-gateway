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
| **A. Full Stack** | `https://app-subdomain.server.nsl.sh/` | End-to-end: Gateway + routing + Caddy + container |
| **B. Caddy Direct** | `https://[pcs-ipv6]:10443/` with Host header | Caddy + TLS + container (bypasses gateway) |
| **C. Container Direct** | `http://[pcs-ipv6]:80/` | Container only (no proxy, no TLS) |
| **D. Gateway Root** | `https://nsl.sh/` | Gateway base latency (no routing) |

### Example Test Endpoints

```bash
# A. Full stack (through gateway)
https://nginx-holyhorse.nsl.sh/

# B. Caddy direct (HTTPS, requires Host header)
https://[2001:bc8:3021:201:be24:11ff:fef0:41b4]:10443/
# With: -H "Host: nginx-holyhorse.nsl.sh"

# C. Container direct (HTTP, no TLS)
http://[2001:bc8:3021:201:be24:11ff:fef0:41b4]/

# D. Gateway root
https://nsl.sh/
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

### Check Active Route

To see if traffic goes through tunnel or direct:
- Check mesh-router-backend logs
- Look at `X-Route-Source` header if exposed

### Common Issues

| Symptom | Possible Cause | Check |
|---------|---------------|-------|
| Consistent high latency | Gateway routing overhead | Compare with Caddy direct |
| Intermittent 502 errors | Mixed DNS resolvers | See gateway README |
| First request slow | Cache miss | Check cache TTL |
| Timeouts under load | Connection limits | Check worker_connections |
