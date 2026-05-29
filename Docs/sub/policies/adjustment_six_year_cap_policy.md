# adjustment_six_year_cap_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Co-owners:** 02 — Tenancy & Access (legal-hold), 15 — Finalization & Secure Archive (retention) · **Stage:** 4 sub-doc (Layer 2)

The retention window enforcement contract for adjustment runs. Cyprus law requires accounting records to be retained for 6 years; adjustments against records older than this window are NOT permitted because the underlying parent run's archive may have already passed its retention boundary. This policy pins the exact date arithmetic, the timezone handling, the legal-hold extension mechanism, and the trigger-time enforcement.

The cap is anchored on `parent_run.finalized_at`, NOT on the period the run covers — a run finalized on 2024-02-15 covering January 2024 has a cap based on the February 2024 finalization timestamp.

---

## The 6-year window — exact definition

A `*_ADJUSTMENT` run targeting `parent_run` is permitted IF AND ONLY IF:

```
trigger_time_in_business_locale - parent_run.finalized_at_in_business_locale <= 6 calendar years
```

Where:

- `trigger_time` is `now()` at the moment `engine.manual_trigger_run` is called
- `parent_run.finalized_at` is from `workflow_runs.finalized_at` (always non-null when status=FINALIZED)
- `6 calendar years` means exactly 72 calendar months — NOT 365 × 6 = 2190 days. Calendar arithmetic respects leap years and varying month lengths.

The comparison uses Postgres `AGE()` for calendar-aware subtraction:

```sql
-- inside engine.validate_adjustment_six_year_cap(parent_run_id):
WITH p AS (
  SELECT business_id, finalized_at
  FROM workflow_runs
  WHERE workflow_run_id = $1
)
SELECT (AGE(now() AT TIME ZONE be.locale_timezone,
            p.finalized_at AT TIME ZONE be.locale_timezone) <= INTERVAL '6 years')
       AS within_window
FROM p
JOIN business_entities be ON be.id = p.business_id;
```

The query converts BOTH timestamps to the business's `locale_timezone` (per `business_entities.locale_timezone` column, defaulting to `Europe/Nicosia`) BEFORE subtraction. This matters for businesses on UTC-leap timezones where the local calendar boundary differs.

## Timezone choice

Cyprus VAT regulations are governed by Cyprus local time (UTC+2 / UTC+3 with DST). The cap is enforced in the **business's** local time, NOT the application server's time and NOT UTC.

- Business in Cyprus: `Europe/Nicosia` timezone (DST-aware)
- Business in another EU country: their declared `business_entities.locale_timezone`
- Default if NULL: `Europe/Nicosia`

Implication: a parent run finalized at 2024-01-15 23:50 UTC has `finalized_at_in_locale = 2024-01-16 01:50 Europe/Nicosia` (Jan 16 local). A trigger at 2030-01-16 00:30 UTC is `2030-01-16 02:30 Europe/Nicosia` — within the window by 30 minutes. A trigger at 2030-01-15 23:00 UTC is `2030-01-16 01:00 Europe/Nicosia` — also within. A trigger at 2030-01-16 22:00 UTC is `2030-01-17 00:00 Europe/Nicosia` — JUST outside (1 day past the local Jan 16 boundary).

Border-case behaviour is documented because it matters: the business in Nicosia perceives 6 years as ending at local midnight, not at UTC midnight, of the corresponding date.

## Leap-year handling

`AGE()` returns intervals that respect calendar arithmetic — `AGE('2030-02-29', '2024-02-29') = 6 years 0 months 0 days`. For non-leap-year anchors, `AGE('2030-02-28', '2024-02-29') = 5 years 11 months 30 days` (just inside the window) and `AGE('2030-03-01', '2024-02-29') = 6 years 0 months 1 day` (just outside).

The 6-year boundary thus shifts by 0-1 day depending on leap-year alignment. This is intentional — calendar arithmetic is the legal standard, NOT day-count arithmetic.

## Legal-hold extension

Some businesses are subject to legal-hold orders (tax investigations, court-ordered preservation). When a legal hold is in effect, the 6-year cap is EXTENDED — the business may amend records that would otherwise be outside the window.

```sql
-- Legal hold table per Block 02 P04 + Block 15 P09
CREATE TABLE legal_holds (
  id                          uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id                 uuid NOT NULL,
  hold_kind                   text NOT NULL,                     -- e.g., 'TAX_INVESTIGATION', 'COURT_ORDER'
  hold_started_at             timestamptz NOT NULL,
  hold_ends_at                timestamptz NULL,                  -- NULL = open-ended
  hold_authority              text NOT NULL,                     -- e.g., 'Tax Department of Cyprus / Case #...'
  filed_by_user_id            uuid NOT NULL,
  filed_at                    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT legal_hold_dates_valid CHECK (hold_ends_at IS NULL OR hold_ends_at > hold_started_at)
);
```

When the validator detects an active legal hold:

```sql
EXISTS (
  SELECT 1 FROM legal_holds lh
  WHERE lh.business_id = $business_id
    AND lh.hold_started_at <= now()
    AND (lh.hold_ends_at IS NULL OR lh.hold_ends_at >= now())
)
```

If the EXISTS is true, the 6-year cap is bypassed AND the adjustment record's `requires_accountant_review` is force-set to TRUE (regardless of `delta_kind`). The legal-hold bypass MUST go through accountant review because legal-hold amendments are unusual and require human verification.

The bypass emits `WORKFLOW_ADJUSTMENT_LEGAL_HOLD_BYPASS` (HIGH severity) with payload `{adjustment_run_id, parent_run_id, legal_hold_id, hold_kind, hold_authority}`. Visible to operations + Owner role + the audit log permanently.

## Trigger validation

Per `manual_trigger_api_policy` step 6 (PARENT_VALIDATION), the trigger handler calls `engine.validate_adjustment_six_year_cap(parent_run_id)`:

```ts
// Inside manual trigger validation:
const capCheck = await db.query(
  `SELECT * FROM engine.validate_adjustment_six_year_cap($1)`,
  [parent_run_id]
);

if (!capCheck.within_window && !capCheck.legal_hold_bypass) {
  return {
    error_code: 'WORKFLOW_ADJUSTMENT_REJECTED_OUTSIDE_RETENTION',
    error_message: localise(
      'The original record was finalized on {finalized_at} (more than 6 years ago). ' +
      'Amendments to records older than the 6-year retention window are not permitted.',
      { finalized_at: capCheck.finalized_at }
    ),
    details: {
      parent_finalized_at: capCheck.finalized_at,
      now: now(),
      age_intervals: capCheck.age_years_months_days
    }
  };
}

if (capCheck.legal_hold_bypass) {
  // Adjustment permitted; flag for downstream
  return {
    cap_bypass: true,
    legal_hold_id: capCheck.legal_hold_id
  };
}
```

The trigger handler proceeds with the rest of validation (concurrency, rate limits, idempotency). The cap is a HARD check — there is no override path for users.

## Audit shape

Rejection:

```ts
emitAudit("WORKFLOW_ADJUSTMENT_REJECTED_OUTSIDE_RETENTION", {
  business_id,
  attempted_parent_run_id,
  parent_finalized_at,
  attempted_at: now(),
  attempted_by_user_id,
  age_at_attempt_years: numeric,
  age_at_attempt_months: numeric
});
```

Severity `LOW` (caller-side limitation; not an engine error). Domain `WORKFLOW`.

Bypass via legal hold:

```ts
emitAudit("WORKFLOW_ADJUSTMENT_LEGAL_HOLD_BYPASS", {
  workflow_run_id,                                  // the new adjustment run
  business_id,
  parent_run_id,
  legal_hold_id,
  hold_kind,
  hold_authority,
  age_at_attempt_years,
  granted_at: now(),
  granted_to_user_id
});
```

Severity `HIGH`. Subscribed by operations alerting per `cross_tenant_alerting_runbook`.

## UI affordances

When a user attempts to trigger an adjustment outside the window via the dashboard's "Start adjustment" form, the form pre-checks against the cap before allowing submit (debounced 500 ms after parent_run selection):

- Inside window: green checkmark "Within 6-year retention window"
- Outside window + no legal hold: red error "This record is beyond the 6-year retention cap (finalized {date})" + Submit button disabled
- Outside window + legal hold active: yellow warning "Legal hold permits this adjustment. The {hold_kind} authority requires accountant review." + Submit button enabled with explicit confirm

The pre-check is informational only; server-side validation is authoritative.

## Cap-violation cleanup

When the cap is reached for an actively-pending adjustment (rare — a multi-week adjustment workflow that started in-window but completion crosses the boundary), the adjustment is allowed to complete. The cap is anchored at trigger time, NOT at finalization time. Once a run is in flight (CREATED or beyond), the cap no longer applies.

This rule prevents the situation where a user starts an adjustment with 1 week of headroom and runs out of time. The engine still completes the in-flight run.

## Cross-block contract

- **Block 02 Phase 04** owns the `business_entities.locale_timezone` column + `legal_holds` table read access.
- **Block 02 Phase 09** owns legal-hold administration RPCs (file, lift).
- **Block 03 Phase 09** invokes `engine.validate_adjustment_six_year_cap` from manual_trigger.
- **Block 03 Phase 11** owns this policy + the validator function.
- **Block 15 Phase 09** retention engine respects the cap when purging old archives (a finalized run within active legal hold is NOT purged).
- **Block 16 dashboard** renders the UI affordances.

## Cross-references

- `manual_trigger_api_policy` — step 6 PARENT_VALIDATION invokes the validator
- `adjustment_record_schema` — parent_run linkage column
- `out_adjustment_policies` / `in_adjustment_policies` — workflow-level adjustment rules
- `adjustment_reason_text_policy` — sibling B03·P11 policy
- `audit_event_payload_schemas` (Stage-6 catalog) — `WORKFLOW_ADJUSTMENT_REJECTED_OUTSIDE_RETENTION` + `_LEGAL_HOLD_BYPASS` payloads
- `cross_tenant_alerting_runbook` — legal-hold-bypass ops alert subscription
- `business_entities` schema — `locale_timezone` column
- `legal_holds` table — B02·P04 administration; B15·P09 retention interaction
- Block 02 Phase 04 / 09 — legal-hold ownership
- Block 03 Phase 11 — owning phase
- Block 15 Phase 09 — retention purge respects active holds
- Cyprus VAT retention regulations — 6-year baseline
