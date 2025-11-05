---
title: Requirements for Kubernetes-based OSS Certificate and Key Lifecycle Management with API Gateways
version: v1.0
author: Samuel Bercovici - samuelb@trelliz.ai
date: 2025-11-05
status: Draft
---

# Requirements for Kubernetes-based OSS Certificate and Key Lifecycle Management with API Gateways

## 1. Core Security and Functional Requirements

1. **No Kubernetes Secrets for private keys or certificates in production**
   - Private key material and issued certificates must **never** be stored in Kubernetes Secrets or etcd.
   - Limited, transient exposure (milliseconds to seconds) during initial issuance is acceptable only if unavoidable and immediately mitigated (e.g., by automatic deletion or redaction).

2. **All components must be 100 % open-source**
   - No enterprise or commercial editions (e.g., no Kong Enterprise, Jetstack Secure, or Vault Enterprise).
   - Stack must rely solely on OSS versions of:
     - cert-manager  
     - HashiCorp Vault  
     - APISIX OSS and/or Kong OSS  
     - Secrets Store CSI Driver (and Vault/cloud providers)

3. **Secure certificate lifecycle management**
   - The system must handle **issuance, renewal, and rotation** automatically, including ACME-based certificates (e.g., Let’s Encrypt).
   - Renewal and rotation must occur without human intervention and without exposing private keys in any persistent store outside the chosen vault.

4. **Centralized and secure secret storage**
   - A **vault system** (HashiCorp Vault OSS or cloud secret manager) is the **only persistent store** for certificate private keys and related sensitive data.
   - Vault acts as both storage and (optionally) certificate authority for internal certificates.

5. **Gateway compatibility**
   - The solution must be compatible with **Kong OSS** and **Apache APISIX OSS**.
   - Gateways must:
     - Load certificates from mounted volumes or direct secret-provider references.
     - Keep private keys **only in memory**.
     - Never persist or re-export private key data back into Kubernetes or external storage.

6. **Automatic certificate delivery**
   - Certificates and keys must be securely delivered to gateways via ephemeral mounts (e.g., tmpfs through CSI driver) or in-memory references.
   - Delivery must be automated and synchronized with certificate issuance and renewal.

7. **Portability across environments**
   - Support local/test environments using HashiCorp Vault OSS.
   - Support production environments using cloud-native vaults (AWS Secrets Manager, GCP Secret Manager, Azure Key Vault) without architecture changes.

8. **Rotation and readiness**
   - Gateways must detect or be notified of certificate rotation and reload without downtime.
   - No manual restarts or redeployments should be required for new certificates to take effect.

9. **Auditability and traceability**
   - All certificate and key operations (issuance, renewal, revocation, access) must be auditable through the vault’s logging and policy systems.
   - No opaque or uncontrolled secret replication between systems.

---

## 2. Key Architectural Considerations

1. **cert-manager as certificate orchestrator**
   - Used to manage ACME challenges and coordinate issuance and renewal events.
   - Must operate without persisting private keys in Kubernetes Secrets long-term.
   - May use Vault as the issuer or temporarily create sanitized Secret placeholders for lifecycle tracking only.

2. **Vault (HashiCorp OSS or cloud equivalent) as system of record**
   - Holds all private keys and certificates.
   - Responsible for enforcing access control, logging, and (optionally) internal PKI signing.

3. **Secrets Store CSI Driver or equivalent injection mechanism**
   - Securely mounts certificates and keys from Vault or cloud secret managers directly into gateway pods.
   - Uses ephemeral, memory-backed volumes to prevent data persistence on disk or in etcd.

4. **Gateway memory-only key handling**
   - Both Kong OSS and APISIX OSS must load certificates into memory for TLS termination.
   - Private keys never written to disk or stored in Kubernetes resources.
   - Short-lived mounts or in-memory secret references are acceptable.

5. **No vendor-locked ACME or secret-management components**
   - All interactions (ACME, PKI, vault, CSI) must use open standards and community-maintained OSS implementations.

---

## 3. Primary Use Cases

| Use Case | Description |
|:--|:--|
| **ACME-based external certificates** | Automatically obtain and renew TLS certificates from Let’s Encrypt (or similar) via cert-manager OSS, storing keys only in Vault and mounting them directly into gateways. |
| **Internal PKI / mTLS** | Use Vault OSS as an internal CA to issue and rotate service certificates; cert-manager acts as automation controller, Vault retains all key material. |
| **Multi-environment vault integration** | Local development uses Vault OSS; production deployments transparently switch to the cloud provider’s secret manager via CSI or secret-provider abstraction. |
| **Gateway certificate hot-reload** | Gateways detect new certificates from mounted volumes or secret providers and reload their TLS contexts without downtime. |
| **Key rotation compliance** | Vault or cert-manager triggers key re-issuance and rotation according to defined security policies, fully auditable via Vault logs. |

---

## 4. Non-Functional Requirements (NFRs)

### 4.1 Security & Compliance

1. **Zero persistent key exposure**
   - Private key material must only ever exist:
     - In the vault (encrypted at rest),
     - In ephemeral tmpfs mounts,
     - Or in RAM within a gateway process.
   - No component may serialize or cache private keys on disk or in etcd.

2. **Cryptographic assurance**
   - Use strong algorithms: RSA ≥ 2048 bits or ECDSA P-256/P-384.
   - TLS certificates must exclude weak algorithms and ciphers.

3. **Access control**
   - Vault must enforce least-privilege policies.
   - Each gateway or controller uses its own vault policy and authentication role.
   - Vault tokens and credentials must be short-lived and rotated automatically.

4. **Auditing and traceability**
   - Log all certificate and key operations with timestamp, actor, and source.
   - Logs must be immutable and retained for compliance (90–180 days).

5. **Regulatory and organizational compliance**
   - Aligns with ISO 27001, SOC 2, and NIST SP 800-57.
   - Data handling meets applicable privacy and data protection standards.

---

### 4.2 Reliability & Availability

1. **High availability**
   - All critical components must support HA or clustering.
   - No single component failure can stop certificate issuance or traffic.

2. **Fault tolerance**
   - Gateways continue serving existing certificates even if vault is temporarily unavailable.

3. **Self-healing reconciliation**
   - cert-manager and controllers must automatically reissue on failure.
   - CSI driver retries mounts on transient vault issues.

4. **No downtime during rotation**
   - Renewal and rotation must occur transparently, without traffic interruption.

---

### 4.3 Performance & Scalability

1. **Low-latency secret retrieval**
   - Secret mounts or retrievals complete within seconds.
   - Certificate reload latency under 5 seconds.

2. **Scalability**
   - Support hundreds of certificates and tens of gateways per cluster.
   - Vault must scale horizontally to handle rotation load.

3. **Resource efficiency**
   - cert-manager, CSI, and sidecars must be lightweight and non-polling.

---

### 4.4 Maintainability & Operability

1. **Observability**
   - All components expose metrics (Prometheus/OpenTelemetry).
   - Dashboards show certificate status and vault access health.

2. **Alerting**
   - Alerts for expiring certificates, renewal failures, vault or mount errors.

3. **Operational simplicity**
   - Adding or rotating certificates must not require downtime or manual steps.

4. **Upgradeability**
   - Upgrades to Vault, cert-manager, or gateways must not invalidate certificates.

---

### 4.5 Resilience & Disaster Recovery

1. **Vault backup and recovery**
   - Use a durable backend (e.g., Raft) with periodic encrypted backups.

2. **Certificate re-issuance**
   - Must support rapid re-issuance if primary vault is lost.

3. **Cluster migration**
   - Moving workloads across clusters or clouds must not require re-keying.

---

### 4.6 Extensibility & Portability

1. **Multi-environment support**
   - Same model for local (Vault OSS) and production (AWS/GCP/Azure).

2. **Pluggable vault providers**
   - Vault abstraction via CSI or secret-provider interfaces.

3. **Interoperability**
   - Use only open standards: ACME (RFC 8555), PKCS#8, X.509, TLS 1.3+.

---

### 4.7 Usability & Developer Experience

1. **Declarative workflow**
   - Certificates, issuers, and vault bindings as declarative YAML managed through GitOps.

2. **Clear operational visibility**
   - Certificate status and validity visible via Kubernetes resources or dashboards.

3. **Minimal onboarding friction**
   - Adding a domain or service requires only simple declarative manifests.

---

### 4.8 Governance & Policy Enforcement

1. **Certificate policy enforcement**
   - Enforce key sizes, allowed issuers, and renewal intervals via policies.

2. **Expiration policy**
   - Automatic alerts and re-issuance before expiry.

3. **Audit reviews**
   - Logs support periodic compliance and security audits.

---

## 5. Summary

> The system must maintain strict security boundaries, operational reliability, and observability while delivering automated, zero-touch certificate lifecycle management.  
> It must remain fully open-source, vendor-neutral, and suitable for multi-environment deployments — ensuring that **private key material never persists outside trusted vault storage or in-memory execution contexts**.
