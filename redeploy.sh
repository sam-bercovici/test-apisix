#!/usr/bin/env bash
set -euo pipefail

### configuration #############################################################
CLUSTER_NAME="${CLUSTER_NAME:-kind}"
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-${CLUSTER_NAME}}"
APISIX_NAMESPACE="${APISIX_NAMESPACE:-apisix}"
VALUES_FILE="${VALUES_FILE:-values-gateway.yaml}"
HTTPBIN_NAMESPACE="${HTTPBIN_NAMESPACE:-default}"
HTTPBIN_IMAGE="${HTTPBIN_IMAGE:-kennethreitz/httpbin}"
HTTPBIN_ROUTE_NAME="${HTTPBIN_ROUTE_NAME:-httpbin-route}"
GATEWAY_NAME="${GATEWAY_NAME:-apisix-gateway}"
GATEWAY_MANIFEST="${GATEWAY_MANIFEST:-gateway.yaml}"
HTTPBIN_ROUTE_FILE="${HTTPBIN_ROUTE_FILE:-httpbin-route.yaml}"
EXTRA_API_DEPLOYMENT="${EXTRA_API_DEPLOYMENT:-api-deployment.yaml}"
EXTRA_API_SERVICE="${EXTRA_API_SERVICE:-api-service.yaml}"
GO_REST_APISIXROUTE_FILE="${GO_REST_APISIXROUTE_FILE:-go-rest-apisixroute.yaml}"
GO_REST_APISIXROUTE_NAME="${GO_REST_APISIXROUTE_NAME:-go-rest-apisix}"
GO_REST_APISIXROUTE_NAMESPACE="${GO_REST_APISIXROUTE_NAMESPACE:-default}"
GO_REST_HTTPROUTE_FILE="${GO_REST_HTTPROUTE_FILE:-}"
GO_REST_HTTPROUTE_NAME="${GO_REST_HTTPROUTE_NAME:-go-rest-route}"
GO_REST_HTTPROUTE_NAMESPACE="${GO_REST_HTTPROUTE_NAMESPACE:-default}"
GO_REST_CONSUMER_FILE="${GO_REST_CONSUMER_FILE:-go-rest-consumer.yaml}"
KEYCLOAK_CONFIGMAP="${KEYCLOAK_CONFIGMAP:-keycloak-realm-configmap.yaml}"
KEYCLOAK_DEPLOYMENT="${KEYCLOAK_DEPLOYMENT:-keycloak-deployment.yaml}"
KEYCLOAK_SERVICE="${KEYCLOAK_SERVICE:-keycloak-service.yaml}"
OIDC_PLUGIN_CONFIG="${OIDC_PLUGIN_CONFIG:-openid-pluginconfig.yaml}"
KEYAUTH_PLUGIN_CONFIG="${KEYAUTH_PLUGIN_CONFIG:-keyauth-pluginconfig.yaml}"
PROMETHEUS_SERVICE_FILE="${PROMETHEUS_SERVICE_FILE:-apisix-prometheus-service.yaml}"
PROMETHEUS_SERVICE_NAME="${PROMETHEUS_SERVICE_NAME:-apisix-prometheus}"
PROMETHEUS_SERVICE_NAMESPACE="${PROMETHEUS_SERVICE_NAMESPACE:-apisix}"
PROMETHEUS_PROBE_NAMESPACE="${PROMETHEUS_PROBE_NAMESPACE:-apisix}"
LOCAL_TLS_MANIFEST="${LOCAL_TLS_MANIFEST:-apisix-local-tls.yaml}"
LOCAL_TLS_CERTIFICATE_NAME="${LOCAL_TLS_CERTIFICATE_NAME:-apisix-local-wildcard}"
LOCAL_TLS_SECRET_NAME="${LOCAL_TLS_SECRET_NAME:-apisix-local-wildcard-tls}"
LOCAL_TLS_ISSUER_NAME="${LOCAL_TLS_ISSUER_NAME:-apisix-local-selfsigned}"
LOCAL_TLS_NAMESPACE="${LOCAL_TLS_NAMESPACE:-${APISIX_NAMESPACE}}"
APISIX_TLS_MANIFEST="${APISIX_TLS_MANIFEST:-apisix-tls-local.yaml}"
CERT_MANAGER_RELEASE="${CERT_MANAGER_RELEASE:-cert-manager}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"
CERT_MANAGER_HELM_REPO_NAME="${CERT_MANAGER_HELM_REPO_NAME:-jetstack}"
CERT_MANAGER_HELM_REPO_URL="${CERT_MANAGER_HELM_REPO_URL:-https://charts.jetstack.io}"
CERT_MANAGER_CHART="${CERT_MANAGER_CHART:-cert-manager}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-}"
CERT_MANAGER_WAIT_TIMEOUT="${CERT_MANAGER_WAIT_TIMEOUT:-240}"
CERT_MANAGER_CRDS=(
  certificates.cert-manager.io
  certificaterequests.cert-manager.io
  challenges.acme.cert-manager.io
  clusterissuers.cert-manager.io
  issuers.cert-manager.io
  orders.acme.cert-manager.io
)
HELM_RELEASE_NAME="${HELM_RELEASE_NAME:-apisix}"
HELM_REPO_NAME="${HELM_REPO_NAME:-apisix}"
HELM_REPO_URL="${HELM_REPO_URL:-https://charts.apiseven.com}"
HTTPBIN_TEST_PATH="${HTTPBIN_TEST_PATH:-/status/200}"
API_TEST_PATH="${API_TEST_PATH:-/health-check}"
###############################################################################

log() {
  printf '[%s] %s\n' "$(date +'%H:%M:%S')" "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

wait_for_deployment() {
  local namespace=$1
  local name=$2
  local timeout=${3:-120}
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    if kubectl get deployment "${name}" -n "${namespace}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  die "Deployment ${namespace}/${name} not found within ${timeout}s"
}

wait_for_gateway_condition() {
  local condition=$1
  local timeout=${2:-120}
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    local status
    status="$(kubectl get gateway "${GATEWAY_NAME}" -n "${APISIX_NAMESPACE}" \
      -o jsonpath="{.status.conditions[?(@.type==\"${condition}\")].status}" 2>/dev/null || true)"
    if [[ "${status^^}" == *TRUE* ]]; then
      log "Gateway ${GATEWAY_NAME} condition ${condition}=True"
      return 0
    fi
    sleep 4
  done
  die "Timed out waiting for Gateway ${GATEWAY_NAME} condition ${condition}"
}

wait_for_route_attachment() {
  local timeout=${1:-120}
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    local attached
    attached="$(kubectl get gateway "${GATEWAY_NAME}" -n "${APISIX_NAMESPACE}" \
      -o jsonpath='{.status.listeners[0].attachedRoutes}' 2>/dev/null || true)"
    if [[ "${attached}" =~ ^[0-9]+$ && "${attached}" -ge 1 ]]; then
      log "Gateway ${GATEWAY_NAME} reports ${attached} attached route(s)"
      return 0
    fi

    local routeAccepted
    routeAccepted="$(kubectl get httproute "${HTTPBIN_ROUTE_NAME}" -n "${HTTPBIN_NAMESPACE}" \
      -o jsonpath="{.status.parents[?(@.parentRef.name==\"${GATEWAY_NAME}\")].conditions[?(@.type==\"Accepted\")].status}" 2>/dev/null || true)"
    if [[ "${routeAccepted^^}" == *TRUE* ]]; then
      log "HTTPRoute ${HTTPBIN_ROUTE_NAME} accepted by ${GATEWAY_NAME}; listener still reports ${attached:-0} route(s) – proceeding"
      return 0
    fi

    sleep 4
  done
  die "Timed out waiting for HTTPRoute ${HTTPBIN_ROUTE_NAME} to attach to Gateway ${GATEWAY_NAME}"
}

wait_for_gateway_resource() {
  local timeout=${1:-120}
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    if kubectl get gateway "${GATEWAY_NAME}" -n "${APISIX_NAMESPACE}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  die "Gateway ${APISIX_NAMESPACE}/${GATEWAY_NAME} not found within ${timeout}s"
}

wait_for_http_route_accepted() {
  local route=$1
  local namespace=$2
  local timeout=${3:-120}
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    local status
    status="$(kubectl get httproute "${route}" -n "${namespace}" \
      -o jsonpath="{.status.parents[?(@.parentRef.name==\"${GATEWAY_NAME}\")].conditions[?(@.type==\"Accepted\")].status}" 2>/dev/null || true)"
    if [[ "${status^^}" == *TRUE* ]]; then
      log "HTTPRoute ${namespace}/${route} accepted by ${GATEWAY_NAME}"
      return 0
    fi
    sleep 4
  done
  die "Timed out waiting for HTTPRoute ${namespace}/${route} to be accepted"
}

wait_for_apisixroute_accepted() {
  local route=$1
  local namespace=$2
  local timeout=${3:-120}
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    local status
    status="$(kubectl get apisixroute "${route}" -n "${namespace}" \
      -o jsonpath="{.status.conditions[?(@.type==\"Accepted\")].status}" 2>/dev/null || true)"
    if [[ "${status^^}" == *TRUE* ]]; then
      log "ApisixRoute ${namespace}/${route} accepted"
      return 0
    fi
    sleep 4
  done
  die "Timed out waiting for ApisixRoute ${namespace}/${route} to be accepted"
}

wait_for_crd_established() {
  local crd=$1
  local timeout=${2:-120}
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    if kubectl get crd "${crd}" >/dev/null 2>&1; then
      local status
      status="$(kubectl get crd "${crd}" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null || true)"
      if [[ "${status^^}" == *TRUE* ]]; then
        return 0
      fi
    fi
    sleep 3
  done
  die "CRD ${crd} was not established within ${timeout}s"
}

wait_for_cert_manager_crds() {
  local crd
  for crd in "${CERT_MANAGER_CRDS[@]}"; do
    wait_for_crd_established "${crd}" "${CERT_MANAGER_WAIT_TIMEOUT}"
  done
}

wait_for_cert_manager_deployments() {
  local deployments=(
    cert-manager
    cert-manager-cainjector
    cert-manager-webhook
  )
  local deployment
  for deployment in "${deployments[@]}"; do
    wait_for_deployment "${CERT_MANAGER_NAMESPACE}" "${deployment}" "${CERT_MANAGER_WAIT_TIMEOUT}"
    kubectl rollout status -n "${CERT_MANAGER_NAMESPACE}" \
      "deployment/${deployment}" \
      --timeout="${CERT_MANAGER_WAIT_TIMEOUT}s" >/dev/null
  done
}

ensure_cert_manager_ready() {
  if ! helm repo list | awk '{print $1}' | grep -Fxq "${CERT_MANAGER_HELM_REPO_NAME}"; then
    log "Adding Helm repo ${CERT_MANAGER_HELM_REPO_NAME}"
    helm repo add "${CERT_MANAGER_HELM_REPO_NAME}" "${CERT_MANAGER_HELM_REPO_URL}"
  else
    log "Helm repo ${CERT_MANAGER_HELM_REPO_NAME} already present"
  fi

  log "Updating Helm repo ${CERT_MANAGER_HELM_REPO_NAME}"
  helm repo update "${CERT_MANAGER_HELM_REPO_NAME}" >/dev/null

  local version_flag=()
  if [[ -n "${CERT_MANAGER_VERSION}" ]]; then
    version_flag=(--version "${CERT_MANAGER_VERSION}")
  fi

  log "Installing/Upgrading cert-manager Helm release ${CERT_MANAGER_RELEASE}"
  helm upgrade --install "${CERT_MANAGER_RELEASE}" "${CERT_MANAGER_HELM_REPO_NAME}/${CERT_MANAGER_CHART}" \
    -n "${CERT_MANAGER_NAMESPACE}" \
    --create-namespace \
    --set crds.enabled=true \
    --wait \
    "${version_flag[@]}"

  wait_for_cert_manager_crds
  wait_for_cert_manager_deployments
}

wait_for_secret() {
  local namespace=$1
  local name=$2
  local timeout=${3:-120}
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    if kubectl get secret "${name}" -n "${namespace}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  die "Secret ${namespace}/${name} not found within ${timeout}s"
}

apply_local_tls_resources() {
  if [[ ! -f "${LOCAL_TLS_MANIFEST}" ]]; then
    log "Skipping local TLS resources; manifest ${LOCAL_TLS_MANIFEST} not found"
    return 0
  fi

  log "Applying local TLS issuer and certificate (${LOCAL_TLS_MANIFEST})"
  kubectl apply -f "${LOCAL_TLS_MANIFEST}"

  log "Waiting for Certificate ${LOCAL_TLS_NAMESPACE}/${LOCAL_TLS_CERTIFICATE_NAME} to be Ready"
  kubectl wait \
    --namespace "${LOCAL_TLS_NAMESPACE}" \
    --for=condition=Ready \
    --timeout="${CERT_MANAGER_WAIT_TIMEOUT}s" \
    "certificate/${LOCAL_TLS_CERTIFICATE_NAME}" >/dev/null

  wait_for_secret "${LOCAL_TLS_NAMESPACE}" "${LOCAL_TLS_SECRET_NAME}" "${CERT_MANAGER_WAIT_TIMEOUT}"
}

apply_apisix_tls_binding() {
  if [[ ! -f "${APISIX_TLS_MANIFEST}" ]]; then
    log "Skipping ApisixTls binding; manifest ${APISIX_TLS_MANIFEST} not found"
    return 0
  fi

  log "Applying ApisixTls binding (${APISIX_TLS_MANIFEST})"
  kubectl apply -f "${APISIX_TLS_MANIFEST}"
}

run_connectivity_probe() {
  log "Probing httpbin route through APISIX (expect 200)"
  local output status
  local url="http://${GATEWAY_NAME}.${APISIX_NAMESPACE}.svc.cluster.local${HTTPBIN_TEST_PATH}"
  echo "# curl -v -H 'Host: httpbin.local' ${url}"
  output="$(kubectl run curl-test --rm \
    --image=curlimages/curl \
    --restart=Never \
    --namespace "${HTTPBIN_NAMESPACE}" \
    --command -- \
      /bin/sh -c 'code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: httpbin.local" '"$url"'); echo "$code"' \
    2>&1)"
  status="$(printf '%s\n' "$output" | sed -n 's/^\([0-9][0-9]*\).*/\1/p' | head -n1)"
  if [[ "${status}" != "200" ]]; then
    die "Connectivity probe returned ${status:-<empty>} (full output: ${output})"
  fi
  log "Connectivity probe succeeded (200)"
}

run_prometheus_probe() {
  local svc="${PROMETHEUS_SERVICE_NAME}"
  local ns="${PROMETHEUS_SERVICE_NAMESPACE}"
  local probe_ns="${PROMETHEUS_PROBE_NAMESPACE}"
  local url="http://${svc}.${ns}.svc.cluster.local:9091/apisix/prometheus/metrics"
  local pod="curl-prometheus-$RANDOM"
  log "Probing APISIX Prometheus metrics endpoint"
  echo "# curl ${url}"
  local output status=0
  output="$(kubectl run "${pod}" --rm --image=curlimages/curl --restart=Never \
    --namespace "${probe_ns}" --command -- /bin/sh -c "curl -sSf '${url}' | head -n 5" 2>&1)" || status=$?
  if (( status != 0 )); then
    die "Prometheus metrics probe failed (exit ${status}): ${output}"
  fi
  printf '%s\n' "${output}"
  log "Prometheus metrics endpoint reachable"
}

print_external_curl_hint() {
  local node_ip
  node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  local node_port
  node_port="$(kubectl get svc "${HELM_RELEASE_NAME}-gateway" -n "${APISIX_NAMESPACE}" \
    -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || true)"
  node_port="${node_port%% *}"
  if [[ -z "${node_port}" ]]; then
    node_port="$(kubectl get svc "${HELM_RELEASE_NAME}-gateway" -n "${APISIX_NAMESPACE}" \
      -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || true)"
    node_port="${node_port%% *}"
  fi
  if [[ -z "${node_port}" ]]; then
    node_port="$(kubectl get svc "${HELM_RELEASE_NAME}-gateway" -n "${APISIX_NAMESPACE}" \
      -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
  fi
  local https_node_port
  https_node_port="$(kubectl get svc "${HELM_RELEASE_NAME}-gateway" -n "${APISIX_NAMESPACE}" \
    -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || true)"
  https_node_port="${https_node_port%% *}"
  if [[ -z "${https_node_port}" ]]; then
    https_node_port="$(kubectl get svc "${HELM_RELEASE_NAME}-gateway" -n "${APISIX_NAMESPACE}" \
      -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || true)"
    https_node_port="${https_node_port%% *}"
  fi
  if [[ -z "${https_node_port}" ]]; then
    https_node_port="$(kubectl get svc "${HELM_RELEASE_NAME}-gateway" -n "${APISIX_NAMESPACE}" \
      -o jsonpath='{.spec.ports[?(@.name=="apisix-gateway-tls")].nodePort}' 2>/dev/null || true)"
    https_node_port="${https_node_port%% *}"
  fi
  if [[ -n "${node_ip}" && -n "${node_port}" ]]; then
    echo "# External (httpbin): curl -v -H 'Host: httpbin.local' http://${node_ip}:${node_port}${HTTPBIN_TEST_PATH}"
    echo "# External (apitest): curl -v -H 'Host: apitest.local' http://${node_ip}:${node_port}${API_TEST_PATH}"
  else
    log "Could not determine NodePort or node IP for external curl hint"
  fi
  if [[ -n "${node_ip}" && -n "${https_node_port}" ]]; then
    cat <<EOF
# External TLS (httpbin via --resolve):
curl -vk --resolve httpbin.local:${https_node_port}:${node_ip} https://httpbin.local:${https_node_port}${HTTPBIN_TEST_PATH}
# External TLS (apitest via --resolve):
curl -vk --resolve apitest.local:${https_node_port}:${node_ip} https://apitest.local:${https_node_port}${API_TEST_PATH}
EOF
  else
    log "HTTPS NodePort not detected; ensure the service exposes port 443 before testing TLS"
  fi
}

main() {
  need kind
  need kubectl
  need helm

  if ! kind get clusters 2>/dev/null | grep -Fxq "${CLUSTER_NAME}"; then
    log "Creating kind cluster ${CLUSTER_NAME}"
    kind create cluster --name "${CLUSTER_NAME}"
  else
    log "Reusing kind cluster ${CLUSTER_NAME}"
  fi

  log "Using kube-context ${KUBE_CONTEXT}"
  kubectl config use-context "${KUBE_CONTEXT}" >/dev/null

  log "Waiting for control-plane node to be Ready"
  kubectl wait --context "${KUBE_CONTEXT}" --for=condition=Ready node --all --timeout=180s >/dev/null

  log "Ensuring cert-manager (Jetstack) is installed and ready"
  ensure_cert_manager_ready

  if ! helm repo list | awk '{print $1}' | grep -Fxq "${HELM_REPO_NAME}"; then
    log "Adding Helm repo ${HELM_REPO_NAME}"
    helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}"
  else
    log "Helm repo ${HELM_REPO_NAME} already present"
  fi

  log "Updating Helm repo ${HELM_REPO_NAME}"
  helm repo update "${HELM_REPO_NAME}" >/dev/null

  [[ -f "${VALUES_FILE}" ]] || die "Values file not found: ${VALUES_FILE}"

  log "Installing/Upgrading APISIX Helm release ${HELM_RELEASE_NAME}"
  helm upgrade --install "${HELM_RELEASE_NAME}" "${HELM_REPO_NAME}/apisix" \
    -f "${VALUES_FILE}" \
    -n "${APISIX_NAMESPACE}" \
    --create-namespace

  wait_for_deployment "${APISIX_NAMESPACE}" "${HELM_RELEASE_NAME}"
  log "Waiting for APISIX dataplane deployment rollout"
  kubectl rollout status -n "${APISIX_NAMESPACE}" \
    "deployment/${HELM_RELEASE_NAME}" \
    --timeout=180s >/dev/null

  wait_for_deployment "${APISIX_NAMESPACE}" "${HELM_RELEASE_NAME}-ingress-controller"
  log "Waiting for APISIX ingress-controller deployment rollout"
  kubectl rollout status -n "${APISIX_NAMESPACE}" \
    "deployment/${HELM_RELEASE_NAME}-ingress-controller" \
    --timeout=180s >/dev/null

  apply_local_tls_resources
  apply_apisix_tls_binding

  log "Deploying httpbin backend (deployment + service)"
  cat <<EOF | kubectl apply -n "${HTTPBIN_NAMESPACE}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
  template:
    metadata:
      labels:
        app: httpbin
    spec:
      containers:
        - name: httpbin
          image: ${HTTPBIN_IMAGE}
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
spec:
  selector:
    app: httpbin
  ports:
    - name: http
      port: 80
      targetPort: 80
EOF

  log "Waiting for httpbin deployment to become available"
  kubectl wait --for=condition=Available deployment/httpbin \
    -n "${HTTPBIN_NAMESPACE}" --timeout=120s >/dev/null

  [[ -f "${GATEWAY_MANIFEST}" ]] || die "Gateway manifest not found: ${GATEWAY_MANIFEST}"
  log "Applying Gateway resources from ${GATEWAY_MANIFEST}"
  kubectl apply -f "${GATEWAY_MANIFEST}"

  [[ -f "${HTTPBIN_ROUTE_FILE}" ]] || die "HTTPRoute manifest not found: ${HTTPBIN_ROUTE_FILE}"
  log "Applying httpbin HTTPRoute from ${HTTPBIN_ROUTE_FILE}"
  kubectl apply -f "${HTTPBIN_ROUTE_FILE}"

  if [[ -f "${KEYCLOAK_CONFIGMAP}" ]]; then
    log "Applying Keycloak realm config (${KEYCLOAK_CONFIGMAP})"
    kubectl apply -f "${KEYCLOAK_CONFIGMAP}"
  fi
  if [[ -f "${KEYCLOAK_DEPLOYMENT}" ]]; then
    log "Applying Keycloak deployment (${KEYCLOAK_DEPLOYMENT})"
    kubectl apply -f "${KEYCLOAK_DEPLOYMENT}"
    wait_for_deployment default keycloak 180
    kubectl rollout status -n default deployment/keycloak --timeout=180s >/dev/null
  fi
  if [[ -f "${KEYCLOAK_SERVICE}" ]]; then
    log "Applying Keycloak service (${KEYCLOAK_SERVICE})"
    kubectl apply -f "${KEYCLOAK_SERVICE}"
    local keycloak_node_ip
    keycloak_node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
    if [[ -n "${keycloak_node_ip}" ]]; then
      log "Keycloak admin console available at http://${keycloak_node_ip}:30080/ (admin/admin)"
    fi
  fi

  if [[ -f "${OIDC_PLUGIN_CONFIG}" ]]; then
    log "Applying APISIX OIDC plugin config (${OIDC_PLUGIN_CONFIG})"
    kubectl apply -f "${OIDC_PLUGIN_CONFIG}"
    log "OIDC client 'go-rest' (secret: go-rest-secret) is ready in Keycloak realm 'demo' (user: demo/demo)."
  fi
  if [[ -f "${KEYAUTH_PLUGIN_CONFIG}" ]]; then
    log "Applying APISIX key-auth plugin config (${KEYAUTH_PLUGIN_CONFIG})"
    kubectl apply -f "${KEYAUTH_PLUGIN_CONFIG}"
  fi
  if [[ -f "${GO_REST_CONSUMER_FILE}" ]]; then
    log "Applying go-rest API key consumer (${GO_REST_CONSUMER_FILE})"
    kubectl apply -f "${GO_REST_CONSUMER_FILE}"
    log "API key auth enabled as alternative for apitest.local (consumer: demo, header: X-API-Key, default key: go-rest-demo-key)"
  fi
  if [[ -f "${PROMETHEUS_SERVICE_FILE}" ]]; then
    log "Applying APISIX Prometheus service (${PROMETHEUS_SERVICE_FILE})"
    kubectl apply -f "${PROMETHEUS_SERVICE_FILE}"
  fi

  if [[ -f "${EXTRA_API_DEPLOYMENT}" ]]; then
    log "Applying extra API deployment (${EXTRA_API_DEPLOYMENT})"
    kubectl apply -f "${EXTRA_API_DEPLOYMENT}"
    local extra_name extra_ns
    extra_name="$(kubectl get -f "${EXTRA_API_DEPLOYMENT}" -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
    extra_ns="$(kubectl get -f "${EXTRA_API_DEPLOYMENT}" -o jsonpath='{.metadata.namespace}' 2>/dev/null || true)"
    [[ -n "${extra_ns}" ]] || extra_ns="default"
    if [[ -n "${extra_name}" ]]; then
      wait_for_deployment "${extra_ns}" "${extra_name}" 120
      kubectl rollout status -n "${extra_ns}" "deployment/${extra_name}" --timeout=180s >/dev/null
    fi
  fi
  if [[ -f "${EXTRA_API_SERVICE}" ]]; then
    log "Applying extra API service (${EXTRA_API_SERVICE})"
    kubectl apply -f "${EXTRA_API_SERVICE}"
  fi
  if [[ -f "${GO_REST_APISIXROUTE_FILE}" ]]; then
    log "Applying go-rest ApisixRoute (${GO_REST_APISIXROUTE_FILE})"
    kubectl apply -f "${GO_REST_APISIXROUTE_FILE}"
    wait_for_apisixroute_accepted "${GO_REST_APISIXROUTE_NAME}" "${GO_REST_APISIXROUTE_NAMESPACE}" 180
  fi
  if [[ -n "${GO_REST_HTTPROUTE_FILE}" && -f "${GO_REST_HTTPROUTE_FILE}" ]]; then
    log "Applying go-rest HTTPRoute (${GO_REST_HTTPROUTE_FILE})"
    kubectl apply -f "${GO_REST_HTTPROUTE_FILE}"
    wait_for_http_route_accepted "${GO_REST_HTTPROUTE_NAME}" "${GO_REST_HTTPROUTE_NAMESPACE}" 180
  fi

  wait_for_gateway_resource 180
  wait_for_gateway_condition "Accepted"
  wait_for_route_attachment
  print_external_curl_hint
  run_connectivity_probe

  log "Probing go-rest API route through APISIX (expect 200)"
  local url_api="http://${GATEWAY_NAME}.${APISIX_NAMESPACE}.svc.cluster.local${API_TEST_PATH}"
  echo "# curl -v -H 'Host: apitest.local' ${url_api}"
  local output_api status_api
  output_api="$(kubectl run curl-test-api --rm --image=curlimages/curl --restart=Never --namespace "${HTTPBIN_NAMESPACE}" --command -- /bin/sh -c "curl -s -o /dev/null -w '%{http_code}' -H 'Host: apitest.local' '${url_api}'" 2>&1 || true)"
  status_api="$(printf '%s\n' "$output_api" | sed -n 's/^\([0-9][0-9]*\).*/\1/p' | head -n1)"
  case "${status_api}" in
    200)
      log "Go-rest API probe succeeded (200)"
      ;;
    302)
      log "Go-rest API probe returned 302 (unauthenticated clients are redirected to Keycloak)"
      ;;
    401)
      log "Go-rest API probe returned 401 (expected for unauthenticated requests)"
      ;;
    *)
      die "Go-rest connectivity probe returned ${status_api:-<empty>} (full output: ${output_api})"
      ;;
  esac

  if kubectl get svc "${PROMETHEUS_SERVICE_NAME}" -n "${PROMETHEUS_SERVICE_NAMESPACE}" >/dev/null 2>&1; then
    run_prometheus_probe
  else
    log "Skipping Prometheus metrics probe; service ${PROMETHEUS_SERVICE_NAMESPACE}/${PROMETHEUS_SERVICE_NAME} not found"
  fi

  log "Deployment complete."
}

main "$@"
