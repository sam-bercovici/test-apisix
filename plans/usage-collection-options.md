# Usage Collection for Billing - Options Analysis

## Problem Statement

Collect used quota (2nd tier rate limit) per `enterprise_id` for usage reporting and charging. The solution must be **resilient to Redis and Envoy restarts/redeployments**.

### Current State
- Two-tier rate limiting: Tier 1 (10 rps burst), Tier 2 (1000/day quota)
- `x-enterprise-id` header extracted from JWT `client_id` claim via SecurityPolicy
- Redis stores ephemeral rate limit counters (lost on restart)
- No persistent usage tracking for billing

### Key Constraint
Envoy's native Prometheus metrics **cannot include custom labels from request headers** like `x-enterprise-id`. All approaches must use **access logging** to capture per-org usage.

---

## Option 1: Access Logging to Loki

### Architecture
```
Envoy Access Log (JSON with x-enterprise-id)
    → OpenTelemetry Collector (OTLP gRPC)
    → Loki (durable log storage)
    → LogQL queries for billing
```

### Implementation
1. Configure EnvoyProxy `telemetry.accessLog` with JSON format including `%REQ(x-enterprise-id)%`
2. Deploy OpenTelemetry Collector in `monitoring` namespace
3. Deploy Loki StatefulSet with PVC for durable storage
4. Query usage via LogQL

### LogQL Query Example
```logql
sum by (enterprise_id) (count_over_time({service_name="envoy-gateway"} | json | enterprise_id != "" [24h]))
```

### Pros
- Complete audit trail of all requests
- Flexible querying (filter by path, method, response code)
- Logs shipped immediately (resilient to Envoy restart)

### Cons
- Higher storage costs for high-traffic APIs
- Requires Loki deployment and management
- Query latency for large time ranges

### Files to Create/Modify
| File | Action |
|------|--------|
| `envoy-gateway/gateway-class.yaml` | Modify - add telemetry.accessLog |
| `monitoring/otel-collector.yaml` | Create |
| `monitoring/loki.yaml` | Create |

---

## Option 2: Access Logging to Prometheus Metrics

### Architecture
```
Envoy Access Log (JSON with x-enterprise-id)
    → OpenTelemetry Collector (OTLP gRPC)
    → Log-to-Metric Connector (count by enterprise_id)
    → Prometheus (durable metrics storage)
    → PromQL queries for billing
```

### Implementation
1. Configure EnvoyProxy `telemetry.accessLog` with JSON format
2. Deploy OpenTelemetry Collector with `count` connector (logs → metrics)
3. Deploy Prometheus with PVC for 30d+ retention
4. Query usage via PromQL

### PromQL Query Example
```promql
sum(increase(envoy_accesslog_requests_total{response_code=~"2..", enterprise_id!=""}[24h])) by (enterprise_id)
```

### Pros
- Efficient storage (counters vs full logs)
- Fast queries via PromQL
- Standard Grafana dashboards and alerting
- Lower storage costs than full logs

### Cons
- Loses request-level detail (only aggregates)
- Requires OTel Collector for log-to-metric conversion
- Cardinality concerns with many enterprise_ids

### Files to Create/Modify
| File | Action |
|------|--------|
| `envoy-gateway/gateway-class.yaml` | Modify - add telemetry.accessLog |
| `monitoring/otel-collector.yaml` | Create - with count connector |
| `monitoring/prometheus.yaml` | Create |

---

## Option 3: Persistent Redis + Export CronJob

### Architecture
```
Envoy Rate Limiter
    → Redis StatefulSet (AOF + RDB persistence)
    → CronJob (hourly export of counters)
    → PVC / S3 (JSON exports for billing)
```

### Implementation
1. Convert Redis Deployment to StatefulSet with PVC
2. Enable AOF persistence (`appendonly yes`, `appendfsync everysec`)
3. Create CronJob to export rate limit keys to JSON
4. Optionally sync exports to S3

### Export Script Query
```bash
redis-cli KEYS '*x-enterprise-id*' | while read key; do
  echo "$key: $(redis-cli GET $key)"
done
```

### Pros
- Simplest architecture (no new components beyond PVC)
- Redis counters survive restarts
- Low overhead

### Cons
- Export lag (hourly CronJob = up to 1 hour missing data)
- Depends on Envoy rate limiter key format (may change)
- No historical trend data (only current counters)
- Single point of failure without Redis HA

### Files to Create/Modify
| File | Action |
|------|--------|
| `redis/deployment.yaml` | Replace with StatefulSet |
| `redis/redis-config.yaml` | Create - persistence config |
| `redis/usage-exporter-cronjob.yaml` | Create |
| `redis/usage-exports-pvc.yaml` | Create |

---

## Comparison Matrix

| Criteria | Option 1: Loki | Option 2: Prometheus | Option 3: Redis Export |
|----------|----------------|---------------------|----------------------|
| **Resilience** | High | High | Medium |
| **Data Granularity** | Per-request | Aggregated | Current counters only |
| **Query Flexibility** | High (LogQL) | High (PromQL) | Low (JSON files) |
| **Storage Cost** | High | Low | Low |
| **Complexity** | Medium | Medium | Low |
| **New Components** | OTel + Loki | OTel + Prometheus | PVC + CronJob |
| **Real-time** | Near real-time | 15-60s delay | Hourly batch |

---

## Recommendation: Hybrid Approach

Combine **Option 3** (Phase 1) + **Option 2** (Phase 2):

### Phase 1: Persistent Redis
- Make Redis durable to prevent rate limit counter loss on restart
- Low complexity, immediate benefit
- Rate limiting continues correctly after restarts

### Phase 2: Access Logging to Prometheus
- Add structured access logging with `x-enterprise-id`
- Deploy OTel Collector + Prometheus for billing queries
- Provides durable, queryable usage data per enterprise_id

### Why This Combination?
1. **Phase 1 is essential** - without persistent Redis, rate limits reset on restart (users get free quota)
2. **Phase 2 provides billing data** - Redis counters only show current state, not historical usage
3. **Incremental deployment** - Phase 1 can be deployed independently

---

## Questions for Decision

1. **Existing Infrastructure**: Do you have Prometheus/Loki/Grafana deployed?
2. **Billing Granularity**: Daily totals, hourly breakdown, or per-request audit trail?
3. **Retention Period**: How long to keep usage data? (30 days for billing? 90 days for compliance?)
4. **Real-time Requirements**: Is near real-time usage visibility needed, or is hourly/daily sufficient?
