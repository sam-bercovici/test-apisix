#!/usr/bin/env bash
set -euo pipefail

# Port-forward Envoy Gateway service to localhost
# HTTP only (TLS terminated externally)

NAMESPACE="${NAMESPACE:-envoy-gateway-system}"
GATEWAY_NAME="${GATEWAY_NAME:-eg-gateway}"
LOCAL_PORT="${LOCAL_PORT:-8888}"

# Find the Envoy service for the gateway
SVC_NAME="$(kubectl get svc -n "${NAMESPACE}" \
  -l gateway.envoyproxy.io/owning-gateway-name="${GATEWAY_NAME}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -z "${SVC_NAME}" ]]; then
  echo "ERROR: Could not find Envoy service for gateway ${GATEWAY_NAME}" >&2
  exit 1
fi

echo "Port-forwarding ${NAMESPACE}/${SVC_NAME} to localhost:${LOCAL_PORT}"
echo ""
echo "Access examples:"
echo "  httpbin:  curl -H 'Host: httpbin.local' http://localhost:${LOCAL_PORT}/status/200"
echo "  token:    curl -X POST -d 'grant_type=client_credentials&client_id=go-rest&client_secret=go-rest-secret' http://localhost:${LOCAL_PORT}/auth/oauth2/token"
echo "  apitest:  curl -H 'Host: apitest.local' -H 'Authorization: Bearer <token>' http://localhost:${LOCAL_PORT}/health-check"
echo ""

kubectl -n "${NAMESPACE}" port-forward "svc/${SVC_NAME}" "${LOCAL_PORT}:80"
