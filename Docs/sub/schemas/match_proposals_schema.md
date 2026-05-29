# Schema: match_proposals (Reference)

**Block:** Matching
**Layer:** 2 — Sub-Doc
**Status:** Reference Alias

## Overview

The canonical schema for the `match_proposals` table is defined in `match_proposal_schema.md`. This file (`match_proposals_schema.md`) exists because several documents in the corpus use the plural form of the filename as a forward reference. All authoritative DDL, index definitions, RLS policies, business rules, and audit events are in `match_proposal_schema.md`.

Read `match_proposal_schema.md` for the complete schema definition.

---

## Canonical Reference

`match_proposal_schema.md` — authoritative DDL, indexes, RLS, audit events, and business rules for the `match_proposals` table.

---

## Read-Only Column Summary

The following table is a read-only summary of the key columns in `match_proposals`. It is reproduced here for quick reference only. Do not use this summary as the source of truth for integration work — always consult `match_proposal_schema.md`.

| Column | Type | Nullable | Description |
|---|---|---|---|
| `id` | UUID | No | PK, generated with `gen_uuid_v7()`. |
| `run_id` | UUID | No | FK to `workflow_runs(id)`. The workflow run in which this proposal was created. ON DELETE RESTRICT. |
| `transaction_id` | UUID | No | FK to `transactions(id)`. The transaction being proposed for matching. ON DELETE RESTRICT. |
| `invoice_id` | UUID | Yes | FK to `invoices(id)`. NULL for NO_MATCH proposals. ON DELETE RESTRICT. |
| `match_level` | match_level_enum | No | EXACT, STRONG_PROBABLE, WEAK_POSSIBLE, or NO_MATCH. |
| `composite_score` | DECIMAL(5,4) | No | Aggregated confidence score, 0.0000–1.0000. |
| `score_breakdown` | JSONB | No | Per-signal score components. Populated by the scoring engine. |
| `status` | match_status_enum | No | Current proposal status. Default PROPOSED. |
| `proposed_at` | TIMESTAMPTZ | No | When the proposal was created by the matching engine. |
| `confirmed_at` | TIMESTAMPTZ | Yes | When status transitioned to CONFIRMED or AUTO_CONFIRMED. |
| `confirmed_by` | UUID | Yes | FK to `auth.users(id)`. NULL for AUTO_CONFIRMED. |
| `rejection_reason` | TEXT | Yes | Human-entered reason when status = REJECTED. |
| `rejected_at` | TIMESTAMPTZ | Yes | When status transitioned to REJECTED. |
| `rejected_by` | UUID | Yes | FK to `auth.users(id)`. NULL if rejected by system. |
| `created_at` | TIMESTAMPTZ | No | Row creation timestamp. |

---

## Enum Definitions (Summary)

Both enums are defined in `match_proposal_schema.md`. Reproduced here for reference.

```sql
CREATE TYPE match_level_enum AS ENUM (
  'EXACT',
  'STRONG_PROBABLE',
  'WEAK_POSSIBLE',
  'NO_MATCH'
);

CREATE TYPE match_status_enum AS ENUM (
  'PROPOSED',
  'CONFIRMED',
  'REJECTED',
  'AUTO_CONFIRMED',
  'SUPERSEDED',
  'EXCEPTION_DOCUMENTED'
);
```

`match_level_enum` reflects the confidence band of the proposal. `match_status_enum` reflects the lifecycle state of the proposal row.

---

## Status Transition Summary

| From | To | Actor |
|---|---|---|
| PROPOSED | AUTO_CONFIRMED | System (EXACT match above auto-confirm threshold) |
| PROPOSED | CONFIRMED | Human reviewer |
| PROPOSED | REJECTED | Human reviewer or system (NO_MATCH assignment) |
| PROPOSED | SUPERSEDED | System (when a newer proposal for the same transaction replaces this one) |
| CONFIRMED | EXCEPTION_DOCUMENTED | Human (post-confirmation exception annotation) |
| AUTO_CONFIRMED | EXCEPTION_DOCUMENTED | Human (post-auto-confirm exception annotation) |

REJECTED and SUPERSEDED are terminal. EXCEPTION_DOCUMENTED is terminal. CONFIRMED and AUTO_CONFIRMED are active terminal states for matching purposes but may be annotated.

---

## Key Constraints (Summary)

- Only one active (non-SUPERSEDED, non-REJECTED) proposal may exist per transaction per run. Enforced by a partial unique index in `match_proposal_schema.md`.
- `invoice_id` must be NULL when `match_level = 'NO_MATCH'`.
- `composite_score` must be in the range [0, 1].
- `confirmed_at` must be set when status is CONFIRMED or AUTO_CONFIRMED.
- `rejected_at` must be set when status is REJECTED.

---

## Index Summary

The following indexes are defined in `match_proposal_schema.md`:

| Index | Columns | Condition |
|---|---|---|
| Primary key | `id` | — |
| run_id lookup | `run_id` | — |
| transaction_id lookup | `transaction_id` | — |
| invoice_id lookup | `invoice_id` | WHERE invoice_id IS NOT NULL |
| Active proposals per transaction | `(run_id, transaction_id)` | WHERE status NOT IN ('REJECTED', 'SUPERSEDED') — partial unique |
| Status filter | `(run_id, status)` | — |
| Match level filter | `(run_id, match_level)` | — |

---

## Row-Level Security (Summary)

RLS is enabled on `match_proposals`. The select policy restricts rows to the `business_entity_id` of the authenticated JWT, enforced via the `run_id` → `workflow_runs` → `business_entity_id` join. Writes are service-role only. See `match_proposal_schema.md` for the exact policy DDL.

---

## Audit Events (Summary)

| Event | Trigger |
|---|---|
| `MATCH_PROPOSED` | Proposal row inserted |
| `MATCHING_AUTO_CONFIRMED` | Status set to AUTO_CONFIRMED by engine |
| `MATCH_CONFIRMED` | Status set to CONFIRMED by human |
| `MATCH_REJECTED` | Status set to REJECTED |
| `MATCH_SUPERSEDED` | Status set to SUPERSEDED |
| `MATCH_EXCEPTION_DOCUMENTED` | Status set to EXCEPTION_DOCUMENTED |

---

## Related Documents

- `match_proposal_schema.md` — canonical DDL (this file is a reference alias)
- `matching_engine_policy.md` — pipeline rules that govern when proposals are created and confirmed
- `matching_scoring_config_schema.md` — per-business scoring thresholds
- `match_scoring_config_schema.md` — scoring configuration schema
- `matching_policy.md` — matching business rules
- `matching_confidence_policy.md` — confidence band definitions and escalation thresholds
- `match_signal_evidence_schema.md` — signal-level evidence linked to proposals
- `workflow_run_schema.md` — parent run for proposals
- `transactions_schema.md` — FK target for transaction_id
- `invoice_schema.md` — FK target for invoice_id
