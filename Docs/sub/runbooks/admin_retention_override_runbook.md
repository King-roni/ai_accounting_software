# Admin Retention Override Runbook

**Category:** Runbooks · **Owning block:** 04 — Data Architecture · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 1 cross-block runbook)

The procedure for the rare operator action of **shortening** a business's `retention_policies.retention_years` value below the previously-recorded value. The standard `archive.update_retention_policy` RPC rejects any shorten attempt with `RETENTION_POLICY_SHORTEN_REJECTED` per `retention_policies_schema.md` §4; this runbook documents the only sanctioned bypass path.

Per the schema's monotonically-non-decreasing rule, the application API has no shortening capability under any role or step-up condition. Shortening exists only as a manual DBA action under explicit compliance approval.

---

## When to use

This runbook applies in narrow circumstances only:

1. A `retention_years` value was set by mistake (operational typo, e.g., `50` entered instead of `5`) and the business has not yet finalized any periods at the inflated value. Bundles already promoted at the higher value retain their Object Lock at the original retention — the override only affects the engine-layer gate and FUTURE bundles.
2. A regulator has explicitly authorised a shorter window in writing for a specific business.
3. Forensic correction of a corrupted seed row from the table-introduction migration.

This runbook is NOT for:
- Routine policy reductions — there are none. The Cyprus 6-year floor is binding and the override cannot bypass it.
- Lifting a legal hold — see `legal_holds_admin_runbook` (B04·P11 cross-block coordination flagged).
- Deleting an existing archive bundle whose Object Lock is still in force — Object Lock COMPLIANCE mode is platform-enforced and cannot be unlocked.

---

## Pre-conditions

ALL of the following must hold before the override proceeds:

1. **Written compliance approval** — signed memo from the platform's Compliance Officer authorising the override, citing the `business_id`, prior and new `retention_years`, and the regulatory or operational rationale.
2. **Co-approval recorded** — a second platform admin (different person) reviews and signs the memo.
3. **Existing-bundle Object Lock check** — verify via `object_lock_integration` API that no archive bundle currently exists at the prior `retention_years` value that has not yet reached its lock expiry. If such bundles exist, the override does NOT reduce their Object Lock retention — COMPLIANCE mode prevents this at the platform layer. The override only affects the engine-layer deletion gate for FUTURE bundles or for bundles that have already reached lock expiry.
4. **Business Owner notification** — the business Owner is notified BEFORE the override is executed (not after) so they can object.
5. **Justification log** — the override request + approval are recorded in the compliance log per `compliance_audit_records_policy` (Stage-6 doc-write candidate; cross-block coordination flagged for B05).

---

## Procedure

The override bypasses `archive.update_retention_policy`'s RPC validation. It is executed directly via a DBA-only SECURITY DEFINER admin function `archive.admin_override_retention_policy`:

```sql
-- DBA console only; not exposed via the application API
SELECT archive.admin_override_retention_policy(
  p_business_id              := $1,
  p_new_retention_years      := $2,
  p_compliance_memo_ref      := $3,    -- pointer to the signed memo (URL or storage key)
  p_authorized_by_user_id    := $4,    -- Compliance Officer
  p_co_signed_by_user_id     := $5,    -- Co-approving admin (must be different user)
  p_override_justification   := $6     -- free text explanation
);
```

The function:

1. Verifies `p_new_retention_years >= 6` (Cyprus floor remains binding; the runbook cannot bypass the hard floor).
2. Verifies `p_authorized_by_user_id != p_co_signed_by_user_id` (co-approval requires two distinct users).
3. Updates `retention_policies.retention_years` to the new value.
4. Sets `retention_policies.updated_by = p_authorized_by_user_id` and `updated_at = now()`.
5. Emits `RETENTION_POLICY_UPDATED` (MEDIUM) with the override-specific payload fields documented in §Audit shape.
6. Returns the prior and new values for verification.

The function lives in the `archive` schema and is granted EXECUTE only to the `platform_dba` role. No application path can reach it.

---

## Post-update verification

1. Re-read `retention_policies` for the business — confirm the new value persisted.
2. Confirm no in-flight retention sweep is mid-execution for the business (check the retention-pass log per `retention_scheduling_policy` — B04·P10 seq 414 sub-doc).
3. Emit a courtesy notification to the business Owner via the standard notification surface (per `notification_dispatch_policy`).
4. File the post-execution outcome (success / failure / aborted) back into the compliance memo record.

---

## Reversal

The override does not reduce Object Lock retention on existing bundles — those values are frozen at the platform layer under COMPLIANCE mode. If the override is itself rejected later (audit finding, regulatory pushback), the path is to call `archive.update_retention_policy` to extend `retention_years` back upward via the standard monotonic-non-decreasing API.

There is no "undo" for an admin override that took effect — extending forward is the only reversal.

---

## Audit shape

The override emits `RETENTION_POLICY_UPDATED` (MEDIUM) per `audit_event_taxonomy.md` (Block 04 RETENTION domain), with the standard payload plus the override-specific extensions:

| Field | Value |
|---|---|
| `business_id` | uuid |
| `prior_retention_years` | integer |
| `new_retention_years` | integer |
| `updated_by_user_id` | Compliance Officer's user_id (= `p_authorized_by_user_id`) |
| `is_admin_override` | `true` |
| `compliance_memo_ref` | string |
| `co_signed_by_user_id` | uuid (the second admin) |
| `override_justification` | text |
| `step_up_token_id` | NULL (override bypasses the standard step-up requirement; co-approval substitutes) |
| `updated_at` | timestamptz |

This payload extension does NOT require a new audit event kind — the existing `RETENTION_POLICY_UPDATED` event absorbs the override scenario via the `is_admin_override` flag. Audit consumers filter by `payload->>'is_admin_override' = 'true'` when investigating override activity.

---

## Cross-references

- `retention_policies_schema.md` — owning schema; §4 monotonic non-decreasing rule; §6 audit event canonical definition
- `data_retention_policy.md` — Cyprus 6-year floor; archive-zone retention defaults
- `object_lock_integration.md` — Object Lock COMPLIANCE mode; platform-enforced floor on existing bundles
- `audit_event_taxonomy.md` — `RETENTION_POLICY_UPDATED` event canonical definition (Block 04 RETENTION domain)
- `compliance_audit_records_policy.md` (Stage-6 doc-write candidate) — compliance approval log
- `legal_holds_admin_runbook.md` (B04·P11 cross-block coordination flagged) — legal-hold lifecycle (NOT a substitute for this runbook)
- `notification_dispatch_policy.md` — Owner notification surface
- Block 04 Phase 10 — owning phase (retention engine background job consumer)
- Block 05 — security audit + compliance log
- Cyprus VAT retention regulations — 6-year minimum (NOT bypassable; the runbook cannot reduce below 6)
