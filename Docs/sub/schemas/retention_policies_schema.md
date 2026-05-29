# Retention Policies Schema

**Category:** Schemas · **Owning block:** 04 — Data Architecture · **Co-owner:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 2)

The per-business retention configuration table that overlays the system-wide zone retention defaults declared in `data_retention_policy.md`. This table holds the per-business `retention_years` override that the retention engine consults at deletion-eligibility time and that `object_lock_integration.md` cites as the source of per-bundle retention windows for new archive bundles.

Per Stage 1: "default ≥ 6 years; retention engine is an internal scheduled background job, not a workflow trigger." Per Cyprus VAT/books retention: 6 years is the legal minimum for accounting records. This schema lets a business **extend** retention beyond 6 years for stricter compliance needs (e.g., active audit subjects) without lowering the floor.

---

## 1. Table definition

```sql
CREATE TABLE retention_policies (
  business_id       uuid PRIMARY KEY REFERENCES business_entities(id),
  retention_years   integer NOT NULL DEFAULT 6,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  updated_by        uuid NOT NULL REFERENCES users(id),

  CONSTRAINT retention_years_minimum CHECK (retention_years >= 6),
  CONSTRAINT retention_years_maximum CHECK (retention_years <= 50)
);

CREATE INDEX idx_retention_policies_extended
  ON retention_policies(business_id)
  WHERE retention_years > 6;
```

Rationale on the constraints:

- **`retention_years >= 6`** is the **hard floor** per Cyprus VAT/books retention. Application code, the UPDATE RPC in §4, and DB-level CHECK all enforce this — any one alone is sufficient defence; together they form defence-in-depth.
- **`retention_years <= 50`** is a sanity upper bound. 50 years exceeds any plausible regulatory retention requirement and prevents accidental `1000` typos that would render the business's archives effectively immortal.
- The `WHERE retention_years > 6` partial index is the fast-lookup path for the retention engine's "which businesses have non-default retention?" query during a sweep.

---

## 2. Default-row seeding

Every business gets a row at business creation:

```sql
-- In the business_entities INSERT trigger:
INSERT INTO retention_policies (business_id, updated_by)
VALUES (NEW.id, NEW.created_by)
ON CONFLICT (business_id) DO NOTHING;
```

The seed is idempotent via `ON CONFLICT DO NOTHING` — a manual re-seed of all businesses is safe and a no-op for businesses already configured.

Per the migration pattern in `data_layer_conventions_policy.md`: the seed migration for existing businesses (those created before this table existed) runs once at table introduction:

```sql
INSERT INTO retention_policies (business_id, updated_by)
SELECT id, created_by FROM business_entities
ON CONFLICT (business_id) DO NOTHING;
```

`RETENTION_POLICY_INITIAL_SEED` audit event is emitted per row inserted during the migration.

---

## 3. Consumer contract — how the retention engine reads this table

The retention engine (Block 04 Phase 10 background job) computes per-business retention thresholds via:

```sql
-- Compute deletion-eligibility threshold for a business
SELECT now() - make_interval(years => retention_years) AS threshold
FROM retention_policies
WHERE business_id = $business_id;
```

Records in archive tables (`archive.archive_packages`, `archive.locked_ledger_entries`, etc.) with `archived_at < threshold` are deletion-eligible **subject to the legal-hold check** (per §7 and the legal-hold hook contract, B04·P10·SD seq 418).

`object_lock_integration.md` uses the same value at archive promotion time to set `X-Object-Lock-Retention-Until-Date = promoted_at + retention_years`. Once set, Object Lock's COMPLIANCE mode enforces the floor at the platform level — even the operator cannot shorten an existing bundle's retention.

**Asymmetry of extension:** increasing `retention_years` for a business AFTER bundles have been promoted does NOT retroactively extend the Object Lock retention on existing bundles. Those bundles retain their original `retention_years` value. New bundles use the updated value. The retention engine's deletion-eligibility check uses the CURRENT `retention_years` from this table — so an extension extends the deletion-block at the engine layer even though the Object Lock attribute on the older bundle remains at its original value. This is intentional: the engine-layer block is the operator-controlled gate; the Object Lock attribute is the immutable floor.

---

## 4. Per-business update API

```ts
// SECURITY DEFINER RPC; owns the update path
archive.update_retention_policy({
  business_id: uuid,
  new_retention_years: integer,    // must be >= current retention_years OR >= 6 (whichever is higher)
  step_up_token_id: uuid,
}) → {
  prior_retention_years: integer,
  new_retention_years: integer,
  updated_at: timestamptz,
}
```

**Authorization:**

- `auth.role_on_business(business_id) IN ('OWNER', 'ADMIN')` — REVIEWER / BOOKKEEPER / ACCOUNTANT / READ_ONLY cannot modify retention
- Step-up MFA required per `step_up_validity_window_policy.md` — the token is consumed by this call
- `permission_matrix` row: `RETENTION_POLICY/UPDATE` (NEW surface — cross-block coordination flagged for B02·P04)

**Validation:**

1. `new_retention_years >= 6` (hard floor — same as the CHECK constraint; rejected before the UPDATE attempts)
2. `new_retention_years >= prior_retention_years` (**retention is monotonically non-decreasing per business**; cannot shorten)
3. Step-up token valid + non-consumed + matches actor

**Cannot shorten:** the API rejects any call with `new_retention_years < prior_retention_years` with error `RETENTION_POLICY_SHORTEN_REJECTED`. This is a binding rule: once a business has committed to N-year retention, it cannot back away — only extend further. This protects users from operational mistakes that would expose them to compliance gaps.

If shortening is legitimately required (rare; e.g., a business was mistakenly set to 50 years), the operator must use the admin escalation path in `admin_retention_override_runbook.md` (cross-block coordination flagged for B05·P07).

---

## 5. RLS

```sql
ALTER TABLE retention_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE retention_policies FORCE ROW LEVEL SECURITY;

-- Any authenticated role on the business may READ its retention value
CREATE POLICY retention_policies_read
  ON retention_policies
  FOR SELECT
  USING (
    business_id = ANY (auth.business_ids_for_session())
  );

-- Writes BLOCKED from authenticated role; UPDATE only via SECURITY DEFINER RPC
CREATE POLICY retention_policies_no_app_write
  ON retention_policies
  FOR ALL
  USING (false)
  WITH CHECK (false);

-- Internal: retention engine reads with elevated role
CREATE POLICY retention_policies_engine_read
  ON retention_policies
  FOR SELECT
  TO retention_engine
  USING (true);
```

`archive.update_retention_policy` is SECURITY DEFINER and runs as a service role with INSERT/UPDATE bypass. Application sessions cannot mutate this table directly under any condition.

---

## 6. Audit events

| Event | Severity | When | Payload |
|---|---|---|---|
| `RETENTION_POLICY_INITIAL_SEED` | LOW | Per-row insert during default seeding (new business creation OR table-introduction migration) | `business_id`, `retention_years` (always `6`), `seeded_by_user_id`, `seeded_at` |
| `RETENTION_POLICY_UPDATED` | MEDIUM | Each successful `archive.update_retention_policy` call | `business_id`, `prior_retention_years`, `new_retention_years`, `updated_by_user_id`, `step_up_token_id`, `updated_at` |
| `RETENTION_POLICY_SHORTEN_REJECTED` | MEDIUM | Attempted call where `new_retention_years < prior_retention_years` | `business_id`, `attempted_by_user_id`, `prior_retention_years`, `attempted_new_retention_years`, `rejected_at` |

All in the `RETENTION` domain per `audit_event_taxonomy.md`. Cross-block coordination flagged for B05·P02 — 3 NEW event kinds.

---

## 7. Legal-hold interaction

This table does NOT directly model legal holds. The legal-hold check lives in the `legal_holds` table per `adjustment_six_year_cap_policy.md`:

```sql
EXISTS (
  SELECT 1 FROM legal_holds lh
  WHERE lh.business_id = retention_policies.business_id
    AND lh.hold_started_at <= now()
    AND (lh.hold_ends_at IS NULL OR lh.hold_ends_at >= now())
)
```

When an active hold is found, the retention engine SKIPS deletion regardless of `retention_years` having elapsed. The hold is checked at the deletion-eligibility moment — the retention engine's legal-hold hook contract (B04·P10·SD seq 418) defines the exact function signature + placeholder-swap mechanism.

Per `processing_zone_ttl_and_prune_policy.md` (this cycle's B04·P06 work): the processing-zone prune job ALSO consults `legal_holds` and emits `LEGAL_HOLD_ACTIVE` as the skip reason. The retention engine emits `RETENTION_DELETION_SKIPPED_LEGAL_HOLD` (the canonical retention-domain skip event).

---

## 8. Mobile rejection

Per `mobile_write_rejection_endpoints.md`:

- `archive.update_retention_policy` — write path; REJECTED on mobile (returns HTTP 405 with `MOBILE_WRITE_REJECTED`). Retention configuration is desktop-only.
- READ access via the dashboard (per role) is allowed on mobile.

Step-up MFA challenge for retention update is not presented on mobile clients.

---

## 9. Stage-6 drift flagged

`data_retention_policy.md` describes the **zone-level** retention contract and includes the claim "Archive zone | Permanent (Object Lock indefinite) | Supabase Storage Object Lock — no deletion path." This wording is inconsistent with:

- `object_lock_integration.md` retention model (6-year default + per-business override via this schema + eventual deletion after Object Lock expiry)
- `archive_schema.md` `object_lock_retention_until` column (per Cyprus 6-year minimum)
- `adjustment_six_year_cap_policy.md` 6-year cap on adjustments
- Stage 1 decision per the P10 phase doc: "default ≥ 6 years; retention engine is an internal scheduled background job"

Stage-6 reconciliation: `data_retention_policy.md` "Archive permanent" wording should be revised to reflect the 6-year-default-plus-per-business-override model (this schema is the source of the per-business override; Object Lock COMPLIANCE mode enforces the floor at the platform layer; legal holds + active-business state defer deletion at the engine layer).

The 7-year operational-zone floor in `data_retention_policy.md` (post-deactivation) is unrelated and remains valid — that's about the live operational tables, NOT the archive zone.

---

## 10. Cross-references

- `data_retention_policy.md` — zone-level retention contract; this schema overlays per-business overrides on top of the archive-zone default; Stage-6 reconcile per §9
- `object_lock_integration.md` — consumes `retention_years` at archive promotion time to set the Object Lock retention-until-date
- `archive_schema.md` — `archive_packages.object_lock_retention_until` carries the per-bundle frozen value
- `archive_promotion_failure_runbook.md` — `LEGAL_HOLD_BLOCKS_RETENTION_DELETE` failure class consumes the §7 legal-hold check
- `adjustment_six_year_cap_policy.md` — `legal_holds` table DDL + active-hold query pattern; 6-year cap rationale
- `processing_zone_ttl_and_prune_policy.md` — sibling processing-zone retention path; same `legal_holds` consumer
- `data_layer_conventions_policy.md` — UUID v7 PK; canonical JSON for audit payloads; `numeric`/`integer`/`timestamptz` column conventions
- `step_up_validity_window_policy.md` — 30-minute default + 5-minute finalization override; step-up token semantics for the update RPC
- `permission_matrix` — NEW `RETENTION_POLICY/UPDATE` surface (Owner/Admin); cross-block coordination flagged for B02·P04
- `audit_log_policies.md` — `RETENTION_*` event severity + domain assignment
- `audit_event_taxonomy.md` — `RETENTION` domain canonical events (must absorb 3 NEW events declared in §6)
- `mobile_write_rejection_endpoints.md` — `archive.update_retention_policy` listed as write surface
- `legal_holds` table — B02·P04 administration; B04·P11 lifecycle; this schema's §7 consumer
- Block 02 Phase 04 — owner of `permission_matrix` + `legal_holds` admin
- Block 04 Phase 10 — owning phase (retention engine background job consumer)
- Block 04 Phase 11 — legal-hold mechanism + admin RPCs
- Block 15 Phase 09 — retention engine implementation respects this table
- Stage 1 decision — 6-year retention default + retention engine as background job
- Cyprus VAT retention regulations — 6-year baseline for accounting records
