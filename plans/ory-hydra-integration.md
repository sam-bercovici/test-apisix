# Ory Hydra Integration (Helm-based with CloudNativePG)

## Overview

Ory Hydra provides M2M OAuth2/OIDC token management for the demo gateway, deployed via Helm chart with CloudNativePG for PostgreSQL.

## Current Implementation

- **Hydra Version**: v25.4.0 (deployed via Helm chart v0.52.0)
- **PostgreSQL**: PostgreSQL 17 via CloudNativePG operator
- **Deployment Method**: Helm chart with values in `hydra/helm-values.yaml`
- **Database Migrations**: Handled automatically by Helm chart (automigration)

## Requirements Summary

- **Use Case**: M2M OAuth2 with 10-100 client IDs
- **Source of Truth**: External system manages client IDs/secrets
- **Hydra Responsibilities**: Token signing (JWKS), `/token` endpoint, OIDC discovery
- **Operational Model**:
  - Clients handle 401 → re-authenticate (no refresh token persistence needed)
  - Revocation via client secret rotation in source of truth
  - Stable JWKS keys across restarts
- **Database**: CloudNativePG-managed PostgreSQL 17 cluster
- **Deployment**: Kind cluster (local), integrated into `redeploy.sh`

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Kubernetes Cluster                      │
│                                                              │
│  ┌──────────────┐      ┌──────────────┐                     │
│  │ Client Sync  │      │ Envoy Gateway│                     │
│  │ Job          │      │   Gateway    │                     │
│  └──────┬───────┘      └──────┬───────┘                     │
│         │                     │ validates JWT via JWKS      │
│         │ Hydra Admin API     │ (backendRefs to hydra-public)│
│         ▼                     ▼                             │
│  ┌────────────────────────────────────────┐                 │
│  │         Ory Hydra (Helm Chart)         │                 │
│  │  - POST /oauth2/token                  │                 │
│  │  - GET /.well-known/jwks.json          │                 │
│  │  - GET /.well-known/openid-configuration│                │
│  └──────────────────┬─────────────────────┘                 │
│                     │                                        │
│                     ▼                                        │
│  ┌────────────────────────────────────────┐                 │
│  │   CloudNativePG PostgreSQL 17          │                 │
│  │   - JWKS signing keys                  │                 │
│  │   - OAuth2 client registrations        │                 │
│  │   - Access token metadata              │                 │
│  └────────────────────────────────────────┘                 │
└─────────────────────────────────────────────────────────────┘
```

## File Structure

All Hydra manifests are in the `hydra/` directory:

| File | Purpose |
|------|---------|
| `hydra/helm-values.yaml` | Hydra Helm chart values (v25.4.0, JWT strategy, PostgreSQL DSN) |
| `hydra/postgres-cluster.yaml` | CloudNativePG Cluster CRD for PostgreSQL 17 |
| `hydra/client-sync-job.yaml` | Job to create OAuth2 clients (go-rest, demo-client) |
| `hydra/reference-grant.yaml` | ReferenceGrant for SecurityPolicy JWKS access |

## Helm Values Configuration

Key settings in `hydra/helm-values.yaml`:

```yaml
image:
  tag: v25.4.0

hydra:
  dev: true  # For local development only
  automigration:
    enabled: true
    type: job
  config:
    dsn: postgres://hydra:hydra@hydra-postgres-rw.hydra.svc.cluster.local:5432/hydra?sslmode=disable
    urls:
      self:
        issuer: http://hydra.local/auth
    strategies:
      access_token: jwt
    ttl:
      access_token: 1h
    oauth2:
      client_credentials:
        default_grant_allowed_scope: true

service:
  public:
    port: 4444
  admin:
    port: 4445

maester:
  enabled: false  # CRD-based client management disabled
```

## CloudNativePG Configuration

The PostgreSQL cluster is defined in `hydra/postgres-cluster.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: hydra-postgres
  namespace: hydra
spec:
  instances: 1  # Single instance for dev
  imageName: ghcr.io/cloudnative-pg/postgresql:17
  storage:
    size: 1Gi
  bootstrap:
    initdb:
      database: hydra
      owner: hydra
      secret:
        name: hydra-postgres-credentials
```

## Deployment Order in redeploy.sh

```
1. Redis (rate limiting)
2. CloudNativePG operator (cnpg-system namespace)
3. Envoy Gateway (Helm)
4. Gateway resources (GatewayClass, Gateway)
5. Workloads (httpbin, go-rest-api)
6. Hydra PostgreSQL cluster (CloudNativePG)
7. Hydra (Helm) - includes automigration
8. Hydra client sync job
9. Hydra ReferenceGrant
10. HTTPRoutes
11. SecurityPolicy (JWT auth)
12. Rate limit policy
```

## Envoy Gateway Integration

### SecurityPolicy JWKS Configuration

The SecurityPolicy in `envoy-gateway/security-policy.yaml` uses `backendRefs` for internal JWKS fetching:

```yaml
spec:
  jwt:
    providers:
    - name: hydra
      issuer: http://hydra.local/auth
      remoteJWKS:
        uri: http://hydra-public.hydra.svc.cluster.local:4444/.well-known/jwks.json
        backendRefs:
        - name: hydra-public
          namespace: hydra
          port: 4444
```

### ReferenceGrant for Cross-Namespace Access

The `hydra/reference-grant.yaml` allows SecurityPolicy in default namespace to reference hydra-public Service:

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-securitypolicy-jwks
  namespace: hydra
spec:
  from:
  - group: gateway.envoyproxy.io
    kind: SecurityPolicy
    namespace: default
  to:
  - group: ""
    kind: Service
    name: hydra-public
```

## Validation

After running `./redeploy.sh`:

1. Check CloudNativePG operator: `kubectl get pods -n cnpg-system`
2. Check PostgreSQL cluster: `kubectl get cluster -n hydra`
3. Check Hydra: `helm list -n hydra` and `kubectl get pods -n hydra`
4. Run validation: `./validate-apitest.sh`

Expected results:
- httpbin (no auth): HTTP 200
- API without creds: HTTP 401 (expected)
- API with JWT: HTTP 200

## OAuth2 Clients

Clients are created by the `hydra-client-sync` job:

| Client ID | Secret | Grant Type | Purpose |
|-----------|--------|------------|---------|
| `go-rest` | `go-rest-secret` | client_credentials | API authentication |
| `demo-client` | `demo-secret` | client_credentials | Demo/testing |

## Token Acquisition

```bash
# Get token from Hydra (via gateway)
TOKEN=$(curl -s -X POST \
  -d 'grant_type=client_credentials&client_id=go-rest&client_secret=go-rest-secret' \
  http://localhost:8080/auth/oauth2/token | jq -r '.access_token')

# Use token for authenticated request
curl -H 'Host: apitest.local' \
  -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/health-check
```

## Notes

- Hydra Admin API (port 4445) is internal-only, never exposed externally
- JWT tokens are valid for 1 hour (configurable in helm-values.yaml)
- `maester` (CRD-based client management) is disabled; clients are managed via Admin API
- The `hydra.dev: true` setting is for local development only; remove for production
