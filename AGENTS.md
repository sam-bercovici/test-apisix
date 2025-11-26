# Repository Guidelines

## Documents
- `plans/` - architecture and migration plans
- `requirements/` - requirements documents

## Project Structure & Module Organization

This repository packages Envoy Gateway manifests for routing demo services with JWT authentication and two-tier rate limiting.

### Directory Structure
- `envoy-gateway/` - Envoy Gateway configuration (GatewayClass, Gateway, policies)
- `routes/` - HTTPRoute definitions for each service
- `workloads/` - Application deployments (httpbin, go-rest-api)
- `redis/` - Redis deployment for rate limit counters
- `hydra/` - Ory Hydra OAuth2/OIDC stack (Helm-based with CloudNativePG)
- `plans/` - Architecture and migration documentation
- `requirements/` - Project requirements documents

### Key Files
- `envoy-gateway/helm-values.yaml` - Helm values for Envoy Gateway with Redis rate limit config
- `envoy-gateway/gateway-class.yaml` - GatewayClass and EnvoyProxy with UDS volume mount
- `envoy-gateway/gateway.yaml` - Gateway with HTTP listener (no TLS)
- `envoy-gateway/security-policy.yaml` - JWT authentication targeting go-rest-route (uses backendRefs for JWKS)
- `envoy-gateway/tier1-rate-limit-policy.yaml` - Burst rate limiting (10 rps per org)
- `hydra/helm-values.yaml` - Ory Hydra Helm chart values (v25.4.0)
- `hydra/postgres-cluster.yaml` - CloudNativePG cluster for PostgreSQL 17
- `hydra/reference-grant.yaml` - Cross-namespace access for SecurityPolicy JWKS
- `routes/*.yaml` - HTTPRoute definitions for httpbin, go-rest-api, and Hydra

## Build, Test, and Development Commands

```bash
# Deploy everything
./redeploy.sh

# Port-forward for local access
./portforward.sh

# Validate deployment
./validate-apitest.sh
./validate-rate_limit.sh
```

### Manual Commands
```bash
# Install CloudNativePG operator
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace

# Install Envoy Gateway
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.6.0 -n envoy-gateway-system --create-namespace \
  -f envoy-gateway/helm-values.yaml

# Install Ory Hydra
helm upgrade --install hydra ory/hydra \
  --version 0.52.0 -n hydra \
  -f hydra/helm-values.yaml

# Apply gateway resources
kubectl apply -f envoy-gateway/gateway-class.yaml
kubectl apply -f envoy-gateway/gateway.yaml

# Apply routes
kubectl apply -f routes/

# Check status
kubectl get gateway,httproute,securitypolicy,backendtrafficpolicy -A
kubectl get cluster -n hydra  # CloudNativePG PostgreSQL status
helm list -n hydra            # Hydra Helm release
```

## Coding Style & Naming Conventions

- Two-space indentation in YAML
- Lowercase-kebab resource names (`httpbin-route`, `eg-gateway`)
- Match namespaces to owning component (`envoy-gateway-system`, `hydra`, `redis-system`, `cnpg-system`)
- Annotate non-obvious values with inline comments
- Document hostnames and backends in `metadata.annotations`
- Use Helm charts when available (Envoy Gateway, Hydra, CloudNativePG) over raw manifests

## Testing Guidelines

- Initialize clean sandbox with `kind create cluster`
- Validate schemas with `kubectl apply --dry-run=client -f <file>`
- Confirm reconciliation via `kubectl get gateway,httproute -A`
- Check for `Programmed=True` on Gateway listeners (note: `AddressNotAssigned` is expected in Kind)
- Use `./validate-apitest.sh` and `./validate-rate_limit.sh` for end-to-end validation

## Commit & Pull Request Guidelines

- Adopt Conventional Commits (`feat:`, `fix:`, `docs:`)
- Commit related manifest changes together
- Include `kubectl diff` output in PR descriptions
- Reference linked issues and note rollout steps

## Security & Configuration Tips

- Keep secrets out of version control (demo credentials only)
- JWT authentication is required for `apitest.local` routes
- `httpbin.local` is intentionally unauthenticated for testing
- TLS is not handled (assumed terminated externally)
