#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Validates rate limiting through Envoy Gateway
# Tests Tier 1 burst limiting (10 rps per org) with JWT authentication
# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
GATEWAY_HOST="${GATEWAY_HOST:-localhost}"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"
HYDRA_TOKEN_PATH="${HYDRA_TOKEN_PATH:-/auth/oauth2/token}"
CLIENT_ID="${CLIENT_ID:-go-rest}"
CLIENT_SECRET="${CLIENT_SECRET:-go-rest-secret}"
API_HOST="${API_HOST:-apitest.local}"
API_PATH="${API_PATH:-/health-check}"
RL_SAMPLE_SIZE="${RL_SAMPLE_SIZE:-30}"
RL_EXPECT_CODE="${RL_EXPECT_CODE:-429}"
RL_PARALLELISM="${RL_PARALLELISM:-15}"

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

curl_bearer() {
  curl -s -o /dev/null -w '%{http_code}' \
    -H "Host: ${API_HOST}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "http://${GATEWAY_HOST}:${GATEWAY_PORT}${API_PATH}"
}

curl_no_auth() {
  curl -s -o /dev/null -w '%{http_code}' \
    -H "Host: ${API_HOST}" \
    "http://${GATEWAY_HOST}:${GATEWAY_PORT}${API_PATH}"
}

collect_statuses() {
  local func="$1"
  local sample="${2:-$RL_SAMPLE_SIZE}"
  local tmp
  tmp="$(mktemp)"
  local pids=()

  for _ in $(seq 1 "$sample"); do
    (
      status="$($func || echo "ERR")"
      echo "$status"
    ) >> "$tmp" &
    pids+=($!)

    # Limit parallelism
    if (( ${#pids[@]} >= RL_PARALLELISM )); then
      wait "${pids[0]}" 2>/dev/null || true
      pids=("${pids[@]:1}")
    fi
  done

  # Wait for remaining jobs
  wait
  cat "$tmp"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
require curl
require jq

API_BASE="http://${GATEWAY_HOST}:${GATEWAY_PORT}"

log "Gateway endpoint: ${API_BASE}"
log "API host: ${API_HOST}, path: ${API_PATH}"
log "Sample size: ${RL_SAMPLE_SIZE}, parallelism: ${RL_PARALLELISM}"
log "Expected rate limit code: ${RL_EXPECT_CODE}"

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
[[ -n "${ACCESS_TOKEN}" && "${ACCESS_TOKEN}" != "null" ]] || die "Failed to obtain access token: ${TOKEN_JSON}"

log "Successfully obtained access token for client '${CLIENT_ID}'"

# ---------------------------------------------------------------------------
# Test: JWT authenticated requests (Tier 1 burst limit)
# ---------------------------------------------------------------------------
echo
log "=== Testing Tier 1 Burst Rate Limit (JWT auth) ==="
log "Sending ${RL_SAMPLE_SIZE} requests in parallel..."

status_series="$(collect_statuses curl_bearer "$RL_SAMPLE_SIZE")"

# Count responses
count_200=$(grep -c '^200$' <<<"$status_series" || echo 0)
count_429=$(grep -c '^429$' <<<"$status_series" || echo 0)
count_401=$(grep -c '^401$' <<<"$status_series" || echo 0)
count_other=$(grep -cv '^200$\|^429$\|^401$' <<<"$status_series" || echo 0)

log "Results: 200=${count_200}, 429=${count_429}, 401=${count_401}, other=${count_other}"

if [[ "$count_429" -gt 0 ]]; then
  log "Rate limit hit! Got ${count_429} requests with HTTP 429"
  result="PASS"
else
  log "WARNING: No 429 responses received. Rate limiting may not be active."
  result="FAIL"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
log "=== Summary ==="
echo "  Tier 1 Burst Limit Test: ${result}"
echo "    - Successful requests (200): ${count_200}"
echo "    - Rate limited (429): ${count_429}"
echo "    - Unauthorized (401): ${count_401}"
echo "    - Other: ${count_other}"
echo

if [[ "$result" == "FAIL" ]]; then
  log "Rate limit validation failed."
  log "Note: Ensure BackendTrafficPolicy is applied and rate limit service is running."
  exit 1
fi

log "Rate limit validation completed successfully."
