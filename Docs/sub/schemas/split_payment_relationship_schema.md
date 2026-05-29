# split_payment_relationship_schema

**Category:** Schemas · **Owning block:** 04 — Data Architecture · **Co-owner:** 10 — Matching Engine · **Stage:** 4 sub-doc (Layer 1 cross-block schema)

The schema for split-payment groups — when one payment covers multiple invoices, or when multiple payments add up to cover one invoice. Per Stage 1 decision: "Split-payment detection: Proactive — engine attempts combinations of unmatched invoices that sum to the transaction amount, surfaces candidates as review issues for user confirmation."

The schema introduces `split_payment_groups` as a first-class entity that match_records reference via `split_payment_group_id`. Per Block 10 Phase 04's combinatorial detection.

---

## Tables

### `split_payment_groups`

```sql
CREATE TYPE split_payment_pattern_enum AS ENUM (
  'ONE_PAYMENT_MANY_INVOICES',                   -- single transaction covers multiple invoices
  'MANY_PAYMENTS_ONE_INVOICE'                    -- multiple transactions add up to one invoice
);

CREATE TYPE split_payment_group_status_enum AS ENUM (
  'PROPOSED',                                    -- engine proposed; awaiting user confirmation
  'CONFIRMED',                                   -- user confirmed
  'REJECTED'                                     -- user rejected
);

CREATE TABLE split_payment_groups (
  id                          uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id                 uuid NOT NULL REFERENCES business_entities(id),
  workflow_run_id             uuid NOT NULL REFERENCES workflow_runs(workflow_run_id),

  -- Pattern
  pattern                     split_payment_pattern_enum NOT NULL,

  -- Status
  status                      split_payment_group_status_enum NOT NULL DEFAULT 'PROPOSED',

  -- The "single" side of the relationship
  parent_target_kind          text NOT NULL,                  -- 'transactions' | 'documents' (or invoices)
  parent_target_id            uuid NOT NULL,                  -- FK to the single transaction OR the single invoice

  -- The "multiple" side — tracked via match_records.split_payment_group_id

  -- Computed metadata
  member_count                integer NOT NULL DEFAULT 0,     -- maintained by trigger
  total_member_amount_eur_cents bigint NOT NULL DEFAULT 0,    -- maintained by trigger
  parent_amount_eur_cents     bigint NOT NULL,                -- denormalised from parent

  -- Lifecycle
  proposed_at                 timestamptz NOT NULL DEFAULT now(),
  resolved_at                 timestamptz,
  resolved_by_user_id         uuid REFERENCES users(id),

  -- Constraints
  CHECK (
    -- ONE_PAYMENT_MANY_INVOICES: parent is a transaction
    (pattern != 'ONE_PAYMENT_MANY_INVOICES') OR (parent_target_kind = 'transactions')
  ),
  CHECK (
    -- MANY_PAYMENTS_ONE_INVOICE: parent is an invoice (or document)
    (pattern != 'MANY_PAYMENTS_ONE_INVOICE') OR (parent_target_kind IN ('invoices', 'documents'))
  )
);
```

### Column on `match_records` (referenced from `match_records_schema`)

```sql
split_payment_group_id  uuid REFERENCES split_payment_groups(id)
```

A match record participates in a split-payment group when this column is non-NULL. The match record represents one member of the group:

- For `ONE_PAYMENT_MANY_INVOICES`: each match record connects the single payment transaction to one of the multiple invoices
- For `MANY_PAYMENTS_ONE_INVOICE`: each match record connects one of the multiple payment transactions to the single invoice

## Member-count maintenance

Per Block 04 Phase 03: `member_count` and `total_member_amount_eur_cents` are maintained by triggers on `match_records`:

```sql
CREATE OR REPLACE FUNCTION update_split_payment_group_metadata() RETURNS TRIGGER AS $$
BEGIN
  IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') AND NEW.split_payment_group_id IS NOT NULL THEN
    UPDATE split_payment_groups
       SET member_count = (
             SELECT COUNT(*) FROM match_records
             WHERE split_payment_group_id = NEW.split_payment_group_id
               AND match_status NOT IN ('REJECTED', 'SUPERSEDED')
           ),
           total_member_amount_eur_cents = (
             SELECT COALESCE(SUM(matched_amount_eur_cents), 0) FROM match_records
             WHERE split_payment_group_id = NEW.split_payment_group_id
               AND match_status NOT IN ('REJECTED', 'SUPERSEDED')
           )
     WHERE id = NEW.split_payment_group_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_match_records_update_split_group
  AFTER INSERT OR UPDATE ON match_records
  FOR EACH ROW EXECUTE FUNCTION update_split_payment_group_metadata();
```

## Lifecycle and status

```
PROPOSED → CONFIRMED
PROPOSED → REJECTED
```

- `PROPOSED` — Block 10 Phase 04's combinatorial detection found a candidate set; raises `matching.split_payment_proposed` review issue per `issue_type_to_group_mapping`
- `CONFIRMED` — user clicks "Confirm" on the proposed group; all member match_records transition to CONFIRMED in one transaction; emits `SPLIT_PAYMENT_GROUP_CONFIRMED`
- `REJECTED` — user clicks "Reject"; all member match_records transition to REJECTED; emits `SPLIT_PAYMENT_GROUP_REJECTED`

No transitions back from CONFIRMED or REJECTED in MVP. Re-evaluation requires creating a new group (after the previous CONFIRMED group is superseded via adjustment).

## Pattern A vs Pattern B exclusion rule

Per the Block 10 scan fix: when scoring a new candidate match, only `PROPOSED` and `CONFIRMED` split-payment groups confer exclusion (the candidates already committed to a group can't be re-suggested elsewhere). `REJECTED` groups do not.

```sql
-- Excluded from re-suggestion:
SELECT DISTINCT mr.document_id
FROM match_records mr
WHERE mr.split_payment_group_id IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM split_payment_groups spg
    WHERE spg.id = mr.split_payment_group_id
      AND spg.status IN ('PROPOSED', 'CONFIRMED')
  );
```

## Combinatorial bounds (Block 10 Phase 04)

Per `split_payment_combinatorial_bounds` (Reference data, Block 10):

- Maximum group size: 5 invoices in a single transaction match (Pattern A); 5 transactions matching one invoice (Pattern B)
- Maximum candidate set search: 20 candidates per transaction; bounded combinatorial search
- Per-business override deferred to Stage 2+ via `split_payment_idempotency_policy` (Block 10) — the merge into `custom_tag_policies` cross-references

## Indexes

```sql
CREATE INDEX idx_split_payment_groups_business_status
  ON split_payment_groups(business_id, status)
  WHERE status = 'PROPOSED';

CREATE INDEX idx_split_payment_groups_parent
  ON split_payment_groups(parent_target_kind, parent_target_id);

-- On match_records (declared in match_records_schema but listed here for context):
CREATE INDEX idx_match_records_split_group
  ON match_records(split_payment_group_id)
  WHERE split_payment_group_id IS NOT NULL;
```

## Audit events

| Event | When |
| --- | --- |
| `SPLIT_PAYMENT_GROUP_PROPOSED` | Block 10 Phase 04 creates a group |
| `SPLIT_PAYMENT_GROUP_CONFIRMED` | User confirms |
| `SPLIT_PAYMENT_GROUP_REJECTED` | User rejects |
| `SPLIT_PAYMENT_GROUP_STATUS_CHANGED` | Fallback for transitions not covered by the named events (per Block 10 Phase 01 audit list — generic catch-all that fires only when no named event matches) |

Per Stage 2 Block 10 scan: named events take precedence; the generic event fires only when no named event applies.

## RLS

Tenant isolation per `permission_matrix`. View open via `REVIEW_QUEUE_VIEW` for all business roles; confirm/reject via `REVIEW_QUEUE_RESOLVE`.

## Cross-references

- `data_layer_conventions_policy` — UUID v7 for `split_payment_group_id`; canonical JSON for any group-metadata payloads
- `match_records_schema` — host table with `split_payment_group_id` column
- `split_payment_review_issue_payload_schema` (Block 10) — review-issue payload shape
- `split_payment_combinatorial_bounds` (Block 10) — combinatorial limits
- `audit_log_policies` — `SPLIT_PAYMENT_GROUP_*` events
- `issue_type_to_group_mapping` — `matching.split_payment_proposed` routing
- `resolution_action_enum` — `confirm_match` / `reject_match` actions
- Block 04 Phase 03 — split_payment_group_id semantics (architecture)
- Block 10 Phase 04 — split-payment combinatorial detection
- Stage 1 decision — proactive split-payment detection
