---
title: Demo Gateway Requirements
version: v2.0
author: Project Team
date: 2025-11-26
status: Draft
---

# Demo Gateway Requirements

## 1. Scope and Objectives

1.1 The system MUST provide a reproducible local environment that validates Envoy Gateway as the API gateway for demo services (httpbin and go-rest).
1.2 The environment MUST exercise authentication, rate limiting, and observability paths needed for evaluation of Envoy Gateway API support.
1.3 The solution MUST remain fully open source, relying only on community editions of all components (Envoy Gateway, Ory Hydra, Redis, Kind, etc.).
1.4 TLS termination is OUT OF SCOPE; TLS is assumed to be terminated externally (e.g., load balancer, CDN).

## 2. Functional Requirements

### 2.1 Gateway and Routing

2.1.1 Envoy Gateway MUST be deployed via the official Helm chart with values stored in `envoy-gateway/helm-values.yaml`.
2.1.2 The deployment MUST create Gateway API `GatewayClass`, `Gateway`, and `HTTPRoute` resources that expose `httpbin.local` and `apitest.local`.
2.1.3 The `redeploy.sh` script MUST install or upgrade Envoy Gateway, apply gateway resources, and all route manifests in the `routes/` directory.
2.1.4 Envoy Gateway MUST surface an HTTP (80) listener through a Kubernetes Service (LoadBalancer or NodePort depending on environment).
2.1.5 The go-rest backend MUST be reachable through Envoy Gateway at `/health-check` and enforce JWT/OIDC token-based access.
2.1.6 The httpbin backend MUST be reachable without authentication for basic connectivity testing.

### 2.2 Authentication and Authorization

2.2.1 The solution MUST provide OIDC/JWT bearer-token validation using Envoy Gateway `SecurityPolicy` with JWT provider configured to validate tokens from Ory Hydra.
2.2.2 The JWT configuration MUST run in bearer-only mode so that requests without tokens receive HTTP 401 and automated clients can supply tokens without browser redirects.
2.2.3 The `SecurityPolicy` MUST target only routes requiring authentication (go-rest-route); httpbin MUST remain unauthenticated.
2.2.4 JWT claims (`client_id`) MUST be extracted to headers (`x-org-id`) for downstream rate limiting and logging.

### 2.3 Rate Limiting

2.3.1 Rate limiting MUST be implemented using a two-tier architecture to separate burst protection from daily quota enforcement.
2.3.2 **Tier 1 (Burst Protection)**: 10 requests per second per organization (`x-org-id` header) with IP-based fallback for unauthenticated requests.
2.3.3 **Tier 2 (Daily Quota)**: 1000 requests per day per organization using a sliding 24-hour window.
2.3.4 Requests blocked by Tier 1 (burst) MUST NOT count against Tier 2 (daily quota).
2.3.5 Rate limiting MUST use Redis as the backend for global counter synchronization across Envoy proxy replicas.
2.3.6 The two-tier architecture MUST be implemented using an internal Unix Domain Socket (UDS) listener via `EnvoyPatchPolicy`.

### 2.4 Supporting Services

2.4.1 Ory Hydra MUST be deployed via official Helm chart (v0.52.0) as the OAuth2/OIDC provider.
2.4.2 Hydra MUST use PostgreSQL 17 managed by CloudNativePG operator for persistence.
2.4.3 Hydra MUST be configured with OAuth2 clients (`go-rest`, `demo-client`) for machine-to-machine authentication via a client sync Job.
2.4.4 The `httpbin` demo service MUST be deployed with a `Deployment` and `Service` managed by `redeploy.sh`.
2.4.5 Redis MUST be deployed in `redis-system` namespace for rate limit counter storage.
2.4.6 A `ReferenceGrant` MUST exist in the `hydra` namespace to allow SecurityPolicy cross-namespace JWKS access.

## 3. Non-Functional Requirements

### 3.1 Environment and Automation

3.1.1 The entire environment MUST stand up on Kind using a single invocation of `./redeploy.sh`, which is responsible for cluster checks, Helm installations, manifests, and readiness probes.
3.1.2 The script MUST wait for CloudNativePG operator, Envoy Gateway controller, Redis, PostgreSQL cluster, Hydra deployments, and Gateway readiness before proceeding.
3.1.3 The script MUST handle Kind cluster limitations (LoadBalancer `<pending>`) by accepting listener-programmed status when addresses are not assigned.
3.1.4 The script MUST print HTTP test hints and port-forward instructions for local access.
3.1.5 A `portforward.sh` helper MUST exist to simplify local access to the gateway.

### 3.2 Documentation

3.2.1 README.md MUST describe the Envoy Gateway architecture and deployment process.
3.2.2 `plans/ory-hydra-integration.md` MUST document the Hydra integration with CloudNativePG.
3.2.3 `AGENTS.md` MUST note the `requirements/` and `plans/` directories and direct contributors to store requirements and plans there.

### 3.3 Maintainability and Extensibility

3.3.1 All configuration and manifests MUST use declarative YAML with two-space indentation and consistent naming (lowercase-kebab).
3.3.2 The repository MUST keep secrets out of version control; sample credentials are limited to demo values (`go-rest-secret`).
3.3.3 The requirements directory MUST capture evolving functional/non-functional requirements so the project baseline remains discoverable.
3.3.4 Manifests MUST be organized by component: `envoy-gateway/`, `routes/`, `redis/`, `hydra/`.

## 4. Architecture Overview

```
                                    ┌─────────────────────────────────────────┐
                                    │           Envoy Gateway Pod             │
┌──────────┐   HTTP :80             │  ┌─────────────────────────────────┐    │
│  Client  │ ───────────────────────┼─►│  External Listener (Tier 1)    │    │
└──────────┘                        │  │  - JWT Validation              │    │
                                    │  │  - Burst Rate Limit (10 rps)   │    │
                                    │  └───────────────┬─────────────────┘    │
                                    │                  │ UDS                  │
                                    │  ┌───────────────▼─────────────────┐    │
                                    │  │  Internal Listener (Tier 2)    │    │
                                    │  │  - Daily Quota (1000/day)      │    │
                                    │  └───────────────┬─────────────────┘    │
                                    └──────────────────┼──────────────────────┘
                                                       │
                    ┌──────────────────────────────────┼──────────────────────────────────┐
                    │                                  │                                  │
            ┌───────▼───────┐                  ┌───────▼───────┐                  ┌───────▼───────┐
            │   httpbin     │                  │  go-rest-api  │                  │    Hydra      │
            │  (no auth)    │                  │  (JWT auth)   │                  │  (OAuth2)     │
            └───────────────┘                  └───────────────┘                  └───────────────┘
```

## 5. Open Questions / Future Considerations

5.1 Browser-based interactive OIDC (redirect to Hydra, session cookies) is NOT currently required; any change would necessitate updates to SecurityPolicy configuration.
5.2 Self-service API key issuance is OUT OF SCOPE; this demo uses only OAuth2 client credentials flow.
5.3 TLS termination MAY be added in future iterations if required; current design assumes external termination.
5.4 Observability (Prometheus metrics, distributed tracing) MAY be added as optional components.
