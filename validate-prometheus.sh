#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment variables)
# ---------------------------------------------------------------------------
SERVICE_NAME="${SERVICE_NAME:-apisix-prometheus}"
SERVICE_NAMESPACE="${SERVICE_NAMESPACE:-apisix}"
PROBE_NAMESPACE="${PROBE_NAMESPACE:-apisix}"
METRICS_PORT="${METRICS_PORT:-9091}"
METRICS_PATH="${METRICS_PATH:-/apisix/prometheus/metrics}"
KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-}"
HEAD_LINES="${HEAD_LINES:-10}"
POD_IMAGE="${POD_IMAGE:-curlimages/curl}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

kubectl_cmd() {
  if [[ -n "${KUBECTL_CONTEXT}" ]]; then
    kubectl --context "${KUBECTL_CONTEXT}" "$@"
  else
    kubectl "$@"
  fi
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
require kubectl

kubectl_cmd get namespace "${SERVICE_NAMESPACE}" >/dev/null 2>&1 || die "Namespace not found: ${SERVICE_NAMESPACE}"

if ! kubectl_cmd get svc "${SERVICE_NAME}" -n "${SERVICE_NAMESPACE}" >/dev/null 2>&1; then
  die "Service ${SERVICE_NAMESPACE}/${SERVICE_NAME} not found"
fi

kubectl_cmd get namespace "${PROBE_NAMESPACE}" >/dev/null 2>&1 || die "Probe namespace not found: ${PROBE_NAMESPACE}"

# ---------------------------------------------------------------------------
# Scrape metrics using a transient curl pod
# ---------------------------------------------------------------------------
FQDN="${SERVICE_NAME}.${SERVICE_NAMESPACE}.svc.cluster.local"
URL="http://${FQDN}:${METRICS_PORT}${METRICS_PATH}"
POD_NAME="prometheus-curl-$RANDOM"
TMP_FILE="$(mktemp)"
trap 'rm -f "${TMP_FILE}"' EXIT

printf '[%s] Scraping %s\n' "$(date +'%H:%M:%S')" "${URL}"

RAW_OUTPUT="$(kubectl_cmd run "${POD_NAME}" \
  --rm \
  --attach \
  --restart=Never \
  --image="${POD_IMAGE}" \
  --namespace "${PROBE_NAMESPACE}" \
  --command -- /bin/sh -c "curl -sSf '${URL}'" 2>&1)" || die "Failed to scrape metrics: ${RAW_OUTPUT}"

# Remove kubectl status line (e.g., pod "...\" deleted")
printf '%s\n' "${RAW_OUTPUT}" | sed '/^pod ".*" deleted$/d' >"${TMP_FILE}"

if ! grep -q '^# HELP apisix_' "${TMP_FILE}"; then
  die "Unexpected metrics payload (missing APISIX HELP lines)"
fi

if ! grep -q '^apisix_' "${TMP_FILE}"; then
  die "No APISIX metric samples found in response"
fi

printf '[%s] Metrics scrape succeeded; showing first %s lines:\n' "$(date +'%H:%M:%S')" "${HEAD_LINES}"
head -n "${HEAD_LINES}" "${TMP_FILE}"
