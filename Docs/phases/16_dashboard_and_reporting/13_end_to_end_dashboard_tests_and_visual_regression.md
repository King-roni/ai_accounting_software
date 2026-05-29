# Block 16 — Phase 13: End-to-End Dashboard Tests & Visual Regression

## References

- Block doc: `Docs/blocks/16_dashboard_and_reporting.md`
- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Phase 10 — invariant-test pattern)
- Prior block Phase 10s (golden-fixture conventions)

## Phase Goal

Build the regression-test layer for Block 16's full surface: per-card rendering, per drill-down path, per export type, per PDF determinism, per accessibility invariant, per responsive breakpoint, per locale, per permission gate, per refresh-state behaviour. Plus visual regression snapshots on light + dark mode + 3 breakpoints. After this phase, every change to any Block 16 phase runs against a fixture suite that catches drift before merge.

This is the **last phase of Stage 2**. After Block 16's scan + sign-off, all 16 blocks are decomposed and the elaboration roadmap moves to Stage 3.

## Dependencies

- All Block 16 phases (01–12)
- Block 02 Phase 10 (invariant-test pattern)
- Prior block Phase 10s (golden-fixture conventions)

## Deliverables

- **Golden fixtures directory** — `Docs/phases/16_dashboard_and_reporting/fixtures/`:
  - Per-fixture files: `business_state.json`, `pre_dashboard_state.json` (the operational + analytics + archive state at the start of the test), `expected_dashboard_render.json` (per-card data + severity + click-through), `expected_drill_down_results.json` (per-route row sets), `expected_export_artifacts.json` (per-export hash + byte size), `expected_pdf_hashes.json` (deterministic PDF byte-hash), `recorded_axe_results.json` (a11y violations baseline), `expected_audit_events.json`, `recorded_step_up_auth_responses.json` (for accountant-pack tests).

- **Per-card rendering fixtures (Phase 06):**
  - `card_monthly_overview_neutral` — clean run; no blocking issues; severity neutral; progress bar renders.
  - `card_monthly_overview_blocking` — BLOCKING issue open; severity-blocking border; count badge correct.
  - `card_income_overview_with_trend` — 12-month series renders line chart with current-month highlight.
  - `card_expense_overview_above_average` — month-to-date significantly above 3-month average; severity-medium triggers.
  - `card_missing_documents_high` — 3 unmatched OUT_EXPENSE rows; severity-high; click-through routes correctly.
  - `card_review_issues_per_bucket_breakdown` — 5-bucket horizontal bar chart with correct counts.
  - `card_vat_summary_with_unknown_treatment` — one entry with `vat_treatment = UNKNOWN`; severity-blocking.
  - `card_subscriptions_top_5` — top-5 vendors bar chart with monthly recurring.
  - `card_team_member_costs_trend` — payroll line chart.
  - `card_client_invoice_aging_90_plus` — invoice 90+ days outstanding; severity-blocking.
  - `card_cash_movement_negative` — net negative this month + positive last month; severity-medium.
  - `card_finalized_periods_with_tamper_alert` — one period with tamper alert; severity-blocking.
  - `card_severity_color_not_only` — every severity badge tested with color-blind simulator; icons present.
  - `card_loading_state_skeleton` — initial render shows skeleton until data resolves.
  - `card_empty_state_no_data` — Empty State with helpful message renders.
  - `card_error_state_retry` — failed materialized view query; Error State with retry button.

- **Drill-down fixtures (Phase 02 + Phase 08):**
  - `drill_down_router_routes_to_operational_for_in_flight` — current-period drill-down hits Operational DB.
  - `drill_down_router_routes_to_archive_for_finalized` — finalized-period drill-down hits Archive schema.
  - `drill_down_router_routes_to_analytics_for_aggregates` — aggregate metric drill-downs hit materialized views.
  - `drill_down_cross_business_filters_inaccessible` — user with access to A,B but not C drills into [A,B,C]; only A,B rows return; audit event records filter.
  - `drill_down_archive_pre_read_verification_blocks_tampered` — tamper-alert period blocks read with placeholder.
  - `drill_down_step_up_required_for_archive` — (deferred Stage 2+ flag enabled) Read-only role triggers step-up prompt.
  - `list_view_transactions_canonical_columns` — transaction list renders all columns; tabular figures align.
  - `list_view_invoices_aging_color_coding` — overdue invoices tint by aging bucket.
  - `list_view_review_issues_shares_with_block_14` — drill-down opens Block 14's review-queue page.
  - `list_view_periods_finalization_status` — periods list shows correct lifecycle badges.
  - `list_view_virtualization_50_plus_rows` — table virtualizes; scroll performance > 60fps.
  - `list_view_filter_chip_application` — filter chips apply correctly; URL-syncs.
  - `detail_transaction_full_tabs` — all 5 tabs render (Overview, Matched Evidence, Ledger, Audit, Issues).
  - `detail_invoice_with_adjustment_overlay` — `v_invoices_with_adjustments` shows v1 + v2 split.
  - `detail_period_manifest_chain` — Manifest chain tab shows v1, v2, v3 in order with correct hashes.
  - `detail_ledger_entry_full_compliance_fields` — all 11 compliance fields render.
  - `detail_audit_history_chronological` — events render in correct order.
  - `detail_permission_denied_clean_404` — permission denial shows Empty State without leaking record existence.

- **Multi-business view fixtures (Phase 07):**
  - `multi_business_aggregation_3_businesses` — per-card aggregation across 3 businesses correct.
  - `multi_business_severity_rolls_up` — single BLOCKING in any business → consolidated card BLOCKING.
  - `multi_business_per_business_drawer` — "By business" drawer opens with correct breakdown.
  - `multi_business_temporary_exclusion` — checkbox excludes a business; metrics recompute.
  - `multi_business_permission_filter_audit_event` — inaccessible business absent from result; audit event fires.
  - `multi_business_period_global_application` — switching period applies to all included businesses.
  - `multi_business_empty_organization` — user with 0 businesses sees Empty State per role.

- **Refresh-state fixtures (Phase 07):**
  - `refresh_banner_appears_during_rebuild` — `dashboard_refresh_state.currently_refreshing = true` → banner renders.
  - `refresh_banner_dismissible_per_session` — user dismisses; banner doesn't reappear in same session.
  - `refresh_per_card_stale_indicator` — MV > 5 minutes old → clock icon shows on card.
  - `refresh_manual_now_triggers_subscriber` — Cmd+Shift+R triggers synthetic event; subscriber refreshes; audit event fires.
  - `refresh_failure_raises_high_review_issue` — persistent refresh failure → HIGH issue surfaces.
  - `drill_down_bypasses_mv_during_refresh` — drill-down query during refresh hits live data, not stale MV.

- **Export fixtures (Phase 09 + 10 + 11):**
  - `export_transaction_csv_synchronous` — small CSV runs synchronously; signed URL returned.
  - `export_accountant_pack_async` — large pack runs async; status PENDING → RUNNING → COMPLETED.
  - `export_permission_denied_for_reviewer` — Reviewer attempting `REPORT_EXPORT_FULL` denied.
  - `export_format_mismatch_rejected` — XLSX requested for XML-only `vies_export_file` → rejected.
  - `export_idempotency_within_minute` — same request twice in <60s returns same export_id.
  - `export_signed_url_expires` — URL valid 1 hour; expired URL returns 403.
  - `export_retention_purges_after_30_days` — Block 04 storage object purged; `exports` row remains.
  - `export_failure_persistent_marks_failed` — generation fails twice; `status = FAILED` + audit event.

- **PDF determinism fixtures (Phase 10):**
  - `pdf_generate_period_report_deterministic` — same input → byte-identical PDF (SHA-256 match across two builds).
  - `pdf_generate_period_report_v2_adjustment_overlay` — adjustment-period PDF clearly distinguishes original vs adjustment.
  - `pdf_generate_pl_overview_eur_formatting` — EUR with EU formatting (1.234,56) verified.
  - `pdf_generate_cashflow_overview_with_waterfall` — waterfall chart renders correctly.
  - `pdf_generate_missing_evidence_lists_unmatched` — only `NO_MATCH` non-exception rows surface.
  - `pdf_generate_client_outstanding_aging_subtotals` — aging buckets sum correctly.
  - `pdf_generate_vat_preparation_8_treatments` — all 8 treatments break out; reverse-charge flagged; VIES summary.
  - `pdf_generate_accessibility_tagged` — PDF structure tree present; screen-reader-friendly.
  - `pdf_generate_font_pinning_drift_detected` — simulated font-version change → hash mismatch fixture.

- **Accountant pack + VIES XML fixtures (Phase 11):**
  - `accountant_pack_full_period_default_config` — all components included; bundle byte-identical across builds.
  - `accountant_pack_quarter_concatenates_3_periods` — 3 periods concatenate correctly.
  - `accountant_pack_year_concatenates_12_periods` — full year.
  - `accountant_pack_supplier_overview_disabled` — config opt-out excludes that file.
  - `accountant_pack_rejected_period_not_finalized` — non-finalized period rejected.
  - `accountant_pack_rejected_tamper_detected` — tampered archive blocks the pack.
  - `accountant_pack_signed_manifest_includes_bundle_hash` — manifest's `bundle_hash_anchor` matches actual zip.
  - `vies_xml_xsd_validation_passes` — generated XML validates against Cyprus VIES XSD.
  - `vies_xml_per_counterparty_rollup_correct` — totals match locked-ledger source.
  - `vies_xml_xsd_validation_failure_audit_event` — invalid XML produces `VIES_XML_VALIDATION_FAILED`.

- **Accessibility fixtures (Phase 12):**
  - `axe_core_passes_dashboard_light` — every Storybook story green.
  - `axe_core_passes_dashboard_dark` — independently verified.
  - `axe_core_passes_drill_down_views` — list + detail.
  - `axe_core_passes_export_dialogs` — export request modal.
  - `keyboard_only_navigation_dashboard` — full keyboard pass.
  - `screen_reader_voiceover_card_summaries` — every chart announces summary.
  - `prefers_reduced_motion_collapses_durations` — durations → 0 ms.
  - `dynamic_type_200_zoom_no_truncation` — text scales without breaking layout.
  - `color_blind_simulator_severity_distinguishable` — severity icons + text disambiguate without color.

- **i18n fixtures (Phase 12):**
  - `i18n_cyprus_eur_formatting_verified` — 1.234,56 €.
  - `i18n_eu_date_format_dd_mm_yyyy` — date columns render correctly.
  - `i18n_monday_week_start_in_date_picker` — Cyprus calendar.
  - `i18n_missing_key_fails_lint` — undefined translation key in code → CI fail.
  - `i18n_greek_placeholder_does_not_break_render` — `el.json` empty; English fallback works.

- **Mobile read-only fixtures (Phase 12):**
  - `mobile_dashboard_renders_read_only` — all cards visible; no horizontal scroll at 375 px.
  - `mobile_drill_down_works` — drill-down read paths function.
  - `mobile_write_action_soft_prompt` — Cmd+Shift+R / hide-card / approve / etc. all soft-prompt.
  - `mobile_settings_inaccessible` — settings page redirects with desktop-only message.
  - `mobile_bottom_nav_5_items` — sidebar replaced by 5-item bottom nav.
  - `mobile_landscape_renders_correctly` — orientation change reflows layout.

- **Performance fixtures (Phase 12):**
  - `cwv_cls_under_0_1` — Lighthouse CI passes.
  - `cwv_lcp_under_2_5s` — passes.
  - `cwv_inp_under_200ms` — passes.
  - `virtualized_table_60fps_at_1000_rows` — table scrolls smoothly.
  - `bundle_split_route_level` — initial bundle < 200 KB gzipped (sub-doc tunes the budget).
  - `lighthouse_score_above_90` — performance score green.

- **Visual regression fixtures:**
  - **Per-page snapshots** on light + dark mode + 3 breakpoints (375 / 1024 / 1440 px) for:
    - Dashboard (single business)
    - Multi-business dashboard
    - Each drill-down list view (transactions, invoices, issues, periods, ledger)
    - Each detail view (transaction, invoice, issue, period, ledger)
    - **Period detail with manifest chain (multi-version v1...vN)** — worst-case complexity page with adjustment overlays
    - **Cross-business drill-down list (rows badged by business)** — multi-business context complexity hotspot
    - **Invoice detail with adjustment overlay** (`v_invoices_with_adjustments` showing v1 + v2 split)
    - Export request modal
    - Settings — Accountant pack config
    - Empty / loading / error states
  - **Screenshot diffing in CI:** Percy or Chromatic equivalent (sub-doc owns the choice); diffs flagged for human review.
  - **Approved-baseline drift policy:** intentional design changes require explicit baseline acceptance; CI does not auto-approve.

- **Test runner — `runDashboardFixture(fixture_name) → FixtureResult`:**
  - Sets up the test business + analytics state.
  - Loads recorded auth / step-up responses.
  - Executes the relevant flow (card render, drill-down, export, accountant-pack generation, etc.).
  - Captures actual rendered DOM, audit events, exports, PDF hashes.
  - Compares to expected fixtures exactly.
  - Visual regression captures screenshots and compares to baseline.

- **CI integration:**
  - Runs on every PR touching Block 16 phase code, fixtures, or any Block 16 dependency.
  - Failure blocks merge.
  - **Performance budget:** axe-core suite < 60s; visual regression < 120s; full Block 16 fixture run < 300s.

- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `DASHBOARD`):
  - **No runtime fixture-execution audit events** — fixture pass / fail are CI artifacts, not Block 05 audit-log emissions (mirrors prior blocks' established pattern).

## Definition of Done

- All listed fixtures exist with input + expected files + recorded responses.
- Running the test runner against any fixture produces the expected output exactly.
- A deliberate change that breaks any Block 16 phase makes the right fixtures fail with clear diffs.
- The deterministic-PDF invariant is verified — same input → byte-identical PDF.
- The deterministic-accountant-pack invariant is verified.
- VIES XML XSD validation passes.
- All accessibility fixtures pass axe-core.
- Cyprus locale formatting verified.
- Mobile read-only constraint verified at client + server layers.
- CWV budgets met in Lighthouse CI.
- Visual regression baseline captured for every page × theme × breakpoint.
- Performance budget met for the test runner itself.

## Sub-doc Hooks (Stage 4)

- **Fixture format sub-doc** — directory structure, file naming, JSON shapes.
- **Visual regression library choice sub-doc** — Percy vs Chromatic vs custom.
- **axe-core CI integration sub-doc** — per-story coverage; regression-blocking config.
- **Lighthouse CI configuration sub-doc** — budget thresholds; per-route variants.
- **Step-up auth simulation sub-doc** — how to mock TOTP / passkey responses in fixtures.
- **PDF determinism CI sub-doc** — font / library version pinning verification.
- **Cross-block fixture-stitching sub-doc** — how Block 16's fixtures inherit state from Blocks 12 / 13 / 15 (the dashboard renders post-finalization data).
- **Performance budget sub-doc** — measurement methodology; per-fixture timing.
- **Visual-regression baseline-acceptance UX sub-doc** — PR review pattern for design changes.
