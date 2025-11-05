#!/usr/bin/env bash
set -euo pipefail

LOCAL_TLS_NAMESPACE="${LOCAL_TLS_NAMESPACE:-apisix}"
LOCAL_TLS_CERTIFICATE_NAME="${LOCAL_TLS_CERTIFICATE_NAME:-apisix-local-wildcard}"
LOCAL_TLS_ISSUER_NAME="${LOCAL_TLS_ISSUER_NAME:-apisix-local-selfsigned}"
LOCAL_TLS_SECRET_NAME="${LOCAL_TLS_SECRET_NAME:-apisix-local-wildcard-tls}"

log() {
  printf '[%s] %s\n' "$(date +'%H:%M:%S')" "$*"
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'ERROR: Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

need kubectl

delete_if_exists() {
  local resource=$1
  local name=$2
log "Deleting ${resource} ${name} (if present)"
  kubectl delete "${resource}" "${name}" --ignore-not-found --wait=false >/dev/null
}

cleanup_certificate_requests() {
  local selector="cert-manager.io/certificate-name=${LOCAL_TLS_CERTIFICATE_NAME}"
  mapfile -t requests < <(kubectl get certificaterequests.cert-manager.io \
    -n "${LOCAL_TLS_NAMESPACE}" \
    -l "${selector}" \
    -o name 2>/dev/null || true)
  if (( ${#requests[@]} )); then
    log "Deleting CertificateRequests: ${requests[*]}"
    kubectl delete -n "${LOCAL_TLS_NAMESPACE}" "${requests[@]}" >/dev/null
  fi
}

delete_if_exists "certificate.cert-manager.io" \
  "${LOCAL_TLS_NAMESPACE}/${LOCAL_TLS_CERTIFICATE_NAME}"
cleanup_certificate_requests
delete_if_exists "issuer.cert-manager.io" \
  "${LOCAL_TLS_NAMESPACE}/${LOCAL_TLS_ISSUER_NAME}"
delete_if_exists "secret" \
  "${LOCAL_TLS_NAMESPACE}/${LOCAL_TLS_SECRET_NAME}"

log "Local TLS resources removed. cert-manager will recreate the secret with a fresh key when the certificate is re-applied."
