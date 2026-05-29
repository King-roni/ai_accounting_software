# CLAUDE.md — Cyprus Bookkeeping SaaS (Stage 5 implementation)

**Read this first on every new session for this project.**

## Bootstrap sequence

1. `mempalace_status` — load palace overview
2. `mempalace_get_drawer` on the `project-meta` drawer in the `cyprus_bookkeeping` wing — that drawer is the source of truth for "where am I?". Drawer id: `drawer_cyprus_bookkeeping_project-meta_3425d21389e8094e778df48c`
3. `mempalace_get_drawer` on the `stage5-build-order-roadmap` drawer (also project-meta room) — confirms next block per the build order
4. Plane MCP `list_work_items` / `retrieve_work_item_by_identifier` — pick the lowest `sequence_id` still in Backlog. The authoritative phase-order signal is Plane `sequence_id` (BOOK-N), not the spec markdown.

## Mempalace workaround (IMPORTANT)

There is a known server-side bug in `mempalace-mcp` where **`mempalace_add_drawer` and `mempalace_diary_write` return generic "Internal tool error"** when more than one Claude session (across all surfaces — Antigravity, terminal, etc.) has mempalace mounted at the same palace path. The other write paths work fine.

**Workaround — explicit instructions for the next session:**

- **I can keep using `update_drawer` to refresh `project-meta` each time we wrap a block — same strategy, works fine.**
- **I can keep filing `kg_add` triples for each phase — works fine.**

So: at the end of every phase, file the per-phase facts as `kg_add` triples. At the end of every block, fold the block summary into the `project-meta` drawer via `update_drawer`. Do NOT call `add_drawer` or `diary_write` for per-phase drawers / diary entries — they will fail. The information lives in `project-meta` + KG triples instead. That is sufficient; nothing is lost or "outdated" as long as this pattern is followed.

When the upstream bug is fixed, 9 per-phase drawers for B03·P03..P11 can be retro-filed for completeness, but they are not load-bearing for resuming work.

## Working pattern per phase

1. Bootstrap (above)
2. Read spec from `Docs/phases/<block>/` → set Plane to In Progress
3. Propose 5–10 bullets of implementation shape → wait for user "go"
4. Write migration → apply → write DO-block lifecycle assertions ending with `RAISE 'TEST_PASS_ROLLBACK'`
5. Verify 12/12 assertions PASS
6. Close Plane with rich DoD comment
7. File KG triples for the phase (`mempalace_kg_add`)
8. On block completion: `mempalace_update_drawer` on `project-meta` to fold the block summary in

## Project conventions to honor

- **No direct writes** from `authenticated` role — `SECURITY DEFINER` RPCs are the only writers (Workflow-First)
- **Action naming** matches `^[A-Z][A-Z0-9_]{3,}$` (DOMAIN_PAST_VERB)
- **UUID v7** for all PKs (time-sortable)
- **Hash chain** SHA-256, lowercase hex, 64 chars. Genesis = `repeat('0', 64)`. Golden: `hash_chain_append(GENESIS, '{"event":"GENESIS","sequence":0}') = 40c3929457af2429a2a701cd95aa3c28781f141f190bd4440f62334f30c512b5`
- **Step-up tokens** via `public.consume_step_up_token(token, business_id, surface, action_id)` returning `(consumed, reason)` — MUST check the return, never `PERFORM` it
- **Audit-then-raise hazard** → Mitigation A (return jsonb envelope on policy failure) or Mitigation B (fresh-tx audit RPC). Never raise after emitting audit in the same tx.
- **`format()` requires `%s`** not bare `%`. RAISE EXCEPTION uses `%` directly; format() does not.
- **`pg_advisory_xact_lock`** has `(bigint)` and `(int, int)` variants only — no `(bigint, bigint)`. Use single-key with concatenated hash.
- **`ti_attempt_positive` CHECK** requires `attempt_number >= 1` — reset paths must set 1, not 0.
- **`audit_events_actor_kind_chk`** requires USER ↔ `actor_user_id` xor SYSTEM ↔ `actor_system` (never both). Engine-driven audits use SYSTEM + actor_system='workflow_engine' + NULL actor_user_id.
- **`can_perform` envelope key is `decision`** (values ALLOW/DENY/STEP_UP), not `allowed`.
- **ALTER TYPE ADD VALUE** has deferred visibility — split into two migrations when the new value is used in the same migration.
- **enum::text cast is STABLE not IMMUTABLE** — can't COALESCE in a single unique index; use two partial unique indexes.

## Test pattern

Lifecycle tests are DO-blocks that end with `RAISE 'TEST_PASS_ROLLBACK'`. The exception aborts the transaction (so test fixtures clean themselves up) AND signals all earlier assertions passed. The line number in the error message confirms it's the trailing RAISE, not an earlier assertion.

## Project identity

- **Supabase project**: `noxvmnxrqlzsdfngfiww` (region eu-west-1, Postgres 17.6.1.121)
- **Repo root**: `/Users/pep_o23kd/Desktop/Cursor/Personal/boekhoudings_Ai_software` (moved from `Desktop/Cursor/boekhoudings_Ai_software` 2026-05-23)
- **Migrations**: `supabase/migrations/`
- **Specs**: `Docs/phases/<block>/`
- **Plane project**: `BOOK` (id `28b250c0-d991-4dcb-a48c-51af27aa17dd`)
  - Backlog state: `06b2fd3b-5d0c-486a-9a37-fe086b725315`
  - In Progress: `d349cb35-77f8-45f8-bbf7-98b6fbf39329`
  - Done: `6e8dcd01-8ef8-4f8f-a3c4-99e73bb5ec98`
- **Stage 5 build order**: `Docs/PLANE_STAGE5_BRIEF.md` Section 2 (mirrors the `stage5-build-order-roadmap` drawer)

## Current state (as of 2026-05-23)

- **Block 04 (Data Architecture)**: ALL 11 phases DONE (BOOK-1..23)
- **Block 05 (Security & Audit)**: ALL 10 phases DONE (BOOK-24..33) + F1 fix
- **Block 02 (Tenancy & Access)**: PARTIAL (placeholder `can_perform` from B05·P06, placeholder `mfa_recent_at` column)
- **Block 03 (Workflow Engine)**: ✅ ALL 11 phases DONE (BOOK-34..44)
- **Block 06 (AI Layer)**: ✅ ALL 11 phases DONE (BOOK-45..55)
- **Block 07 (Bank Statement Pipeline)**: ✅ ALL 10 phases DONE (BOOK-56..65)
- **Block 08 (Transaction Classification & Tagging)**: ✅ ALL 10 phases DONE (BOOK-66..75)
- **Block 09 (Document Intake & Extraction)**: ✅ ALL 10 phases DONE (BOOK-76..85)
- **Block 10 (Matching Engine)**: ✅ ALL 10 phases DONE (BOOK-86..95)
- **Block 11 (Ledger & Cyprus VAT Engine)**: ✅ ALL 10 phases DONE (BOOK-96..105)
- **Block 12 (OUT Workflow)**: ✅ ALL 10 phases DONE (BOOK-106..115)
- **Post-Block-12 audit**: ✅ DONE 2026-05-24. 31 findings triaged across 8 fix waves. Migrations `20260524000013..18`. Tracker: `Docs/sub/audit/2026-05-24_post_block_12_audit.md`.
  - `can_perform` now does real RBAC (was a test stub returning unconditional ALLOW). 28 RPCs now properly permission-gated. Test GUC hooks preserved unconditionally for DO-block tests.
  - 20 runtime tables gained RLS+FORCE + per-tenant/deny policies (`business_ai_config`, `ai_*`, `out_workflow_reminders`, `statement_*` rows/runs, `prompt_*`, `redaction_*`, `tier_3_pricing`, etc.). 10 fixture tables intentionally left no-RLS.
  - `MATCHED_AUTO_HIGH_CONFIDENCE` added to `transaction_match_status_enum` per Block 12 spec.
  - 20 FK covering indexes added across blocks 4–12.
  - 3 upper-bound CHECKs added (out_workflow_reminders.ordinal ≤ 100, adjustment_records.reason ≤ 4000 chars, manual_upload_hold_reminder_days ≤ 365).
  - IN_ADJUSTMENT phases rebuilt to mirror OUT_ADJUSTMENT (5 canonical phases).
  - Lint script `scripts/lint_step_up_token_usage.sh` blocks new `PERFORM consume_step_up_token` regressions.
- **Next**: verify next BOOK-N (expected BOOK-116 = Block 13 P01) against Plane before proceeding.
- **Block 13 P02 / P-rebuild prereq (audit M5)**: IN_MONTHLY still carries 8 unused placeholder phases (no gates/tools). DB currently has 5 EVIDENCE_DISCOVERY phases incl. `_GMAIL` + `_LOCAL`; spec expects 2 with `_EMAIL`. **First substantive Block 13 task should mirror B12·P02's phase rebuild for IN_MONTHLY** before any IN-side gate/tool wiring lands.

Full per-block summaries + all gotchas (audit.emit_audit signature, tool_registry retry CHECK, gate_registry naming, side_effect array cast, transactions.transaction_type NOT NULL, review_issues schema shape, documents column naming, business table is `business_entities` not `businesses`, file_hash + transaction_fingerprint require sha256 hex format, etc.) live in the `project-meta` drawer.

Latest migration file: `supabase/migrations/20260524000018_audit_m4_in_adjustment_phase_rebuild.sql` (audit fixes 13–18 applied 2026-05-24). Next migration should start `20260524000019_...`.
