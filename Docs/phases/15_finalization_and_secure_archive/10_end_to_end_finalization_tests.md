# Block 15 — Phase 10: End-to-End Finalization Tests

## References

- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md`
- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Phase 10 — invariant-test pattern)
- Prior block Phase 10s (golden-fixture conventions)

## Phase Goal

Build the regression-test layer for Block 15's full surface: clean monthly lock, all 8 precondition gates, step-up auth requirement, the 8-step lock sequence with auto-retry, archive package construction (deterministic bundle hash), manifest versioning across adjustments, three-layer immutability, re-finalization for adjustment runs, the failure-mode taxonomy, and resumability after engine restart. After this phase, every change to any Block 15 phase runs against a fixture suite that catches drift before merge.

## Dependencies

- All Block 15 phases (01–09)
- Prior block Phase 10s (Blocks 02 through 14 — fixture format conventions)

## Deliverables

- **Golden fixtures directory** — `Docs/phases/15_finalization_and_secure_archive/fixtures/`:
  - Per-fixture files: `business_state.json`, `pre_finalization_state.json` (the operational state at the start of FINALIZATION), `expected_archive_package_state.json`, `expected_workflow_run_state.json`, `expected_audit_events.json`, `expected_locked_ledger_entries_count.json`, `expected_bundle_hash_anchor.json` (for deterministic-bundle tests), `recorded_step_up_auth_responses.json` (for the TOTP / passkey simulation).
- **Clean lock fixtures:**
  - `lock_clean_out_monthly_happy_path` — single business; all 8 preconditions met; step-up'd approval; lock sequence runs in one pass; archive bundle written with deterministic hash; locked ledger rows promoted; `FINALIZATION_LOCK_COMMITTED` audit event fires.
  - `lock_clean_in_monthly_happy_path` — symmetric IN-side; bundle includes `vies_export.csv` with the expected counterparty rollup.
  - `lock_clean_paired_out_in_runs_independent_finalize` — both runs from one Statement Upload; OUT finalizes while IN is still in HOLD; no cross-contamination.
  - `lock_clean_deterministic_bundle_hash` — same input across two builds → byte-identical bundle → identical `bundle_hash_anchor`.
  - `lock_clean_period_report_pdf_deterministic` — same input → byte-identical `period_report.pdf`.
- **Precondition fixtures (per-gate negative test):**
  - `precondition_transactions_processing_holds` — one transaction in `PENDING_DEDUP` → gate 1 fails → composite `HOLD` with `transactions_processed`.
  - `precondition_unknown_type_holds` — one row with `transaction_type = UNKNOWN` → gate 2 fails.
  - `precondition_evidence_unsatisfied_holds` — one OUT_EXPENSE NO_MATCH without exception → gate 3 fails.
  - `precondition_draft_ledger_incomplete_holds` — one in-scope transaction without ledger entries → gate 4 fails.
  - `precondition_vat_classification_incomplete_holds` — one entry with null `vat_treatment` → gate 5 fails.
  - `precondition_blocking_issue_open_holds` — one BLOCKING issue OPEN → gate 6 fails.
  - `precondition_no_approval_recorded_holds` — no `workflow_run_approvals` row → gate 7 fails.
  - `precondition_audit_log_pending_holds` — pending audit-log writes → gate 8 fails.
  - `precondition_first_failure_halts_subsequent_gates_skipped` — gate 2 fails → gates 3–8 do NOT run; the failure_payload identifies gate 2 only.
- **Approval / step-up fixtures:**
  - `approval_step_up_owner_finalizes` — Owner records step-up'd approval → finalizes.
  - `approval_step_up_admin_finalizes` — Admin path symmetric.
  - `approval_standard_method_rejected_at_finalization` — `STANDARD` approval clears HUMAN_REVIEW_HOLD but `gate.finalization.approval_recorded` rejects; UI prompts for step-up; second approval (STEP_UP) succeeds.
  - `approval_bookkeeper_step_up_denied` — Bookkeeper attempts step-up'd approval; matrix narrowing rejects.
  - `approval_accountant_denied` — Accountant attempts any approval; denied per existing matrix.
  - `approval_revoked_blocks_finalization` — approval recorded then revoked → gate 7 fails.
  - `approval_step_up_5_failures_lockout` — 5 failed step-up attempts trigger Block 02 Phase 06 lockout.
  - `approval_step_up_window_expired_re_prompts` — user step-up's at HUMAN_REVIEW_HOLD time but doesn't approve until 6 minutes later → Block 02 Phase 06's 5-minute step-up validity window has expired → re-prompt for fresh step-up; the original approval row is treated as `STANDARD` for finalization purposes (the step-up validity has lapsed).
  - `approval_staleness_after_new_blocking_issue` — new blocker post-approval makes the prior approval stale; fresh STEP_UP required.
- **Lock-sequence fixtures:**
  - `lock_sequence_8_steps_in_order` — fixture verifies each step fires in order via audit events.
  - `lock_sequence_atomicity_step5_fails_rolls_back` — step 5 (Object Lock) failure → entire sequence rolls back; no `archive_packages` / `locked_ledger_entries` rows; bundle file cleaned up.
  - `lock_sequence_storage_compensation_runs` — step 4 fails after step 3 wrote bundle; bundle compensation deletes the orphan; `FINALIZATION_STORAGE_COMPENSATION_RAN` fires.
  - `lock_sequence_audit_event_atomic_with_state_transition` — step 6 + step 7 commit together; on rollback, neither persists.
  - `lock_sequence_step_8_failure_does_not_rollback` — analytics enqueue fails AFTER lock commit; run remains `FINALIZED`; HIGH issue surfaces; analytics catches up via reconciliation.
  - `lock_sequence_idempotent_on_already_finalized` — re-invocation of `execute_lock_sequence` on a `FINALIZED` run is a no-op; `FINALIZATION_NO_OP_ALREADY_FINALIZED` fires.
- **Auto-retry fixtures (Phase 09):**
  - `retry_transient_failure_step5_succeeds_on_retry` — first attempt fails (simulated storage blip); auto-retry succeeds; run finalizes with one retry event.
  - `retry_persistent_failure_step5_raises_high_issue` — both attempts fail; HIGH `finalization.object_lock_failed` issue surfaces; bundle file cleaned up.
  - `retry_deterministic_failure_no_retry_blocking` — evidence-hash-mismatch at step 2 → no auto-retry; BLOCKING issue surfaces immediately.
  - `retry_backoff_timing` — auto-retry fires after the configured 5-second delay (with jitter); fixture asserts the wait.
- **Archive-package construction fixtures (Phase 05):**
  - `bundle_contains_all_11_file_types` — verifies presence of every file from the layout.
  - `bundle_two_pass_manifest_self_reference_converges` — manifest's `bundle_hash_anchor` field equals the SHA-256 of the final bundle bytes.
  - `bundle_evidence_deduplicated_by_hash` — two `match_records` rows pointing at the same document → bundle's `evidence/` contains one file.
  - `bundle_vat_summary_matches_locked_ledger_totals` — `vat_summary.json` totals = sum of `locked_ledger_entries` per treatment.
  - `bundle_vies_export_groups_correctly` — multiple `vies_relevant = true` entries for one counterparty → grouped into one row in `vies_export.csv`.
  - `bundle_zip_deterministic_no_timestamps` — same input → byte-identical zip; mtimes are zeroed.
- **Manifest versioning fixtures (Phase 06):**
  - `manifest_v1_at_original_finalization` — first lock writes `manifest_v1.json`; `archive_manifests` has one row with `version = 1`.
  - `manifest_v2_at_first_adjustment` — `OUT_ADJUSTMENT` finalizes; `manifest_v2.json` written; `archive_manifests` gets row with `version = 2`; `manifest_v1.json` unchanged.
  - `manifest_v3_at_second_adjustment` — second adjustment → `manifest_v3.json`; v1 + v2 unchanged.
  - `manifest_chain_walk_reconstructs_history` — reader walks `archive_manifests` ASC; the sequence reflects the period's full history.
  - `manifest_overwrite_blocked_by_object_lock` — direct API call to overwrite `manifest_v1.json` rejected at storage layer.
- **Three-layer immutability fixtures (Phase 07):**
  - `immutability_layer_1_update_locked_ledger_rejected` — UPDATE on `archive.locked_ledger_entries` from any role rejected.
  - `immutability_layer_1_delete_locked_ledger_rejected` — DELETE rejected.
  - `immutability_layer_1_insert_outside_lock_session_rejected` — INSERT outside `app.lock_sequence_active = true` rejected.
  - `immutability_layer_2_object_lock_blocks_overwrite` — storage-layer overwrite rejected.
  - `immutability_layer_2_object_lock_blocks_delete` — delete rejected during retention window.
  - `immutability_layer_3_tamper_detected_on_corrupted_bundle` — simulated bundle byte-corruption → daily reconciliation detects; `ARCHIVE_TAMPER_DETECTED` fires; BLOCKING review issue surfaces.
  - `immutability_layer_3_tamper_detected_on_audit_chain_break` — simulated audit-log chain break → tamper detection; alert.
  - `immutability_pre_read_verification_blocks_tampered_read` — pre-read verification on a tampered package blocks the read.
  - `immutability_on_demand_verification_returns_correct_verdict` — user-triggered verification.
- **Re-finalization fixtures (Phase 08):**
  - `adjustment_clean_path` — finalized period; `OUT_ADJUSTMENT` runs; `ADJUSTMENT_FINALIZATION` produces v2 manifest; original v1 unchanged.
  - `adjustment_does_not_modify_original_locked_rows` — hash comparison verifies original `locked_ledger_entries` rows are byte-identical pre and post adjustment.
  - `adjustment_rejected_for_unfinalized_parent` — parent in `RUNNING` state → adjustment-precondition gate fails.
  - `adjustment_rejected_for_retention_expired` — 7-year-old period → fails.
  - `adjustment_concurrent_with_monthly_run_for_different_period` — `OUT_ADJUSTMENT` for period 1 + `OUT_MONTHLY` for period 3 both progress.
  - `adjustment_two_concurrent_against_same_parent` — two adjustment runs against the same parent → first finalizes as v2, second as v3.
  - `adjustment_step_up_required` — adjustment finalization requires STEP_UP approval (same as monthly).
  - `adjustment_overlay_visible_to_block_16` — Block 16 dashboard reads latest manifest → adjustment overlay surfaces.
- **Resumability fixtures (Phase 09):**
  - `resumability_crash_between_step_3_and_step_4` — simulated crash; restart re-runs from step 1; no orphans.
  - `resumability_crash_between_step_7_and_step_8` — run is `FINALIZED`; analytics-enqueue reconciliation fires on restart.
  - `resumability_storage_orphan_detected` — orphan bundle file detected; logged for cleanup.
- **Cross-cutting fixtures:**
  - `audit_chain_intact_post_lock` — Block 05 hash-chain anchor verifiable at every step; RFC 3161 timestamp valid.
  - `analytics_rebuild_enqueued_post_commit` — step 8 enqueues; Block 04 Phase 09 picks up the job.
  - `lock_sequence_performance_within_budget` — typical period (1000 transactions, 50 ledger rows) finalizes in under 30 seconds.
- **Test runner** — `runFinalizationFixture(fixture_name) → FixtureResult`:
  - Sets up the test business state with seeded `transactions`, `match_records`, `draft_ledger_entries`, `review_issues`, `workflow_run_approvals`.
  - Loads the simulated step-up auth responses.
  - Invokes the lock sequence (Phase 04) or adjustment-finalization sequence (Phase 08) end-to-end.
  - Captures actual archive package state, locked ledger rows, audit events, bundle hash, manifest chain.
  - Compares to expected JSON files exactly.
- **CI integration:**
  - Runs on every PR touching Block 15 phase code, fixtures, or any Block 15 dependency.
  - Failure blocks merge.
  - Performance budget: total fixture run time under 180 seconds.

## Definition of Done

- All listed fixtures exist with input + expected files + recorded responses.
- Running the test runner against any fixture produces the expected output exactly.
- A deliberate change that breaks any Block 15 phase makes the right fixtures fail with clear diffs.
- The deterministic-bundle invariant is verified — same input → byte-identical bundle.
- The manifest chain reconstruction works across at least 3 manifest versions.
- All three immutability layers' rejection paths are verified.
- The auto-retry-once contract is verified for both transient-recovery and persistent-failure paths.
- Resumability across simulated engine restarts produces no orphans.
- All AI calls (period_report.pdf generation has no AI; this block is AI-tier `NONE` end-to-end) are absent.
- CI is wired so PR merges are blocked on fixture failures.
- Performance budget is met.

## Sub-doc Hooks (Stage 4)

- **Fixture format sub-doc** — directory structure, file naming, JSON shapes.
- **Step-up auth simulation sub-doc** — how to mock TOTP / passkey responses in fixtures.
- **Bundle determinism verification sub-doc** — exact byte-comparison methodology.
- **Tamper-detection simulation sub-doc** — how to inject corruption safely in tests.
- **Performance budget sub-doc** — measurement methodology; per-fixture timing.
- **Cross-block fixture-stitching sub-doc** — how Block 15 fixtures inherit upstream state.
