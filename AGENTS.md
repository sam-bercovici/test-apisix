# Repository Guidelines

## Documents
- `plans/` - architecture and migration plans
- `requirements/` - requirements documents

## Project Structure & Module Organization

This repository packages Envoy Gateway manifests for routing demo services with JWT authentication and two-tier rate limiting.

### Directory Structure
- `envoy-gateway/` - Envoy Gateway configuration (GatewayClass, Gateway, policies)
- `routes/` - HTTPRoute definitions for each service
- `workloads/` - Application deployments (httpbin, go-rest-api, hydra-sidecar)
- `redis/` - Redis deployment for rate limit counters
- `hydra/` - Ory Hydra OAuth2/OIDC stack (Helm-based with CloudNativePG)
- `plans/` - Architecture and migration documentation
- `requirements/` - Project requirements documents

### Key Files
- `envoy-gateway/helm-values.yaml` - Helm values for Envoy Gateway with Redis rate limit config
- `envoy-gateway/gateway-class.yaml` - GatewayClass and EnvoyProxy with UDS volume mount
- `envoy-gateway/gateway.yaml` - Gateway with HTTP listener (no TLS)
- `envoy-gateway/security-policy.yaml` - JWT authentication targeting go-rest-route (uses backendRefs for JWKS)
- `envoy-gateway/tier1-rate-limit-policy.yaml` - Tiered burst rate limiting (50/10/5 rps by tier per client)
- `envoy-gateway/tier2-quota-policy.yaml` - Tiered daily quota (10K/1K/500 per day by tier per org)
- `hydra/helm-values.yaml` - Ory Hydra Helm chart values (v25.4.0)
- `hydra/postgres-cluster.yaml` - CloudNativePG cluster for PostgreSQL 17
- `hydra/reference-grant.yaml` - Cross-namespace access for SecurityPolicy JWKS
- `routes/*.yaml` - HTTPRoute definitions for httpbin, go-rest-api, and Hydra (public and internal)
- `hydra/client-sync-job.yaml` - OAuth2 client provisioning with org metadata
- `hydra/hydra-sidecar-service.yaml` - K8s service for hydra-sidecar (external access to sync API)
- `workloads/hydra-sidecar/` - Hydra sidecar (Go) for token-hook, client creation with hash, and bulk sync

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

### Hydra Sidecar Build Commands

Go module operations must be run via the Makefile using the build container (no local Go installation required).

**Go Version:** This project uses Go 1.25 (latest). The Makefile runs all Go commands in a `golang:1.25-alpine` container.

```bash
# Tidy go modules (runs in golang:1.25-alpine container)
make -C workloads/hydra-sidecar tidy

# Build image for local Kind cluster
make -C workloads/hydra-sidecar build-local

# Load image into Kind and restart deployment
kind load docker-image hydra-sidecar:latest --name kind
kubectl rollout restart deployment/hydra -n hydra
```

**Important:** Never run `go mod tidy` directly - always use `make tidy` to ensure consistent Go version and environment.

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
  --version 0.60.0 -n hydra \
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
