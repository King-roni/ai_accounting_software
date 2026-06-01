# Pre-Testing Readiness Audit — 2026-06-01

**Verdict: NOT yet walkable end-to-end by a tester.** The build is broad and the
units are healthy (web tsc+eslint clean, api 312/314 tests pass), but a cluster
of integration/ops blockers means the core journey (upload → classify → match →
ledger → finalize → adjust → export) cannot currently be completed in the app.
This is a *readiness* gap, not a code-quality gap — most fixes are small.

Method: read-only multi-agent audit (34 agents, ~2.3M tokens, 839 tool calls)
across 9 subsystems + adversarial verification of every Blocker/High + a
completeness critic. Source: workflow `pretest-readiness-audit` (run
`wf_c5c2d33b-771`). Tested against the **live** project `noxvmnxrqlzsdfngfiww`
(the live DB is the source of truth — see rebuild note below).

---

## Two corrections to prior assumptions (verified)

1. **The orchestrator phase handlers are NOT stubs.** `phases.py:214-217` overrides
   the literal registry with real engines — `CLASSIFICATION`, `MATCHING`,
   `INCOME_MATCHING`, `LEDGER_PREPARATION` all run real per-transaction work.
   `handle_wiring_pending` ends up bound to **zero** phases. Only `AI_END_SCAN` +
   `EVIDENCE_DISCOVERY_EMAIL/DRIVE` are genuine stubs. The pipeline CAN run
   deterministically end-to-end (no AI keys needed) **once a run is actually driven**.
   (The `phases.py` module docstring is stale and says otherwise — misleading.)
2. **The REQUIRE_STEP_UP bug does NOT block the finalize/approve path.**
   `transition_run`, `out/in_workflow_user_approval` all handle `REQUIRE_STEP_UP`
   correctly. The bug bites `request_statement_upload` (active, but that RPC is
   **orphaned** — the live upload path uses `request_raw_upload` + the *patched*
   `complete_statement_upload`) plus **7 latent** admin RPCs whose surfaces aren't
   step-up today. Real blast radius is smaller than "9 RPCs deny OWNER" implied.

---

## BLOCKERS — must fix (or stand up a harness) before meaningful testing

1. **`execute_lock_sequence` has zero callers → monthly runs can never reach
   FINALIZED via the app.** `FinalizationChecklist.approveWithStepUp` only records
   an approval; nothing calls the lock sequence (the engine treats `FINALIZATION`
   as an await-approval sentinel). Fix: have the checklist call
   `execute_lock_sequence(run, actor, {})` after a successful step-up approval
   (mirror `AdjustmentFinalizePanel.refinalize`), or add a worker step. Cascades:
   no archive package → R7.8 Archive/adjustment UI unreachable.
2. **Worker can't drive the seeded runs.** `WORKER_SYSTEM_ACTOR_USER_ID` is unset
   and the 4 seeded runs have `started_by=null` + empty `principal_snapshot`, so
   `require_actor()` raises → `safe_drive_run` swallows it as CRASH → runs sit at
   CREATED forever. Worse: the seeded runs are non-canonical (the real
   start/upload paths populate the actor), so even setting the env var won't drive
   *those* rows. Fix: set the env var to the demo owner AND re-seed runs via
   `out_workflow_start_run_manually`/`create_paired_workflow_runs`, or backfill
   `started_by`+snapshot.
3. **No worker is running and nothing schedules the tick.** pg_cron only has the
   daily invoice/pro-forma jobs; the tick endpoint is 503 (no `WORKER_TICK_SECRET`).
   Nothing advances runs/exports/ingestion automatically. Fix: run
   `python -m cyprus_bookkeeping_api.worker` for the test window (poll 5s).
4. **Default accounting period = current month (June 2026), which has zero demo
   data.** Dashboard/Transactions/Ledger open empty; the dashboard "month-to-date"
   headline shows 0 while rolling-12m has data (mixed signal). All demo data is
   Feb–May 2026. Fix: default the period to the latest month with data, or seed a
   current-month row, or add an "empty period — jump to May" hint.
5. **Statement-upload journey dead-ends silently.** Upload enqueues an outbox row;
   `consume_statement_upload_completed_event` only runs inside the worker tick (not
   running). UI polls "Queued" forever, no error. Fix: run the worker + add a
   stuck-detection timeout in `RecentUploads`.
6. **No MFA factor seeded for admin@admin.com.** Every step-up-gated flow
   (finalize, team role-change/remove, integration disconnect) dead-ends at "MFA
   not enrolled". Fix: seed a verified TOTP factor + recovery codes, or make
   "enroll authenticator" the explicit first step of the test script.
7. **No global `error.tsx`/`not-found.tsx`/`global-error.tsx`.** Any
   server-component throw or bad URL drops the tester onto a raw Next.js crash/404
   with no recovery. Several async server pages (`integrations`, `team`) have
   unguarded awaits. Fix: add branded error + not-found boundaries with a
   "Back to dashboard" action.
8. **Finalization preconditions can't be satisfied for demo data + no finalized
   period exists.** Unclassified txns → HIGH `classification.needs_confirmation`
   issues that `gate_finalization_zero_blocking_issues` treats as blocking, with
   **no in-app RPC to confirm/resolve a classification issue**. Fix: add a
   classify-confirm RPC+UI, and/or seed a fully-processed + FINALIZED period (under
   the `seed-r79` teardown tag) so R7.8 Archive/adjustment is demoable.

## SHOULD-FIX (HIGH) — fix before broad testing or scope explicitly

- **REQUIRE_STEP_UP stale-vocab sweep (8 RPCs).** `request_statement_upload`
  (active, orphaned) + `activate_redaction_policy`, `deploy_prompt`,
  `rollback_prompt`, `register_prompt`, `grant_cost_ceiling_override`,
  `update_business_ai_config`, `update_business_cost_ceiling` (latent). Change
  `NOT IN ('ALLOW','STEP_UP')` → `NOT IN ('ALLOW','STEP_UP','REQUIRE_STEP_UP')` and
  add a guard test. (The P0.2 patch only fixed `complete_statement_upload` +
  `trigger_run_manual` and noted ~9 remain.)
- **No realtime/polling on run/period/matching/ledger screens** → the app looks
  frozen during async backend work (phases never tick forward without a manual
  reload). Add a `refreshInterval` while a run is non-terminal, or a Supabase
  realtime subscription.
- **`adjustment_records` dead-code** — `check_adjustment_intake_gate`,
  `record_adjustment_finalization_handoff`, unattached
  `fn_check_adjustment_record_run_type` reference non-existent columns
  (`workflow_run_id`, `target_record_type`) → 42703 if reached. Fix to `run_id` or
  retire. (Not on the live re-finalize path, so latent.)
- **Demo fixtures too shallow / inconsistent.** `match_records` (3) contradict
  `transactions.match_status` (all UNMATCHED); pre-existing progressed-state rows
  (matches/reviews/notifications/exports) aren't produced by the seed nor cleared
  by reset; Feb/Mar transactions have no `workflow_run`; no raw CSV bytes in
  storage (can't re-parse). Reconcile under the `seed-r79` tag.
- **Migration rebuild integrity.** Two divergent rebuild artifacts (233 repo
  migrations vs the `_baseline/` MCP-introspected snapshot, which post-dates
  a6*/p0_*/r7_*), neither replay-verified; no `supabase/config.toml`; ledger drift
  (264 live vs 233 repo); `p0_2..p0_5` not in the live ledger. **Test against the
  live DB only**; reconcile before any fresh rebuild / branch DB.
- **Keys-gated integrations are inert (overlaps P2/R8).** Anthropic key not in the
  `secrets.managed_secrets` vault → Tier-3 AI raises; OCR is Google Document AI and
  the Python runner is unwritten (PDFs silently skipped despite the UI promising
  OCR); Google OAuth unset → integrations "Connect" throws. Scope AI/OCR/integration
  testing OUT of this pass, or provision keys (P2).

## KNOWN LIMITATIONS / scope-out for first test pass

- Ledger surface is empty until a run is driven (depends on Blockers 2/3).
- Multi-business aggregation unexercised (demo owner has one business).
- Invoice "Preview PDF data" returns a JSON payload, not a rendered PDF.
- Integrations page is off-brand + chrome-less; Help is a "coming soon" placeholder;
  per-session revoke + MFA recovery-code regen are deferred (copy is dev-facing).
- Mobile: period switcher is hidden < sm, so a mobile tester can't escape the empty
  default period.

## MEDIUM/LOW hygiene (post-test or opportunistic)

- 39 tracked `__pycache__/*.pyc` (27 dirty) despite `.gitignore` → `git rm -r
  --cached` them. No CI pipeline. Zero web unit tests (e2e is the only web coverage,
  brittle to seed literals). 17 SECURITY DEFINER views (verify each tenant-filters).
  `vies_checks` RLS-on/no-policy (deny-all; confirm reads go via SECDEF). No
  run-claim lease (single-worker only). Live prod-grade secrets in plaintext on disk
  (rotate before distribution). FastAPI CORS hardcoded to localhost; no security
  response headers; `export-artifacts` bucket omitted from the at-rest self-check;
  placeholder SPKI pins block APP_ENV=production startup (R4/P3).

---

## What IS testable right now (steer testers here)

Set the period to **May 2026** first, then: Transactions (view), Documents,
Invoices (list/detail/create — not PDF render), Clients (+ VIES badges),
Subscriptions, Reports (catalogue + download the 2 COMPLETED exports), Matching
(switch filter to "All matches"), Reviews (snooze/assign — 4 issues), Notifications
(bell + drawer + mark-read — 4 unread), Team (invite/list), Account (profile, MFA
*enroll*, sign-out-others). VIES is the one live external integration that works.

## Recommended pre-test fix order

1. Set `WORKER_SYSTEM_ACTOR_USER_ID` + run the worker (Blockers 2,3).
2. Re-seed runs canonically + a fully-processed + FINALIZED May period (Blockers 2,8; fixtures).
3. Wire `execute_lock_sequence` into FinalizationChecklist (Blocker 1).
4. Default period → latest-with-data; add error/not-found boundaries (Blockers 4,7).
5. Add refresh interval to run/period screens; stuck-detect on uploads (Blocker 5, HIGH).
6. REQUIRE_STEP_UP 8-RPC sweep + adjustment_records dead-code fix (HIGH).
7. Seed an MFA factor or script "enroll first" (Blocker 6).

Plane: see cycle **"★ Pre-Testing — Readiness Blockers (2026-06-01 audit)"**.
