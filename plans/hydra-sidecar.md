# Hydra Sidecar - Implementation Plan

## Overview

Create a **unified sidecar** for Ory Hydra that combines:
1. **Token hook** - JWT claim injection (existing functionality)
2. **Enhanced client creation** - Returns both plaintext AND hashed secrets
3. **Bulk sync** - Restores clients with pre-hashed secrets directly to Hydra's database

This allows your system to be the source of truth for client credentials while Hydra handles secret generation and hashing.

**Scope**: Single-tenant self-hosted Hydra (one network). The sidecar internally handles the `nid` (network ID) - your API consumers don't need to know about it.

## Use Case Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│ FLOW 1: New Client Creation                                             │
├─────────────────────────────────────────────────────────────────────────┤
│  Your System                  Client-Sync Sidecar              Hydra    │
│      │                              │                            │      │
│      │──POST /admin/clients────────>│                            │      │
│      │                              │──POST /admin/clients──────>│      │
│      │                              │<──{client_secret: "abc"}───│      │
│      │                              │                            │      │
│      │                              │──SELECT client_secret──────│      │
│      │                              │   FROM hydra_client        │      │
│      │                              │<──"$pbkdf2-sha256$..."─────│      │
│      │                              │                            │      │
│      │<─{secret:"abc",              │                            │      │
│      │   secret_hash:"$pbkdf2..."}──│                            │      │
│      │                              │                            │      │
│  Store hash in your DB        Give plaintext to end-user               │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│ FLOW 2: Bulk Sync on Fresh Install/Upgrade                              │
├─────────────────────────────────────────────────────────────────────────┤
│  Your System                  Client-Sync Sidecar        Hydra DB       │
│      │                              │                        │          │
│      │──POST /sync/clients─────────>│                        │          │
│      │  [{client_id, hash, ...}]    │                        │          │
│      │                              │                        │          │
│      │                              │──Validate hashes match │          │
│      │                              │  configured hasher     │          │
│      │                              │                        │          │
│      │                              │──UPSERT + DELETE───────>│         │
│      │                              │  (full reconciliation) │          │
│      │                              │                        │          │
│      │<─{created, updated, deleted} │                        │          │
│                                                                         │
│  No Hydra DB backup needed - restore from your source of truth         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Key Design Decisions

### Reuse Ory Packages (No Custom Types/DB Code)

| Component | Package | What We Reuse |
|-----------|---------|---------------|
| **Client types** | `github.com/ory/hydra/client` | `Client` struct - no custom types needed |
| **Hash validation** | `github.com/ory/x/hasherx` | `IsPbkdf2Hash()`, `IsBcryptHash()` |
| **Database ORM** | `github.com/gobuffalo/pop/v6` | Same ORM Hydra uses - auto multi-DB support |
| **Persistence pattern** | `github.com/ory/hydra/persistence` | Reference `Persister` interface |

### Hash Validation Strategy

Hydra uses **ONE configured hasher** at runtime (not auto-detection). Our sidecar:
1. Accepts `HASHER_ALGORITHM` config (default: `pbkdf2`, alternative: `bcrypt`)
2. Uses `hasherx.IsPbkdf2Hash()` or `hasherx.IsBcryptHash()` to validate incoming hashes
3. Rejects hashes that don't match the configured algorithm

```go
// Using github.com/ory/x/hasherx
func validateHash(hash []byte, algorithm string) error {
    switch algorithm {
    case "pbkdf2":
        if !hasherx.IsPbkdf2Hash(hash) {
            return fmt.Errorf("hash format must be PBKDF2, got: %s", detectFormat(hash))
        }
    case "bcrypt":
        if !hasherx.IsBcryptHash(hash) {
            return fmt.Errorf("hash format must be BCrypt, got: %s", detectFormat(hash))
        }
    }
    return nil
}
```

---

## API Specification

### API Models

Uses **go-swagger** (same tool as Hydra) with `swagger:allOf` composition.

| Model | Description |
|-------|-------------|
| `oAuth2Client` | Hydra's client model (from `github.com/ory/hydra/v2/client.Client`) |
| `clientData` | `oAuth2Client` + `client_secret_hash` (via swagger:allOf) |
| `syncClientsRequest` | `{ clients: []clientData }` |
| `syncResult` | Sync operation result with counts and per-client status |
| `rotateClientRequest` | Optional body for secret rotation |

### `client_secret` Field Behavior by Endpoint

| Endpoint | Method | `client_secret` | `client_secret_hash` |
|----------|--------|-----------------|----------------------|
| `/admin/clients` | POST request | Optional (for testing, Hydra generates if empty) | - |
| `/admin/clients` | POST response | **Plaintext** (show to user, never store) | **Hash** (store this) |
| `/admin/clients/{id}` | GET response | Empty (Hydra never returns it) | - |
| `/admin/clients/rotate/{id}` | POST response | **Plaintext** (new secret, show to user) | **Hash** (new hash, store this) |
| `/sync/clients` | POST request | **Hash** (the stored `client_secret_hash`) | Ignored |
| `/sync/clients` | POST response | - | - (returns `syncResult`) |

---

### API 1: Enhanced Client Creation

**Endpoint**: `POST /admin/clients`

Proxies to Hydra, then enriches response with hashed secret from DB.

**Request**: `oAuth2Client` - passthrough to Hydra (same as Hydra's `/admin/clients`)

**Response**: `clientData` - Hydra response + `client_secret_hash` field added

```json
{
  "client_id": "acme-service-1",
  "client_secret": "plaintext-secret-abc123",
  "client_secret_hash": "$pbkdf2-sha256$i=25000,l=32$salt$hash",
  "client_name": "Acme Service 1",
  "grant_types": ["client_credentials"],
  "scope": "read write",
  "metadata": {"enterprise_id": "org-acme", "tier": "premium"},
  "created_at": "2024-01-01T00:00:00Z"
}
```

### API 2: Get Client

**Endpoint**: `GET /admin/clients/{client_id}`

Passthrough to Hydra - returns `oAuth2Client` directly.

**Note**: `client_secret` is never returned by Hydra on GET.

### API 3: Rotate Client Secret

**Endpoint**: `POST /admin/clients/rotate/{client_id}`

Rotates the client secret and returns the new secret with its hash.

**Request**: `rotateClientRequest` (optional)
```json
{
  "client_secret_expires_at": 1735689600
}
```

**Response**: `clientData` - same as creation response with new secret

### API 4: Bulk Sync (Full Reconciliation)

**Endpoint**: `POST /sync/clients`

Full reconciliation - Hydra's client table will exactly match the request.

**Behavior:**
1. Validate all hashes match configured hasher
2. Upsert all clients from the request
3. **Delete** any clients in Hydra NOT present in the request

**Request**: `syncClientsRequest` - Array of `clientData` with `client_secret` containing the **hash**
```json
{
  "clients": [
    {
      "client_id": "acme-service-1",
      "client_secret": "$pbkdf2-sha256$i=25000,l=32$salt$hash",
      "client_name": "Acme Service 1",
      "grant_types": ["client_credentials"],
      "token_endpoint_auth_method": "client_secret_post",
      "scope": "read write",
      "metadata": {"enterprise_id": "org-acme", "tier": "premium"}
    }
  ]
}
```

**Note**: In sync requests, `client_secret` contains the hash (from `client_secret_hash` in creation response). The `client_secret_hash` field is ignored.

**Response**: `syncResult`
```json
{
  "created_count": 1,
  "updated_count": 0,
  "deleted_count": 2,
  "failed_count": 0,
  "results": [
    {"client_id": "acme-service-1", "status": "created", "error": null},
    {"client_id": "old-client-1", "status": "deleted", "error": null},
    {"client_id": "old-client-2", "status": "deleted", "error": null}
  ]
}
```

**Algorithm:**
```go
func (s *Store) SyncClients(ctx context.Context, clients []client.Client) (SyncResult, error) {
    // 1. Get all existing client IDs
    existingIDs := s.getAllClientIDs(ctx)

    // 2. Track which IDs are in the sync request
    syncedIDs := make(map[string]bool)

    // 3. Upsert each client
    for _, c := range clients {
        syncedIDs[c.GetID()] = true
        s.upsertClient(ctx, &c)  // creates or updates
    }

    // 4. Delete clients not in sync request
    for _, id := range existingIDs {
        if !syncedIDs[id] {
            s.deleteClient(ctx, id)
        }
    }
}
```

### API 5: Token Hook (Migrated)

**Endpoint**: `POST /token-hook`

JWT claim injection - existing functionality from token-hook.

### Supporting Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Health check (always 200 if running) |
| `GET /ready` | Readiness check (200 if DB connected) |

---

## Implementation Plan

### Step 1: Create Go Project Structure

**Path**: `workloads/hydra-sidecar/` (replaces `workloads/token-hook/`)

```
workloads/hydra-sidecar/
├── main.go              # Entry point, HTTP server, config
├── handlers.go          # HTTP handlers (token-hook + client APIs)
├── store.go             # Database operations using pop
├── go.mod               # Module with Ory dependencies
├── go.sum
└── Dockerfile           # Multi-arch, distroless
```

### Step 2: Dependencies (`go.mod`)

```go
module github.com/example/hydra-sidecar

go 1.25

require (
    github.com/ory/hydra/v2          // Client struct, types
    github.com/ory/x                 // Hash format validation, sqlxx
    github.com/gobuffalo/pop/v6      // Database ORM (same as Hydra)
    github.com/gofrs/uuid
)
```

**Note**: No swaggo/swag dependency - uses go-swagger for OpenAPI generation.

### Step 3: Database Store (`store.go`)

Use `gobuffalo/pop` - the same ORM Hydra uses. It handles PostgreSQL, MySQL, CockroachDB, SQLite automatically.

```go
import (
    "github.com/gobuffalo/pop/v6"
    "github.com/ory/hydra/client"
)

type Store struct {
    conn *pop.Connection
}

func NewStore(databaseURL string) (*Store, error) {
    // pop auto-detects DB type from DSN
    conn, err := pop.NewConnection(&pop.ConnectionDetails{
        URL: databaseURL,
    })
    // ...
}

func (s *Store) GetHashedSecret(ctx context.Context, clientID string) (string, error) {
    var c client.Client
    err := s.conn.Where("id = ?", clientID).First(&c)
    return c.Secret, err
}

func (s *Store) UpsertClient(ctx context.Context, c *client.Client) error {
    // pop handles upsert syntax per database
    return s.conn.Save(c)
}
```

### Step 4: Hash Validation (`handlers.go`)

```go
import "github.com/ory/x/hasherx"

func (s *Server) validateClientHashes(clients []client.Client) error {
    for _, c := range clients {
        hash := []byte(c.Secret)
        switch s.hasherAlgorithm {
        case "pbkdf2":
            if !hasherx.IsPbkdf2Hash(hash) {
                return fmt.Errorf("client %s: expected PBKDF2 hash", c.GetID())
            }
        case "bcrypt":
            if !hasherx.IsBcryptHash(hash) {
                return fmt.Errorf("client %s: expected BCrypt hash", c.GetID())
            }
        }
    }
    return nil
}
```

### Step 5: HTTP Handlers

```go
// POST /token-hook - JWT claim injection (migrated from token-hook)
func (s *Server) handleTokenHook(w http.ResponseWriter, r *http.Request)

// POST /admin/clients - Proxy to Hydra, add hash to response
func (s *Server) handleCreateClient(w http.ResponseWriter, r *http.Request)

// POST /sync/clients - Validate hashes, full reconciliation (upsert + delete)
func (s *Server) handleSyncClients(w http.ResponseWriter, r *http.Request)
```

### Step 6: Main Entry Point (`main.go`)

```go
func main() {
    cfg := loadConfig() // PORT, DATABASE_URL, HYDRA_ADMIN_URL, HASHER_ALGORITHM

    store, _ := NewStore(cfg.DatabaseURL)

    // Cache network ID at startup (single-tenant: one network)
    nid, _ := store.GetDefaultNetworkID(context.Background())

    server := &Server{store: store, hasher: cfg.HasherAlgorithm, networkID: nid}

    http.HandleFunc("/token-hook", server.handleTokenHook)    // JWT claim injection
    http.HandleFunc("/admin/clients", server.handleCreateClient)
    http.HandleFunc("/sync/clients", server.handleSyncClients)
    http.HandleFunc("/health", server.handleHealth)
    http.HandleFunc("/ready", server.handleReady)

    http.ListenAndServe(":"+cfg.Port, nil)
}
```

### Step 7: Dockerfile (Multi-arch, Distroless)

```dockerfile
FROM --platform=$BUILDPLATFORM golang:1.21-alpine AS builder
ARG TARGETOS TARGETARCH

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o hydra-sidecar .

# Default: debug-nonroot (with busybox shell)
# Override with --build-arg DISTROLESS_VARIANT=nonroot for hardened production
ARG DISTROLESS_VARIANT=debug-nonroot
FROM gcr.io/distroless/static:${DISTROLESS_VARIANT}
COPY --from=builder /app/hydra-sidecar /hydra-sidecar
ENTRYPOINT ["/hydra-sidecar"]
```

**Build commands:**
```bash
# Standard build (with shell) - default
docker buildx build --platform linux/amd64,linux/arm64 \
  -t hydra-sidecar:latest .

# Hardened build (no shell) - for production
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg DISTROLESS_VARIANT=nonroot \
  -t hydra-sidecar:latest .
```

### Step 8: Update Helm Values (Shared Config via Templating)

**File**: `hydra/helm-values.yaml`

Use Helm templating to define shared config once:

```yaml
# Shared configuration
global:
  database:
    url: "postgres://hydra:hydra@hydra-postgres-rw.hydra.svc.cluster.local:5432/hydra?sslmode=disable"
  hasher:
    algorithm: "pbkdf2"
  sidecar:
    port: 8080

image:
  tag: v25.4.0

hydra:
  dev: true
  config:
    dsn: "{{ .Values.global.database.url }}"
    oauth2:
      hashers:
        algorithm: "{{ .Values.global.hasher.algorithm }}"
      token_hook:
        url: "http://127.0.0.1:{{ .Values.global.sidecar.port }}/token-hook"
    # ... rest of hydra config

deployment:
  extraContainers: |
    - name: hydra-sidecar
      image: hydra-sidecar:latest
      imagePullPolicy: IfNotPresent
      ports:
        - containerPort: {{ .Values.global.sidecar.port }}
          name: http
      env:
        - name: PORT
          value: "{{ .Values.global.sidecar.port }}"
        - name: HYDRA_ADMIN_URL
          value: "http://localhost:4445"
        - name: DATABASE_URL
          value: "{{ .Values.global.database.url }}"
        - name: HASHER_ALGORITHM
          value: "{{ .Values.global.hasher.algorithm }}"
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 200m
          memory: 128Mi
      readinessProbe:
        httpGet:
          path: /ready
          port: {{ .Values.global.sidecar.port }}
        initialDelaySeconds: 5
        periodSeconds: 10
      livenessProbe:
        httpGet:
          path: /health
          port: {{ .Values.global.sidecar.port }}
        initialDelaySeconds: 10
        periodSeconds: 30
```

### Step 9: Kubernetes Service (Optional - for external access)

**File**: `hydra/hydra-sidecar-service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: hydra-sidecar
  namespace: hydra
spec:
  selector:
    app.kubernetes.io/name: hydra
  ports:
    - port: 8080
      targetPort: 8080
      name: http
```

### Step 10: Update `redeploy.sh`

Replace token-hook build with hydra-sidecar build.

### Step 11: Remove old token-hook

Delete `workloads/token-hook/` directory (functionality merged into hydra-sidecar).

---

## Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `workloads/hydra-sidecar/main.go` | Create | Entry point, config, swagger:meta annotation |
| `workloads/hydra-sidecar/models.go` | Create | API models with go-swagger annotations (`ClientData`, `SyncClientsRequest`, etc.) |
| `workloads/hydra-sidecar/handlers.go` | Create | HTTP handlers with swagger:route annotations |
| `workloads/hydra-sidecar/store.go` | Create | DB ops using pop |
| `workloads/hydra-sidecar/go.mod` | Create | Ory dependencies (no swaggo) |
| `workloads/hydra-sidecar/Dockerfile` | Create | Multi-arch distroless build |
| `workloads/hydra-sidecar/Makefile` | Create | Build targets including `swagger` (uses go-swagger) |
| `workloads/hydra-sidecar/docs/` | Generated | Swagger/OpenAPI spec files |
| `hydra/helm-values.yaml` | Modify | Shared config + unified sidecar |
| `hydra/hydra-sidecar-service.yaml` | Create | K8s service (optional) |
| `redeploy.sh` | Modify | Replace token-hook with hydra-sidecar |
| `workloads/token-hook/` | Delete | Merged into hydra-sidecar |

---

## Configuration

All configuration is centralized in `hydra/helm-values.yaml` under `global:` and pushed to both Hydra and the sidecar.

| Environment Variable | Source | Description |
|---------------------|--------|-------------|
| `PORT` | `global.sidecar.port` | HTTP server port (default: 8080) |
| `HYDRA_ADMIN_URL` | hardcoded | Always `http://localhost:4445` (sidecar shares pod network) |
| `DATABASE_URL` | `global.database.url` | Database DSN (pop auto-detects type) |
| `HASHER_ALGORITHM` | `global.hasher.algorithm` | `pbkdf2` or `bcrypt` - shared with Hydra |

---

## Security Considerations

1. **Internal only**: Sync API should only be cluster-internal
2. **No secret logging**: Never log plaintext or hashed secrets
3. **Hash validation**: Validate format matches configured hasher before insert
4. **DB credentials**: Use K8s secrets for production
