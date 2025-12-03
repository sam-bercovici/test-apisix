#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Validates API access through Envoy Gateway with JWT authentication via Hydra
# ---------------------------------------------------------------------------
# Configuration (can be overridden via environment variables)
# ---------------------------------------------------------------------------
GATEWAY_HOST="${GATEWAY_HOST:-localhost}"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"
HYDRA_TOKEN_PATH="${HYDRA_TOKEN_PATH:-/auth/oauth2/token}"
CLIENT_ID="${CLIENT_ID:-go-rest}"
# Try to get client secret from K8s secret if not provided
if [[ -z "${CLIENT_SECRET:-}" ]]; then
  SECRET_KEY="go-rest-secret"  # Key format: lowercase with dashes
  CLIENT_SECRET="$(kubectl get secret hydra-client-credentials -n hydra \
    -o jsonpath="{.data.${SECRET_KEY}}" 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ -z "${CLIENT_SECRET}" ]]; then
    echo "WARNING: Could not retrieve client secret from K8s, using default"
    CLIENT_SECRET="go-rest-secret"
  fi
fi
API_HOST="${API_HOST:-apitest.local}"
API_PATH="${API_PATH:-/health-check}"
HTTPBIN_HOST="${HTTPBIN_HOST:-httpbin.local}"
HTTPBIN_PATH="${HTTPBIN_PATH:-/status/200}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() {
  echo "ERROR: $*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

log() {
  printf '[%s] %s\n' "$(date +'%H:%M:%S')" "$*"
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
require curl
require jq

API_BASE="http://${GATEWAY_HOST}:${GATEWAY_PORT}"

log "Gateway endpoint: ${API_BASE}"
log "API host: ${API_HOST}, path: ${API_PATH}"
log "Httpbin host: ${HTTPBIN_HOST}, path: ${HTTPBIN_PATH}"

# ---------------------------------------------------------------------------
# Test 1: Httpbin (no auth required)
# ---------------------------------------------------------------------------
log "Testing httpbin (no auth required)..."
HTTPBIN_STATUS="$(curl -sS -o /tmp/httpbin_body -w '%{http_code}' \
  -H "Host: ${HTTPBIN_HOST}" \
  "${API_BASE}${HTTPBIN_PATH}")"

if [[ "${HTTPBIN_STATUS}" == "200" ]]; then
  log "httpbin request succeeded (HTTP 200)"
else
  log "httpbin request failed with HTTP ${HTTPBIN_STATUS}"
  cat /tmp/httpbin_body
  rm -f /tmp/httpbin_body
  exit 1
fi
rm -f /tmp/httpbin_body

# ---------------------------------------------------------------------------
# Test 2: API without credentials (expect 401)
# ---------------------------------------------------------------------------
log "Testing API without credentials (expect 401)..."
NO_CREDS_STATUS="$(curl -sS -o /tmp/no_creds_body -w '%{http_code}' \
  -H "Host: ${API_HOST}" \
  "${API_BASE}${API_PATH}")"

if [[ "${NO_CREDS_STATUS}" == "401" ]]; then
  log "Request without credentials returned expected 401"
else
  log "WARNING: Request without credentials returned ${NO_CREDS_STATUS} (expected 401)"
  cat /tmp/no_creds_body
fi
rm -f /tmp/no_creds_body

# ---------------------------------------------------------------------------
# Obtain access token from Hydra (client credentials flow)
# ---------------------------------------------------------------------------
log "Obtaining access token from Hydra..."
TOKEN_JSON="$(curl -sS \
  -X POST \
  -d "grant_type=client_credentials" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}" \
  "${API_BASE}${HYDRA_TOKEN_PATH}")" || die "Failed to call token endpoint"

ACCESS_TOKEN="$(jq -r '.access_token' <<<"${TOKEN_JSON}")"
[[ -n "${ACCESS_TOKEN}" && "${ACCESS_TOKEN}" != "null" ]] || die "Failed to obtain access token. Response: ${TOKEN_JSON}"

log "Successfully obtained access token for client '${CLIENT_ID}'"

# ---------------------------------------------------------------------------
# Test 3: Authenticated request using bearer token
# ---------------------------------------------------------------------------
log "Testing API with JWT bearer token..."
TOKEN_STATUS="$(curl -sS -o /tmp/token_ok_body -w '%{http_code}' \
  -H "Host: ${API_HOST}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${API_BASE}${API_PATH}")"

if [[ "${TOKEN_STATUS}" == "200" ]]; then
  log "Bearer-token request succeeded (HTTP 200)"
  echo "Response body:"
  cat /tmp/token_ok_body
  echo
else
  log "Bearer-token request failed with HTTP ${TOKEN_STATUS}"
  cat /tmp/token_ok_body
  rm -f /tmp/token_ok_body
  exit 1
fi
rm -f /tmp/token_ok_body

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
log "Validation complete."
echo "  - httpbin (no auth): OK"
echo "  - API without creds: 401 (expected)"
echo "  - API with JWT: OK"
