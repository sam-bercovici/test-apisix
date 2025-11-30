# Envoy Gateway Demo

This repository provisions a Kind cluster with Envoy Gateway and supporting
components to validate gateway behaviour across authentication, rate limiting,
and routing paths. TLS is assumed to be terminated externally.

## Features

- **Envoy Gateway** with Gateway API resources (GatewayClass, Gateway, HTTPRoute)
- **JWT Authentication** via Ory Hydra (OAuth2/OIDC provider) with token-hook sidecar
- **Organization Binding** - Multiple clients can share rate limit quotas via org_id
- **Tiered Rate Limiting** based on client tier (premium/basic/default):
  - Tier 1: Burst protection (50/10/5 rps per client by tier)
  - Tier 2: Daily quota (10K/1K/500 per day per org by tier) via internal UDS listener
- **Redis** backend for global rate limit counters

## Repository Layout

```
.
├── envoy-gateway/           # Envoy Gateway configuration
│   ├── helm-values.yaml     # Helm values with Redis rate limit config
│   ├── gateway-class.yaml   # GatewayClass + EnvoyProxy with UDS volume
│   ├── gateway.yaml         # Gateway with HTTP listener
│   ├── security-policy.yaml # JWT authentication via Hydra
│   ├── tier1-rate-limit-policy.yaml  # Burst rate limiting
│   ├── uds-backend.yaml     # Backend CRD for UDS endpoint
│   └── uds-patch-policy.yaml # EnvoyPatchPolicy for internal listener
├── routes/                  # HTTPRoute definitions
│   ├── go-rest-route.yaml   # API route (JWT required)
│   ├── httpbin-route.yaml   # Httpbin route (no auth)
│   ├── hydra-route.yaml     # Hydra internal endpoints (JWKS, introspect)
│   └── hydra-public-route.yaml  # Hydra public endpoints (token, revoke)
├── workloads/               # Application deployments
│   ├── go-rest-api.yaml     # Go REST API deployment + service
│   ├── httpbin.yaml         # Httpbin deployment + service
│   └── token-hook/          # Token hook sidecar (Go, Dockerfile)
├── redis/                   # Redis for rate limiting
│   └── deployment.yaml      # Redis deployment + service
├── hydra/                   # Ory Hydra OAuth2 stack (Helm-based)
│   ├── helm-values.yaml     # Hydra Helm values with token-hook sidecar
│   ├── postgres-cluster.yaml # CloudNativePG PostgreSQL cluster
│   ├── client-sync-job.yaml # OAuth2 client provisioning with org metadata
│   └── reference-grant.yaml # Cross-namespace JWKS access
├── plans/                   # Architecture and migration plans
├── requirements/            # Project requirements documents
├── redeploy.sh              # Full deployment automation
├── portforward.sh           # Port-forward helper for local access
├── validate-apitest.sh      # API and auth validation
└── validate-rate_limit.sh   # Rate limit validation
```

## Quick Start

```bash
# Deploy everything to Kind cluster
./redeploy.sh

# Port-forward for local access
./portforward.sh &

# Validate deployment
./validate-apitest.sh
./validate-rate_limit.sh
```

## Access Examples

With port-forward running (`./portforward.sh`):

```bash
# Httpbin (no auth required)
curl -H 'Host: httpbin.local' http://localhost:8080/status/200

# Get JWT token from Hydra
TOKEN=$(curl -s -X POST \
  -d 'grant_type=client_credentials&client_id=go-rest&client_secret=go-rest-secret' \
  http://localhost:8080/auth/oauth2/token | jq -r '.access_token')

# Authenticated API request
curl -H 'Host: apitest.local' \
  -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/health-check
```

## Architecture

```
Client → Gateway (Tier 1: 50/10/5 rps by tier) → UDS → Internal Listener (Tier 2: 10K/1K/500 per day) → Backend
```

- **Tier 1**: External listener handles JWT validation and tiered burst rate limiting per client
- **Tier 2**: Internal UDS listener enforces tiered daily quota per organization
- Requests blocked by Tier 1 do NOT count against Tier 2 quota
- Multiple clients can share quotas via `org_id` (organization binding)

## Prerequisites

- Docker (for Kind)
- kubectl
- Helm
- curl, jq

## OAuth2 Clients

Pre-configured Hydra clients with organization binding:

| Client | Secret | Org ID | Tier | Scopes |
|--------|--------|--------|------|--------|
| `acme-service-1` | `acme-service-1-secret` | `org-acme` | premium | read, write |
| `acme-service-2` | `acme-service-2-secret` | `org-acme` | premium | read |
| `demo-client` | `demo-secret` | `org-demo` | basic | read |
| `go-rest` | `go-rest-secret` | (none) | default | read, write |

**Organization Binding**: Clients with the same `org_id` share daily quota limits. For example,
`acme-service-1` and `acme-service-2` share the 10K/day quota for `org-acme`.
