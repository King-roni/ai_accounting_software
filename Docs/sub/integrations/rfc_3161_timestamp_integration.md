# rfc_3161_timestamp_integration

**Category:** Integrations · **Owning block:** 05 — Security & Audit · **Co-owner:** 04 — Data Architecture · **Stage:** 4 sub-doc (Layer 1 cross-block integration)

External Timestamp Authority integration for audit hash-chain anchoring. Per Stage 1: "Audit log tamper resistance: Hash-chained log with periodic RFC 3161 third-party timestamping of chain heads."

The integration periodically takes a chain head hash, sends it to a third-party TSA, and stores the signed timestamp token. Verification at any future point proves the chain hash existed at the recorded time — even if the operator's own infrastructure is compromised.

---

## Protocol

RFC 3161 Time-Stamp Protocol (TSP) over HTTPS.

```
Request:  POST <tsa_url>
          Content-Type: application/timestamp-query
          Body: <ASN.1 DER-encoded TimeStampReq>

Response: 200 OK
          Content-Type: application/timestamp-reply
          Body: <ASN.1 DER-encoded TimeStampResp (PKCS#7/CMS-signed)>
```

The request carries the chain head hash; the response carries a signed timestamp token bound to that hash.

## TSA providers

Multiple providers as fallback chain:

| Priority | Provider | Notes |
| --- | --- | --- |
| 1 (primary) | EU-resident commercial TSA (e.g., DigiCert EU, GlobalSign EU, FreeTSA EU mirror) | Pin one EU TSA per Cyprus-domiciled compliance |
| 2 (secondary) | Backup EU TSA — different organization | For provider outages |
| 3 (free fallback) | Free TSA (`freetsa.org` or equivalent) | Best-effort when both commercial fail |

Per the cross-tenant alerting runbook, ops alerts fire on cascading TSA failures.

Per Stage 1: EU-residency rule means TSAs must be EU-domiciled. US-based TSAs are forbidden.

## Anchoring cadence

Per `audit_log_policies` Section 4:

| Chain | Default cadence | Rationale |
| --- | --- | --- |
| Global | Every 1 hour | High-value chain; frequent anchoring strengthens forensic guarantees |
| Per-organization | Every 6 hours | Mid-tier value; balances cost and security |
| Per-business | Every 24 hours | Most chains are low-volume; daily is sufficient for Cyprus VAT audit horizons |

Cadence is configurable per `key_rotation_runbook` shape (the runbook covers TSA rotation alongside key rotation).

## Storage

```sql
CREATE TABLE rfc_3161_timestamps (
  id                     uuid PRIMARY KEY DEFAULT gen_uuid_v7(),

  -- The chain head being anchored
  chain_id               text NOT NULL,                    -- 'global' | 'org:<uuid>' | 'business:<uuid>'
  sequence_number        bigint NOT NULL,
  chain_hash             text NOT NULL,                    -- the hex SHA-256 being anchored

  -- The TSA response
  tsa_url                text NOT NULL,                    -- which TSA fulfilled the request
  timestamp_token        bytea NOT NULL,                   -- the signed CMS token from the TSA
  timestamp_value        timestamptz NOT NULL,             -- the parsed time recorded by the TSA
  tsa_cert_chain         bytea NOT NULL,                   -- the TSA's certificate chain (for verification)

  -- Outcome
  status                 timestamp_status_enum NOT NULL,
  failure_message        text,

  -- Lifecycle
  requested_at           timestamptz NOT NULL DEFAULT now(),
  received_at            timestamptz,

  -- Index
  UNIQUE (chain_id, sequence_number, tsa_url)
);

CREATE TYPE timestamp_status_enum AS ENUM ('REQUESTED', 'RECORDED', 'FAILED');
```

The unique constraint allows multiple TSA anchors for the same `(chain_id, sequence_number)` — a chain head can be anchored at multiple TSAs for redundancy.

## Verification

Re-verifying a recorded timestamp:

1. Read the stored chain_hash, timestamp_token, tsa_cert_chain
2. Parse the timestamp_token (CMS/PKCS#7)
3. Verify the timestamp_token's signature against tsa_cert_chain
4. Verify tsa_cert_chain against a trusted root (configurable list)
5. Extract the `MessageImprint` from the timestamp_token; assert it equals the chain_hash
6. Extract the `genTime` from the timestamp_token; that's the proven moment

Any failure raises `AUDIT_CHAIN_TIMESTAMP_VERIFICATION_FAILED` (BLOCKING).

## Audit events

| Event | When |
| --- | --- |
| `TIMESTAMP_AUTHORITY_INVOKED` | Per TSA call |
| `TIMESTAMP_RECORDED` | Successful storage of the response |
| `TIMESTAMP_AUTHORITY_UNREACHABLE` | TSA failed; fallback engaged |
| `AUDIT_CHAIN_TIMESTAMP_VERIFICATION_FAILED` | Verification call detected tampering or invalid signature |

## Failure modes

| Failure | Behavior |
| --- | --- |
| Primary TSA unreachable | Fall back to secondary TSA |
| All TSAs unreachable | Chain advancement continues; anchoring retries on next cadence; alert |
| TSA returns invalid response | Treat as unreachable; fall back |
| TSA cert expired | Fall back; raise admin alert to update cert pinning |

Per Stage 1: anchoring is best-effort. A missed anchor does not block chain advancement. Multiple consecutive misses are escalated.

## Performance + cost

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| Single TSA round-trip | 500 ms | 2 s | 5 s |
| Anchor cadence overhead per chain | < 100 ms per cadence cycle | — | — |

Cost (commercial TSAs): ~$0.001-0.005 per timestamp request. Daily cost for 1000 businesses: ~$5 (per-business cadence).

## EU residency

The TSA must be EU-domiciled. The integration enforces an allowlist of acceptable TSA URLs (EU-only). Cert chain validation pins to EU CAs. Any TSA outside the allowlist fails at request-time.

## TSA rotation

Per `key_rotation_runbook`: TSA rotation procedure runs alongside annual cert rotation. New TSA provider added to allowlist before old one is removed; cadence covers both during transition; old TSA removed after retention window for that TSA's timestamps elapses.

## Cross-references

- `audit_log_policies` — hash-chain partitioning + emit-as-separate-transaction
- `tool_hash_chain_append` — chain advancement
- `archive_hash_anchor_integration` — archive manifests use same TSA infrastructure for archive-bundle anchoring
- `key_rotation_runbook` — TSA + cert rotation
- `cross_tenant_alerting_runbook` — TSA-cascading-failure alert path
- Block 05 Phase 03 — audit log tamper resistance (architecture)
- Stage 1 decision — RFC 3161 timestamping of chain heads
