# Envoy Gateway Demo

This repository provisions a Kind cluster with Envoy Gateway and supporting
components to validate gateway behaviour across authentication, rate limiting,
and routing paths. TLS is assumed to be terminated externally.

## Features

- **Envoy Gateway** with Gateway API resources (GatewayClass, Gateway, HTTPRoute)
- **JWT Authentication** via Ory Hydra (OAuth2/OIDC provider)
- **Two-Tier Rate Limiting**:
  - Tier 1: Burst protection (10 rps per org)
  - Tier 2: Daily quota (1000 req/day per org) via internal UDS listener
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
│   └── hydra-route.yaml     # Hydra OAuth2 endpoints
├── workloads/               # Application deployments
│   ├── go-rest-api.yaml     # Go REST API deployment + service
│   └── httpbin.yaml         # Httpbin deployment + service
├── redis/                   # Redis for rate limiting
│   └── deployment.yaml      # Redis deployment + service
├── hydra/                   # Ory Hydra OAuth2 stack
│   ├── postgres-deployment.yaml
│   ├── postgres-service.yaml
│   ├── hydra-deployment.yaml
│   ├── hydra-service.yaml
│   ├── migration-job.yaml
│   └── client-sync-job.yaml
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
Client → Gateway (Tier 1: 10 rps burst) → UDS → Internal Listener (Tier 2: 1000/day) → Backend
```

- **Tier 1**: External listener handles JWT validation and burst rate limiting
- **Tier 2**: Internal UDS listener enforces daily quota
- Requests blocked by Tier 1 do NOT count against Tier 2 quota

## Prerequisites

- Docker (for Kind)
- kubectl
- Helm
- curl, jq

## OAuth2 Clients

Pre-configured Hydra clients:
- `go-rest` / `go-rest-secret` - For API access (scopes: read, write)
- `demo-client` / `demo-secret` - For testing (scopes: openid, profile)
