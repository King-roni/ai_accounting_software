# Block 12 — Phase 10: End-to-End OUT Workflow Tests & Golden-File Regression

## References

- Block doc: `Docs/blocks/12_out_workflow.md`
- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Phase 10 — invariant-test pattern)
- Block doc: `Docs/blocks/07_bank_statement_pipeline.md`, `Docs/blocks/08_transaction_classification_and_tagging.md`, `Docs/blocks/09_document_intake_and_extraction.md`, `Docs/blocks/10_matching_engine.md`, `Docs/blocks/11_ledger_and_cyprus_vat_engine.md` (Phase 10s — golden-fixture conventions)

## Phase Goal

Build the regression-test layer for the full `OUT_MONTHLY` and `OUT_ADJUSTMENT` workflow types. Cover: clean monthly run, runs held at `MANUAL_UPLOAD_HOLD` and `HUMAN_REVIEW_HOLD`, INTERNAL_TRANSFER dedup across the parallel OUT+IN pair, paired-run linkage, OUT_MONTHLY + OUT_ADJUSTMENT concurrency, the 7-day reminder cadence, the retention-expiry rejection, and the per-business config short-circuits. After this phase, every change to any Block 12 phase runs against a fixture suite that catches drift before merge.

## Dependencies

- All Block 12 phases (01–09)
- Block 02 Phase 10 (invariant-test pattern)
- Block 07 / 08 / 09 / 10 / 11 Phase 10s (golden-fixture format conventions); these per-block fixtures are the upstream sources Block 12's fixtures stitch together
- Block 06 Phase 10 (recorded AI responses for end-scan and plain-language calls; consumed across multiple phases)

## Deliverables

- **Golden fixtures directory** — `Docs/phases/12_out_workflow/fixtures/`:
  - Per-fixture files: `business_state.json` (chart of accounts, rules, vendor memory, OUT config, role assignments), `input_statement_upload.json` (file content + period), `input_documents.json` (matched-document corpus available across email/Drive/manual paths), `input_invoices.json` (where present, for the IN-pair fixtures), `expected_workflow_run_state_machine.json` (the ordered list of run-state transitions), `expected_phase_outputs.json` (per-phase: transactions, classifications, match records, draft ledger entries, review issues, audit events), `expected_archive_bundle_manifest.json` (for fixtures that reach `FINALIZATION`), `recorded_ai_responses.json`.
- **Initial fixture set:**
  - **Clean monthly run:**
    - `out_monthly_clean_happy_path` — single business, 50 OUT-side transactions of mixed types, all matched cleanly, no review issues, user clicks Approve, run finalizes. End-to-end run-state transitions: `CREATED → RUNNING → AWAITING_APPROVAL → FINALIZING → FINALIZED`. Verify no side phases entered.
  - **Held at `MANUAL_UPLOAD_HOLD`:**
    - `out_monthly_held_unmatched_evidence` — three OUT_EXPENSE rows have `match_status = NO_MATCH`; the run enters `MANUAL_UPLOAD_HOLD`; verify run-level state is `REVIEW_HOLD`, the gate's `ROUTE_TO_SIDE_PHASE` decision, and the `OUT_MANUAL_UPLOAD_HOLD_ENTERED` audit event.
    - `out_monthly_manual_upload_resolves_hold` — same fixture as above, then user invokes `out_workflow.upload_invoice` for each held row; the matcher runs; the gate clears; the run resumes through `LEDGER_PREPARATION`.
    - `out_monthly_exception_documented_resolves_hold` — same fixture, but user invokes `out_workflow.document_exception` with a mandatory reason; `match_status = EXCEPTION_DOCUMENTED`; the gate clears.
    - `out_monthly_reminder_fires_after_seven_days` — held run with the simulated clock advanced 7 days; `out_workflow.send_reminder` fires once; verify `OUT_MANUAL_UPLOAD_REMINDER_SENT` audit event with cadence-ordinal `1`. Advance another 7 days → cadence-ordinal `2`. **No auto-action** ever fires regardless of how long the hold lasts.
    - `out_monthly_reminder_suppressed_when_disabled` — `manual_upload_hold_reminder_enabled = false`; advance the clock 30 days; verify zero reminder events.
    - `out_monthly_re_enters_manual_upload_hold_after_recompute` — held run exits cleanly; downstream `LEDGER_PREPARATION` recompute discovers a newly-NO_MATCH OUT_EXPENSE (e.g., a chart customization disabled the previously-resolved mapping); the engine routes back to `MANUAL_UPLOAD_HOLD`; verify `OUT_MANUAL_UPLOAD_HOLD_RE_ENTERED` audit event AND a fresh reminder cadence (the 7-day window starts from re-entry, not from the original entry).
  - **Held at `HUMAN_REVIEW_HOLD`:**
    - `out_monthly_held_blocking_high_issue` — AI_END_SCAN produces one HIGH-severity review issue in the `Possible Tax/VAT Issue` bucket; the run enters `HUMAN_REVIEW_HOLD`; verify run-level state is `AWAITING_APPROVAL`.
    - `out_monthly_user_resolves_and_approves` — same fixture, then user resolves the issue (Block 14 path) and invokes `out_workflow.user_approval`; the gate clears; the run finalizes.
    - `out_monthly_approval_required_even_with_no_issues` — fixture with zero issues; the run still enters `HUMAN_REVIEW_HOLD` (per Phase 07 — approval is required regardless of issues); user approves; run finalizes.
    - `out_monthly_approval_revoked_re_holds` — user approves, then revokes; the gate flips back to `HOLD`; run remains in `AWAITING_APPROVAL`.
    - `out_monthly_new_blocking_issue_post_approval_stales_approval` — user approves; a re-run of `AI_END_SCAN` (after a re-classification) produces a new HIGH issue; verify `OUT_HUMAN_REVIEW_APPROVAL_STALENESS_DETECTED` fires; the gate flips to `HOLD`; the prior approval row remains in audit but is no longer counted.
    - `out_monthly_approval_denied_for_accountant` — Accountant role attempts approval; denied with the right error.
  - **Per-business config short-circuits:**
    - `out_monthly_email_finder_disabled` — `evidence_discovery_email_enabled = false`; verify `EVIDENCE_DISCOVERY_EMAIL` is entered and immediately exits with `OUT_WORKFLOW_PHASE_SKIPPED_BY_CONFIG`; matching still proceeds against Drive + manual sources.
    - `out_monthly_drive_finder_disabled` — same shape for Drive.
    - `out_monthly_auto_start_disabled` — Statement Upload event fires; `auto_start_on_statement_upload = false`; verify `OUT_WORKFLOW_AUTO_START_SUPPRESSED` and no run created. Then user invokes `out_workflow.start_run_manually`; run is created normally.
  - **OUT/IN paired run:**
    - `paired_out_in_clean_run` — single Statement Upload triggers both `OUT_MONTHLY` and `IN_MONTHLY`; verify INGESTION fires once across both runs; verify `paired_run_id` linkage on both `workflow_runs` rows; verify both runs progress in parallel.
    - `paired_out_in_internal_transfer_dedup` — fixture includes one `INTERNAL_TRANSFER` transaction; both runs reach `LEDGER_PREPARATION`; verify exactly one `draft_ledger_entries` PRIMARY row exists for the transfer; verify both runs' audit chains contain a `LEDGER_DRAFT_ENTRY_CREATED` event for that row.
    - `paired_out_finalizes_before_in` — OUT finalizes while IN is still in `MANUAL_UPLOAD_HOLD`; verify OUT's `FINALIZATION` succeeds independently; IN remains held.
  - **Triggers and idempotency:**
    - `manual_trigger_duplicate_rejected` — user manually starts; while the first run is `RUNNING`, user starts again for the same period; verify second start returns `OUT_WORKFLOW_RUN_ALREADY_ACTIVE`.
    - `event_trigger_dedup_on_duplicate_event` — same `STATEMENT_UPLOAD_COMPLETED` event arrives twice; verify only one run is created; `OUT_WORKFLOW_EVENT_TRIGGER_DEDUPLICATED` fires.
    - `manual_trigger_for_finalized_period_rejected` — user attempts manual start for an already-finalized period; verify `OUT_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED`.
    - `manual_trigger_denied_for_read_only` — Read-only role attempts start; denied.
  - **`OUT_ADJUSTMENT`:**
    - `adjustment_clean_path` — finalized period from a prior fixture run; user initiates `out_workflow.adjustment_intake` with `delta_kind = CORRECT_VAT_TREATMENT` and a mandatory reason; verify the 6-phase adjustment sequence executes; `ADJUSTMENT_FINALIZATION` interleaves the new adjustment entry into the archive additively.
    - `adjustment_does_not_modify_original_entries` — same fixture; verify the original `draft_ledger_entries` rows in `LOCKED` status have unchanged content (a hash comparison).
    - `adjustment_concurrent_with_monthly_run` — `OUT_ADJUSTMENT` for period 1 runs concurrently with `OUT_MONTHLY` for period 3; both progress; both run ids are recorded on touched entries.
    - `adjustment_rejected_for_retention_expired` — user attempts adjustment on a 7-year-old period; verify `OUT_ADJUSTMENT_REJECTED_RETENTION_EXPIRED`.
    - `adjustment_rejected_for_unfinalized_parent` — user attempts adjustment against a `RUNNING` (non-finalized) parent run; verify `OUT_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED`.
  - **Failure-mode robustness:**
    - `transient_failure_retry_then_success` — Block 09's email finder times out twice then succeeds; verify the bounded-retry pattern (Block 03 Phase 08) and the run continues without holding.
    - `permanent_failure_holds_phase` — a persistent OCR failure raises a HIGH review issue; verify `LEDGER_PHASE_HOLDING` (Block 11 Phase 09) fires; user resolves manually and the run resumes.
    - `crash_mid_phase_resumes` — simulate a crash during MATCHING; verify the engine resumes from the last persisted phase boundary; idempotency keys prevent double-writes.
- **Test runner** — `runOutWorkflowFixture(fixture_name) → FixtureResult`:
  - Sets up the test business per `business_state.json` (chart, mapping rules, vendor memory, OUT config, role assignments).
  - Loads the input statement upload, document corpus, optional invoices, and recorded AI responses.
  - Runs the relevant workflow type (`OUT_MONTHLY` or `OUT_ADJUSTMENT`) end-to-end via Block 03's engine.
  - Captures actual run-state transitions, per-phase outputs, audit events, archive bundle manifest.
  - Compares to expected JSON files exactly. Failure produces a clear diff highlighting which transition, output field, audit event, or bundle file diverged.
- **CI integration:**
  - Runs on every PR touching Block 12 phase code, fixtures, or any Block 12 dependency in Blocks 02 / 03 / 04 / 05 / 06 / 07 / 08 / 09 / 10 / 11.
  - Failure blocks merge.
  - Performance budget: total fixture run time under 180 seconds (the workflow tests are end-to-end and span every domain block; longer than per-block fixtures).
- **Audit events:** `OUT_WORKFLOW_FIXTURE_RAN`, `OUT_WORKFLOW_FIXTURE_PASSED`, `OUT_WORKFLOW_FIXTURE_FAILED`. Fixture removal is governance-only (PR documentation).

## Definition of Done

- All listed fixtures exist with input + expected files + recorded responses.
- Running the test runner against any fixture produces the expected output exactly.
- A deliberate change that breaks any Block 12 phase (e.g., flipping a gate's return value, dropping the manual-upload-hold reminder, removing the `paired_run_id` linkage) makes the right fixtures fail with clear diffs.
- The INTERNAL_TRANSFER dedup fixture passes — exactly one ledger entry across the OUT+IN pair.
- The 7-day reminder fixture passes — exactly one reminder per cadence boundary, no auto-action.
- The retention-cap rejection fixture passes — adjustment beyond 6 years is rejected.
- All AI calls in CI use recorded responses; no live API hits.
- CI is wired so PR merges are blocked on fixture failures.
- Performance budget is met.
- Adding a fixture is easy; removing one requires a documented PR entry.

## Sub-doc Hooks (Stage 4)

- **Fixture format sub-doc** — directory structure, file naming, JSON shapes, mock-service seeding rules.
- **AI response recording sub-doc** — capture procedure across multiple AI-using phases, version pinning, when to re-record.
- **Per-fixture content sub-doc** — what each fixture covers, why it's representative, the expected runtime.
- **Live integration test cadence sub-doc** — schedule and scope (the deferred VIES-online and live VAT-rate-table checks; live email/Drive integration tests).
- **Performance budget sub-doc** — measurement methodology for end-to-end workflow tests; per-phase timing breakdown.
- **Cross-block fixture-stitching sub-doc** — how Block 12's fixtures inherit / extend per-block fixtures from Blocks 07–11.
