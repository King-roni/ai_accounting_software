# rejection_memory_schema

**Category:** Schemas · **Owning block:** 10 — Matching Engine · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the `match_rejection_memory` table that permanently records every user-rejected `(transaction, document)` match pair. Per the Stage 1 decision: "Remember forever for the same (transaction, document) pair; never re-suggest a pair the user has rejected." Rejection memory is pair-scoped — rejecting one pair does not suppress either entity's participation in other pairs. Records are never deleted in MVP.

---

## Table definition

```sql
CREATE TABLE match_rejection_memory (
  rejection_id                  uuid        PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id                   uuid        NOT NULL REFERENCES business_entities(id),
  transaction_id                uuid        NOT NULL REFERENCES transactions(transaction_id),
  document_id                   uuid        NOT NULL REFERENCES documents(document_id),
  rejected_by_user_id           uuid        NOT NULL REFERENCES users(id),
  rejected_at                   timestamptz NOT NULL DEFAULT now(),
  rejection_reason              text        CHECK (char_length(rejection_reason) <= 500),
  original_match_record_id      uuid        REFERENCES match_records(match_record_id),
  is_active                     boolean     NOT NULL DEFAULT true,

  -- One memory record per (business, transaction, document) triplet
  CONSTRAINT uq_rejection_memory_pair
    UNIQUE (business_id, transaction_id, document_id)
);
```

### Column notes

- `rejection_id` — UUID v7 per `data_layer_conventions_policy §2`.
- `business_id` — explicit tenant column for RLS. The `(business_id, transaction_id, document_id)` triplet is the unique constraint key; `business_id` is included for safety even though `transaction_id` and `document_id` already imply a single business. Cross-business ID collision on UUID v7 is theoretically impossible but the explicit tenant column is required by the RLS pattern.
- `rejection_reason` — free text, maximum 500 characters; nullable. The review queue encourages but does not require a reason. Common reasons ("wrong supplier", "wrong amount", "different period", "already matched elsewhere", "other") are provided as a picklist by the UI; the selected value is stored as plain text.
- `original_match_record_id` — nullable FK to `match_records`. Populated when the rejection originates from an existing scored pair; null when the rejection is recorded from the "edit and confirm" path where no `match_records` row existed. The `match_records` row is preserved for audit traceability even after rejection (its `match_status` transitions to `REJECTED`); the FK here is informational only and is not cascade-deleted.
- `is_active` — soft-inactivation flag used by the privileged override path (Block 10 Phase 06). Setting `is_active = false` removes the pair from the suppression lookup, effectively allowing re-suggestion. This is an Owner-only, step-up-authenticated action. The record is never physically deleted.

### Upsert-on-re-rejection semantics

The unique constraint `(business_id, transaction_id, document_id)` means a pair can have exactly one memory record. If a user rejects the same pair a second time (after a privileged override re-activated it), the insertion uses `ON CONFLICT (business_id, transaction_id, document_id) DO UPDATE SET rejected_by_user_id = EXCLUDED.rejected_by_user_id, rejected_at = EXCLUDED.rejected_at, rejection_reason = EXCLUDED.rejection_reason, is_active = true`. This preserves the original record's `rejection_id` and history while updating to the latest rejection actor.

---

## Retention policy

Records are never deleted in MVP. Per the Stage 1 decision, the forever-remember guarantee is a core correctness property: users should not be surprised by re-suggestions of pairs they have previously rejected.

**Archival:** When Block 15 finalizes a period, all `match_rejection_memory` rows whose `transaction_id` belongs to that period are included in the archive bundle manifest for auditability. The rows remain in the live table — archival is an export copy, not a move. This ensures the suppression lookup continues to work for cross-period matching (Block 10's ±1–2 month lookback window).

**Retention window:** Governed by the standard 6-year retention window for business data (per Block 04 Data Architecture). After the retention window expires, records may be purged under the retention engine's standard deletion path. No early deletion is permitted.

---

## Suppression lookup

The scoring engine (Block 10 Phase 02) performs the following check before computing signals for any `(transaction_id, document_id)` pair:

```sql
SELECT rejection_id
FROM match_rejection_memory
WHERE business_id = $1
  AND transaction_id = $2
  AND document_id = $3
  AND is_active = true
LIMIT 1;
```

If a row is returned, the pair is suppressed: no score is computed, no `match_records` row is created, no review issue is raised, and `MATCHING_REJECTION_SUPPRESSED` is emitted (declared in Block 10 Phase 02 / taxonomy via this sub-doc's taxonomy amendment).

The lookup uses the `(business_id, transaction_id, document_id)` unique constraint index, making it an index-only scan with O(1) per-pair cost.

---

## Pair-scoped semantics

Rejection is strictly scoped to the `(transaction_id, document_id)` pair:

- Rejecting `(txn1, doc1)` does NOT suppress `(txn2, doc1)`. `doc1` remains a candidate for other transactions.
- Rejecting `(txn1, doc1)` does NOT suppress `(txn1, doc2)`. `txn1` remains scored against other documents.
- No "reject all documents for this transaction" or "reject all transactions for this document" bulk-rejection path exists in MVP.

---

## Privileged override

The Owner-only override path (Block 10 Phase 06) sets `is_active = false` on a memory record, requiring step-up authentication (Block 02 Phase 06). The override is audit-logged as `MATCHING_REJECTION_OVERRIDDEN_PRIVILEGED` with the overriding user ID and a mandatory reason text. After inactivation, the pair re-enters the scoring pool on the next workflow run.

`Admin` is intentionally excluded from this action (Stage 1 decision per Block 10 Phase 06): the "rejection-is-permanent" guarantee requires the highest accountable role (Owner) to override. Stage 2+ may revisit this scope.

---

## Indexes

```sql
-- Transaction-direction lookup (used by scoring engine pre-check)
CREATE INDEX idx_rejection_memory_transaction
  ON match_rejection_memory (business_id, transaction_id)
  WHERE is_active = true;

-- Document-direction lookup (used by document-side suppression check)
CREATE INDEX idx_rejection_memory_document
  ON match_rejection_memory (business_id, document_id)
  WHERE is_active = true;

-- Active-pair suppression lookup (primary hot path)
-- Covered by the unique constraint index on (business_id, transaction_id, document_id)
-- The unique index serves double duty as the hot-path index.

-- Audit/export lookup for period finalization
CREATE INDEX idx_rejection_memory_transaction_created
  ON match_rejection_memory (transaction_id, rejected_at);
```

---

## RLS

```sql
CREATE POLICY rejection_memory_isolation ON match_rejection_memory
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

---

## Audit event

| Event | When | Severity |
|---|---|---|
| `MATCHING_REJECTION_RECORDED` | New rejection memory record written (or upserted on re-rejection) | LOW |

Emitted via `emitAudit()` per `audit_log_policies`. Exists in `audit_event_taxonomy`.

`MATCHING_REJECTION_SUPPRESSED` (emitted by the scoring engine when a pair is skipped due to an active memory record) and `MATCHING_REJECTION_OVERRIDDEN_PRIVILEGED` (emitted by the privileged override path) are declared in Block 10 Phase 02 and Phase 06 respectively and catalogued in `audit_event_taxonomy` as part of this sub-doc's taxonomy amendments.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK
- `audit_log_policies` — `MATCHING_*` domain; `<DOMAIN>_<PAST_VERB>` naming
- `audit_event_taxonomy` — `MATCHING_REJECTION_RECORDED`, `MATCHING_REJECTION_SUPPRESSED`, `MATCHING_REJECTION_OVERRIDDEN_PRIVILEGED`
- `match_level_enum` — the 4-value closed enum; match level of the original proposed pair is preserved on `match_records` (FK via `original_match_record_id`), not duplicated here
- Block 04 Phase 03 — `match_records` table (`original_match_record_id` FK target)
- Block 10 Phase 01 — matching schema foundation (declares this table)
- Block 10 Phase 02 — scoring engine (suppression lookup)
- Block 10 Phase 06 — rejection memory operational flow and privileged override path
- Block 15 Phase 04 — period finalization (archive bundle includes rejection memory rows for the period)
- `tool_naming_convention_policy` — `matching.*` namespace for all tools referencing this schema
