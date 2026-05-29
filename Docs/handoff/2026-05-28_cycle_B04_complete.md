# Cycle B04 — Data Architecture — COMPLETE

**Date closed:** 2026-05-28
**Cycle UUID:** `1de935db-12b4-4eb9-aa0b-4731cdf56725`
**Tickets:** 65/65 (100%) closed across 2 sessions
**Status:** ✅ DONE

This document is the LOAD-BEARING cross-reference artifact downstream cycles read first.

---

## 1. Cycle scope

Cycle B04 covered the Data Architecture layer — every storage zone (Raw Upload, Processing, Operational, Finalized Archive, Analytics), the schemas inside each zone, the hashing/ID conventions, the zone-promotion pipeline, the retention engine, and the legal-hold mechanism. After this cycle, downstream blocks have the binding storage contracts they need to read/write business data while respecting retention + legal-hold + audit-trail invariants.

The cycle spanned 11 phases (P01-P11). Surface area: 29 verified pre-existing sub-docs (P01-P06 — heavy verify) + 13 NEW sub-docs authored across P06, P07-P11 (P06 = 3, P07 = 0, P08 = 0, P09 = 1, P10 = 5, P11 = 6). Plus 3 catalog edits to permission_matrix + audit_event_taxonomy + data_retention_policy.

## 2. Session-by-session disposition

| Session | Date | Tickets | Writes | Verifies |
| --- | --- | --- | --- | --- |
| `2026-05-28c` | extended session | 29 (P01-P06 SD clusters) | 3 (B04·P06 only) | 26 |
| `2026-05-28d` | this session | 25 (P07-P11 + cross-block) + 11 phase-level tickets already closed | 13 sub-docs + 4 catalog edits + 1 cross-block runbook | 9 (P07 + P08 + 4 of P09) |
| **TOTAL** | | **65 (54 SD + 11 phase-level Stage-2)** | **16 sub-docs** + 4 catalog edits + 1 runbook | **35 verify-only sub-doc closes** |

This session: 25 tickets closed (P07: 4 verify; P08: 5 verify; P09: 4 verify + 1 write; P10: 5 writes; P11: 6 writes).

## 3. NEW canonical sub-docs authored this cycle (13)

All in `Docs/sub/` unless noted.

### B04·P06 — Processing zone (3, authored prior session)
1. `policies/processing_artefact_taxonomy_policy.md`
2. `policies/processing_zone_ttl_and_prune_policy.md`
3. `policies/inline_vs_storage_decision_policy.md`

### B04·P09 — Analytics zone (1, this session)
4. `schemas/multi_business_aggregation_schema.md` — `analytics.v_consolidated_*` view family + `auth.business_ids_for_session()` permission filtering at view-evaluation time

### B04·P10 — Retention engine (5, this session)
5. `schemas/retention_policies_schema.md` — per-business `retention_years` table with monotonic-non-decreasing API
6. `policies/retention_scheduling_policy.md` — pg_cron schedule (02:00 EU/Athens) + advisory locking
7. `policies/retention_deletion_atomicity_policy.md` — 8-step ordered procedure + Storage HEAD orphan reconciliation + `archive_deletion_state_enum`
8. `policies/retention_legal_hold_hook_contract.md` — runtime hook registry pattern + Phase 10 placeholder + Phase 11 swap-in
9. `policies/retention_dry_run_mode_policy.md` — `p_dry_run := true` parameter + `RETENTION_DELETION_PLANNED_DRY_RUN` event

### B04·P11 — Legal hold (6, this session)
10. `ui/legal_hold_ui_spec.md` — Owner-only panel + set/lift forms + history
11. `policies/object_lock_retention_extension_policy.md` — extension calc + COMPLIANCE no-shorten reconciliation
12. `policies/legal_hold_lifecycle_policy.md` — date-range schema + `lift_reason`/`lifted_by_user_id` extensions + `v_legal_hold_status` view
13. `policies/legal_hold_reason_guidance.md` — `hold_kind` enum + content rules + PII redaction
14. `policies/legal_hold_maximum_window_policy.md` — 10yr default + per-business override + jurisdictional table
15. `policies/legal_hold_admin_extension_policy.md` — Owner-only MVP + Stage-2 grantable design

### Cross-block runbook authored this cycle (1)
16. `runbooks/admin_retention_override_runbook.md` — narrow shortening path under compliance + co-approval

## 4. Cross-block coordination punch list (grouped by consumer)

### B02·P03 (Business lifecycle)
- `business_entities` deactivation API must check active `legal_holds` and emit `BUSINESS_DEACTIVATION_BLOCKED_LEGAL_HOLD` (per `legal_hold_lifecycle_policy.md` §5.2)

### B02·P04 (Permission matrix host)
- NEW `RETENTION_POLICY/UPDATE` surface (Owner + Admin + step-up) — **added to `permission_matrix.md` this cycle**
- NEW `LEGAL_HOLD/SET` + `LEGAL_HOLD/LIFT` surfaces (Owner-only + step-up) — **added to `permission_matrix.md` this cycle**
- Stage-2 grantable model deferred per `legal_hold_admin_extension_policy.md` §3

### B02·P06 (Step-up framework)
- NEW `legal_hold_step_up_policy.md` Stage-6 doc-write candidate — step-up validity window for `LEGAL_HOLD/*` actions (5-min equivalent to finalization, OR override per business policy)

### B04·P07 (Archive schema — closed this cycle, retroactive)
- Add `deletion_state archive_deletion_state_enum NOT NULL DEFAULT 'PENDING'` column to `archive.archive_packages` per `retention_deletion_atomicity_policy.md` §6
- Add `archive_deletion_state_enum` (PENDING / IN_PROGRESS / HELD_LEGAL / INCONSISTENT)
- Add partial index `WHERE deletion_state != 'PENDING'`

### B05·P02 (Audit taxonomy — 16 NEW events from this cycle, all added to `audit_event_taxonomy.md`)
- RETENTION_POLICY family: `_INITIAL_SEED`, `_UPDATED`, `_SHORTEN_REJECTED`
- RETENTION_PASS family: `_STARTED`, `_COMPLETED`, `_SKIPPED_CONCURRENT`, `_TIMEOUT`, `_TRIGGERED_MANUAL`, `_AUTH_ERROR`, `_DELETION_STATE_RESET`
- RETENTION_DELETION family: `_PLANNED`, `_RECONCILED_ORPHAN`, `_PLANNED_DRY_RUN`
- RETENTION_HOOK family: `_REGISTERED`
- LEGAL_HOLD family: `_EXPIRED`, `_WINDOW_OVERRIDE_SET`, `_OBJECT_LOCK_EXTENSION_STARTED`, `_OBJECT_LOCK_EXTENSION_COMPLETED`, `_EXTENSION_TIMEOUT`, `_EXTENSION_AUTH_ERROR`
- OBJECT_LOCK family: `_EXTENSION_DUE_FOR_RENEWAL`, `_EXTENSION_REJECTED_SHORTEN`
- BUSINESS family: `BUSINESS_DEACTIVATION_BLOCKED_LEGAL_HOLD`
- DASHBOARD family: `MULTI_BUSINESS_DASHBOARD_VIEWED`, `MULTI_BUSINESS_DRILL_DOWN_ACCESSED`

### B05·P07 (Admin escalation)
- NEW `admin_legal_hold_window_runbook.md` Stage-6 doc-write candidate — procedure for `archive.set_business_legal_hold_window` override
- NEW `admin_legal_hold_lift_runbook.md` Stage-6 doc-write candidate — Owner-removed-mid-hold lift path
- `admin_retention_override_runbook.md` AUTHORED THIS CYCLE — sibling of the two above

### B05·P09 (GDPR redaction)
- `legal_hold_reason_lint` function proposal — Stage-2 content discipline enforcement for legal-hold reason text

### B14·P02 (Issue type registry)
- NEW `RETENTION_INCONSISTENCY` issue type (HIGH; DATA_INTEGRITY group) per `retention_deletion_atomicity_policy.md` §8

### B15·P06 (Accountant pack)
- `accountant_pack_manifest_schema.md` must include active legal holds per `legal_hold_reason_guidance.md` §8

### B15 (Stage-2)
- `retention_orphan_cleanup_policy.md` Stage-2 — Storage prefix-listing reconciler for DB-cleaned-Storage-orphan case per `retention_deletion_atomicity_policy.md` §5

## 5. Stage-6 drift queue — additions from this cycle

### Reconciled this session
- **`data_retention_policy.md`** archive-zone wording "Permanent (Object Lock indefinite)" → corrected to "6 years default + per-business override + retention_engine deletion path"

### Resolved this cycle (no Stage-6 work needed)
- `legal_holds` schema canonicalization — added `lift_reason` + `lifted_by_user_id` columns + `legal_hold_lift_pair_consistent` CHECK
- `permission_matrix` extended with `RETENTION_POLICY/UPDATE` + `LEGAL_HOLD/SET` + `LEGAL_HOLD/LIFT`

### Carried over from prior sessions + new this cycle
- B04·P09 3-way list drift (hook 11 tables vs 11 MVs vs 11 dashboard cards) — Stage-6 reconcile
- B04·P08 hook text drift (8-step `archivePromotion.run` vs canonical 5-step lock_sequence) — Stage-6 reconcile
- B04·P10 phase doc nomenclature drift (`legal_holds.status` enum and `set_by/lift_by` columns) vs canonical date-range model — Stage-6 phase-doc rewrite

### Stage-6 doc-write candidates flagged this cycle
- `audit_event_payload_schemas.md` — STILL highest priority; cycle B04 added ~16 new events without payload schemas
- `admin_retention_override_runbook.md` — **AUTHORED this cycle** (no longer pending)
- `admin_legal_hold_window_runbook.md` (B05·P07)
- `admin_legal_hold_lift_runbook.md` (B05·P07)
- `compliance_audit_records_policy.md` (B05·P07)
- `legal_hold_step_up_policy.md` (B02·P06)

## 6. The retention + legal-hold pipeline contract (binding across 11 sub-docs)

```
Engine daily 02:00 EU/Athens via pg_cron → archive.run_retention_pass(region)
  → acquire pg_try_advisory_lock(hashtext('retention_pass_' || region))
  → for each business in uuid-ascending order:
      → acquire per-business sub-lock
      → call archive.call_legal_hold_hook(business_id)         [hook contract]
        → dispatch via archive.runtime_hook_registry
        → Phase 11 impl: query legal_holds for active row
        → returns (on_hold, hold_reasons[])
      → if on_hold:
          emit RETENTION_DELETION_SKIPPED_LEGAL_HOLD; skip business
      → else for each archive_packages row with deletable + PENDING:
          → SELECT FOR UPDATE; mark deletion_state = IN_PROGRESS
          → Storage DELETE bundle_object_uri
          → on 200/204/404: DB DELETE cascade
          → on 5xx: retry per retry_policy std tier; if exhausted skip
          → emit RETENTION_DELETION_PLANNED then _EXECUTED
      → release per-business lock
  → release region lock; emit RETENTION_PASS_COMPLETED

Legal-hold filing → POST /api/v1/businesses/:id/legal-holds
  → Owner role + step-up + hold_kind enum check
  → INSERT legal_holds; emit LEGAL_HOLD_SET (HIGH)
  → trigger async archive.extend_object_lock_for_hold
    → enumerate archive_packages for business_id
    → per bundle: extend Object Lock retention via Supabase Storage API
                   to max(current, hold_started_at + max_legal_hold_window)
    → COMPLIANCE mode: cannot shorten; defense-in-depth at platform
    → emit OBJECT_LOCK_RETENTION_EXTENDED per bundle
    → log batch outcome in archive.legal_hold_extension_log

Legal-hold lift → POST /api/v1/legal-holds/:id/lift
  → Owner role + step-up + lift_reason required
  → UPDATE legal_holds SET hold_ends_at = now(),
                            lift_reason = $reason,
                            lifted_by_user_id = $caller
  → CHECK legal_hold_lift_pair_consistent ensures atomic write
  → emit LEGAL_HOLD_LIFTED (MEDIUM)
  → NO Object Lock companion job — platform retention floor stays at extended value
  → Engine resumes deletion gating on next pass via the hook
```

## 7. Critical "watch this when implementing B04" items

1. **`legal_holds` uses the date-range model** (`hold_started_at` + `hold_ends_at NULL = open-ended`). NOT the `status` enum from the P11 phase doc. The phase doc is the drift item.
2. **COMPLIANCE Object Lock CANNOT be shortened** — extension is monotonic; lift does NOT shorten. The engine-layer hook is what resumes deletion gating; Object Lock retention itself stays at the extended value.
3. **Use `bigint` overload of `pg_try_advisory_lock`** per `phase_execution_locking_policy.md` — `hashtext()` for the key narrowing.
4. **Storage HEAD before DB delete** for orphan reconciliation — the §5 pre-flight scan handles the asymmetric-failure case.
5. **`legal_hold_hook_placeholder` is replaceable at runtime** via `archive.runtime_hook_registry` — Phase 11 swap-in needs NO Phase 10 code change.
6. **`v_legal_hold_status` derives status from date-range** — consumers should query the view, not infer status from raw columns.
7. **`lift_reason` + `lifted_by_user_id` + `hold_ends_at` are set atomically** at lift time per the `legal_hold_lift_pair_consistent` CHECK.
8. **`MULTI_BUSINESS_DASHBOARD_VIEWED` payload does NOT include individual business IDs** — `accessible_business_count` only, for cross-tenant disclosure protection.
9. **`retention_years` is monotonically non-decreasing** through the standard API. Shortening only via `admin_retention_override_runbook.md` with compliance co-approval.
10. **Object Lock extension is defense-in-depth, not primary gate** — the engine's hook check is primary; if extension fails the engine still blocks deletion via the hook.

## 8. Catalog edits made this cycle

- `permission_matrix.md` — added 3 new surfaces (`RETENTION_POLICY/UPDATE`, `LEGAL_HOLD/SET`, `LEGAL_HOLD/LIFT`) in 3 sections each (consolidated matrix + step-up section + cross-block contracts row for Block 04)
- `audit_event_taxonomy.md` — added 16 new events in RETENTION/LEGAL_HOLD/OBJECT_LOCK/DASHBOARD sections (Block 04 RETENTION block grew from ~13 events to ~29)
- `data_retention_policy.md` — archive-zone wording reconciled in both the zone summary table and the §"Archive zone" body

## 9. Cross-references

This cycle's authored sub-docs and consumers all in `Docs/sub/` unless noted:

- `multi_business_aggregation_schema.md`
- `retention_policies_schema.md`
- `retention_scheduling_policy.md`
- `retention_deletion_atomicity_policy.md`
- `retention_legal_hold_hook_contract.md`
- `retention_dry_run_mode_policy.md`
- `admin_retention_override_runbook.md` (cross-block)
- `legal_hold_ui_spec.md`
- `object_lock_retention_extension_policy.md`
- `legal_hold_lifecycle_policy.md`
- `legal_hold_reason_guidance.md`
- `legal_hold_maximum_window_policy.md`
- `legal_hold_admin_extension_policy.md`
- (B04·P06, prior session) `processing_artefact_taxonomy_policy.md`, `processing_zone_ttl_and_prune_policy.md`, `inline_vs_storage_decision_policy.md`

Pre-existing canonical docs that this cycle ratified or amended:
- `adjustment_six_year_cap_policy.md` (B03·P11; introduced `legal_holds` table; extended this cycle)
- `archive_schema.md` (B04·P07; must absorb `deletion_state` column — flagged)
- `object_lock_integration.md` (B04·P07)
- `analytics_snapshot_schema.md`, `dashboard_preferences_schema.md`, `dashboard_card_definitions_ui_spec.md`, `analytics_refresh_runbook.md`, `analytics_stale_state_ui_spec.md` (B04·P09 verifies)
- `data_retention_policy.md` (wording reconciled this cycle)
- `permission_matrix.md` (3 surfaces added this cycle)
- `audit_event_taxonomy.md` (16 events added this cycle)

---

**End of Cycle B04 wrap-up.** Next: **Cycle B05 (Security & Audit)** — 47 backlog tickets at UUID `14cf9a0f-24d0-4c60-9883-c3e363c3d6c6`.

Per the resume pointer: Cycle B04 closed; next pickup is **Cycle B05 (Security & Audit)** — first ticket via `mcp__plane__list_cycle_work_items` lowest backlog `sequence_id`.
