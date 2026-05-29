# Block 13 — Phase 12: End-to-End IN Workflow & Invoice Generator Tests

## References

- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md`
- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Phase 10 — invariant-test pattern)
- Block doc: `Docs/blocks/12_out_workflow.md` (Phase 10 — symmetric OUT workflow tests; cross-block fixture-stitching pattern)
- Block doc: `Docs/blocks/07_bank_statement_pipeline.md`, `Docs/blocks/08_transaction_classification_and_tagging.md`, `Docs/blocks/10_matching_engine.md`, `Docs/blocks/11_ledger_and_cyprus_vat_engine.md` (Phase 10s — golden-fixture conventions)

## Phase Goal

Build the regression-test layer for both sub-systems of Block 13: the Invoice Generator (composition, numbering, recurring scheduler, PDF rendering, pro-forma conversion, credit notes, write-off) and the IN_MONTHLY workflow type (clean run, multi-invoice allocation, refund-or-transfer reclassification, written-off bad-debt routing). Plus the IN_ADJUSTMENT variant. After this phase, every change to any Block 13 phase runs against a fixture suite that catches drift before merge.

## No-Block-09-Evidence-Discovery Invariant

The architectural rule "`IN_MONTHLY` does not invoke Block 09's `EVIDENCE_DISCOVERY_*` phases" is the canonical statement, owned by Phase 07. This phase's fixtures verify the rule by inspecting the registered phase sequence; no separate restatement of the rule lives here.

## Dependencies

- All Block 13 phases (01–11)
- Block 02 Phase 10 (invariant-test pattern)
- Block 07 / 08 / 10 / 11 / 12 Phase 10s (golden-fixture format conventions)
- Block 06 Phase 10 (recorded AI responses for end-scan and plain-language calls)

## Deliverables

- **Golden fixtures directory** — `Docs/phases/13_in_workflow_and_invoice_generator/fixtures/`:
  - Per-fixture files: `business_state.json` (chart of accounts, mapping rules, vendor memory, IN config, role assignments, clients, opening invoices), `input_invoice_actions.json` (composition / lifecycle calls for the invoice generator), `input_statement_upload.json` (for IN_MONTHLY fixtures), `input_recurring_templates.json` (for scheduler fixtures), `expected_invoice_state.json` (the `invoices` / `invoice_lines` / `credit_notes` / `invoice_payment_allocations` rows), `expected_workflow_run_state_machine.json` (for IN_MONTHLY fixtures — ordered run-state transitions), `expected_phase_outputs.json`, `expected_archive_bundle_manifest.json` (for fixtures reaching `FINALIZATION`), `expected_pdf_hashes.json` (deterministic PDF rendering), `recorded_ai_responses.json`.
- **Invoice Generator fixtures (Phases 01–06):**
  - `invoice_create_simple_tax_invoice` — user composes a 3-line invoice; totals compute correctly; transitions through `DRAFT → SENT`; `INV-YYYY-NNNN` allocates atomically; PDF renders with the right VAT-treatment text.
  - `invoice_currency_lock_immutable` — invoice issued in EUR; attempting to change currency post-creation is rejected.
  - `invoice_numbering_gap_detected` — artificially injected gap in `INV-YYYY-NNNN` sequence; daily integrity job raises HIGH review issue with `INVOICE_NUMBER_GAP_DETECTED`.
  - `invoice_void_via_credit_note` — issued invoice cannot be deleted; user issues full-amount credit note; source invoice transitions to `CREDITED`; `CN-YYYY-NNNN` allocates from a separate sequence.
  - `pro_forma_create_and_render` — `PRO-YYYY-NNNN` allocates from the pro-forma sequence; PDF renders with pro-forma watermark; restricted lifecycle (cannot reach `PAID`).
  - `pro_forma_to_tax_invoice_conversion` — user converts a sent pro-forma; fresh `INV-YYYY-NNNN` allocates; line items copy; pro-forma transitions to `CONVERTED_TO_TAX_INVOICE`; both PDFs queryable.
  - `pro_forma_re_conversion_rejected` — attempting to re-convert an already-converted pro-forma is rejected.
  - `credit_note_partial` — $50 credit note against $200 invoice; source invoice's `lifecycle_status` does NOT transition (partial); cumulative-credit-cap correctly checked on subsequent credit notes.
  - `credit_note_full` — full-amount credit note transitions source to `CREDITED`; Block 11 Phase 07's negative-side ledger entry is produced.
  - `credit_note_against_pro_forma_rejected` — credit notes can only be issued against `TAX` invoices; FK constraint enforces.
  - `invoice_write_off_bad_debt` — user writes off `SENT` invoice with mandatory reason; `lifecycle_status = WRITTEN_OFF`; Block 11's bad-debt-expense path invokes; receivable is offset.
  - `invoice_write_off_paid_rejected` — `PAID` invoice cannot be written off; rejected.
  - `recurring_template_monthly_generates_invoice` — daily scheduler runs on monthly anchor day; produces `DRAFT` invoice; `next_due_date` advances correctly; idempotent re-run.
  - `recurring_template_auto_send_immediate_inv_allocation` — `auto_send = true`; generated invoice immediately transitions to `SENT` and allocates `INV-YYYY-NNNN`.
  - `recurring_template_weekly_mid_month` — weekly Monday cadence produces invoices regardless of `IN_MONTHLY` boundaries.
  - `recurring_template_end_date_transitions_to_ended` — `next_due_date > end_date` correctly transitions template to `ENDED`.
  - `recurring_template_failure_isolation` — one template fails generation; others in the daily run continue; failed template retries next day; persistent failure raises HIGH review issue.
  - `recurring_pro_forma_template` — pro-forma recurring template generates pro-formas with restricted lifecycle.
- **PDF rendering fixtures:**
  - `pdf_render_each_vat_treatment` — one fixture per Block 11 Phase 05 treatment; PDF carries the right disclosure text; `expected_pdf_hashes.json` confirms deterministic rendering.
  - `pdf_render_pro_forma_watermark` — pro-forma PDF carries the watermark and footer text.
  - `pdf_render_mixed_rate_invoice` — multi-rate invoice renders per-rate breakdown.
  - `pdf_render_unknown_vat_rejected` — `vat_treatment = UNKNOWN` invoice rejected from FINAL render with the right audit event.
  - `pdf_render_idempotent_unchanged` — re-rendering an unchanged invoice reuses the stored PDF.
- **`IN_MONTHLY` fixtures (Phases 07–10):**
  - `in_monthly_clean_happy_path` — single business, 30 IN-side transactions, all matched cleanly, no review issues, user approves, run finalizes; verify `lifecycle_status = FINALIZED` on every affected invoice.
  - `in_monthly_full_match_with_invoice_number_reference` — `IN_INCOME` payment with invoice-number reference in descriptor → `FULL_MATCH` auto-confirms; `invoice.markPaid` fires.
  - `in_monthly_partial_payment_user_confirms` — partial payment routes to `MATCHED_NEEDS_CONFIRMATION`; user confirms; `invoice.markPartiallyPaid` fires; `invoice_payment_allocations` row created.
  - `in_monthly_overpayment_routes_credit_note_prompt` — overpayment routes to `MATCHED_NEEDS_CONFIRMATION` + `Possible Tax/VAT Issue` prompting credit-note for surplus.
  - `in_monthly_multiple_invoices_one_payment_user_confirms_proposal` — payment matches a sum of two invoices; `MULTIPLE_INVOICES_ONE_PAYMENT` outcome; review issue surfaces; user confirms proposed allocation; per-invoice lifecycle transitions fire.
  - `in_monthly_multiple_invoices_one_payment_user_edits_allocation` — same fixture; user edits allocation amounts; invariants enforced; per-invoice transitions fire with edited amounts.
  - `in_monthly_multiple_invoices_one_payment_user_rejects` — same fixture; user rejects all proposed; `match_records` row → `REJECTED_MATCH`; rejection feeds into Block 10 Phase 06's rejection memory; transaction reverts to `NO_MATCH`.
  - `in_monthly_one_invoice_multiple_payments_running_total` — three sequential partial payments accumulate; cumulative reaches `total_amount` → automatic `invoice.markPaid`.
  - `in_monthly_no_match_payment_with_pro_forma_reference_offers_conversion` — payment descriptor carries `PRO-YYYY-NNNN`; matcher returns `NO_MATCH`; review issue's recommended action is "Convert pro-forma to tax invoice and re-match"; user converts; re-run produces `FULL_MATCH`.
  - `in_monthly_pro_forma_excluded_from_candidates` — pro-forma invoices in candidate pool are NEVER considered by matcher; verified by inspecting matcher input.
  - `in_monthly_written_off_excluded_from_candidates` — written-off invoices excluded from matcher input.
  - `in_monthly_possible_refund_or_transfer_reclassification` — incoming payment matches prior outgoing transaction; outcome is `POSSIBLE_REFUND_OR_TRANSFER`; review issue suggests reclassification to `REFUND_IN` or `INTERNAL_TRANSFER`; user reclassifies; re-run produces clean match.
  - `in_monthly_human_review_hold_blocking_high` — `AI_END_SCAN` produces HIGH review issue (e.g., missing client VAT number on VIES-relevant invoice); run enters `HUMAN_REVIEW_HOLD`; user resolves; user approves; run finalizes.
  - `in_monthly_approval_required_with_zero_issues` — fixture with no issues; run still enters `HUMAN_REVIEW_HOLD`; approval required; on approval, finalizes.
  - `in_monthly_approval_revoked_re_holds` — user approves, then revokes; gate flips back to `HOLD`.
  - `in_monthly_approval_staleness_after_new_blocking_issue` — user approves; re-run of `AI_END_SCAN` produces new HIGH issue; gate flips back; `IN_HUMAN_REVIEW_APPROVAL_STALENESS_DETECTED` fires.
- **Paired OUT+IN fixtures:**
  - `paired_out_in_internal_transfer_dedup` — same as Block 12 Phase 10's fixture, verified from the IN side; `INTERNAL_TRANSFER` produces exactly one `draft_ledger_entries` PRIMARY row; both runs' audit chains carry the relevant events.
  - `paired_out_in_loan_in_direction_routes_to_in` — `LOAN_OR_SHAREHOLDER_MOVEMENT` IN direction passes through `IN_FILTER` only; OUT direction passes through `OUT_FILTER` only; verified.
  - `paired_in_finalizes_independently_of_out` — IN finalizes while OUT is in `MANUAL_UPLOAD_HOLD`; verified independence.
- **Triggers and idempotency fixtures:**
  - `in_manual_trigger_duplicate_rejected` — second start while first is active returns `IN_WORKFLOW_RUN_ALREADY_ACTIVE_REJECTED`.
  - `in_event_trigger_dedup_on_duplicate_event` — same `STATEMENT_UPLOAD_COMPLETED` arrives twice; only one IN run created; `IN_WORKFLOW_EVENT_TRIGGER_DEDUPLICATED` fires.
  - `in_manual_trigger_for_finalized_period_rejected` — already-finalized period rejected with `IN_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED`.
  - `in_auto_start_disabled_suppresses_event_trigger` — `auto_start_on_statement_upload = false` suppresses the IN run on event arrival.
- **`IN_ADJUSTMENT` fixtures:**
  - `in_adjustment_retroactive_credit_note` — finalized period with a `PAID` invoice; user initiates adjustment with `delta_kind = RETROACTIVE_CREDIT_NOTE`; credit note issues with current-year `CN-YYYY-NNNN`; ledger impact reverses revenue for the historical period; original `invoices` row's `lifecycle_status = FINALIZED` unchanged in storage.
  - `in_adjustment_correct_payment_allocation` — finalized period with a `MULTIPLE_INVOICES_ONE_PAYMENT` allocation user later realizes was wrong; adjustment re-allocates; new `invoice_payment_allocations` rows created; original allocations remain in audit.
  - `in_adjustment_mark_invoice_written_off` — retroactive write-off via adjustment; bad-debt-expense routing fires; original lifecycle stays `FINALIZED`; adjustment overlay surfaces the new state.
  - `in_adjustment_other_kind_mandatory_human_review` — `delta_kind = OTHER` always sets `requires_accountant_review = true` and `ADJUSTMENT_HUMAN_REVIEW` cannot fast-path.
  - `in_adjustment_concurrent_with_monthly_run` — `IN_ADJUSTMENT` for period 1 + `IN_MONTHLY` for period 3 both active; both progress; both run ids recorded on touched entries.
  - `in_adjustment_rejected_for_retention_expired` — 7-year-old period rejected with `IN_ADJUSTMENT_REJECTED_RETENTION_EXPIRED`.
  - `in_adjustment_does_not_modify_originals` — hash comparison verifies no original `invoices`, `invoice_lines`, `draft_ledger_entries`, `invoice_payment_allocations` rows were modified.
- **End-scan IN-specific checks:**
  - `end_scan_invoice_unpaid_past_due_date` — flagged with the right severity and bucket.
  - `end_scan_payment_received_without_invoice` — surfaces as `NO_MATCH` + `Missing Documents` HIGH.
  - `end_scan_missing_client_vat_on_vies_relevant` — flagged as `Possible Tax/VAT Issue` HIGH.
  - `end_scan_reverse_charge_text_missing` — flagged.
  - `end_scan_duplicate_payment_against_same_invoice` — flagged as `Possible Wrong Match`.
  - `end_scan_late_payment_past_due_date` — flagged informational.
- **Test runner** — `runInWorkflowFixture(fixture_name) → FixtureResult`:
  - Sets up the test business state.
  - Loads the input invoice actions, statement upload, recurring templates, recorded AI responses.
  - Runs the relevant flow (invoice generator API calls, `IN_MONTHLY` end-to-end, `IN_ADJUSTMENT` end-to-end, recurring scheduler invocation).
  - Captures actual invoice state, run-state transitions, per-phase outputs, audit events, archive bundle manifest, PDF hashes.
  - Compares to expected JSON files exactly. Failure produces a clear diff.
- **CI integration:**
  - Runs on every PR touching Block 13 phase code, fixtures, or any Block 13 dependency in Blocks 02 / 03 / 04 / 05 / 06 / 07 / 08 / 10 / 11 / 12.
  - Failure blocks merge.
  - Performance budget: total fixture run time under 240 seconds (Block 13 has the largest scope — generator + workflow + adjustment).
- **No runtime audit events** for fixture lifecycle. Fixture pass / fail are CI-pipeline artifacts (test runner output, CI status), not Block 05 audit-log emissions — fixture-execution events are repo-governance, not runtime audit. Mirrors the pattern Block 09 Phase 10's prior scan established (`INTAKE_FIXTURE_REMOVED` was removed for the same reason). Fixture addition / removal is documented via PR review.

## Definition of Done

- All listed fixtures exist with input + expected files + recorded responses + PDF hashes.
- Running the test runner against any fixture produces the expected output exactly.
- A deliberate change that breaks any Block 13 phase makes the right fixtures fail with clear diffs.
- The `MULTIPLE_INVOICES_ONE_PAYMENT` mandatory-user-confirmation rule is verified — no fixture passes by silently allocating.
- The pro-forma exclusion is verified across all relevant fixtures.
- The `INV-YYYY-NNNN` and `CN-YYYY-NNNN` and `PRO-YYYY-NNNN` numbering integrity is verified across all fixtures (no gaps, no re-use).
- The chart-version-pin replay invariant from Block 11 Phase 10 is honored when an `IN_MONTHLY` fixture spans a chart customization.
- All AI calls in CI use recorded responses; no live API hits.
- CI is wired so PR merges are blocked on fixture failures.
- Performance budget is met.
- Adding a fixture is easy; removing one requires a documented PR entry.

## Sub-doc Hooks (Stage 4)

- **Fixture format sub-doc** — directory structure, file naming, JSON shapes, mock-service seeding rules.
- **AI response recording sub-doc** — capture procedure across multiple AI-using phases (Phase 04 of Block 06 prompts, Phase 11 end-scan, Phase 10 plain-language).
- **PDF determinism sub-doc** — font / version pinning; reproducibility of `expected_pdf_hashes.json` across CI environments.
- **Per-fixture content sub-doc** — what each fixture covers, why it's representative, expected runtime.
- **Live integration test cadence sub-doc** — schedule and scope (the deferred VIES-online check; live email-send tests for `auto_send` recurring templates).
- **Performance budget sub-doc** — measurement methodology; per-phase / per-tool timing breakdown.
- **Cross-block fixture-stitching sub-doc** — how Block 13's fixtures inherit / extend Blocks 07 / 08 / 10 / 11 / 12's fixtures (especially the paired OUT+IN cases).
