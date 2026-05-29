# Hash Chain Verification Policy

**Category:** Policies · Block 05 — Security & Audit  
**Owner:** security  
**Last updated:** 2026-05-16

---

## 1. Purpose

This policy defines the structure of the audit log hash chain, how it is verified, when verification runs, and the response procedure when tampering is detected.

---

## 2. Chain Structure

Each row in the `audit_log` table contains a `chain_hash` column computed as:

```
chain_hash = SHA-256(
  prev_chain_hash
  || event_id
  || event_name
  || payload_canonical_json
  || occurred_at::text
)
```

Where:
- `prev_chain_hash` is the `chain_hash` of the immediately preceding row in `chain_sequence` order for the same `business_id`.
- `||` denotes concatenation of UTF-8 encoded strings.
- `payload_canonical_json` is the deterministic JSON serialization (keys sorted lexicographically, no extra whitespace) of the event payload.
- The first row in a chain has `prev_chain_hash` set to the null-hash sentinel: 64 ASCII zeros (`"0000000000000000000000000000000000000000000000000000000000000000"`).

The `chain_hash` is computed and written by `security.append_audit_event` (documented in `tool_hash_chain_append.md`) inside the same database transaction as the audit event insert.

---

## 3. Full Chain Verification

Full chain verification walks all `audit_log` rows for a given `business_id` in ascending `chain_sequence` order and recomputes each hash.

Algorithm:
```
prev_hash = null_sentinel
for each row r in ORDER BY chain_sequence ASC:
    expected = SHA-256(prev_hash || r.event_id || r.event_name
                       || r.payload_canonical_json || r.occurred_at::text)
    if expected != r.chain_hash:
        return { verified: false, first_broken_at_sequence: r.chain_sequence, ... }
    prev_hash = r.chain_hash
return { verified: true, first_broken_at_sequence: null, rows_checked: N }
```

A mismatch at sequence N indicates one of:
- Row N was modified after insertion.
- A row was deleted between N-1 and N (causing N's `prev_chain_hash` input to be wrong).
- Row N was inserted out of order.

---

## 4. Incremental Verification

During finalization, full chain verification for the entire business history is expensive. Incremental verification covers only rows associated with the current `workflow_run_id`:

1. Retrieve the `chain_hash` of the row immediately preceding the first run row (the anchor).
2. Walk only the run's rows in `chain_sequence` order.
3. Verify each hash using the anchor as the starting `prev_chain_hash`.

Incremental verification is sufficient for per-period integrity proofs included in the accountant pack. It does not detect tampering outside the current run's rows; full verification is used for forensic investigations.

---

## 5. Verification Tool

`archive.verify_hash_chain` is the authorised tool for both full and incremental verification.

**Parameters:**
- `business_id` (required)
- `workflow_run_id` (optional — if provided, performs incremental verification)
- `mode` (`FULL` | `INCREMENTAL`)

**Return type:**
```typescript
{
  verified: boolean,
  first_broken_at_sequence: integer | null,
  rows_checked: integer,
  verification_mode: 'FULL' | 'INCREMENTAL',
  verified_at: timestamptz
}
```

The verification result is itself appended to the audit log via `security.append_audit_event`, creating a verifiable record that verification occurred.

---

## 6. When Verification Runs

Verification is triggered in three scenarios:

| Scenario | Mode | Tool |
|----------|------|------|
| Every `FINALIZING` phase entry | INCREMENTAL | `engine.finalize_run` calls it automatically |
| On demand by ADMIN | FULL or INCREMENTAL | Via `archive.verify_hash_chain` with step-up auth |
| On receipt of `SECURITY_HASH_CHAIN_TAMPER_DETECTED` | FULL | Automated forensic response (see section 8) |

The on-demand path requires step-up authentication (`archive_step_up_policy.md`) and is documented in `tamper_detection_forensic_runbook.md`.

---

## 7. RLS Guarantee

The `audit_log` table has two layers of tamper protection:

**Layer 1 — INSERT-only RLS:**
- `audit_log` has no UPDATE or DELETE RLS policies.
- Even `service_role` connections cannot UPDATE or DELETE rows.
- The only permitted write operation is INSERT via `security.append_audit_event`.
- Any attempt to UPDATE or DELETE returns a policy-denied error and emits an alert.

**Layer 2 — Hash chain:**
- Even if a row were somehow modified (e.g., direct database access bypassing RLS), the hash chain would break at that row.
- Detection is guaranteed provided at least one verified snapshot of the chain tip is preserved (e.g., in the archive bundle's `hash_chain_tip` field).

The combination of INSERT-only RLS and the hash chain means tampering requires both bypassing the RLS policy and either re-computing the entire downstream chain or going undetected until the next verification run.

---

## 8. Tamper Response

If `archive.verify_hash_chain` returns `verified: false`:

1. `SECURITY_HASH_CHAIN_TAMPER_DETECTED` (BLOCKING) is emitted immediately.
2. The current workflow run transitions to `FAILED` with `failure_reason = 'HASH_CHAIN_TAMPER'`.
3. The period cannot be finalized until the incident is resolved.
4. The operator is notified via the alerting pipeline.
5. The forensic runbook (`tamper_detection_forensic_runbook.md`) is initiated.
6. `first_broken_at_sequence` is used to determine the earliest potentially compromised event.

No automated recovery is possible. Resolution requires human investigation and is documented in `accountant_pack_tamper_runbook.md`.

---

## 9. Tools

| Tool | Action |
|------|--------|
| `archive.verify_hash_chain` | Runs full or incremental hash chain verification |
| `security.append_audit_event` | Appends audit event and computes chain_hash |

All `archive` WRITE tools: see `mobile_write_rejection_endpoints.md` — write operations are rejected on mobile clients.

---

## 10. Audit Events

| Event | Severity | Trigger |
|-------|----------|---------|
| `SECURITY_HASH_CHAIN_VERIFIED` | LOW | Verification completed successfully |
| `SECURITY_HASH_CHAIN_TAMPER_DETECTED` | BLOCKING | Verification found hash mismatch |

---

## 11. Cross-References

- `tool_hash_chain_append.md`
- `tool_emit_audit.md`
- `tamper_detection_forensic_runbook.md`
- `accountant_pack_tamper_runbook.md`
- `audit_log_policies.md`
- `archive_step_up_policy.md`
- `mobile_write_rejection_endpoints.md`
