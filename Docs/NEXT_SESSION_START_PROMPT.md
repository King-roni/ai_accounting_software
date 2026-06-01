# NEXT SESSION — Pre-Testing: Readiness Fixes → Deep Re-Audit → Guided E2E

**Paste this as the first message of the next session.** It is an
ultracode/workflow-scale run: stand the demo up so the full journey works, then
adversarially re-verify, then drive guided end-to-end testing — as one insane,
multi-agent pass. Read `Docs/handoff/2026-06-01_pretest_readiness_audit.md` and the
Plane cycle "★ Pre-Testing — Readiness Blockers (2026-06-01 audit)" before acting.

---

You are taking the Cyprus Bookkeeping SaaS into its manual testing phase. The
2026-06-01 readiness audit found the app is NOT yet walkable end-to-end. Your job
this session, at maximum thoroughness (ultracode — token cost is not a constraint;
orchestrate with multi-agent workflows, adversarially verify every fix and finding,
and run a completeness critic):

CONTEXT
- Real codebase: `/Users/pep_o23kd/Desktop/Cursor/Personal/boekhoudings_Ai_software`
  (web/ Next.js+pnpm, api/ FastAPI+uv, supabase/migrations). Live DB =
  Supabase `noxvmnxrqlzsdfngfiww` (the source of truth — do NOT rely on a clean
  rebuild; the repo↔live migration ledger has drift). Demo: admin@admin.com (OWNER,
  password admin123), business `0e000000-0000-4000-8000-0000000000b1`, org `…001`,
  public user `019e751a-0eda-7c6e-9c79-7e2c4ea9bff7`. Data spans Feb–May 2026.
- Branch `build/full-snapshot-2026-05-29`; commit per piece; ff `main`; push; end
  commit messages with `Co-Authored-By: claude-flow <ruv@ruv.net>`. No secrets in
  commits. Keep demo mutations reversible (scripts/seed_demo_dataset.sql +
  reset_demo_dataset.sql; tag new fixtures `seed-r79`).

PHASE A — Stand up the harness / clear the BLOCKERS (fix + verify each):
1. Set `WORKER_SYSTEM_ACTOR_USER_ID` to the demo owner and start the worker
   (`python -m cyprus_bookkeeping_api.worker`); confirm a tick advances a run.
2. Re-seed the demo runs CANONICALLY (via `out_workflow_start_run_manually` /
   `create_paired_workflow_runs`, not raw inserts) so they carry started_by +
   principal_snapshot; drive one OUT+IN May period through to AWAITING_APPROVAL.
3. Wire `execute_lock_sequence` into `FinalizationChecklist` (after a successful
   STEP_UP approval) so a month can reach FINALIZED + produce an archive package;
   verify the R7.8 Archive/adjustment UI then populates.
4. Seed a fully-processed + FINALIZED May 2026 period (+ one adjustment) under the
   `seed-r79` tag so Archive/adjustment is demoable even without a live run.
5. Default the accounting period to the latest month with data (or seed current-
   month rows); add branded `error.tsx` + `not-found.tsx` + `global-error.tsx`.
6. Add a `refreshInterval` (or Supabase realtime) to run/period/matching/ledger
   SWR while runs are non-terminal; add stuck-detection to `RecentUploads`.
7. REQUIRE_STEP_UP sweep: patch the 8 RPCs (`NOT IN ('ALLOW','STEP_UP')` →
   add `'REQUIRE_STEP_UP'`) + add a guard test. Fix the adjustment_records
   dead-code (`workflow_run_id`/`target_record_type` → `run_id` / retire).
8. Seed a verified TOTP factor + recovery codes for admin@admin.com (or make
   "enroll authenticator" step 1 of the test script).
Re-run `npx tsc --noEmit` + `npx eslint src` (web) and `uv run pytest` (api) after
fixes; nothing else gates them (no CI).

PHASE B — Deep multi-agent VERIFICATION re-audit (read-only, adversarial):
Re-run a fan-out audit (security/RLS, workflow/finalization, data integrity, auth,
frontend, api/worker, migrations) that (a) confirms each Phase-A fix actually
holds with file:line/DB evidence, and (b) hunts for NEW regressions + anything the
first audit missed. Adversarially verify every Blocker/High; run a completeness
critic. Update the readiness report with the new verdict.

PHASE C — Guided END-TO-END testing (drive the product, log defects):
As the demo OWNER, walk the full journey in a real browser (Playwright): log in →
enroll MFA → upload a Revolut CSV → watch parse/normalize/dedup → classify → match
(confirm/reject) → review queue (resolve/snooze) → ledger → finalize a period
(step-up) → verify archive integrity → open an adjustment → re-finalize → export +
download. Also sweep every nav screen for crashes/empty states/placeholder copy.
Capture screenshots; log EVERY defect as a Plane work item in the readiness cycle
with severity + repro + evidence. Produce a final go/no-go test report.

Deliverables: all Phase-A fixes committed + pushed; updated readiness report;
defects logged in Plane; a go/no-go verdict for opening the product to testers.
