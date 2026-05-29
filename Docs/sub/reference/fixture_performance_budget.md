# Fixture Performance Budget

**Category:** Reference data · **Owning block:** 07 — Bank Statement Pipeline · **Co-owners:** 08, 09, 10, 11, 12, 13, 14, 15, 16 · **Stage:** 4 sub-doc (Layer 1 reference)

Per-block performance budgets (P50 / P95 / P99 latency targets) for the end-to-end fixture pipelines. Every block's Phase 10 / 11 / 12 end-to-end tests run against these budgets in CI; a regression failure blocks the merge.

Block 07 owns the canonical shape (the first block to introduce fixtures); each later block adopts the same budget structure for its own surface. Block 16 carries the dashboard / export budgets separately because of the visual-regression dimension.

---

## Budget shape

Each block's end-to-end fixture suite declares its budget in one of two forms:

**Form 1 — per-fixture latency budget** (typical):

```yaml
fixture: out_monthly_typical_50_transactions
budget:
  p50_ms: 8000
  p95_ms: 15000
  p99_ms: 30000
```

**Form 2 — per-operation latency budget** (for tools / queries):

```yaml
operation: tool_matching_score_pair
inputs: { transaction_count: 100, candidate_count: 100 }
budget:
  p50_ms: 200
  p95_ms: 800
  p99_ms: 2000
```

The fixture format and recording mechanism live in `fixture_format_spec`. This sub-doc carries the budget targets.

## Per-block budget tables

### Block 07 — Bank Statement Pipeline

| Fixture | P50 | P95 | P99 |
| --- | --- | --- | --- |
| `statement_csv_revolut_50_rows` | 500 ms | 1.5 s | 3 s |
| `statement_pdf_revolut_50_rows` (via Document AI) | 5 s | 12 s | 25 s |
| `statement_with_50_duplicates` | 800 ms | 2 s | 4 s |
| `evidence_pdf_generation_50_transactions` | 2 s | 5 s | 10 s |

### Block 08 — Transaction Classification & Tagging

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| Classification Layer 1 (per row, deterministic) | < 1 ms | < 5 ms | < 10 ms |
| Classification Layer 2 (per row, vendor memory lookup) | < 10 ms | < 30 ms | < 50 ms |
| Classification Layer 3 (per row, AI escalation — Tier 2) | 200 ms | 1 s | 3 s |
| Classification Layer 3 (per row, Tier 3 escalation) | 1 s | 4 s | 10 s |
| Full classification phase, 100 rows | 1 s | 5 s | 15 s |

### Block 09 — Document Intake & Extraction

| Fixture | P50 | P95 | P99 |
| --- | --- | --- | --- |
| `intake_invoice_pdf_typical` (OCR + extract) | 4 s | 10 s | 25 s |
| `intake_email_finder_50_search` | 3 s | 8 s | 15 s |
| `intake_drive_finder_50_search` | 5 s | 12 s | 25 s |
| `intake_cross_source_dedupe_100_documents` | 1 s | 3 s | 6 s |

### Block 10 — Matching Engine

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| `tool_matching_score_pair` (1 × 100) | 100 ms | 200 ms | 500 ms |
| Matching batch (100 × 100) | 1 s | 5 s | 15 s |
| Matching batch (1000 × 100) | 10 s | 30 s | 60 s |
| Split-payment combinatorial (transaction with 5 candidates) | 50 ms | 200 ms | 800 ms |
| Match reason generation (Tier 3, per row) | 1 s | 3 s | 8 s |

### Block 11 — Ledger & Cyprus VAT Engine

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| `ledger.prepare_entries` per transaction | 50 ms | 200 ms | 500 ms |
| VAT classifier per transaction | 20 ms | 80 ms | 200 ms |
| LEDGER_PREPARATION phase, 100 entries | 5 s | 15 s | 30 s |
| Manual override pre-check | < 5 ms | < 10 ms | < 20 ms |

### Block 12 — OUT Workflow

| Fixture | P50 | P95 | P99 |
| --- | --- | --- | --- |
| `out_monthly_typical_50_transactions` | 30 s | 90 s | 180 s |
| `out_monthly_partial_upload_30_transactions` | 25 s | 70 s | 150 s |
| `out_adjustment_5_corrections` | 15 s | 45 s | 90 s |
| `out_workflow_filter_phase_500_transactions` | 2 s | 5 s | 10 s |

### Block 13 — IN Workflow + Invoice Generator

| Fixture | P50 | P95 | P99 |
| --- | --- | --- | --- |
| `in_monthly_typical_50_invoices` | 30 s | 90 s | 180 s |
| `invoice_pdf_render_typical` | 500 ms | 1.5 s | 3 s |
| `invoice_pdf_render_multi_line_50_items` | 1.5 s | 4 s | 8 s |
| `recurring_invoice_daily_scheduler_50_templates` | 3 s | 8 s | 20 s |

### Block 14 — Review Queue

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| Review queue list view (100 issues) | 100 ms | 300 ms | 800 ms |
| Single-issue resolution action | 100 ms | 400 ms | 1 s |
| Bulk action (50 issues) | 1 s | 3 s | 8 s |
| Re-scan on resolution (affected-only) | 500 ms | 2 s | 5 s |

### Block 15 — Finalization & Secure Archive

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| Lock sequence (50 ledger entries) | 5 s | 15 s | 30 s |
| Lock sequence (500 ledger entries) | 30 s | 90 s | 180 s |
| Archive bundle construction (50 entries + evidence PDFs) | 10 s | 30 s | 60 s |
| Archive bundle verification (re-hash) | 5 s | 15 s | 30 s |

### Block 16 — Dashboard & Reporting

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| Dashboard initial render (11 cards, single business) | 800 ms | 2 s | 5 s |
| Dashboard initial render (multi-business consolidated) | 1.5 s | 4 s | 10 s |
| Drill-down list view (100 records) | 300 ms | 1 s | 2 s |
| Period report PDF generation (50 entries) | 5 s | 15 s | 30 s |
| Accountant pack assembly | 15 s | 45 s | 90 s |
| Manual refresh (dashboard re-fetch) | 500 ms | 2 s | 5 s |

Visual-regression budgets are separate (per `visual_regression_baseline_runbook`) — they measure pixel deltas, not latency.

## Regression gating

Each fixture's run in CI compares against these budgets:

1. If P95 exceeds the target by ≤ 10%, the test passes with a warning
2. If P95 exceeds the target by > 10% but ≤ 25%, the test fails as a soft regression (`fixture_performance_soft_regression`); a re-run on a different runner may pass (machine variance)
3. If P95 exceeds the target by > 25%, the test fails hard (`fixture_performance_regression`); a retry won't help; the change in code must be investigated

P50 and P99 are recorded but not gating in MVP. Stage 2+ may add P50 gating once the corpus stabilises.

## Budget escalation

If a target needs adjustment (e.g., a new feature legitimately increases latency):

1. PR proposes new target with rationale
2. Profile data attached showing where time is spent
3. Stage 4 sub-doc patch — this doc updates the table
4. If the change is > 25% widening of any P95, requires a `Docs/decisions_log.md` amendment

## Performance recording

Per-run latencies recorded in `fixture_performance_recording` artifacts (per `fixture_format_spec`). Aggregation across the last N runs (typically N=50) computes the per-CI-job P50/P95/P99 used for gating.

Variance considerations: cold-start vs warm-cache; first-run vs steady-state; per-runner machine specs. CI infrastructure normalises by running each fixture twice and reporting the second run only.

## Cross-references

- `fixture_format_spec` — fixture file shape + recording mechanism
- `ai_response_recording_fixtures` — AI-call recording for deterministic replay
- `live_integration_test_runbook` — runbook for live (non-recorded) integration tests
- `cross_block_fixture_stitching` — multi-block end-to-end fixtures
- Block 07 Phase 10 — end-to-end pipeline tests (canonical first instance)
- Per-block Phase 10/11/12 — end-to-end test surfaces
