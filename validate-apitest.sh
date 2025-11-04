#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (can be overridden via environment variables)
# ---------------------------------------------------------------------------
NODE_IP="${NODE_IP:-$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')}"
NODE_PORT="${NODE_PORT:-$(kubectl get svc apisix-gateway -n apisix -o jsonpath='{.spec.ports[0].nodePort}')}"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://$NODE_IP:30080}"
REALM="${REALM:-demo}"
CLIENT_ID="${CLIENT_ID:-go-rest}"
CLIENT_SECRET="${CLIENT_SECRET:-go-rest-secret}"
USERNAME="${USERNAME:-demo}"
PASSWORD="${PASSWORD:-demo}"
API_HOST="${API_HOST:-apitest.local}"
API_PATH="${API_PATH:-/health-check}"
API_KEY_HEADER="${API_KEY_HEADER:-X-API-Key}"
API_KEY_VALUE="${API_KEY_VALUE:-go-rest-demo-key}"

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

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
require kubectl
require curl
require jq

[[ -n "$NODE_IP" ]]   || die "Unable to determine node IP"
[[ -n "$NODE_PORT" ]] || die "Unable to determine APISIX nodePort"
[[ -n "$API_KEY_HEADER" ]] || die "API key header not set"
[[ -n "$API_KEY_VALUE" ]] || die "API key value not set"

API_URL="http://$NODE_IP:$NODE_PORT$API_PATH"

echo "Using node IP: $NODE_IP"
echo "Using APISIX nodePort: $NODE_PORT"
echo "Keycloak URL: $KEYCLOAK_URL"
echo "API endpoint: $API_URL (Host header: $API_HOST)"
echo "API key header: $API_KEY_HEADER"

# ---------------------------------------------------------------------------
# Obtain access token from Keycloak
# ---------------------------------------------------------------------------
TOKEN_JSON="$(curl -s \
  -d "grant_type=password" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" \
  -d "username=$USERNAME" \
  -d "password=$PASSWORD" \
  "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token")" || die "Failed to call token endpoint"

ACCESS_TOKEN="$(jq -r '.access_token' <<<"$TOKEN_JSON")"
[[ -n "$ACCESS_TOKEN" && "$ACCESS_TOKEN" != "null" ]] || die "Failed to obtain access token. Response: $TOKEN_JSON"

echo "Successfully obtained access token for user '$USERNAME'."

# ---------------------------------------------------------------------------
# Authenticated request using bearer token only
# ---------------------------------------------------------------------------
TOKEN_STATUS="$(curl -sS -o /tmp/apisix_token_ok_body -w '%{http_code}' \
  -H "Host: $API_HOST" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$API_URL")"

if [[ "$TOKEN_STATUS" == "200" ]]; then
  echo "Bearer-token request succeeded (HTTP 200)."
  echo "Response body:"
  cat /tmp/apisix_token_ok_body
else
  echo "Bearer-token request failed with HTTP $TOKEN_STATUS."
  echo "Response body:"
  cat /tmp/apisix_token_ok_body
  rm -f /tmp/apisix_token_ok_body
  exit 1
fi
rm -f /tmp/apisix_token_ok_body

# ---------------------------------------------------------------------------
# Authenticated request using API key only
# ---------------------------------------------------------------------------
APIKEY_STATUS="$(curl -sS -o /tmp/apisix_apikey_ok_body -w '%{http_code}' \
  -H "Host: $API_HOST" \
  -H "${API_KEY_HEADER}: ${API_KEY_VALUE}" \
  "$API_URL")"

if [[ "$APIKEY_STATUS" == "200" ]]; then
  echo "API-key request succeeded (HTTP 200)."
  echo "Response body:"
  cat /tmp/apisix_apikey_ok_body
else
  echo "API-key request failed with HTTP $APIKEY_STATUS."
  echo "Response body:"
  cat /tmp/apisix_apikey_ok_body
  rm -f /tmp/apisix_apikey_ok_body
  exit 1
fi
rm -f /tmp/apisix_apikey_ok_body

# ---------------------------------------------------------------------------
# Negative checks
# ---------------------------------------------------------------------------
NO_CREDS_STATUS="$(curl -sS -o /tmp/apisix_no_creds_body -w '%{http_code}' \
  -H "Host: $API_HOST" \
  "$API_URL")"

if [[ "$NO_CREDS_STATUS" == "302" || "$NO_CREDS_STATUS" == "401" ]]; then
  echo "Request without credentials returned expected status $NO_CREDS_STATUS."
  echo "Response body:"
  cat /tmp/apisix_no_creds_body
else
  echo "WARNING: Request without credentials returned unexpected status $NO_CREDS_STATUS."
  echo "Response body:"
  cat /tmp/apisix_no_creds_body
fi
rm -f /tmp/apisix_no_creds_body

echo "Validation complete."
