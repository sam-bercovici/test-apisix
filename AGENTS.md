# Repository Guidelines

## Project Structure & Module Organization
This repository packages Apache APISIX Gateway API manifests for routing demo services.
- `httpbin-route.yaml` declares the `GatewayClass`, `Gateway`, and `HTTPRoute` used to expose httpbin; group related routes in future under a directory per service and reference them from an overlay.
- `values-gateway.yaml` is the Helm values file applied to the APISIX chart; it now manages the default `GatewayProxy` via Helm—keep environment-specific overrides in similarly named files (`values-<env>.yaml`) and avoid mixing secrets into them.

## Build, Test, and Development Commands
- `helm repo add apisix https://charts.apiseven.com` once per environment to source the APISIX chart.
- `helm upgrade --install apisix apisix/apisix -f values-gateway.yaml -n apisix --create-namespace` deploys or updates the gateway with the repo configuration.
- `kubectl apply -f httpbin-route.yaml` syncs the Gateway API resources; pair with `kubectl delete -f` when retiring routes.

## Coding Style & Naming Conventions
Stick to two-space indentation in YAML and alphabetize top-level keys where practical.
Use lowercase-kebab resource names (`httpbin-route`, `apisix-gateway`) and match namespaces to their owning component.
Annotate non-obvious values with inline comments, and prefer documenting hostnames and backend services in the `metadata.annotations` block.

## Testing Guidelines
Initialize a clean sandbox with `kind create cluster` before applying manifests locally.
After manifest changes, validate schemas locally with `kubectl apply --server-dry-run=client -f <file>`.
Confirm controller reconciliation via `kubectl get gateway,httproute -A`; ensure `Programmed=True` and check controller logs for any `gateway proxy not found` errors.
When touching Helm values, run `helm template apisix apisix/apisix -f values-gateway.yaml | kubeconform` to catch regressions before pushing, and confirm `kubectl get gatewayproxy -n apisix` reports the `apisix-config` control-plane target.

## Commit & Pull Request Guidelines
Adopt Conventional Commits (e.g., `feat: expose metrics route`) to signal intent in history.
Commit related manifest changes together and include the rendered diff from `helm template` or `kubectl diff` in the PR description for reviewers.
Reference linked issues, note required rollout steps (helm upgrade, kubectl apply), and attach any validation output or dashboard screenshots relevant to the change.

## Security & Configuration Tips
Keep secrets in external secret managers; reference them with `Secret` objects instead of embedding credentials.
Review Gateway hostnames before merging to avoid leaking internal domains, and ensure TLS additions include certificate provisioning steps.
