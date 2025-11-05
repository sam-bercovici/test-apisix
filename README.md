# APISIX Integration Test Manifests

This repository provisions a Kind cluster with Apache APISIX and supporting
components so we can validate gateway behaviour across multiple plugins and
traffic paths. The focus is on exercising authentication, rate limiting, and
observability in a repeatable way.

Jetstack cert-manager is installed via Helm during `redeploy.sh` runs so APISIX
can terminate TLS with a locally issued `*.local` wildcard certificate.
The APISIX Helm values enable the built-in TLS listener (`apisix.ssl.enabled`)
and expose both HTTP (80) and HTTPS (443) ports via a single NodePort service.

## Plugins Covered

APISIX is deployed with the following plugins enabled in this environment:

- `openid-connect` – verifies Keycloak-issued JWT access tokens and propagates
  user context downstream.
- `key-auth` – enforces API keys for non-OIDC clients.
- `limit-req` – throttles per authenticated identity (APISIX consumer name).
- `limit-count` – applies a fallback quota per client IP.
- `prometheus` – exposes metrics for scraping.

## Repository Layout

| File | Purpose |
| ---- | ------- |
| `values-gateway.yaml` | Helm values enabling the APISIX dataplane, ingress controller, and Prometheus plugin. |
| `gateway.yaml` | GatewayClass and Gateway definitions for the APISIX Gateway API controller. |
| `apisix-local-tls.yaml` | cert-manager Issuer/Certificate providing the self-signed `*.local` wildcard secret used by the TLS listener (rotation policy set to `Always`). |
| `apisix-tls-local.yaml` | Binds the wildcard secret to APISIX via the `ApisixTls` custom resource so HTTPS listeners serve `*.local`. |
| `httpbin-route.yaml` | Gateway API HTTPRoute to expose the httpbin sample backend. |
| `api-deployment.yaml` / `api-service.yaml` | Deploy and expose the Go REST sample service used for OIDC/API-key testing. |
| `go-rest-apisixroute.yaml` | APISIX CRD configuring dual auth (OIDC or API key) and rate limits for `apitest.local`. |
| `go-rest-consumer.yaml` | APISIX `Consumer` representing the demo user/API key so rate limits apply per identity. |
| `go-rest-consumer-secret.yaml` | Optional example secret for key-auth if you prefer secretRef wiring. |
| `keyauth-pluginconfig.yaml` | APISIX plugin config bundling key-auth plus identity/IP-based rate limiting. |
| `openid-pluginconfig.yaml` | APISIX plugin config for OIDC plus identity/IP-based rate limiting. |
| `apisix-prometheus-service.yaml` | ClusterIP service exposing APISIX Prometheus metrics (port 9091). |
| `keycloak-realm-configmap.yaml` | Seeds the Keycloak realm, user, and client required for OIDC tests. |
| `keycloak-deployment.yaml` / `keycloak-service.yaml` | Deploy Keycloak and expose its admin UI via NodePort 30080. |
| `redeploy.sh` | End-to-end automation: create/update Kind cluster, install APISIX via Helm, deploy backends, apply plugin configs. |
| `validate-apitest.sh` | Smoke test covering OIDC-only, API-key-only, and unauthenticated requests against APISIX. |
| `validate-rate_limit.sh` | Burst tester ensuring limit-req / limit-count emit HTTP 429 for API-key and bearer flows. |
| `validate-prometheus.sh` | Verifies that the Prometheus metrics endpoint responds correctly. |
| `portforward.sh` | Helper for port-forwarding into APISIX services (HTTP 8080↔80 and HTTPS 8443↔443) when NodePort access isn’t available. |
| `test_apisix.md` | Detailed walkthrough covering Keycloak setup, manual testing, troubleshooting, and rate-limit notes. |
| `api-route.yaml` | Optional HTTPRoute example (not applied by default). |
| `cleanup-local-tls.sh` | Removes the self-signed TLS certificate, issuer, and secret created for local testing. |

## Typical Workflow

1. `./redeploy.sh` – bootstrap or refresh the Kind cluster with APISIX, cert-manager, and all supporting services (including the `*.local` TLS secret).
2. `./validate-apitest.sh` – verify dual-auth behaviour (OIDC vs API key) and anonymous blocking.
3. `./validate-rate_limit.sh` – confirm throttling triggers 429 responses.
4. `./validate-prometheus.sh` – check metrics reachability (optional).
5. Consult `test_apisix.md` for in-depth validation steps and troubleshooting tips.
6. `./cleanup-local-tls.sh` – (optional) remove the self-signed wildcard certificate/issuer; cert-manager will mint a fresh keypair on the next apply because rotation is set to `Always`.

## Prerequisites

- Docker (for Kind), kubectl, Helm, curl, jq.
- Sufficient local resources to run a Kind cluster.
- Network access to container registries for pulling APISIX, Keycloak, and sample images.

Once the cluster is running, `/etc/hosts` (or an equivalent mechanism) should map
`apitest.local` and `httpbin.local` to the Kind node IP so you can test from your
workstation.
