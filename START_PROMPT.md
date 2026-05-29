# Start prompt — paste this into a fresh Claude Code session

---

Bootstrap context, then propose the next phase. Do not start implementing until I say "go".

## 1. Read the handoff (parallel)

- `mempalace_status` — load palace overview + protocol
- `mempalace_get_drawer` with `drawer_id = drawer_cyprus_bookkeeping_project-meta_3425d21389e8094e778df48c` — full project state through end of Block 12 + post-Block-12 audit (2026-05-24), all conventions, per-block summaries, gotchas
- `mempalace_list_drawers` with `wing=cyprus_bookkeeping room=project-meta`, find `stage5-build-order-roadmap`, `mempalace_get_drawer` it — canonical build order
- `Read` the project `CLAUDE.md` at `/Users/pep_o23kd/Desktop/Cursor/Personal/boekhoudings_Ai_software/CLAUDE.md` — bootstrap sequence + conventions
- `Read` the post-Block-12 audit tracker at `/Users/pep_o23kd/Desktop/Cursor/Personal/boekhoudings_Ai_software/Docs/sub/audit/2026-05-24_post_block_12_audit.md` — 31 findings table with resolution status (skim for context on what's recently changed)

## 2. Where we are (as of 2026-05-24, end of session)

- **Blocks 03, 04, 05, 06, 07, 08, 09, 10, 11, 12** — ALL phases DONE (BOOK-1..115)
- **Block 02** — partial (placeholder `mfa_recent_at`; `can_perform` was a stub but post-audit-C1 made it real RBAC)
- **Post-Block-12 audit (2026-05-24)** — DONE. 31 findings, 8 fix waves, 6 migrations (`20260524000013..18`) + 1 lint script. Most consequential changes:
  - `can_perform` is now real RBAC (joins `business_user_roles × permission_matrix`); test GUC hooks preserved
  - RLS+FORCE on 20 runtime tables (was no-RLS)
  - 20 FK covering indexes added
  - `MATCHED_AUTO_HIGH_CONFIDENCE` enum value added
  - IN_ADJUSTMENT phases rebuilt to mirror OUT_ADJUSTMENT
- **Next**: BOOK-116 = **Block 13 P01** per build order (verify against Plane before naming)
- **Latest migration**: `supabase/migrations/20260524000018_audit_m4_in_adjustment_phase_rebuild.sql`. Next file starts `20260524000019_...`.

## 3. ⚠️ Block 13 prerequisite (audit M5)

**BEFORE building any IN-side gates or tools, rebuild the IN_MONTHLY phase sequence.** Current state: DB has 5 EVIDENCE_DISCOVERY phases incl. `_GMAIL` + `_LOCAL`; spec wants 2 with `_EMAIL`. 8 IN_MONTHLY phases unused (no gates/tools). Mirror the B12·P02 dance: rename phase_name → shift phase_order +100 → delete → insert new. **This should be Block 13 P02 (or an explicit Block 13 P01 prereq if P01 is shape-defining only).**

## 4. Pull the next phase from Plane

Phase-order signal is Plane `sequence_id`. Lowest in Backlog is next.

- `mcp__plane__list_work_items` for project `28b250c0-d991-4dcb-a48c-51af27aa17dd`, filter to Backlog state `06b2fd3b-5d0c-486a-9a37-fe086b725315`, sort by sequence_id asc
- `mcp__plane__retrieve_work_item_by_identifier` with `project_identifier=BOOK, issue_identifier=<seq>` — full detail
- Description references a spec at `Docs/phases/<block>/<NN>_<name>.md` — `Read` it in full
- Expected: BOOK-116 → Block 13 P01. **If Plane disagrees, surface the discrepancy before assuming.** (Per pinned feedback: never say "likely" about next phase — verify.)

## 5. Propose

Once spec is read and Plane confirmed:

- Move the work item to In Progress state `d349cb35-77f8-45f8-bbf7-98b6fbf39329`
- Propose the implementation shape in **5–10 bullets**: new schemas/enums/tables, RPCs (with signatures), audit events, RLS, deferred items, test outline (12 assertions)
- End with **"Waiting for 'go'."** Stop. Do not write migration code yet.

## 6. Working pattern (after I say "go")

1. Write migration → `mcp__claude_ai_Supabase__apply_migration`. Mirror to `supabase/migrations/YYYYMMDDHHMMSS_<phase_slug>.sql`. **Forward-only** — fix-ups are NEW files, never edits to historical migrations.
2. DO-block lifecycle test → `mcp__claude_ai_Supabase__execute_sql`. End with `RAISE 'TEST_PASS_ROLLBACK'`. Trailing RAISE's line number in the error confirms all assertions passed (target: 12/12).
3. Close Plane: rich DoD comment via `mcp__plane__create_work_item_comment` (list migrations, schema, RPCs, audit actions, A1–A12 outcomes, gotchas), then move to Done `6e8dcd01-8ef8-4f8f-a3c4-99e73bb5ec98`.
4. File 5–10 `mempalace_kg_add` triples per phase (`object` field has 128-char limit — split long facts).
5. **On block completion**: `mempalace_update_drawer` on project-meta to fold the block summary in.

## 7. Mempalace rules (CRITICAL)

Known server-side bug: `mempalace_add_drawer` + `mempalace_diary_write` return Internal tool error when multiple Claude sessions share the palace.
- **Use `mempalace_update_drawer`** to refresh project-meta on block completion — works fine.
- **Keep filing `mempalace_kg_add` triples** — works fine.
- Do NOT call `add_drawer` or `diary_write` until the bug is fixed.

## 8. Load-bearing gotchas (already pinned in drawer, but worth flagging)

**New from 2026-05-24 audit:**
- **`can_perform` is REAL RBAC now.** Any new RPC test that calls a user-facing RPC depending on can_perform must pre-seed a `business_user_roles` row for the test user (with appropriate role) — else the call DENIES with `reason_code: NO_ROLE_ASSIGNMENT`. Test GUC hooks (`test.can_perform_decision='DENY'`/`'ALLOW'`/`'STEP_UP'`) still work unconditionally for explicit override paths.
- **RLS+FORCE on 20 runtime tables** (`business_ai_config`, `ai_*`, `out_workflow_reminders`, `statement_*` runs/rows, `prompt_*`, `redaction_*`, `tier_3_pricing`, etc.) — SECURITY DEFINER RPC writes verified intact under FORCE. No change to DO-block test pattern.
- **`transactions.match_status` enum** now includes `MATCHED_AUTO_HIGH_CONFIDENCE` (clear state).
- **IN_ADJUSTMENT phases** now mirror OUT_ADJUSTMENT (5 phases: ADJUSTMENT_INTAKE → LEDGER_PREP → AI_REVIEW → HUMAN_REVIEW → FINALIZATION).
- **Lint guard** at `scripts/lint_step_up_token_usage.sh` blocks new `PERFORM consume_step_up_token` regressions.

**Pinned from prior sessions:**
- **`audit.emit_audit`** returns `audit.audit_events` ROW (not uuid); `p_after_state` + `p_request_context` — NO `p_payload`.
- **`tool_registry.tr_retry_base_pos`** CHECK requires positive backoff_base_ms even with retry_max_attempts=1 — use `(1, 100, 100)`.
- **`gate_registry.gr_name_namespaced`** CHECK requires `namespace.name` form.
- **`side_effect_class_enum`**: `READ_ONLY` (NOT `READS_ONLY`), WRITES_RUN_STATE, CALLS_EXTERNAL_API.
- **`workflow_runs.status` direct UPDATE forbidden** by `fn_block_direct_status_update` — use `public.transition_run`. Trigger fires only on UPDATE; INSERTing FINALIZED directly works in test fixtures.
- **`wfr_workflow_type_parent_chk`**: OUT/IN_ADJUSTMENT require `parent_run_id NOT NULL`; OUT/IN_MONTHLY require it NULL.
- **`wr_trigger_kind_event_id_coupling`**: trigger_kind=EVENT ↔ trigger_event_id NOT NULL; MANUAL ↔ NULL. Don't store unrelated text (like statement_upload_id) in `trigger_event_id`.
- **`wfr_finalized_state_chk`**: FINALIZED requires both `finalized_at` + `finalized_by`.
- **`review_issue_at_least_one_entity_chk`**: one of transaction_id/document_id/match_record_id/draft_ledger_entry_id required.
- **`review_issues.created_at`**: defaults to `now()` (transaction-start) NOT `clock_timestamp()` — for staleness/ordering tests set explicitly via `clock_timestamp() + interval`.
- **`transactions_amount_direction_chk`**: OUT requires amount<0, IN requires amount>0.
- **`transactions.transaction_type` is NOT NULL.**
- **business table is `business_entities`** (not `businesses`).
- **`ALTER TYPE ADD VALUE`** has deferred visibility — split into two migrations when the value is used in the same migration.
- **plpgsql UNION ALL with LIMIT** in subquery branches requires parens: `(SELECT … LIMIT 1) UNION ALL (SELECT … LIMIT 1)`.
- **plpgsql array concat** needs `ARRAY[v]` literal on RHS.
- **prompt_id regex**: `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$` — each segment lowercase-letter-prefixed.

## 9. After bootstrap

Now run steps 1–5 and stop at **"Waiting for 'go'."**
