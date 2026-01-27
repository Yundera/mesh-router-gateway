# mesh-router-gateway Development Environment

Local development setup for the mesh-router-gateway.

## Quick Start

### 1. Configure Environment

```bash
cp .env.example .env
# Edit .env with your values
```

### 2. Run Gateway Only (Against Remote Backend)

```bash
docker compose up -d
```

This mode runs only the gateway, connecting to a remote backend specified in `BACKEND_URL`.

### 3. Run Full Local Stack

```bash
docker compose --profile full-stack up -d
```

This mode runs:
- **gateway**: HTTP reverse proxy (port 8080)
- **mesh-router-backend**: Resolution API (port 8192)
- **redis**: Route storage (port 6379)

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `SERVER_DOMAIN` | Domain suffix (e.g., `nsl.sh`) | `nsl.sh` |
| `BACKEND_URL` | Resolution backend API URL | `http://mesh-router-backend:8192` |
| `CACHE_TTL` | Resolution cache TTL (seconds) | `60` |
| `BUILD_VERSION` | Docker image version tag | `dev` |

## Services

### Gateway (Always Running)

- **Port**: 8080 (HTTP)
- **Health**: `http://localhost:8080/_health`

### Backend (Full Stack Profile)

- **Port**: 8192
- **Health**: `http://localhost:8192/available/healthcheck`
- **Requires**: `config/serviceAccount.json` for Firebase

### Redis (Full Stack Profile)

- **Port**: 6379

## Usage Examples

### Test Domain Resolution

```bash
# Check if gateway is healthy
curl http://localhost:8080/_health

# Test resolution (requires backend with registered domain)
curl -H "Host: alice.nsl.sh" http://localhost:8080/
```

### Register a Test Route (Full Stack)

```bash
# Register a route via backend API
curl -X POST "http://localhost:8192/routes/testuser/testsig" \
  -H "Content-Type: application/json" \
  -d '[{"ip": "192.168.1.100", "port": 443, "priority": 1}]'

# Resolve the route
curl "http://localhost:8192/resolve/v2/testdomain"
```

## Directory Structure

```
dev/
├── .env.example      # Environment template
├── .env              # Your local config (git-ignored)
├── docker-compose.yml
├── config/           # Firebase config (for full-stack)
│   └── serviceAccount.json
└── README.md
```

## Troubleshooting

### Gateway returns 502

1. Check backend is running: `docker compose logs mesh-router-backend`
2. Verify `BACKEND_URL` is correct in `.env`
3. Check network connectivity: `docker compose exec gateway ping mesh-router-backend`

### Cache not updating

The gateway caches resolutions for `CACHE_TTL` seconds. To force refresh:
```bash
docker compose restart gateway
```

### Full stack won't start

Ensure you're using the `full-stack` profile:
```bash
docker compose --profile full-stack up -d
```

## Development Tips

1. **Hot reload**: Gateway requires rebuild for config changes
   ```bash
   docker compose up -d --build
   ```

2. **View logs**:
   ```bash
   docker compose logs -f gateway
   ```

3. **Access container**:
   ```bash
   docker compose exec gateway sh
   ```

4. **Test Lua changes**: Edit files in `../nginx/lua/` and rebuild
