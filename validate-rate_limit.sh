#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# This script drives bursts against the APISIX gateway to verify the rate
# limiting behaviour for API-key (consumer) and OIDC-authenticated requests.
# Pass INCLUDE_IP_SCENARIO=1 to exercise the fallback IP-based limit (requires
# sending ~260 unauthenticated requests, which can take longer).
# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NODE_IP="${NODE_IP:-$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')}"
NODE_PORT="${NODE_PORT:-$(kubectl get svc apisix-gateway -n apisix -o jsonpath='{.spec.ports[0].nodePort}')}"
API_HOST="${API_HOST:-apitest.local}"
API_PATH="${API_PATH:-/health-check}"
API_KEY="${API_KEY:-go-rest-demo-key}"
JWT_USER="${JWT_USER:-demo}"
JWT_PASS="${JWT_PASS:-demo}"
REALM="${REALM:-demo}"
CLIENT_ID="${CLIENT_ID:-go-rest}"
CLIENT_SECRET="${CLIENT_SECRET:-go-rest-secret}"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://$NODE_IP:30080}"
RL_SAMPLE_SIZE="${RL_SAMPLE_SIZE:-30}"
RL_EXPECT_CODE="${RL_EXPECT_CODE:-429}"
RL_PARALLELISM="${RL_PARALLELISM:-10}"

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

curl_api_key() {
  curl -s -o /dev/null -w '%{http_code}' \
    -H "Host: ${API_HOST}" \
    -H "X-API-Key: ${API_KEY}" \
    "http://${NODE_IP}:${NODE_PORT}${API_PATH}"
}

curl_bearer() {
  curl -s -o /dev/null -w '%{http_code}' \
    -H "Host: ${API_HOST}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "http://${NODE_IP}:${NODE_PORT}${API_PATH}"
}

collect_statuses() {
  local func="$1"
  local sample="${2:-$RL_SAMPLE_SIZE}"
  local tmp
  tmp="$(mktemp)"
  local active=0
  for _ in $(seq 1 "$sample"); do
    (
      status="$($func || echo "ERR")"
      echo "$status" >>"$tmp"
    ) &
    ((active++))
    while (( active >= RL_PARALLELISM )); do
      sleep 0.05
      active="$(jobs -p | wc -l | tr -d ' ')"
    done
  done
  wait
  cat "$tmp"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
require kubectl
require curl
require jq

[[ -n "$NODE_IP" ]] || die "Unable to determine node IP"
[[ -n "$NODE_PORT" ]] || die "Unable to determine nodePort"

echo "Using node IP: $NODE_IP"
echo "Using nodePort: $NODE_PORT"
echo "API endpoint: http://$NODE_IP:$NODE_PORT$API_PATH (Host: $API_HOST)"
echo "Sample size: $RL_SAMPLE_SIZE, expected 429 after threshold: $RL_EXPECT_CODE"

# ---------------------------------------------------------------------------
# Obtain Keycloak token for the demo user
# ---------------------------------------------------------------------------
TOKEN_JSON="$(curl -s \
  -d "grant_type=password" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" \
  -d "username=$JWT_USER" \
  -d "password=$JWT_PASS" \
  "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token")" || die "Failed to call token endpoint"

ACCESS_TOKEN="$(jq -r '.access_token' <<<"$TOKEN_JSON")"
[[ -n "$ACCESS_TOKEN" && "$ACCESS_TOKEN" != "null" ]] || die "Failed to obtain access token: $TOKEN_JSON"

# ---------------------------------------------------------------------------
# Test matrix
# ---------------------------------------------------------------------------
scenarios=(api_key bearer)

declare -A func_map=(
  [api_key]=curl_api_key
  [bearer]=curl_bearer
)

declare -A results

for scenario in "${scenarios[@]}"; do
  echo
  echo "=== Scenario: $scenario ==="
  func_name="${func_map[$scenario]}"
  status_series="$(collect_statuses "$func_name" "$RL_SAMPLE_SIZE")"

  echo "$status_series"
  if grep -q "^${RL_EXPECT_CODE}$" <<<"$status_series"; then
    echo "Scenario '$scenario' hit rate limit (${RL_EXPECT_CODE})."
    results["$scenario"]="hit"
  else
    echo "WARNING: Scenario '$scenario' did NOT produce ${RL_EXPECT_CODE}."
    results["$scenario"]="miss"
  fi
done

echo
echo "=== Summary ==="
for scenario in "${scenarios[@]}"; do
  printf '%-10s : %s\n' "$scenario" "${results[$scenario]}"
done

if [[ "${results[api_key]}" != "hit" || "${results[bearer]}" != "hit" ]]; then
  die "Rate limit validation failed for API key or bearer scenario."
fi

echo "Rate limit validation completed successfully."
