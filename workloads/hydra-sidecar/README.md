# Hydra Sidecar

A sidecar service for [Ory Hydra](https://www.ory.sh/hydra/) that provides:

- **Token Hook** - Injects client metadata into JWT claims and rejects expired clients
- **Client Creation with Hash** - Proxies client creation to Hydra and returns the hashed secret
- **Client Secret Rotation** - Rotates secrets with optional expiration update
- **Bulk Client Sync** - Full reconciliation of clients from an external source of truth

## Architecture

The sidecar runs alongside Hydra and shares its PostgreSQL database. It uses the same ORM (pop) and client structs as Hydra for database operations.

```
┌─────────────┐     ┌─────────────────┐     ┌─────────────┐
│   Client    │────▶│  Hydra Sidecar  │────▶│    Hydra    │
└─────────────┘     └────────┬────────┘     └─────────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │   PostgreSQL    │
                    └─────────────────┘
```

## Configuration

Environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `PORT` | HTTP server port | `8080` |
| `DATABASE_URL` | PostgreSQL connection URL | (required) |
| `HYDRA_ADMIN_URL` | Hydra Admin API URL | `http://localhost:4445` |
| `HASHER_ALGORITHM` | Hash algorithm (`pbkdf2` or `bcrypt`) | `pbkdf2` |

## Build

All Go operations run in a container (no local Go installation required).

```bash
# Tidy go modules
make tidy

# Build Docker image for local Kind cluster
make build-local

# Load into Kind and restart deployment
kind load docker-image hydra-sidecar:latest --name kind
kubectl rollout restart deployment/hydra -n hydra
```

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make tidy` | Run `go mod tidy` in container |
| `make build-local` | Build Docker image for Kind |
| `make swagger` | Generate OpenAPI/Swagger documentation |
| `make swagger-fmt` | Format swagger comments |

## API Documentation

OpenAPI/Swagger documentation is available in the `docs/` directory:

- `docs/swagger.json` - OpenAPI 2.0 spec (JSON)
- `docs/swagger.yaml` - OpenAPI 2.0 spec (YAML)

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/token-hook` | Token hook for JWT claim injection |
| `POST` | `/admin/clients` | Create OAuth2 client (proxies to Hydra) |
| `GET` | `/admin/clients/{id}` | Get OAuth2 client |
| `DELETE` | `/admin/clients/{id}` | Delete OAuth2 client |
| `POST` | `/admin/clients/rotate/{id}` | Rotate client secret |
| `POST` | `/sync/clients` | Bulk sync OAuth2 clients |
| `GET` | `/health` | Liveness probe |
| `GET` | `/ready` | Readiness probe |

### Token Hook

Configure Hydra to call the sidecar's token hook:

```yaml
urls:
  self:
    issuer: https://auth.example.com
oauth2:
  token_hook:
    url: http://hydra-sidecar:8080/token-hook
```

The hook:
1. Fetches client metadata from Hydra
2. Checks if the client has expired (`client_secret_expires_at`)
3. Injects all metadata fields into the JWT access token

### Bulk Sync

The `/sync/clients` endpoint performs full reconciliation:
- Creates new clients
- Updates existing clients
- Deletes clients not in the sync request

Expects pre-hashed secrets matching the configured `HASHER_ALGORITHM`.

```bash
curl -X POST http://localhost:8080/sync/clients \
  -H "Content-Type: application/json" \
  -d '{
    "clients": [
      {
        "client_id": "service-1",
        "client_secret": "$pbkdf2-sha512$...",
        "client_name": "Service 1",
        "metadata": {"org_id": "acme", "tier": "premium"}
      }
    ]
  }'
```

### Client Secret Rotation

Rotate a client's secret with optional expiration:

```bash
# Rotate without changing expiration
curl -X POST http://localhost:8080/admin/clients/rotate/my-client

# Rotate and set new expiration (Unix timestamp)
curl -X POST http://localhost:8080/admin/clients/rotate/my-client \
  -H "Content-Type: application/json" \
  -d '{"client_secret_expires_at": 1735689600}'
```

## Development

Generate/update swagger documentation after changing API annotations:

```bash
make swagger
```

Swagger annotations use [swaggo/swag](https://github.com/swaggo/swag) format in handler comments.
