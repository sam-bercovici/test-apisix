# Testing APISIX + Keycloak (OIDC) Integration

## Prerequisites

- APISIX, Keycloak, httpbin, and go-rest services deployed (as in repo setup).
- `kubectl`, `curl`, `jq` in your PATH.
- Access to the kind cluster (use `kubectl config use-context kind-kind` if needed).
- `/etc/hosts` (or equivalent) contains entries pointing `apitest.local` and `httpbin.local` to the kind node IP.

---

## 1. Verify the Keycloak Realm

1. Open the admin console: `http://<node-ip>:30080/`.
2. Log in as `admin` / `admin`.
3. Use the realm selector (top-left) to confirm the `Demo Realm`.
4. Under `Demo Realm` check:
   - Users → user `demo` exists, is enabled, email verified.
   - Clients → client `go-rest`, secret `go-rest-secret`.
   - `Service Accounts Enabled` and `Direct Access Grants Enabled` should be `ON`.

---

## 2. Run the Validation Script

The repo contains `validate-apitest.sh`. It:

- Detects the kind node IP and the APISIX NodePort.
- Requests a password grant token for `demo/demo`.
- Calls `/health-check` once with a bearer token (no API key) and once with the API key (no token), then confirms requests with no credentials are rejected.

**Usage**:
```bash
chmod +x validate-apitest.sh             # first time
./validate-apitest.sh
```

**Expected Output** (abridged):
```
Using node IP: 172.23.0.2
Using APISIX nodePort: 30368
Keycloak URL: http://172.23.0.2:30080
API endpoint: http://172.23.0.2:30368/health-check (Host header: apitest.local)
API key header: X-API-Key
Successfully obtained access token for user 'demo'.
Bearer-token request succeeded (HTTP 200).
Response body:
{"healthy":true}
API-key request succeeded (HTTP 200).
Response body:
{"healthy":true}
Request without credentials returned expected status 401.
Response body:
<html>...401 Authorization Required...</html>
Validation complete.
```

### Notes

- If `curl` cannot reach the NodePort:
  - Ensure `NODE_PORT` isn’t exported to an outdated value (`unset NODE_PORT`).
  - Confirm the current NodePort:  
    `kubectl get svc apisix-gateway -n apisix -o jsonpath='{.spec.ports[0].nodePort}'`
  - If direct NodePort access isn’t possible, port-forward APISIX and override the script’s env vars:
    ```bash
    kubectl -n apisix port-forward svc/apisix-gateway 8080:80
    export NODE_IP=127.0.0.1
    export NODE_PORT=8080
    ./validate-apitest.sh
    ```
- Override the API key header/value if you rotated credentials:
  ```bash
  export API_KEY_HEADER=X-API-Key
  export API_KEY_VALUE=new-secret-key
  ./validate-apitest.sh
  ```
- Rate limits apply per authenticated identity (APISIX `consumer_name`) at ~10 req/s with a burst of 5. A fallback `limit-count` caps each client IP at 240 req/min; expect HTTP 429 when either quota is exceeded (quick check: `for i in {1..20}; do curl -s -o /dev/null -w '%{http_code}\n' -H "Host: apitest.local" -H "X-API-Key: go-rest-demo-key" "http://$NODE_IP:$NODE_PORT/health-check"; done`).
- OIDC traffic binds to a consumer via `consumer_by: [preferred_username, sub]`; create matching `Consumer` objects (example: `demo`) to give each user its own quota bucket. Missing consumers fall back to the IP-based limiter.
- To rate-limit on a forwarded header instead of the node IP, edit `go-rest-keyauth` / `go-rest-oidc` and change the fallback `limit-count` key from `remote_addr` to `http_x_forwarded_for` (or any trusted header).
- Use `./validate-rate_limit.sh` to burst-test throttling for API-key and bearer flows.
- The Gateway `HTTPRoute` example (`api-route.yaml`) is optional and not applied by default; `go-rest-apisixroute.yaml` is what enforces the “OIDC OR API key” policy. Gateway API today can’t express that OR logic—attaching both plugins to a single rule would require clients to supply *both* credentials, while attaching only one would drop the other checks.

---

## 3. Manual Steps (optional)

### 3.1 Grab an Access Token

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
TOKEN=$(curl -s \
  -d 'grant_type=password' \
  -d 'client_id=go-rest' \
  -d 'client_secret=go-rest-secret' \
  -d 'username=demo' \
  -d 'password=demo' \
  "http://$NODE_IP:30080/realms/demo/protocol/openid-connect/token" | jq -r '.access_token')
```

### 3.2 API-Key Call

```bash
NODE_PORT=$(kubectl get svc apisix-gateway -n apisix -o jsonpath='{.spec.ports[0].nodePort}')
curl -H "Host: apitest.local" \
     -H "X-API-Key: go-rest-demo-key" \
     "http://$NODE_IP:$NODE_PORT/health-check"
# → {"healthy":true}
```

### 3.3 Bearer-Token Call

```bash
curl -H "Host: apitest.local" \
     -H "Authorization: Bearer $TOKEN" \
     "http://$NODE_IP:$NODE_PORT/health-check"
# → {"healthy":true}
```

### 3.4 Unauthenticated Call

```bash
curl -H "Host: apitest.local" \
     "http://$NODE_IP:$NODE_PORT/health-check"
# → 401 Authorization Required (or 302 if bearer_only=false)
```

### 3.5 Introspect the Token

```bash
curl -s \
  -d "client_id=go-rest" \
  -d "client_secret=go-rest-secret" \
  -d "token=$TOKEN" \
  "http://$NODE_IP:30080/realms/demo/protocol/openid-connect/token/introspect" | jq
```
Ensure `"active": true`.

---

## 4. Check APISIX Configuration (optional)

### 4.1 Routes

```bash
kubectl run apisix-inspect --rm -i --tty \
  --image=curlimages/curl --restart=Never -n apisix \
  --command -- /bin/sh -c \
  "curl -s -H 'X-API-KEY: edd1c9f034335f136f87ad84b625c8f1' \
  http://apisix-admin.apisix.svc.cluster.local:9180/apisix/admin/routes"
```

Look for `apitest.local` routes referencing plugin configs `go-rest-keyauth` and `go-rest-oidc`.

### 4.2 Plugin Config (OIDC)

```bash
kubectl get apisixpluginconfig go-rest-oidc -n default -o yaml
```

Should list the discovery URL, client, secret, `bearer_only: true`, and `introspection_endpoint_auth_method/token_endpoint_auth_method: client_secret_post`.

### 4.3 Plugin Config (API key)

```bash
kubectl get apisixpluginconfig go-rest-keyauth -n default -o yaml
```

Ensure `key_names` contains `x-api-key` and the plugin is enabled.

### 4.4 Prometheus Metrics

If `apisix-prometheus-service.yaml` has been applied, confirm the metrics endpoint is live:

```bash
kubectl run curl-prometheus --rm --image=curlimages/curl --restart=Never \
  -n apisix --command -- \
  /bin/sh -c "curl -sSf http://apisix-prometheus.apisix.svc.cluster.local:9091/apisix/prometheus/metrics | head -n 5"
```

Expect several `# HELP` / `# TYPE` lines along with APISIX metric samples. A failure indicates the service or plugin is misconfigured.

---

## 5. Keycloak Login Flow (browser)

- Browse to `http://apitest.local:<nodeport>/health-check`.
- Expect redirect to Keycloak login.
- Log in as `demo/demo`.
- Redirect back to the API with `{"healthy":true}`.

---

## Troubleshooting

- **API key requests fail (401)** → ensure the `Consumer` named `demo` exists:  
  `kubectl get consumer demo -n default -o yaml`  
  The default key is `go-rest-demo-key`; export `API_KEY_VALUE` if you rotate it.  
  Verify `kubectl get apisixpluginconfig go-rest-keyauth -n default -o yaml` lists `limit-req` with `key_type: consumer_name`.
- **NodePort unreachable** → use port-forward or double-check NodePort value.
- **Token request fails** (“Account is not fully set up”) → ensure user is imported with no required actions and password reset done.
- **401 even with token** → check Keycloak logs (`kubectl logs deploy/keycloak -n default`) for introspection errors; ensure `go-rest-oidc` plugin config is applied and client `go-rest` has `serviceAccountsEnabled = true` with both `token_endpoint_auth_method` and `introspection_endpoint_auth_method` set to `client_secret_post`.
- **Realm missing** → restart Keycloak pod to re-import realm:  
  `kubectl rollout restart deploy/keycloak -n default`.

---

By following these steps (script + manual checks), you confirm APISIX accepts either the configured API key or a Keycloak-issued token for the go-rest API while blocking unauthenticated requests.
