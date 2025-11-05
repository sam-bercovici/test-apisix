---
title: APISIX Demo Gateway Requirements
version: v1.0
author: Project Team
date: 2025-11-05
status: Draft
---

# APISIX Demo Gateway Requirements

## 1. Scope and Objectives

1.1 The system MUST provide a reproducible local environment that validates Apache APISIX OSS as the API gateway for demo services (httpbin and go-rest).  
1.2 The environment MUST exercise authentication, rate limiting, TLS termination, and observability paths needed for evaluation of APISIX Gateway API support.  
1.3 The solution MUST remain fully open source, relying only on community editions of all components (APISIX OSS, cert-manager, Kind, Keycloak, etc.).

## 2. Functional Requirements

### 2.1 Gateway and Routing

2.1.1 APISIX MUST be deployed via the official Helm chart with values stored in `values-gateway.yaml`.  
2.1.2 The deployment MUST create a Gateway API `GatewayClass`, `Gateway`, and HTTPRoute resources that expose `httpbin.local` and `apitest.local`.  
2.1.3 The `redeploy.sh` script MUST install or upgrade APISIX, apply `gateway.yaml`, `httpbin-route.yaml`, and any additional route manifests in the repository.  
2.1.4 APISIX MUST surface both HTTP (80) and HTTPS (443) listeners through a single `apisix-gateway` Kubernetes Service of type `NodePort`.  
2.1.5 The go-rest backend MUST be reachable through APISIX at `/health-check` and enforce either API key or OIDC/token-based access.

### 2.2 Authentication and Authorization

2.2.1 The solution MUST provide API key authentication using the APISIX `key-auth` plugin configured via `go-rest-keyauth` (header `X-API-Key`, default key `go-rest-demo-key`).  
2.2.2 The solution MUST provide OIDC bearer-token validation using the APISIX `openid-connect` plugin configured via `go-rest-oidc`, pointing to Keycloak's demo realm discovery endpoint.  
2.2.3 The OIDC configuration MUST run in bearer-only mode so that requests without tokens receive HTTP 401 and automated clients can supply tokens without browser redirects.  
2.2.4 Rate limiting MUST be enforced for both auth paths using APISIX `limit-req` (10 req/s with burst 5 per consumer) and `limit-count` (240 req/min per client address).

### 2.3 TLS and Certificate Management

2.3.1 Jetstack cert-manager MUST be installed or upgraded automatically via `redeploy.sh`, with CRDs ensured present (`crds.enabled=true`).  
2.3.2 A self-signed wildcard certificate for `*.local` MUST be issued by cert-manager using manifests under source control (`apisix-local-tls.yaml`).  
2.3.3 The certificate secret `apisix-local-wildcard-tls` MUST be bound to APISIX through an `ApisixTls` resource (`apisix-tls-local.yaml`), enabling TLS termination on the HTTPS listener.  
2.3.4 The certificate MUST include SAN entries for `*.local`, `apitest.local`, and `httpbin.local`, and private key rotation MUST be set to `Always`.  
2.3.5 Documentation MUST instruct users to test TLS using either `/etc/hosts` entries or `curl --resolve` to ensure SNI matches the wildcard.

### 2.4 Supporting Services

2.4.1 Keycloak MUST be deployed (manifests in repo) with the demo realm, client (`go-rest`), and user (`demo/demo`) required for OIDC flows.  
2.4.2 The `httpbin` demo service MUST be deployed with a `Deployment` and `Service` managed directly by `redeploy.sh`.  
2.4.3 Optional Prometheus metrics exposure MUST be available via the APISIX `prometheus` plugin and `apisix-prometheus-service.yaml`.  
2.4.4 Validation scripts (`validate-apitest.sh`, `validate-rate_limit.sh`, `validate-prometheus.sh`) MUST remain functional against the deployed stack.

## 3. Non-Functional Requirements

### 3.1 Environment and Automation

3.1.1 The entire environment MUST stand up on Kind using a single invocation of `./redeploy.sh`, which is responsible for cluster checks, Helm repos, chart installations, manifests, and readiness probes.  
3.1.2 The script MUST wait for APISIX, ingress-controller, cert-manager deployments, and certificate readiness before proceeding.  
3.1.3 The script MUST print HTTP and HTTPS test hints, including the required `curl --resolve` examples for TLS verification.  
3.1.4 A cleanup helper (`cleanup-local-tls.sh`) MUST exist to remove the self-signed certificate, issuer, and secret when the environment is torn down.

### 3.2 Documentation

3.2.1 README.md MUST describe the role of cert-manager, the TLS wildcard secret, and the dual HTTP/HTTPS ports.  
3.2.2 `test_apisix.md` MUST cover preflight checks (cert-manager pods, certificate status, ApisixTls presence), HTTP/HTTPS validation, and rate-limit behavior.  
3.2.3 `AGENTS.md` MUST note the `requirements/` directory and direct contributors to store future requirements there.

### 3.3 Maintainability and Extensibility

3.3.1 All configuration and manifests MUST use declarative YAML with two-space indentation and consistent naming (lowercase-kebab).  
3.3.2 The repository MUST keep secrets out of version control; sample credentials are limited to demo values (`go-rest-demo-key`).  
3.3.3 The requirements directory MUST capture evolving functional/non-functional requirements so the project baseline remains discoverable.

## 4. Open Questions / Future Considerations

4.1 Browser-based interactive OIDC (redirect to Keycloak, session cookies) is NOT currently required; any change would necessitate updates to plugin configuration and possibly consumer flows.  
4.2 Self-service API key issuance is OUT OF SCOPE; generating or rotating API keys remains a manual or external process at this stage.  
4.3 Integration with external vaults and CSI drivers is documented separately (see `k8s-oss-cert-key-lifecycle-api-gateways.md`) and MAY affect future iterations of the local demo.
