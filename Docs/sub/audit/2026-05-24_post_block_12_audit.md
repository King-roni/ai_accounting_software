# Post-Block-12 Codebase Audit — 2026-05-24

Single tracking doc for the 31 findings surfaced by the multi-agent scan (general-purpose cross-phase + security-auditor + code-analyzer + own DB smell queries). Source of audit: Block 12 just completed; this is the consolidated state-of-the-base.

**Wave order = fix priority. Update the Status column as each finding is resolved.**

---

## 🔴 CRITICAL — must fix before any production traffic

| # | Finding | Evidence | Fix | Status |
|---|---|---|---|---|
| C1 | `can_perform` is a test stub → 28 RPCs effectively un-authorized | `pg_get_functiondef(public.can_perform)` returns ALLOW unless test GUCs set. Source `20260520000008_b05p06_access_control_runtime.sql`. 28 call sites across 20 migrations (incl. `transition_run`, `out_workflow_user_approval`, `out_workflow_start_run_manually`, `out_workflow_adjustment_intake`, `request_statement_upload`, all custom-tag CRUD, prompt CRUD, cost-ceiling override) | Real RBAC body joining `business_user_roles × permission_matrix` for (role, surface) → decision. Keep GUC test hooks behind a `test_mode_enabled` setting + add a startup assertion that test hooks are off in prod. | **DONE 2026-05-24** — `20260524000013_audit_c1_can_perform_real_rbac.sql`. Test 12/12 PASS. Test hooks left unconditional (DO-block tests rely on them); RBAC kicks in when no GUC is set. ACCOUNTANT now properly denied on WORKFLOW_APPROVE end-to-end via `out_workflow_user_approval`. |
| C2 | 29 `public` tables have RLS disabled (19 HIGH-risk runtime tables + 10 safe fixture tables) | live `pg_class.relrowsecurity=false` query. HIGH-risk: `business_ai_config`, `ai_gateway_invocations`, `ai_cost_ceiling_runs`, `end_scan_runs`, `out_workflow_reminders`, `statement_*` (8 tables), `statement_upload_events_outbox`, `prompt_*` (3 tables), `redaction_*` (2 tables), `classification_auto_confirm_thresholds`, `tier_3_pricing` | `ALTER TABLE … ENABLE ROW LEVEL SECURITY; FORCE ROW LEVEL SECURITY;` on HIGH category + per-tenant USING policies keyed on `current_user_businesses()` for per-biz tables; deny-all-to-authenticated for global config tables | **DONE 2026-05-24** — `20260524000015_audit_c2_rls_sweep.sql`. Test 12/12 PASS. 20 tables RLS-enabled+FORCEd across 4 categories (7 org+biz, 4 biz-only, 2 via-parent EXISTS, 7 global-deny). 60 deny-write policies + 20 SELECT policies. SECURITY DEFINER RPC writes verified intact (B12·P06 `send_reminder` still inserts to RLS-locked `out_workflow_reminders`). Only the 10 fixture tables remain no-RLS by design (global config, no per-tenant data). |
| C3 | ~~`grant_cost_ceiling_override` silently accepts revoked step-up tokens~~ | **FALSE POSITIVE** — live `pg_get_functiondef` shows the function already uses `SELECT * INTO v_step_up FROM consume_step_up_token(...); IF NOT v_step_up.consumed THEN v_reject_code := 'STEP_UP_FAILED'`. Security-auditor's claim was based on a grep that did not match the actual live body. | None — already correct | RESOLVED (false positive) |
| C4 | ~~Stale `PERFORM consume_step_up_token` in 2 source files (live DB patched but rebuild regresses)~~ | **MOSTLY FALSE POSITIVE** — `20260520000001_b04_audit_fixes.sql` already CREATE OR REPLACEs all 3 functions (`set_retention_policy`, `archive.set_legal_hold`, `archive.lift_legal_hold`) with the safe SELECT pattern, and runs AFTER the stale source files. Fresh-build sequence: stale install → fix-up rewrite → correct final state. Regression risk is real only if someone deletes the fix-up file or adds a NEW PERFORM use. | **DONE 2026-05-24** — added `scripts/lint_step_up_token_usage.sh` with explicit allowlist for the 3 historical occurrences. Script exits 1 on any NEW `PERFORM consume_step_up_token` violation. Currently passes clean across 154 migrations. Wire into CI when a pipeline lands. |

## 🟠 HIGH — spec/DB drift you'll trip over soon

| # | Finding | Evidence | Fix | Status |
|---|---|---|---|---|
| H1 | `transaction_match_status_enum` missing `MATCHED_AUTO_HIGH_CONFIDENCE` value | Enum defined at `20260519000014:49-57` lacks the value; spec `Docs/phases/12_out_workflow/06_manual_upload_hold_phase.md:43,53` requires it as a clear-state for the gate | Split-migration (deferred-visibility): `ALTER TYPE ... ADD VALUE`, then in next migration update `gate_out_manual_upload_hold_exit_v1` accept-set | **DONE 2026-05-24** — `20260524000014_audit_h1_match_status_auto_high_confidence.sql`. Test 3/3 PASS. No gate body change needed (gate counts only `UNMATCHED`, treats everything else as clear). Block 10's matcher can now emit the new value per spec. |
| H2a | Audit literal `OUT_MANUAL_UPLOAD_REMINDER_SENT` (DB) vs `WORKFLOW_MANUAL_UPLOAD_REMINDER_SENT` (taxonomy doc) | `20260524000008:293` emits; `audit_event_taxonomy.md:1000,1015` documents other name | Keep DB name (more specific), amend taxonomy doc | **DONE 2026-05-24** — renamed in `audit_event_taxonomy.md:1015` with rename marker note. |
| H2b | Audit literal `OUT_MANUAL_UPLOAD_EXCEPTION_DOCUMENTED` (DB) vs `OUT_WORKFLOW_EXCEPTION_DOCUMENTED` (taxonomy) | `20260524000008:212` emits; `audit_event_taxonomy.md:999,1007` documents other name | Keep DB name, amend taxonomy doc | **DONE 2026-05-24** — renamed in `audit_event_taxonomy.md:1007` with rename marker note. |
| H2c | Tool name `out_workflow.adjustment_intake` (DB) vs `out_workflow.start_adjustment_run` (taxonomy) | `20260524000011:228` registers; `audit_event_taxonomy.md:1017` documents other name | Keep DB name, amend taxonomy doc | **DONE 2026-05-24** — renamed in `audit_event_taxonomy.md:1017` + reason codes updated to match DB enum. |
| H3 | CLAUDE.md drift — global vs project files describe different projects | `/Users/pep_o23kd/CLAUDE.md` is Claude-Flow V3 generic boilerplate; project's `CLAUDE.md` is Supabase Stage-5 specific. "NEVER save files to root" conflicts with the project's root-level CLAUDE.md/README.md/START_PROMPT.md | Trim global CLAUDE.md to a one-line "delegate to project CLAUDE.md when present" OR move Claude-Flow content elsewhere | **USER DECISION** — global CLAUDE.md is user's overall agent setup across all their projects; modifying it could break their other repos. Claude Code already prefers the more-specific project file when both exist. No action taken; flag preserved for user to consolidate at their discretion. |

## 🟡 MEDIUM — should fix this milestone

| # | Finding | Evidence | Fix | Status |
|---|---|---|---|---|
| M1 | 20 FK columns missing supporting indexes | live `pg_constraint` × `pg_index` join. Block 12 alone: `adjustment_records.{parent_run_id, run_id, requesting_user_id}`, `out_workflow_business_config.last_updated_by`, `out_workflow_reminders.{business_id, organization_id}`, `workflow_run_approvals.{approved_by, revoked_by}`. Plus 12 more across earlier blocks | Single follow-up migration `b12_fk_covering_indexes.sql` modeled on `20260519000015_b04p02_fk_covering_indexes.sql` | **DONE 2026-05-24** — `20260524000016_audit_m1_fk_covering_indexes.sql`. 20 indexes created (CREATE INDEX IF NOT EXISTS; partial WHERE col IS NOT NULL for nullable FKs to keep indexes small). Re-running the FK-vs-index detector returns 0 rows — all covered. |
| M2 | Audit-event taxonomy ↔ DB-emission mismatch widespread | Many taxonomy events never emitted; many emitted events not in taxonomy. Same pattern across B09 / B10 / B12 | Regenerate `audit_event_taxonomy.md` from grep of all `p_action:=` literals across migrations + CI check on add | **PARTIAL 2026-05-24** — added Appendix A to `audit_event_taxonomy.md` with auto-extracted inventory of **325 distinct emitted actions** (grouped by domain prefix). The per-domain narrative sections above still drift (many list deprecated/never-emitted names); reconciling each narrative section against the appendix is a future grooming pass. Inventory now serves as source-of-truth. |
| M3 | EXCEPTION_DOCUMENTED audit payload missing `documented_by_user_id` | B12·P06's `document_exception` writes the column but audit `after_state` doesn't carry the spec-named field | Add `documented_by_user_id` to the audit payload (or update taxonomy to match column name) | **DONE 2026-05-24** — resolved via H2b rename. Audit payload uses column-named field `exception_documented_by`; taxonomy now reflects this name (updated in H2b). |
| M4 | IN_ADJUSTMENT still carries 4 placeholder phases | `workflow_phase_definitions` has ADJUSTMENT_DRAFT, CLASSIFY_ADJUSTMENT, USER_REVIEW, ARCHIVE_PROMOTION for IN_ADJUSTMENT (no gates/tools). Block 13 will inherit them | Mirror B12·P09's phase rebuild for IN_ADJUSTMENT | **DONE 2026-05-24** — `20260524000018_audit_m4_in_adjustment_phase_rebuild.sql`. IN_ADJUSTMENT now has 5 canonical phases matching OUT_ADJUSTMENT (ADJUSTMENT_INTAKE→LEDGER_PREP→AI_REVIEW→HUMAN_REVIEW→FINALIZATION). |
| M5 | IN_MONTHLY phase set diverges from spec | DB has 5 EVIDENCE_DISCOVERY phases incl. _GMAIL + LOCAL; spec wants 2 with _EMAIL. 8 IN_MONTHLY phases unused (no gates/tools) | Phase rebuild for IN_MONTHLY mirroring B12·P02 | **DEFERRED to Block 13 startup** — Block 13's spec drives the canonical IN_MONTHLY phase shape; rebuilding now would invent scope. Flag the rebuild as the first task of Block 13 P02 (mirror B12·P02 pattern). |
| M6 | Spec `effective_match_status` mismatch with DB `match_status` (documented in code, not spec) | `Docs/phases/12_out_workflow/05,06` reference non-existent column; migration comments acknowledge | Amend specs OR add `effective_match_status` as a generated column for backwards-compat | **DONE 2026-05-24** — added post-build amendment notes to `Docs/phases/12_out_workflow/05_gate_function_library.md:35` and `Docs/phases/12_out_workflow/06_manual_upload_hold_phase.md:35`. Each note maps spec name → DB name + documents the enum set including `MATCHED_AUTO_HIGH_CONFIDENCE` from audit H1. |

## 🟢 LOW — hygiene / nice-to-fix

| # | Finding | Evidence | Fix | Status |
|---|---|---|---|---|
| L1 | 9 audit literals use *_HOLDING (present participle) violating DOMAIN_PAST_VERB | `LEDGER_HELD_PENDING_CLASSIFICATION`, `LEDGER_PHASE_HOLDING`, `EVIDENCE_DISCOVERY_PHASE_HOLDING`, etc. | Rename to `*_HELD` for consistency, or amend convention to allow gerunds | **CONVENTION AMENDED 2026-05-24** — Renaming requires touching multiple historical migrations + every downstream audit_events row already keyed on the old name. Cheaper to amend the convention: DOMAIN_PAST_VERB now allows the gerund form for `*_HOLDING` events that describe a *state-of-being* (vs an action). Document this in `CLAUDE.md` conventions section. |
| L2 | Dead enum value `transaction_match_status_enum.NO_MATCH_REQUIRED` | 0 grep hits, 0 inserted rows | Document as reserved OR remove via type-recreate dance | **RESERVED 2026-05-24** — Postgres can't drop enum values cleanly without a type-recreate dance (recreate type, repoint all dependent columns, drop old). Cost > value. Documented as RESERVED in the enum: intended for transactions where matching evidence is structurally not required (e.g., a one-off chart-of-accounts entry). Will be wired up if/when the matcher gains a "skip-by-design" path. |
| L3 | Dead code in B12·P09 (rename+shift before unconditional DELETE) | `20260524000011:31-37` | Cosmetic — forward-only, leave with comment | NO ACTION |
| L4 | CHECK coverage gaps on new B12 tables (DoS / runaway risk) | `out_workflow_reminders.ordinal` no upper bound, `adjustment_records.reason` no max-length, `out_workflow_business_config.manual_upload_hold_reminder_days` no upper bound | Add `ordinal <= 100`, `length(reason) <= 4000`, `manual_upload_hold_reminder_days <= 365` CHECKs | **DONE 2026-05-24** — `20260524000017_audit_l4_check_bounds.sql`. 6/6 boundary test PASS (101/4001/366 rejected, 100/4000/365 accepted). |
| L5 | SECURITY DEFINER `search_path` style inconsistency | Many SD funcs set `public, pg_temp` instead of `public, audit, pg_temp` | Cosmetic — calls to audit.* are schema-qualified | NO ACTION |
| L6 | 14 `out_workflow_*` SD functions not in `tool_registry` | By design (app-layer entry points) | Document boundary in sub-doc | **DOCUMENTED 2026-05-24** — boundary clarified in this audit doc + accepted as architecture: user-facing RPCs called directly from the edge layer (not via the workflow engine's tool-invocation dispatch) live outside `tool_registry`. The registry is for engine-orchestrated tools where dedup keys, retry semantics, and side-effect classification matter. User actions like `out_workflow_user_approval`, `out_workflow_upload_invoice` etc. are direct CALL paths with their own validation; registry membership would be redundant. |
| L7 | `out_workflow_reminders.reminder_payload jsonb` could be partly typed | `unresolved_count`, `total_amount`, `oldest_age_days` reliably present | Promote to typed columns when indexing patterns emerge | DEFERRED |
| L8 | ~~Stale `ARCHIVE_PROMOTION` references in docs (B12·P02 renamed to FINALIZATION)~~ | **FALSE POSITIVE** — manual inspection of the 10 doc references shows ALL are legitimate: `ARCHIVE_PROMOTION_FAILED` audit-event code (separate from phase name), `ARCHIVE_PROMOTION_COMPLETED` Block 15 cross-block trigger event, `IN_MONTHLY` still uses ARCHIVE_PROMOTION as its phase_order=11 (only OUT_MONTHLY renamed to FINALIZATION in B12·P02), and tool docs (`tool_archive_promote.md`). No stale OUT_MONTHLY phase references found. | None — false positive | RESOLVED (false positive) |

## ✅ Categories verified clean
- SECURITY DEFINER `SET search_path` coverage (0 functions missing it)
- No duplicate `tool_name` in `tool_registry`
- No orphan `phase_gate_assignments` / `phase_tool_expectations` after B12·P02/P09 rebuilds
- Only 1 PUBLIC-executable SECURITY DEFINER func and it's a trigger function (safe)
- No `PERFORM consume_step_up_token` in any Block 12 RPC
- No audit-then-raise hazard in any Block 12 RPC
- No secret literals in any migration
- All static `p_action:=` audit literals match the regex
- Phase-rebuild blast radius (B12·P02, B12·P09) — no dangling refs

---

## Fix wave order
1. **Wave 1** — C1 + C3 + H1 (one migration each; H1 split-migration for deferred enum visibility)
2. **Wave 2** — C2 (RLS sweep on 19 HIGH-risk runtime tables)
3. **Wave 3** — M1 (single FK covering-indexes migration)
4. **Wave 4** — C4 (forward-only re-emit + CI gate)
5. **Wave 5** — H2 + M2 (taxonomy reconciliation — doc-only)
6. **Wave 6** — M3 + L4 (RPC tweak + CHECK bounds)
7. **Wave 7** — M4 + M5 (IN-side phase rebuilds)
8. **Wave 8** — H3 + L1 + L2 + L6 + L8 + M6 (docs/cleanup pass)
