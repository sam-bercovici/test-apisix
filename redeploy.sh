#!/usr/bin/env bash
set -euo pipefail

### configuration #############################################################
CLUSTER_NAME="${CLUSTER_NAME:-kind}"
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-${CLUSTER_NAME}}"

# Envoy Gateway configuration
ENVOY_GATEWAY_NAMESPACE="${ENVOY_GATEWAY_NAMESPACE:-envoy-gateway-system}"
ENVOY_GATEWAY_RELEASE="${ENVOY_GATEWAY_RELEASE:-eg}"
ENVOY_GATEWAY_VERSION="${ENVOY_GATEWAY_VERSION:-v1.6.0}"
ENVOY_GATEWAY_VALUES="${ENVOY_GATEWAY_VALUES:-envoy-gateway/helm-values.yaml}"
GATEWAY_CLASS_MANIFEST="${GATEWAY_CLASS_MANIFEST:-envoy-gateway/gateway-class.yaml}"
GATEWAY_MANIFEST="${GATEWAY_MANIFEST:-envoy-gateway/gateway.yaml}"
INTERNAL_GATEWAY_MANIFEST="${INTERNAL_GATEWAY_MANIFEST:-envoy-gateway/internal-gateway.yaml}"
INTERNAL_BACKEND_MANIFEST="${INTERNAL_BACKEND_MANIFEST:-envoy-gateway/uds-backend.yaml}"
EXTERNAL_FORWARD_ROUTE="${EXTERNAL_FORWARD_ROUTE:-envoy-gateway/external-forward-route.yaml}"
SECURITY_POLICY_MANIFEST="${SECURITY_POLICY_MANIFEST:-envoy-gateway/security-policy.yaml}"
TIER1_RATE_LIMIT_POLICY="${TIER1_RATE_LIMIT_POLICY:-envoy-gateway/tier1-rate-limit-policy.yaml}"
TIER2_QUOTA_POLICY="${TIER2_QUOTA_POLICY:-envoy-gateway/tier2-quota-policy.yaml}"
GATEWAY_NAME="${GATEWAY_NAME:-eg-gateway}"
INTERNAL_GATEWAY_NAME="${INTERNAL_GATEWAY_NAME:-eg-internal}"

# Redis configuration
REDIS_NAMESPACE="${REDIS_NAMESPACE:-redis-system}"
REDIS_MANIFEST="${REDIS_MANIFEST:-redis/deployment.yaml}"

# Routes
HTTPBIN_ROUTE_FILE="${HTTPBIN_ROUTE_FILE:-routes/httpbin-route.yaml}"
HTTPBIN_NAMESPACE="${HTTPBIN_NAMESPACE:-default}"
GO_REST_ROUTE_FILE="${GO_REST_ROUTE_FILE:-routes/go-rest-route.yaml}"
HYDRA_ROUTE_FILE="${HYDRA_ROUTE_FILE:-routes/hydra-route.yaml}"

# Workloads
HTTPBIN_MANIFEST="${HTTPBIN_MANIFEST:-workloads/httpbin.yaml}"
GO_REST_API_MANIFEST="${GO_REST_API_MANIFEST:-workloads/go-rest-api.yaml}"
WORKLOADS_NAMESPACE="${WORKLOADS_NAMESPACE:-default}"

# Hydra configuration (Helm-based)
HYDRA_NAMESPACE="${HYDRA_NAMESPACE:-hydra}"
HYDRA_RELEASE="${HYDRA_RELEASE:-hydra}"
HYDRA_VERSION="${HYDRA_VERSION:-0.52.0}"
HYDRA_VALUES="${HYDRA_VALUES:-hydra/helm-values.yaml}"
HYDRA_POSTGRES_CLUSTER="${HYDRA_POSTGRES_CLUSTER:-hydra/postgres-cluster.yaml}"
HYDRA_REFERENCE_GRANT="${HYDRA_REFERENCE_GRANT:-hydra/reference-grant.yaml}"
HYDRA_CLIENT_SYNC_JOB="${HYDRA_CLIENT_SYNC_JOB:-hydra/client-sync-job.yaml}"

# Test paths
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

wait_for_gateway_programmed() {
  local timeout=${1:-120}
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    local status reason
    status="$(kubectl get gateway "${GATEWAY_NAME}" -n "${ENVOY_GATEWAY_NAMESPACE}" \
      -o jsonpath="{.status.conditions[?(@.type==\"Programmed\")].status}" 2>/dev/null || true)"
    reason="$(kubectl get gateway "${GATEWAY_NAME}" -n "${ENVOY_GATEWAY_NAMESPACE}" \
      -o jsonpath="{.status.conditions[?(@.type==\"Programmed\")].reason}" 2>/dev/null || true)"
    if [[ "${status^^}" == *TRUE* ]]; then
      log "Gateway ${GATEWAY_NAME} condition Programmed=True"
      return 0
    fi
    # In Kind clusters, LoadBalancer services remain pending but gateway is functional
    # Accept AddressNotAssigned as success if the listener is programmed
    if [[ "${reason}" == "AddressNotAssigned" ]]; then
      local listener_status
      listener_status="$(kubectl get gateway "${GATEWAY_NAME}" -n "${ENVOY_GATEWAY_NAMESPACE}" \
        -o jsonpath="{.status.listeners[0].conditions[?(@.type==\"Programmed\")].status}" 2>/dev/null || true)"
      if [[ "${listener_status^^}" == *TRUE* ]]; then
        log "Gateway ${GATEWAY_NAME} listener is Programmed (AddressNotAssigned expected in Kind)"
        return 0
      fi
    fi
    sleep 4
  done
  die "Timed out waiting for Gateway ${GATEWAY_NAME} to be Programmed"
}

wait_for_http_route_accepted() {
  local route=$1
  local namespace=$2
  local gateway=${3:-${GATEWAY_NAME}}
  local timeout=${4:-120}
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    local status
    status="$(kubectl get httproute "${route}" -n "${namespace}" \
      -o jsonpath="{.status.parents[?(@.parentRef.name==\"${gateway}\")].conditions[?(@.type==\"Accepted\")].status}" 2>/dev/null || true)"
    if [[ "${status^^}" == *TRUE* ]]; then
      log "HTTPRoute ${namespace}/${route} accepted by ${gateway}"
      return 0
    fi
    sleep 4
  done
  die "Timed out waiting for HTTPRoute ${namespace}/${route} to be accepted by ${gateway}"
}

wait_for_job_completion() {
  local namespace=$1
  local name=$2
  local timeout=${3:-180}
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    local succeeded
    succeeded="$(kubectl get job "${name}" -n "${namespace}" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
    if [[ "${succeeded}" == "1" ]]; then
      log "Job ${namespace}/${name} completed successfully"
      return 0
    fi
    local failed
    failed="$(kubectl get job "${name}" -n "${namespace}" -o jsonpath='{.status.failed}' 2>/dev/null || true)"
    if [[ -n "${failed}" && "${failed}" -ge 3 ]]; then
      die "Job ${namespace}/${name} failed after ${failed} attempts"
    fi
    sleep 5
  done
  die "Job ${namespace}/${name} did not complete within ${timeout}s"
}

deploy_redis() {
  if [[ ! -f "${REDIS_MANIFEST}" ]]; then
    die "Redis manifest not found: ${REDIS_MANIFEST}"
  fi

  log "Deploying Redis for rate limiting (${REDIS_MANIFEST})"
  kubectl apply -f "${REDIS_MANIFEST}"

  wait_for_deployment "${REDIS_NAMESPACE}" "redis" 120
  kubectl rollout status -n "${REDIS_NAMESPACE}" deployment/redis --timeout=120s >/dev/null
  log "Redis is ready"
}

install_envoy_gateway() {
  log "Installing Envoy Gateway ${ENVOY_GATEWAY_VERSION}"

  local values_flag=()
  if [[ -f "${ENVOY_GATEWAY_VALUES}" ]]; then
    values_flag=(-f "${ENVOY_GATEWAY_VALUES}")
  fi

  helm upgrade --install "${ENVOY_GATEWAY_RELEASE}" \
    oci://docker.io/envoyproxy/gateway-helm \
    --version "${ENVOY_GATEWAY_VERSION}" \
    -n "${ENVOY_GATEWAY_NAMESPACE}" \
    --create-namespace \
    "${values_flag[@]}"

  wait_for_deployment "${ENVOY_GATEWAY_NAMESPACE}" "envoy-gateway" 180
  kubectl rollout status -n "${ENVOY_GATEWAY_NAMESPACE}" \
    deployment/envoy-gateway \
    --timeout=180s >/dev/null
  log "Envoy Gateway controller is ready"
}

wait_for_internal_gateway_programmed() {
  local timeout=${1:-120}
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    local status reason
    status="$(kubectl get gateway "${INTERNAL_GATEWAY_NAME}" -n "${ENVOY_GATEWAY_NAMESPACE}" \
      -o jsonpath="{.status.conditions[?(@.type==\"Programmed\")].status}" 2>/dev/null || true)"
    reason="$(kubectl get gateway "${INTERNAL_GATEWAY_NAME}" -n "${ENVOY_GATEWAY_NAMESPACE}" \
      -o jsonpath="{.status.conditions[?(@.type==\"Programmed\")].reason}" 2>/dev/null || true)"
    if [[ "${status^^}" == *TRUE* ]]; then
      log "Gateway ${INTERNAL_GATEWAY_NAME} condition Programmed=True"
      return 0
    fi
    if [[ "${reason}" == "AddressNotAssigned" ]]; then
      local listener_status
      listener_status="$(kubectl get gateway "${INTERNAL_GATEWAY_NAME}" -n "${ENVOY_GATEWAY_NAMESPACE}" \
        -o jsonpath="{.status.listeners[0].conditions[?(@.type==\"Programmed\")].status}" 2>/dev/null || true)"
      if [[ "${listener_status^^}" == *TRUE* ]]; then
        log "Gateway ${INTERNAL_GATEWAY_NAME} listener is Programmed (AddressNotAssigned expected)"
        return 0
      fi
    fi
    sleep 4
  done
  die "Timed out waiting for Gateway ${INTERNAL_GATEWAY_NAME} to be Programmed"
}

apply_gateway_resources() {
  if [[ -f "${GATEWAY_CLASS_MANIFEST}" ]]; then
    log "Applying GatewayClass and EnvoyProxy (${GATEWAY_CLASS_MANIFEST})"
    kubectl apply -f "${GATEWAY_CLASS_MANIFEST}"
  fi

  if [[ -f "${GATEWAY_MANIFEST}" ]]; then
    log "Applying External Gateway (${GATEWAY_MANIFEST})"
    kubectl apply -f "${GATEWAY_MANIFEST}"
    wait_for_gateway_programmed 120
  fi

  if [[ -f "${INTERNAL_GATEWAY_MANIFEST}" ]]; then
    log "Applying Internal Gateway (${INTERNAL_GATEWAY_MANIFEST})"
    kubectl apply -f "${INTERNAL_GATEWAY_MANIFEST}"
    wait_for_internal_gateway_programmed 120
  fi
}

apply_two_tier_routing() {
  # Apply internal backend service that routes to internal gateway pods
  if [[ -f "${INTERNAL_BACKEND_MANIFEST}" ]]; then
    log "Applying internal backend service (${INTERNAL_BACKEND_MANIFEST})"
    kubectl apply -f "${INTERNAL_BACKEND_MANIFEST}"
  fi

  # Apply forward route: external gateway → internal gateway
  if [[ -f "${EXTERNAL_FORWARD_ROUTE}" ]]; then
    log "Applying external forward route to internal gateway (${EXTERNAL_FORWARD_ROUTE})"
    kubectl apply -f "${EXTERNAL_FORWARD_ROUTE}"
  fi
}

apply_security_policy() {
  if [[ -f "${SECURITY_POLICY_MANIFEST}" ]]; then
    log "Applying SecurityPolicy for JWT authentication (${SECURITY_POLICY_MANIFEST})"
    kubectl apply -f "${SECURITY_POLICY_MANIFEST}"
  fi
}

apply_rate_limit_policies() {
  if [[ -f "${TIER1_RATE_LIMIT_POLICY}" ]]; then
    log "Applying Tier 1 burst rate limit policy (${TIER1_RATE_LIMIT_POLICY})"
    kubectl apply -f "${TIER1_RATE_LIMIT_POLICY}"
  fi

  if [[ -f "${TIER2_QUOTA_POLICY}" ]]; then
    log "Applying Tier 2 daily quota policy (${TIER2_QUOTA_POLICY})"
    kubectl apply -f "${TIER2_QUOTA_POLICY}"
  fi
}

ensure_hydra_namespace() {
  if ! kubectl get namespace "${HYDRA_NAMESPACE}" >/dev/null 2>&1; then
    log "Creating namespace ${HYDRA_NAMESPACE}"
    kubectl create namespace "${HYDRA_NAMESPACE}"
  fi
}

install_cnpg_operator() {
  log "Installing CloudNativePG operator"
  helm repo add cnpg https://cloudnative-pg.github.io/charts 2>/dev/null || true
  helm repo update cnpg

  helm upgrade --install cnpg cnpg/cloudnative-pg \
    --namespace cnpg-system --create-namespace

  wait_for_deployment "cnpg-system" "cnpg-cloudnative-pg" 180
  kubectl rollout status -n cnpg-system deployment/cnpg-cloudnative-pg --timeout=180s >/dev/null
  log "CloudNativePG operator is ready"
}

deploy_hydra_postgres() {
  if [[ ! -f "${HYDRA_POSTGRES_CLUSTER}" ]]; then
    log "Skipping Hydra PostgreSQL; manifest ${HYDRA_POSTGRES_CLUSTER} not found"
    return 1
  fi

  ensure_hydra_namespace

  log "Creating Hydra PostgreSQL cluster (${HYDRA_POSTGRES_CLUSTER})"
  kubectl apply -f "${HYDRA_POSTGRES_CLUSTER}"

  log "Waiting for PostgreSQL cluster to be ready"
  local timeout=180
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    local ready
    ready="$(kubectl get cluster hydra-postgres -n "${HYDRA_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "${ready}" == "Cluster in healthy state" ]]; then
      log "Hydra PostgreSQL cluster is ready"
      return 0
    fi
    sleep 5
  done
  die "Hydra PostgreSQL cluster did not become ready within ${timeout}s"
}

deploy_hydra() {
  if [[ ! -f "${HYDRA_VALUES}" ]]; then
    log "Skipping Hydra; values file ${HYDRA_VALUES} not found"
    return 1
  fi

  log "Adding Ory Helm repository"
  helm repo add ory https://k8s.ory.sh/helm/charts 2>/dev/null || true
  helm repo update ory

  log "Installing Ory Hydra ${HYDRA_VERSION}"
  helm upgrade --install "${HYDRA_RELEASE}" ory/hydra \
    --version "${HYDRA_VERSION}" \
    --namespace "${HYDRA_NAMESPACE}" \
    -f "${HYDRA_VALUES}"

  wait_for_deployment "${HYDRA_NAMESPACE}" "hydra" 180
  kubectl rollout status -n "${HYDRA_NAMESPACE}" deployment/hydra --timeout=180s >/dev/null
  log "Ory Hydra is ready"
}

apply_hydra_reference_grant() {
  if [[ -f "${HYDRA_REFERENCE_GRANT}" ]]; then
    log "Applying Hydra ReferenceGrant (${HYDRA_REFERENCE_GRANT})"
    kubectl apply -f "${HYDRA_REFERENCE_GRANT}"
  fi
}

sync_hydra_clients() {
  if [[ ! -f "${HYDRA_CLIENT_SYNC_JOB}" ]]; then
    log "Skipping Hydra client sync; manifest ${HYDRA_CLIENT_SYNC_JOB} not found"
    return 0
  fi

  # Delete previous job if exists
  kubectl delete job hydra-client-sync -n "${HYDRA_NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1

  log "Syncing OAuth2 clients to Hydra (${HYDRA_CLIENT_SYNC_JOB})"
  kubectl apply -f "${HYDRA_CLIENT_SYNC_JOB}"
  wait_for_job_completion "${HYDRA_NAMESPACE}" "hydra-client-sync" 120
  log "OAuth2 clients synced (go-rest, demo-client)"
}

deploy_workloads() {
  if [[ -f "${HTTPBIN_MANIFEST}" ]]; then
    log "Deploying httpbin (${HTTPBIN_MANIFEST})"
    kubectl apply -n "${WORKLOADS_NAMESPACE}" -f "${HTTPBIN_MANIFEST}"
    kubectl wait --for=condition=Available deployment/httpbin \
      -n "${WORKLOADS_NAMESPACE}" --timeout=120s >/dev/null
    log "httpbin is ready"
  fi

  if [[ -f "${GO_REST_API_MANIFEST}" ]]; then
    log "Deploying go-rest-api (${GO_REST_API_MANIFEST})"
    kubectl apply -n "${WORKLOADS_NAMESPACE}" -f "${GO_REST_API_MANIFEST}"
    kubectl wait --for=condition=Available deployment/go-rest-api \
      -n "${WORKLOADS_NAMESPACE}" --timeout=120s >/dev/null
    log "go-rest-api is ready"
  fi
}

apply_routes() {
  # Routes now attach to internal gateway (eg-internal)
  if [[ -f "${HTTPBIN_ROUTE_FILE}" ]]; then
    log "Applying httpbin HTTPRoute (${HTTPBIN_ROUTE_FILE})"
    kubectl apply -f "${HTTPBIN_ROUTE_FILE}"
    wait_for_http_route_accepted "httpbin-route" "${HTTPBIN_NAMESPACE}" "${INTERNAL_GATEWAY_NAME}" 120
  fi

  if [[ -f "${GO_REST_ROUTE_FILE}" ]]; then
    log "Applying go-rest HTTPRoute (${GO_REST_ROUTE_FILE})"
    kubectl apply -f "${GO_REST_ROUTE_FILE}"
    wait_for_http_route_accepted "go-rest-route" "default" "${INTERNAL_GATEWAY_NAME}" 120
  fi

  if [[ -f "${HYDRA_ROUTE_FILE}" ]]; then
    log "Applying Hydra HTTPRoute (${HYDRA_ROUTE_FILE})"
    kubectl apply -f "${HYDRA_ROUTE_FILE}"
    wait_for_http_route_accepted "hydra-route" "${HYDRA_NAMESPACE}" "${INTERNAL_GATEWAY_NAME}" 120
  fi
}


run_connectivity_probe() {
  log "Probing httpbin route through Envoy Gateway (expect 200)"
  local svc_name
  svc_name="$(kubectl get svc -n "${ENVOY_GATEWAY_NAMESPACE}" -l gateway.envoyproxy.io/owning-gateway-name="${GATEWAY_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${svc_name}" ]]; then
    svc_name="envoy-${GATEWAY_NAME}-envoy-gateway-system"
  fi
  local url="http://${svc_name}.${ENVOY_GATEWAY_NAMESPACE}.svc.cluster.local${HTTPBIN_TEST_PATH}"
  echo "# curl -H 'Host: httpbin.local' ${url}"
  local output status
  # Use busybox with wget since curlimages/curl has entrypoint issues with --command
  output="$(kubectl run curl-test --rm -i \
    --image=busybox:1.36 \
    --restart=Never \
    --namespace "${HTTPBIN_NAMESPACE}" \
    -- sh -c 'wget -q -O /dev/null -S --header="Host: httpbin.local" "'"${url}"'" 2>&1 | head -1 | grep -o "[0-9][0-9][0-9]"' \
    2>&1)"
  status="$(printf '%s\n' "$output" | grep -o '^[0-9][0-9][0-9]' | head -n1)"
  if [[ "${status}" != "200" ]]; then
    die "Connectivity probe returned ${status:-<empty>} (full output: ${output})"
  fi
  log "Connectivity probe succeeded (200)"
}

print_external_curl_hint() {
  local node_ip
  node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"

  local svc_name
  svc_name="$(kubectl get svc -n "${ENVOY_GATEWAY_NAMESPACE}" -l gateway.envoyproxy.io/owning-gateway-name="${GATEWAY_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${svc_name}" ]]; then
    svc_name="envoy-${GATEWAY_NAME}-envoy-gateway-system"
  fi

  local node_port
  node_port="$(kubectl get svc "${svc_name}" -n "${ENVOY_GATEWAY_NAMESPACE}" \
    -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || true)"
  node_port="${node_port%% *}"

  if [[ -n "${node_ip}" && -n "${node_port}" ]]; then
    echo ""
    echo "# External access examples:"
    echo "# httpbin:  curl -v -H 'Host: httpbin.local' http://${node_ip}:${node_port}${HTTPBIN_TEST_PATH}"
    echo "# apitest:  curl -v -H 'Host: apitest.local' http://${node_ip}:${node_port}${API_TEST_PATH}"
    echo ""
    echo "# Get JWT token from Hydra:"
    echo "# TOKEN=\$(curl -s -X POST -d 'grant_type=client_credentials&client_id=go-rest&client_secret=go-rest-secret' http://${node_ip}:${node_port}/auth/oauth2/token | jq -r '.access_token')"
    echo ""
    echo "# Authenticated request:"
    echo "# curl -H 'Host: apitest.local' -H \"Authorization: Bearer \$TOKEN\" http://${node_ip}:${node_port}${API_TEST_PATH}"
  else
    log "Could not determine NodePort or node IP for external curl hint"
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

  # Phase 1: Infrastructure
  deploy_redis
  install_cnpg_operator
  install_envoy_gateway

  # Phase 2: Gateway Resources
  apply_gateway_resources

  # Phase 3: Two-Tier Routing (external → internal gateway)
  apply_two_tier_routing

  # Deploy workloads (httpbin, go-rest-api)
  deploy_workloads

  # Deploy Hydra OAuth2 stack (Helm-based with CloudNativePG)
  deploy_hydra_postgres
  deploy_hydra
  sync_hydra_clients
  apply_hydra_reference_grant

  # Phase 4: Routes (must exist before policies that target them)
  apply_routes

  # Phase 5: Security Policy (targets HTTPRoute, so routes must exist first)
  apply_security_policy

  # Phase 6: Rate Limiting (two-tier: burst + daily quota)
  apply_rate_limit_policies

  # Validation
  print_external_curl_hint
  run_connectivity_probe

  log ""
  log "Deployment complete!"
  log ""
  log "Resources deployed:"
  kubectl get gateway,httproute,securitypolicy,backendtrafficpolicy -A 2>/dev/null || true
}

main "$@"
