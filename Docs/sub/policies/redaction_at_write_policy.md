# redaction_at_write_policy

**Category:** Policies · **Owning block:** 04 — Data Architecture · **Co-owner:** 06 — AI Layer · **Stage:** 4 sub-doc (Layer 1 cross-block policy)

The AI Privacy Gateway is the **sole writer** of `AI_PAYLOAD_REDACTED` records in the Processing zone. Per `gateway_bypass_detection_policy`: every AI call flows through the gateway; the gateway applies redaction per `redaction_policies`; the gateway-written record is the canonical post-redaction artefact.

This policy pins: the single-writer rule, the Processing-zone artefact pattern, the audit emission, and the consumer contract.

---

## The single-writer rule

```
Tier 2 / Tier 3 AI call
  ↓
AI Privacy Gateway
  ↓ apply redaction (per redaction_policies)
  ↓
INSERT INTO processing_zone.ai_payload_redacted (
  workflow_run_id,
  tool_invocation_id,
  business_id,
  original_payload_hash,                          -- hash of the pre-redaction input (audit forensic only)
  redacted_payload_json,                          -- the redacted form sent to the AI provider
  redaction_policy_version,                       -- e.g., "1.4.0" per redaction_policies
  redacted_at,
  dropped_field_paths                             -- list of fields the redactor dropped
)
```

ONLY the gateway writes here. No phase doc, no tool, no operator action writes directly. Per `gateway_bypass_detection_policy`: bypass detection includes a check for direct writes to this table — any non-gateway writer is rejected.

## Why a separate Processing-zone table

The redacted payload is what was actually sent to the AI provider. It's the audit-relevant record:

- Forensic queries reconstruct "what data did this business expose to Tier 3?"
- Operator queries verify redaction is working (the redacted form should NOT contain PII)
- Test fixtures replay redacted payloads to validate cache behavior per `ai_response_recording_fixtures`

The Processing zone (per `archive_schema`) is the right home — it's a working zone separate from the operational data and separate from the finalized archive.

## RLS

```sql
CREATE POLICY ai_payload_redacted_read ON processing_zone.ai_payload_redacted
  FOR SELECT
  USING (
    business_id = ANY (auth.business_ids_for_session())
    AND auth.has_surface(business_id, 'BUSINESS_SETTINGS_EDIT')
  );

CREATE POLICY ai_payload_redacted_write ON processing_zone.ai_payload_redacted
  FOR INSERT
  USING (
    -- Only the gateway-bound role can insert
    current_setting('app.ai_gateway_active', true) = 'true'
  );

CREATE POLICY ai_payload_redacted_no_update ON processing_zone.ai_payload_redacted
  FOR UPDATE
  USING (false);                                  -- never updateable

CREATE POLICY ai_payload_redacted_delete ON processing_zone.ai_payload_redacted
  FOR DELETE
  USING (current_setting('app.retention_engine_active', true) = 'true');
```

Per `data_layer_conventions_policy` — the session-variable gating mirrors `archive_schema`'s `app.original_lock_active` pattern. Only the gateway code path sets `app.ai_gateway_active = 'true'` for the duration of its work.

## Audit events

| Event | When |
| --- | --- |
| `AI_PAYLOAD_REDACTED` | One row inserted per AI gateway call (after redaction completes, before provider dispatch) |
| `AI_REDACTION_ALLOWLIST_DROP` | Per dropped field (per `redaction_policies`) |
| `AI_REDACTION_VALIDATION_FAILED` | Post-redaction schema validation failed |

Aggregated per `audit_log_policies` aggregation rule when many calls fire in one workflow run.

## Retention

Per `retention_policies_schema`: Processing-zone rows retain for 7 days after run completion or cancellation. The `ai_payload_redacted` rows are subject to the same retention.

For records inside an active workflow run: retention is deferred until the run completes (the run's resumability framework per Block 03 Phase 07 may need to replay the redacted payload).

For records associated with a finalized period: the redacted payload is included in the archive bundle per `archive_bundle_layout_schema` (the "ai_invocations.json" file inside the bundle). The Processing-zone record can then be retention-deleted; the bundle preserves the audit-forensic copy.

## Consumer contract

Downstream consumers (test fixtures, audit queries, operator investigations) read `ai_payload_redacted` to understand what the AI saw:

| Consumer | Use |
| --- | --- |
| `ai_response_recording_fixtures` test runner | Match recorded payloads against fresh requests (deterministic replay) |
| Block 16 audit drill-down | Show "what was sent to AI" for forensic transparency |
| Operator investigation per `cross_tenant_alerting_runbook` | Verify redaction in real incidents |

The consumer never SEES the original PII — only the redacted form is reachable. This is the privacy guarantee.

## Cross-business safety

Per `cross_tenant_key_isolation_policy` (now part of `audit_log_policies` cross-references): a query scoped to business A never returns rows for business B. RLS enforces this.

A misconfigured query that asks for cross-business `ai_payload_redacted` returns the empty set. The gateway never writes rows mis-attributed to a wrong business.

## Cross-references

- `redaction_policies` — redaction allowlist + versioning
- `gateway_bypass_detection_policy` — single-writer enforcement
- `ai_cache_policies` (consolidated) — cache key includes `redaction_policy_version`
- `ai_response_recording_fixtures` — recording consumer
- `archive_bundle_layout_schema` — finalized archive consumer
- `audit_log_policies` — `AI_*` event family
- `retention_policies_schema` — retention behavior
- `processing_zone_ttl_policy` (now part of Block 04 policies) — Processing-zone retention
- Block 04 Phase 06 — Processing zone (architecture)
- Block 06 Phase 02 — gateway pipeline (writer)
- Block 06 Phase 03 — redaction policy & engine
- Block 06 Phase 07 — AI usage logging & cost tracking

---

## Enforcement examples — before/after redaction

The redaction engine processes the AI input payload before it is dispatched to the Tier 2 or Tier 3 provider. The following examples show the transformation for common PII fields.

**Example 1 — Transaction classification payload:**

Before redaction (raw payload):
```json
{
  "transaction_id": "txn_01J2...",
  "amount_eur_cents": 85000,
  "counterparty_name": "ACME Ltd",
  "counterparty_iban": "GB29NWBK60161331926819",
  "description": "Invoice 2026-042 from ACME Ltd, IBAN GB29NWBK60161331926819",
  "transaction_date": "2026-04-15"
}
```

After redaction (`redacted_payload_json`):
```json
{
  "transaction_id": "[REDACTED:UUID]",
  "amount_eur_cents": 85000,
  "counterparty_name": "[REDACTED:COMPANY_NAME]",
  "counterparty_iban": "[REDACTED:IBAN]",
  "description": "Invoice 2026-042 from [REDACTED:COMPANY_NAME], IBAN [REDACTED:IBAN]",
  "transaction_date": "2026-04-15"
}
```

`dropped_field_paths`: `["counterparty_name", "counterparty_iban", "description.counterparty_name", "description.iban"]`

`amount_eur_cents` and `transaction_date` are NOT redacted — they are required for classification accuracy and are not PII per `redaction_policies`.

**Example 2 — Document OCR payload (partial):**

Before redaction: the document contains a full name, address, and VAT number in the extracted text.

After redaction: name → `[REDACTED:PERSON_NAME]`, address → `[REDACTED:ADDRESS]`, VAT number → `[REDACTED:VAT_NUMBER]`.

The VAT number is redacted from the payload sent to Tier 3 AI (where the task is classification, not validation). The VAT number is separately validated via VIES (a distinct, purpose-scoped call). The redaction policy version is stored alongside the redacted payload so forensic review can reconstruct which fields were masked under which version.

---

## Gateway-bypass detection cross-reference

The redaction write (INSERT into `processing_zone.ai_payload_redacted`) is itself a signal that the gateway executed correctly. If a gateway bypass occurred, no row is inserted. The bypass detection policy (`gateway_bypass_detection_policy`) includes a negative check: if a tool that declares `LOCAL` or `EXTERNAL` tier completes without a corresponding `ai_payload_redacted` row being written, this is a potential bypass and raises `AI_PRIVACY_GATEWAY_BYPASS_DETECTED`.

---

## Failure modes

**Case 1: Redaction engine fails before provider dispatch**

The redaction library throws an exception during field masking (e.g., an unrecognized PII pattern type in a new `redaction_policies` version). Behavior:

- The gateway ABORTS the AI call entirely; the payload is NOT sent to the provider
- The `ai_payload_redacted` row is NOT inserted (no partial-redaction record)
- Audit event `AI_REDACTION_VALIDATION_FAILED` is emitted with `reason = redaction_engine_exception` and the tool invocation ID
- The calling tool receives an `AI_TIER_UNAVAILABLE` error with `reason = REDACTION_FAILED`
- The workflow phase handles this as a tool failure; depending on phase retry policy, it may retry or raise a review issue

The write ABORTS — the gateway never sends a partially-redacted payload to a provider.

**Case 2: Post-redaction schema validation fails**

The redacted payload fails the output-schema validation check (the redacted form has a structural issue the original didn't). Behavior:

- Same abort path as Case 1
- Audit event `AI_REDACTION_VALIDATION_FAILED` with `reason = schema_validation_failure` and the specific schema violation
- No dispatch to provider

**Case 3: `ai_payload_redacted` INSERT fails (database error)**

If the INSERT itself fails after redaction succeeds:

- The gateway ABORTS and does NOT dispatch to the provider (consistency: dispatch is always preceded by a committed row)
- The tool receives `AI_TIER_UNAVAILABLE` with `reason = AUDIT_WRITE_FAILED`
- Retries per the calling phase's retry policy may succeed if the database issue is transient

The invariant is: the `ai_payload_redacted` row exists before any provider call. No row → no dispatch. This is enforced within the gateway transaction boundary.

---

## Additional cross-references

- `gateway_bypass_detection_policy` — single-writer enforcement and bypass detection logic
