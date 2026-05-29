# Block 14 — Phase 10: End-to-End Review Queue Tests

## References

- Block doc: `Docs/blocks/14_review_queue.md`
- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Phase 10 — invariant-test pattern)
- Block doc: prior Phase 10s of Blocks 07 / 08 / 09 / 10 / 11 / 12 / 13 (golden-fixture conventions)

## Phase Goal

Build the regression-test layer for Block 14: issue routing across upstream blocks, severity-driven finalization gating, all 13 resolution actions, bulk actions with mandatory confirmation, snooze + cross-run carry-forward, re-scan-on-resolution affected-set scope, notes & assignment + notification, and mobile read-only enforcement. After this phase, every change to any Block 14 phase runs against a fixture suite that catches drift before merge.

## Dependencies

- All Block 14 phases (01–09)
- Block 02 Phase 10 (invariant-test pattern)
- Prior block Phase 10s (golden-fixture format conventions)
- Block 06 Phase 10 (recorded AI responses for card-content generation)

## Deliverables

- **Golden fixtures directory** — `Docs/phases/14_review_queue/fixtures/`:
  - Per-fixture files: `business_state.json` (chart, mapping rules, role assignments, opening review_issues), `input_actions.json` (sequence of resolution / assignment / snooze / bulk / re-scan calls), `expected_review_issues_state.json` (the post-action `review_issues` rows including notes, assignment, snooze, status), `expected_audit_events.json`, `expected_workflow_gate_state.json` (when actions affect run gates), `recorded_ai_responses.json` (for card-content generation calls).
- **Issue-routing fixtures** (Phase 02):
  - `routing_endscan_unusual_amount` — Block 06 raises `endscan.unusual_amount`; lands in `Unusual Transaction` MEDIUM.
  - `routing_matching_no_match_out_expense` — Block 10 raises `matching.no_match_out_expense`; lands in `Missing Documents` HIGH.
  - `routing_classification_unknown_type` — Block 08 raises `classification.unknown_type`; lands in `Possible Wrong Match` HIGH.
  - `routing_ledger_accountant_review_unknown_treatment` — Block 11 raises; lands in `Possible Tax/VAT Issue` HIGH.
  - `routing_invoice_numbering_gap_detected` — Block 13 raises; lands in `Possible Wrong Match` HIGH.
  - `routing_unregistered_issue_type_rejected` — attempting to insert a row with unregistered `issue_type` is rejected with `REVIEW_ISSUE_TYPE_REJECTED`.
- **Severity gating fixtures** (Phase 02):
  - `severity_high_blocks_finalization_gate` — single HIGH OPEN issue; `gate.out.ai_end_scan_complete` returns `ROUTE_TO_SIDE_PHASE`.
  - `severity_medium_does_not_block` — single MEDIUM OPEN issue; gate ADVANCEs.
  - `severity_blocking_blocks_even_with_approval` — BLOCKING issue + recorded approval → gate still HOLDs.
  - `severity_critical_value_rejected` — attempting to set `severity = CRITICAL` is rejected at the schema layer (Block 14's enum has no such value; post-2026-05-08 decisions-log fix).
  - `severity_critical_drift_lint_check` — repository-wide lint scan asserts no phase doc still references `severity ∈ {HIGH, CRITICAL}` SQL or wording. Catches future regressions of the kind that affected Block 12 Phase 07.
- **Card-rendering fixtures** (Phase 03):
  - `card_content_tier_2_default` — typical card; AI tier 2; persisted at issue creation.
  - `card_content_tier_3_escalation_blocking` — BLOCKING severity triggers Tier 3.
  - `card_content_tier_3_escalation_cross_currency` — cross-currency match triggers Tier 3.
  - `card_content_ai_failure_fallback` — recorded AI response is timeout; fallback applied; LOW follow-up issue surfaces.
  - `card_content_cache_hit_in_run` — second issue with identical structured input hits Block 06 Phase 09's cache.
  - `card_content_immutable_after_creation` — post-creation re-render does not change the persisted text (no auto-regenerate).
  - `card_content_regenerate_owner_only` — Owner triggers regenerate → old content preserved in audit; new content persists.
- **Resolution-action fixtures** (Phase 04 — one per action):
  - `resolution_upload_document` — `Upload document` invokes Block 09 Phase 07; on match, issue closes.
  - `resolution_confirm_match` — `Confirm match` invokes Block 10 Phase 03; `match_records.match_status = MATCHED_CONFIRMED`.
  - `resolution_reject_match` — `Reject match` writes to Block 10 Phase 06's rejection memory.
  - `resolution_change_tag` — Block 11 ledger recomputes for the affected entry.
  - `resolution_change_transaction_type` — Block 08 reclassification; OUT/IN filter re-runs if direction changes.
  - `resolution_mark_internal_transfer` / `resolution_mark_bank_fee` — convenience type-changes work.
  - `resolution_mark_non_deductible` — Block 11 chart-of-accounts customization sets the non-deductible sub-account.
  - `resolution_mark_no_invoice_available` — `out_workflow.document_exception` path; mandatory reason; `effective_match_status = EXCEPTION_DOCUMENTED`.
  - `resolution_add_explanation_note` — issue stays OPEN; note persists.
  - `resolution_send_to_accountant_review` — assignee picker; `assigned_to` set; notification fires.
  - `resolution_ignore_with_reason_medium_succeeds` — MEDIUM issue → `DISMISSED`.
  - `resolution_ignore_with_reason_blocking_rejected` — BLOCKING issue → rejected with `REVIEW_RESOLUTION_REJECTED_BLOCKING_DISMISSAL`.
  - `resolution_re_run_scan_after_change` — manual `Re-run scan after change` invokes Phase 08's wider re-scan.
  - `resolution_disallowed_action_rejected` — invoking an action not in the issue's `allowed_resolution_actions` is rejected.
  - `resolution_permission_denied_for_reviewer` — Reviewer attempting any resolution is denied.
  - `resolution_idempotent_on_already_closed` — re-applying a resolution to a closed issue is a no-op; audit-logged.
- **Bulk-action fixtures** (Phase 05):
  - `bulk_preview_then_apply` — preview returns confirmation token; apply executes 50 issues; 50 audit events.
  - `bulk_partial_success_disallowed_actions` — mix of allowed and disallowed actions; partial result; failures listed.
  - `bulk_severity_blocking_skipped_for_ignore` — bulk `Ignore with reason` over MEDIUM + BLOCKING → BLOCKING ones skipped.
  - `bulk_cross_bucket_rejected` — bulk apply across two `issue_group` buckets is rejected.
  - `bulk_expired_token_rejected` — stale confirmation token rejected; user re-previews.
  - `bulk_filter_based_selection` — filter `issue_type = dedup.possible_duplicate AND amount < 5` resolves to IDs at preview; new matches between preview and commit are NOT included.
  - `bulk_triggers_gate_re_evaluation_once` — 50-issue bulk → 50 per-issue audit events but only 1 gate re-eval event (debounced).
- **Notes & assignment fixtures** (Phase 06):
  - `notes_update_succeeds` — Bookkeeper writes a note; `REVIEW_NOTE_UPDATED` fires.
  - `notes_reviewer_denied` — Reviewer attempting note write is denied.
  - `assignment_owner_assigns_to_bookkeeper` — `REVIEW_ASSIGNMENT_CREATED` fires; in-app + email notifications dispatched.
  - `assignment_bookkeeper_attempt_denied` — Bookkeeper trying to assign is denied with `REVIEW_ASSIGN`.
  - `assignment_invalid_assignee_role_rejected` — Owner trying to assign to Read-only is rejected.
  - `assignment_invalid_assignee_business_rejected` — Owner trying to assign to a user from a different business is rejected.
  - `assignment_reassign` — Admin reassigns; both prior and new assignee in audit; new notification.
  - `assignment_clear` — assignment cleared; no inverse notification.
  - `non_assignee_resolves_assigned_issue` — anyone with the right role can resolve regardless of assignment; audit captures both `actor_user_id` and `assigned_to`.
  - `email_opt_out` — user opted out of emails; assignment creates in-app entry only; no email sent.
  - `notification_failure_raises_review_issue` — email delivery fails after retries; HIGH review issue raised.
- **Snooze fixtures** (Phase 07):
  - `snooze_medium_succeeds` — MEDIUM issue snoozed with reason; hidden from active queue.
  - `snooze_high_rejected` — HIGH issue snooze rejected with `REVIEW_SNOOZE_REJECTED_SEVERITY`.
  - `snooze_blocking_rejected` — BLOCKING issue snooze rejected.
  - `snooze_empty_reason_rejected` — empty reason rejected.
  - `manual_unsnooze` — issue reappears in active queue.
  - `snooze_carry_forward_to_next_run` — next run starts; unsnooze pass clears all snoozed issues; `REVIEW_UNSNOOZED` per row with `unsnoozed_by_run_id`.
  - `snooze_severity_elevated_auto_clears` — re-scan elevates MEDIUM → HIGH; snooze auto-cleared; `REVIEW_SNOOZE_AUTO_CLEARED_SEVERITY_ELEVATED` fires.
  - `snooze_persists_through_finalization` — run finalizes with snoozed issues; archive captures the state; next run picks up from operational DB.
  - `bulk_snooze_skips_high_blocking` — bulk snooze; HIGH / BLOCKING skipped.
- **Re-scan fixtures** (Phase 08):
  - `rescan_affected_set_one_hop` — resolved issue's `transaction_id` shared by 2 other open issues; both re-validated.
  - `rescan_auto_resolves_no_longer_valid` — affected issue's underlying state no longer matches; auto-closes with `status = AUTO_RESOLVED_BY_RESCAN`.
  - `rescan_severity_change_demotion_persists_snooze` — re-scan demotes severity; snooze persists.
  - `rescan_severity_change_elevation_clears_snooze` — escalation triggers Phase 07's auto-clear.
  - `rescan_surfaces_new_issue` — re-validation discovers a new related issue; new card created; new issue does NOT trigger another re-scan immediately.
  - `rescan_revalidation_failure_does_not_rollback_resolution` — producing-block failure; resolution succeeds; LOW follow-up issue surfaces.
  - `rescan_manual_wider_scope` — `Re-run scan after change` action triggers wider scope.
  - `rescan_gate_re_evaluates_after_completion` — re-scan completes → gate re-eval fires → `AWAITING_APPROVAL` → `RUNNING` if last blocker cleared (the canonical run-state for HUMAN_REVIEW_HOLD per Block 12 Phase 07 / Block 13 Phase 09).
  - `rescan_bulk_resolution_debounced_gate` — 50-issue bulk → 50 re-scans → 1 gate re-eval (debounced).
- **Mobile read-only fixtures** (Phase 09):
  - `mobile_view_queue_works` — all six buckets render with full card content on mobile.
  - `mobile_resolution_action_disabled_with_soft_prompt` — tapping a resolution action shows the prompt; no API call.
  - `mobile_copy_link_to_issue` — soft prompt's `Copy link to issue` works.
  - `mobile_send_to_my_inbox_self_link` — soft prompt's `Send to my inbox` writes a notification.
  - `mobile_form_factor_write_api_rejected` — server-side rejection of a write API with `client_form_factor = MOBILE` signal.
  - `mobile_notes_read_only` — notes visible; edit textbox replaced.
  - `mobile_assignment_read_only_for_owner` — Owner sees the assignment; cannot reassign.
  - `mobile_settings_redirect_to_desktop` — Block 02 Phase 11 settings inaccessible on mobile (per the prior phase's decision; Block 14 aligns).
- **Cross-cutting fixtures:**
  - `ready_to_finalize_state_when_all_buckets_empty` — all five work-item buckets empty + approval recorded → Phase 02's "Ready to Finalize" projection surfaces.
  - `human_review_hold_phase_name_vs_run_state` — `phase_state.status = HOLDING` ↔ `run.status = AWAITING_APPROVAL`; the two travel together but are different namespaces (per Block 14 architecture line 144).
- **Test runner** — `runReviewQueueFixture(fixture_name) → FixtureResult`:
  - Sets up the test business state with seeded `review_issues` rows.
  - Loads the input action sequence and recorded AI responses.
  - Executes each action via the relevant Block 14 phase API.
  - Captures actual `review_issues` state, audit events, gate state.
  - Compares to expected JSON files exactly. Failure produces a clear diff.
- **CI integration:**
  - Runs on every PR touching Block 14 phase code, fixtures, or any dependency in Blocks 02 / 03 / 04 / 05 / 06 / 07 / 08 / 09 / 10 / 11 / 12 / 13.
  - Failure blocks merge.
  - Performance budget: total fixture run time under 90 seconds.

## Definition of Done

- All listed fixtures exist with input + expected files + recorded AI responses.
- Running the test runner against any fixture produces the expected output exactly.
- A deliberate change that breaks any Block 14 phase makes the right fixtures fail with clear diffs.
- The severity-enum fix from the decisions-log amendment is verified — no `CRITICAL` value accepted.
- The "card content generated at creation, not render time" invariant is verified.
- The cross-run carry-forward of snoozed issues is verified end-to-end.
- The re-scan-affected-set-one-hop scope is verified — no transitive cascade.
- The mobile read-only constraint is verified at both client and server layers.
- All AI calls in CI use recorded responses; no live API hits.
- CI is wired so PR merges are blocked on fixture failures.
- Performance budget is met.

## Sub-doc Hooks (Stage 4)

- **Fixture format sub-doc** — directory structure, file naming, JSON shapes.
- **Per-fixture content sub-doc** — what each fixture covers, why it's representative.
- **Cross-block fixture-stitching sub-doc** — how Block 14's fixtures inherit / extend per-block fixtures from upstream blocks.
- **Performance budget sub-doc** — measurement methodology; per-fixture timing.
- **Mobile-fixture mechanism sub-doc** — how to simulate `client_form_factor` in tests.
