# Legal Hold Lifecycle Policy

**Category:** Policies · **Owning block:** 04 — Data Architecture · **Stage:** 4 sub-doc (Layer 2)

The canonical lifecycle contract for `legal_holds` rows: the date-range storage model, the derived state machine (ACTIVE / LIFTED / EXPIRED / SCHEDULED), the set and lift transitions, the schema extensions added this cycle, and the edge-case behavior for Owner removal mid-hold + business dissolution. Establishes `v_legal_hold_status` as the canonical status-derivation view consumed by the UI and audit feeds.

The base `legal_holds` table DDL was introduced by `adjustment_six_year_cap_policy.md` for the 6-year adjustment cap. This policy extends it with lift-audit columns and pins the lifecycle behavior across all consumers (retention engine, processing-zone prune, adjustment validator, Object Lock extension).

---

## 1. Storage model — date-range

The canonical storage is the date-range model introduced by `adjustment_six_year_cap_policy.md` with two additions this cycle (`lift_reason`, `lifted_by_user_id`):

```sql
CREATE TABLE legal_holds (
  id                          uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id                 uuid NOT NULL,
  hold_kind                   text NOT NULL,
  hold_started_at             timestamptz NOT NULL,
  hold_ends_at                timestamptz NULL,
  hold_authority              text NOT NULL,
  filed_by_user_id            uuid NOT NULL,
  filed_at                    timestamptz NOT NULL DEFAULT now(),

  -- Added by B04·P11·SD seq 426 (this cycle):
  lift_reason                 text NULL,
  lifted_by_user_id           uuid NULL REFERENCES users(id),

  CONSTRAINT legal_hold_dates_valid
    CHECK (hold_ends_at IS NULL OR hold_ends_at > hold_started_at),

  CONSTRAINT legal_hold_lift_pair_consistent
    CHECK (
      (lift_reason IS NULL AND lifted_by_user_id IS NULL)
      OR
      (lift_reason IS NOT NULL AND lifted_by_user_id IS NOT NULL AND hold_ends_at IS NOT NULL)
    )
);

CREATE INDEX idx_legal_holds_business_active
  ON legal_holds(business_id)
  WHERE hold_ends_at IS NULL OR hold_ends_at >= now();
```

The partial index supports the retention hook's `EXISTS (...WHERE business_id = ? AND hold_started_at <= now() AND (hold_ends_at IS NULL OR hold_ends_at >= now()))` query at P95 < 5 ms per business.

---

## 2. Derived state machine

Status is derived per-row via the canonical view:

```sql
CREATE VIEW v_legal_hold_status AS
SELECT
  *,
  CASE
    WHEN hold_started_at > now()                              THEN 'SCHEDULED'
    WHEN hold_ends_at IS NULL OR hold_ends_at > now()         THEN 'ACTIVE'
    WHEN lift_reason IS NOT NULL                              THEN 'LIFTED'
    ELSE                                                           'EXPIRED'
  END AS status
FROM legal_holds;
```

State machine:

```
        ┌──────────────────┐
        │   SCHEDULED      │  filed for future activation
        └────────┬─────────┘
                 │ hold_started_at passes
                 ↓
        ┌──────────────────┐
        │     ACTIVE       │
        └────────┬─────────┘
                 │
       ┌─────────┴──────────┐
manual lift                  hold_ends_at passes
       ↓                     ↓
  ┌──────────┐         ┌──────────┐
  │  LIFTED  │         │ EXPIRED  │
  └──────────┘         └──────────┘
```

Terminal states: `LIFTED`, `EXPIRED`. No reactivation — re-establishing a hold requires filing a NEW row.

---

## 3. Set transition

`POST /api/v1/businesses/:business_id/legal-holds`:

1. **Authn:** Owner role on the business per `permission_matrix.md` `LEGAL_HOLD/SET` surface.
2. **Authz:** step-up MFA token valid + non-consumed (per `legal_hold_step_up_policy` — cross-block coordination flagged for B02·P06).
3. **Validate:** `hold_kind` in enum (per `legal_hold_reason_guidance.md` §2); `hold_authority` non-empty ≤ 200 chars; `hold_ends_at` (if provided) > now() + 1 hour.
4. INSERT `legal_holds` row with `filed_at = now()`, `filed_by_user_id = caller`, lift fields NULL.
5. Emit `LEGAL_HOLD_SET` (HIGH — existing event).
6. Trigger async `archive.extend_object_lock_for_hold` job per `object_lock_retention_extension_policy.md`.
7. Return 201 with the new row id.

---

## 4. Lift transition

`POST /api/v1/legal-holds/:id/lift`:

1. **Authn:** Owner role per `LEGAL_HOLD/LIFT` surface.
2. **Authz:** step-up MFA token valid.
3. **Validate:** hold is `ACTIVE` or `SCHEDULED` (not already LIFTED/EXPIRED); `lift_reason` non-empty ≤ 2000 chars.
4. ```sql
   UPDATE legal_holds
   SET hold_ends_at      = now(),
       lift_reason       = $reason,
       lifted_by_user_id = $caller
   WHERE id = $1
     AND lifted_by_user_id IS NULL;
   ```
5. The `legal_hold_lift_pair_consistent` CHECK enforces the three lift fields being set atomically.
6. Emit `LEGAL_HOLD_LIFTED` (MEDIUM — existing event).
7. Object Lock retention is NOT shortened per `object_lock_retention_extension_policy.md` §5 — there is no Object-Lock-side companion job for lift.
8. Return 200.

---

## 5. Edge cases

### 5.1 Owner removed mid-hold

If the filing Owner is removed from the business while a hold is active, the hold remains active. Lifting requires a current Owner — the original filer's role status is not consulted at lift time.

If NO Owner exists on the business, the hold cannot be lifted via the standard API. Recovery: platform-admin co-approval via `admin_legal_hold_lift_runbook.md` (Stage-6 doc-write candidate).

### 5.2 Business dissolution mid-hold

If a business is set `is_active = false` (operational-zone soft-delete per `data_retention_policy.md`) with active holds, the business's archive bundles remain locked until ALL holds are lifted or expire. The 7-year post-deactivation operational hard-delete is also blocked while ANY hold is active.

The `business_entities` deactivation API must check active holds and emit `BUSINESS_DEACTIVATION_BLOCKED_LEGAL_HOLD` (NEW MEDIUM event) if any are present — cross-block coordination flagged for B02·P03 business lifecycle. Operator decides: lift the holds OR proceed with retention-blocking active.

### 5.3 Multiple concurrent holds on one business

Allowed. The retention hook returns `on_hold = true` if ANY active hold exists. The `hold_reasons` array aggregates all active holds' `(hold_kind, hold_authority)` pairs.

Lifting one hold while others remain active does NOT resume retention — the hook still returns true. All active holds must be lifted/expired before the engine resumes deletion.

### 5.4 Hold ends_at in the past (system clock skew)

Cannot happen by design: `legal_hold_dates_valid` CHECK requires `hold_ends_at > hold_started_at`; the set-API validates `hold_ends_at > now() + 1 hour`. Combined, no row can be inserted with an effectively-immediate or past ends_at.

---

## 6. Audit completeness

| Stage | Event | Payload |
|---|---|---|
| Filed | `LEGAL_HOLD_SET` | `business_id`, `legal_hold_id`, `hold_kind`, `hold_authority`, `hold_started_at`, `hold_ends_at`, `filed_by_user_id`, `step_up_token_id` |
| Lifted | `LEGAL_HOLD_LIFTED` | `legal_hold_id`, `business_id`, `lift_reason`, `lifted_by_user_id`, `hold_ended_at`, `was_active_for_duration_seconds`, `step_up_token_id` |
| Naturally expired | `LEGAL_HOLD_EXPIRED` (NEW) | `legal_hold_id`, `business_id`, `hold_ended_at`, `was_active_for_duration_seconds` — emitted by daily 04:00 UTC scan when `hold_ends_at` passes without manual lift |

2 NEW events: `LEGAL_HOLD_EXPIRED`, `BUSINESS_DEACTIVATION_BLOCKED_LEGAL_HOLD`. Added to `audit_event_taxonomy.md` this cycle.

---

## 7. RLS

```sql
ALTER TABLE legal_holds ENABLE ROW LEVEL SECURITY;
ALTER TABLE legal_holds FORCE ROW LEVEL SECURITY;

CREATE POLICY legal_holds_read
  ON legal_holds FOR SELECT
  USING (business_id = ANY (auth.business_ids_for_session()));

CREATE POLICY legal_holds_no_app_write
  ON legal_holds FOR ALL
  USING (false) WITH CHECK (false);
```

Writes go through SECURITY DEFINER RPCs in §3 and §4. The `retention_engine` role has SELECT via the hook contract per `retention_legal_hold_hook_contract.md` (the hook is SECURITY DEFINER and reads as its owner).

---

## 8. Mobile rejection

Set/lift are write surfaces — rejected on mobile per `mobile_write_rejection_endpoints.md`. Read access (history rendering) is allowed.

---

## 9. Cross-references

- `adjustment_six_year_cap_policy.md` — original `legal_holds` table DDL + adjustment-cap consumer
- `legal_hold_ui_spec.md` (B04·P11 seq 421) — UI consumer of `v_legal_hold_status`
- `object_lock_retention_extension_policy.md` (B04·P11 seq 424) — `LEGAL_HOLD_SET` consumer
- `legal_hold_reason_guidance.md` (B04·P11 seq 428) — `hold_kind` enum + reason rules
- `legal_hold_maximum_window_policy.md` (B04·P11 seq 430) — `hold_ends_at` constraints
- `legal_hold_admin_extension_policy.md` (B04·P11 seq 436) — Owner-only rule + Stage-2 Admin extension
- `retention_legal_hold_hook_contract.md` (B04·P10 seq 418) — engine reads via the hook
- `retention_deletion_atomicity_policy.md` — engine consults the hook before each bundle's deletion
- `processing_zone_ttl_and_prune_policy.md` — sibling consumer of `legal_holds`
- `permission_matrix.md` — NEW `LEGAL_HOLD/SET` + `LEGAL_HOLD/LIFT` surfaces (added this cycle)
- `legal_hold_step_up_policy` (cross-block coordination flagged for B02·P06) — step-up window
- `audit_event_taxonomy.md` — `LEGAL_HOLD_*` event family
- `data_retention_policy.md` — operational-zone deactivation interaction
- Block 02 Phase 03 — business dissolution flow (cross-block coordination flagged for `BUSINESS_DEACTIVATION_BLOCKED_LEGAL_HOLD`)
- Block 04 Phase 11 — owning phase
