# Ory Hydra Integration Plan (Dev Setup)

## Overview

Replace Keycloak with Ory Hydra for M2M OAuth2/OIDC token management, starting with a dev-friendly single PostgreSQL setup on local kind cluster.

## Requirements Summary

- **Use Case**: M2M OAuth2 with 10-100 client IDs
- **Source of Truth**: External system manages client IDs/secrets
- **Hydra Responsibilities**: Token signing (JWKS), `/token` endpoint, OIDC discovery
- **Operational Model**:
  - Clients handle 401 → re-authenticate (no refresh token persistence needed)
  - Revocation via client secret rotation in source of truth
  - Stable JWKS keys across restarts
- **Database**: Self-contained, in-cluster PostgreSQL (dev setup first, CloudNativePG for HA later)
- **Deployment**: kind cluster (local), integrated into `redeploy.sh`

## Current Keycloak Integration (to be replaced)

From `redeploy.sh`:
- `KEYCLOAK_CONFIGMAP` → `keycloak-realm-configmap.yaml`
- `KEYCLOAK_DEPLOYMENT` → `keycloak-deployment.yaml`
- `KEYCLOAK_SERVICE` → `keycloak-service.yaml`
- `OIDC_PLUGIN_CONFIG` → `openid-pluginconfig.yaml`

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Kubernetes Cluster                      │
│                                                              │
│  ┌──────────────┐      ┌──────────────┐                     │
│  │ Client Sync  │      │   APISIX     │                     │
│  │ Job/Init     │      │   Gateway    │                     │
│  └──────┬───────┘      └──────┬───────┘                     │
│         │                     │ validates JWT via JWKS      │
│         │ Hydra Admin API     │                             │
│         ▼                     ▼                             │
│  ┌────────────────────────────────────────┐                 │
│  │         Ory Hydra (2+ replicas)        │                 │
│  │  - POST /oauth2/token                  │                 │
│  │  - GET /.well-known/jwks.json          │                 │
│  │  - GET /.well-known/openid-configuration│                │
│  └──────────────────┬─────────────────────┘                 │
│                     │                                        │
│                     ▼                                        │
│  ┌────────────────────────────────────────┐                 │
│  │   PostgreSQL (single pod + PVC)        │                 │
│  │   - JWKS signing keys                  │                 │
│  │   - OAuth2 client registrations        │                 │
│  │   - Access token metadata              │                 │
│  └────────────────────────────────────────┘                 │
└─────────────────────────────────────────────────────────────┘
```

## Implementation Steps

### Step 1: Create Hydra Manifest Files

Create new files (following existing Keycloak pattern):

| New File | Replaces | Purpose |
|----------|----------|---------|
| `hydra-postgres-deployment.yaml` | - | PostgreSQL 15 single pod + PVC |
| `hydra-postgres-service.yaml` | - | PostgreSQL ClusterIP service |
| `hydra-deployment.yaml` | `keycloak-deployment.yaml` | Hydra public + admin containers |
| `hydra-service.yaml` | `keycloak-service.yaml` | Hydra services (public:4444, admin:4445) |
| `hydra-migration-job.yaml` | - | One-time DB migration job |
| `hydra-client-sync-job.yaml` | `keycloak-realm-configmap.yaml` | Sync clients from source of truth |
| `values-gateway.yaml` (update) | - | Update OIDC plugin to use Hydra JWKS |

### Step 2: Update redeploy.sh

Add new configuration variables:
```bash
# Hydra configuration (replaces Keycloak)
HYDRA_NAMESPACE="${HYDRA_NAMESPACE:-hydra}"
HYDRA_POSTGRES_DEPLOYMENT="${HYDRA_POSTGRES_DEPLOYMENT:-hydra/postgres-deployment.yaml}"
HYDRA_POSTGRES_SERVICE="${HYDRA_POSTGRES_SERVICE:-hydra/postgres-service.yaml}"
HYDRA_DEPLOYMENT="${HYDRA_DEPLOYMENT:-hydra/hydra-deployment.yaml}"
HYDRA_SERVICE="${HYDRA_SERVICE:-hydra/hydra-service.yaml}"
HYDRA_MIGRATION_JOB="${HYDRA_MIGRATION_JOB:-hydra/migration-job.yaml}"
HYDRA_CLIENT_SYNC_JOB="${HYDRA_CLIENT_SYNC_JOB:-hydra/client-sync-job.yaml}"
HYDRA_ROUTE="${HYDRA_ROUTE:-hydra/hydra-route.yaml}"
```

Add deployment functions (after APISIX, before httpbin):
1. `ensure_hydra_postgres()` - Deploy PostgreSQL, wait for ready
2. `run_hydra_migrations()` - Run migration job, wait for completion
3. `deploy_hydra()` - Deploy Hydra pods, wait for ready
4. `sync_hydra_clients()` - Run client sync job

Update main() to call Hydra functions instead of Keycloak.

### Step 3: Hydra Configuration

**hydra-deployment.yaml** key settings:
```yaml
env:
  - name: DSN
    value: postgres://hydra:hydra@hydra-postgres.hydra.svc.cluster.local:5432/hydra?sslmode=disable
  - name: URLS_SELF_ISSUER
    value: http://hydra.local/
  - name: STRATEGIES_ACCESS_TOKEN
    value: jwt
  - name: TTL_ACCESS_TOKEN
    value: 1h
  - name: OAUTH2_EXPOSE_INTERNAL_ERRORS
    value: "false"
```

**hydra-service.yaml**:
```yaml
ports:
  - name: public
    port: 4444
    nodePort: 30444  # For external access in kind
  - name: admin
    port: 4445       # Internal only, no nodePort
```

### Step 4: Client Sync Job

The `hydra-client-sync-job.yaml` will:
1. Wait for Hydra admin API to be ready
2. Create/update OAuth2 clients via Admin API
3. Example client creation:
```bash
curl -X POST http://hydra-admin:4445/admin/clients \
  -H "Content-Type: application/json" \
  -d '{
    "client_id": "go-rest",
    "client_secret": "go-rest-secret",
    "grant_types": ["client_credentials"],
    "token_endpoint_auth_method": "client_secret_post"
  }'
```

### Step 5: Update APISIX OIDC Plugin Config

Update `openid-pluginconfig.yaml` to use Hydra endpoints:
```yaml
discovery: http://hydra-public.hydra.svc.cluster.local:4444/.well-known/openid-configuration
# Or for JWT validation only:
jwks_uri: http://hydra-public.hydra.svc.cluster.local:4444/.well-known/jwks.json
```

### Step 6: Add Hydra HTTPRoute under /auth

Expose Hydra endpoints under `/auth` path prefix via APISIX Gateway:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: hydra-route
  namespace: hydra
spec:
  parentRefs:
    - name: apisix-gateway
      namespace: apisix
  rules:
    # /auth/.well-known/* → Hydra /.well-known/*
    - matches:
        - path: {type: PathPrefix, value: /auth/.well-known}
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /.well-known
      backendRefs:
        - name: hydra-public
          namespace: hydra
          port: 4444
    # /auth/oauth2/token → Hydra /oauth2/token
    - matches:
        - path: {type: PathPrefix, value: /auth/oauth2}
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /oauth2
      backendRefs:
        - name: hydra-public
          namespace: hydra
          port: 4444
```

**Exposed endpoints:**
- `GET  /auth/.well-known/openid-configuration` → OIDC discovery
- `GET  /auth/.well-known/jwks.json` → JWKS public keys
- `POST /auth/oauth2/token` → Token endpoint (client_credentials grant)

## Files to Create/Modify

All new Hydra manifests go under `hydra/` directory:

| File | Action | Purpose |
|------|--------|---------|
| `hydra/postgres-deployment.yaml` | Create | PostgreSQL 15 + PVC |
| `hydra/postgres-service.yaml` | Create | PostgreSQL ClusterIP |
| `hydra/hydra-deployment.yaml` | Create | Hydra pods |
| `hydra/hydra-service.yaml` | Create | Hydra public/admin services |
| `hydra/migration-job.yaml` | Create | DB schema migration |
| `hydra/client-sync-job.yaml` | Create | Client sync from source of truth |
| `hydra/hydra-route.yaml` | Create | HTTPRoute for /auth endpoints |
| `openid-pluginconfig.yaml` | Modify | Point to Hydra JWKS |
| `redeploy.sh` | Modify | Add Hydra deployment logic, reference hydra/ files |

## Validation Steps

After running `./redeploy.sh`:

1. Check PostgreSQL: `kubectl get pods -n hydra -l app=hydra-postgres`
2. Check Hydra: `kubectl get pods -n hydra -l app=hydra`
3. Check migration job completed: `kubectl get jobs -n hydra`
4. Verify OIDC discovery:
   ```bash
   kubectl run curl-test --rm -it --image=curlimages/curl --restart=Never -- \
     curl http://hydra-public.hydra.svc.cluster.local:4444/.well-known/openid-configuration
   ```
5. Get token (via APISIX /auth path):
   ```bash
   # From inside cluster
   kubectl run curl-test --rm -it --image=curlimages/curl --restart=Never -- \
     curl -X POST http://apisix-gateway.apisix.svc.cluster.local/auth/oauth2/token \
     -d "grant_type=client_credentials&client_id=go-rest&client_secret=go-rest-secret"

   # External (kind NodePort)
   curl -X POST http://<node-ip>:<nodeport>/auth/oauth2/token \
     -d "grant_type=client_credentials&client_id=go-rest&client_secret=go-rest-secret"
   ```
6. Verify OIDC discovery via /auth:
   ```bash
   curl http://<node-ip>:<nodeport>/auth/.well-known/openid-configuration
   ```

## Deployment Order in redeploy.sh

```
1. kind cluster (existing)
2. cert-manager (existing)
3. APISIX Helm (existing)
4. → Hydra PostgreSQL (NEW)
5. → Hydra migration job (NEW)
6. → Hydra deployment (NEW)
7. → Hydra client sync (NEW)
8. httpbin backend (existing)
9. Gateway + HTTPRoutes (existing)
10. OIDC plugin config (UPDATED to use Hydra)
11. Connectivity probes (existing)
```

## Future: HA Upgrade Path

When ready for production:
1. Install CloudNativePG operator
2. Create `Cluster` CRD with 3 replicas
3. Update Hydra DSN to point to CloudNativePG service
4. Scale Hydra to 3+ replicas
5. Add PodDisruptionBudget

## Keycloak Removal

Remove from `redeploy.sh`:
- Lines 24-26: `KEYCLOAK_CONFIGMAP`, `KEYCLOAK_DEPLOYMENT`, `KEYCLOAK_SERVICE` variables
- Lines 474-492: Keycloak deployment logic
- Lines 494-498: OIDC plugin config referencing Keycloak

Keycloak manifest files to delete (or archive):
- `keycloak-realm-configmap.yaml`
- `keycloak-deployment.yaml`
- `keycloak-service.yaml`

## Notes

- Hydra Admin API (port 4445) must never be exposed externally
- Client secrets should be stored in Kubernetes Secrets, referenced by sync job
- Consider using ExternalSecrets operator for production secret management
