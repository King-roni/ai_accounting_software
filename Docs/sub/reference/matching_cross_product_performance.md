# matching_cross_product_performance

**Category:** Reference · **Owning block:** 10 — Matching Engine · **Stage:** 4 sub-doc (Layer 2)

The **performance characteristics** of the matching engine's per-phase per-pair invocation pattern: `transactions × documents` (for OUT-side `MATCHING`) and `transactions × invoices` (for IN-side `INCOME_MATCHING`). Defines per-scale latency targets, candidate-narrowing rules that bound the cross-product cardinality, and the safety valves that prevent pathological scaling.

Companion to `matching_tools_io_schemas.md` (BOOK-228), `matching_phase_definitions.md` (BOOK-229), and `match_signal_weights.md` §"Performance bounds".

---

## 1. The cross-product

For each phase invocation, the engine considers pairs:

```
MATCHING:         transactions_unmatched_OUT × candidate_documents_in_window
INCOME_MATCHING:  transactions_unmatched_IN  × candidate_invoices_active
```

A "candidate" is a row that PASSES the narrowing predicates per §2. The narrowed cross-product (not the full O(N×M)) is what feeds `matching.score_pair`.

---

## 2. Candidate narrowing (the cardinality bound)

Per `matching_index_schema.md` and the indexes shipped at Block 04 / Block 10:

### 2.1 Window filter

| Side | Window |
|---|---|
| OUT (transactions → documents) | document's `expected_period` ± 60 days from transaction's date (cross-period look-back per Phase 02) |
| IN (transactions → invoices) | invoice's `issued_at` within [transaction.date − 60 days, transaction.date + 30 days] (asymmetric per `income_matching_signal_weighting.md` §2.3) |

The window filter alone typically reduces M (candidates per transaction) from "all documents in the business" to **~50-100** for a typical Cyprus SME book.

### 2.2 Status filter

| Side | Statuses kept |
|---|---|
| OUT | documents with `match_status ∈ {UNMATCHED, REJECTED}` (REJECTED candidates still considered because rejection-memory acts per-pair, not per-row) |
| IN | invoices with `status ∈ {SENT, PAYMENT_EXPECTED, PARTIALLY_PAID, OVERPAID}` per phase doc B10·P08; explicitly excluded: DRAFT, CANCELLED, REFUNDED, PAID, PRO_FORMA |

### 2.3 Amount filter (coarse)

A transaction's amount must be within ±200% of any candidate amount to be considered. This is a very loose filter — the actual amount-match scoring per `match_signal_weights.md` §"Amount match calibration" is the tight one. The ±200% filter is purely to discard obvious mismatches before scoring.

A €100 transaction has candidates whose amount is in [€33, €300] roughly (1/3 to 3×). This filter excludes transactions matching €1000-invoices outright without scoring them.

### 2.4 Combined narrowing

The combined filter — window AND status AND amount — typically reduces a 500-document business library to **5-25 candidates per transaction**. The narrowed cross-product is therefore:

```
typical narrowed cardinality = N_transactions_in_run × ~15 (median candidates per tx)
```

For a typical monthly OUT_MONTHLY run with 200 transactions: ~3,000 pair evaluations. For a stress case with 1,000 transactions: ~15,000 pair evaluations.

---

## 3. Per-pair latency

`matching.score_pair` runs the full signal computation per pair (per `match_signal_weights.md` §"Performance bounds"):

| Per-pair phase | P95 budget |
|---|---|
| Index lookup (rejection memory, vendor memory) | < 5 ms |
| Signal computation (6 signals) | < 8 ms |
| Score aggregation + level mapping | < 1 ms |
| `match_records` row write (when applicable) | < 5 ms |
| Audit emission (aggregated per `audit_log_policies`) | < 3 ms (amortised) |
| **Total per pair** | **< 25 ms** |

This is a synchronous tool invocation — the workflow engine calls it sequentially per pair (not parallelised) so that audit ordering and write contention behave predictably.

---

## 4. Phase-level latency targets

Combining §2 narrowing × §3 per-pair latency:

| Run scale | Transactions | Documents/Invoices | Narrowed pairs | Phase P95 latency |
|---|---|---|---|---|
| Small | 50 | 100 | 500 | **< 15 s** |
| Typical | 200 | 400 | 3,000 | **< 90 s** |
| Stress | 1,000 | 2,000 | 15,000 | **< 7 min** |
| Pathological | 5,000 | 10,000 | 100,000 | **< 50 min** |

The "Pathological" tier (5k transactions) is unusual for the Cyprus SME segment but possible for a large client. At this scale, the phase blocks the workflow run for ~50 minutes — acceptable for end-of-month batch processing, but the user surface should show a progress indicator + estimated completion time.

**Cross-block coordination flagged for B14 review queue:** the run-in-progress view should display a phase-level progress indicator with estimated completion time computed as `pairs_remaining × 25ms_p95`.

---

## 5. Safety valves

Beyond the typical operating envelope, three safety valves prevent runaway behaviour:

### 5.1 Per-transaction candidate cap

A transaction with > **100 candidates** after §2 narrowing triggers a HIGH-severity review issue `MATCHING_CANDIDATE_EXPLOSION`. The phase continues (the engine still scores all candidates) but the issue surfaces the anomaly for the user to investigate — typically this means the business has a structural data issue (e.g., a malformed VAT number causing all invoices to fuzzy-match every supplier).

The 100-candidate cap is a calibrated alert, not a hard cut-off. The engine does NOT silently drop candidates.

### 5.2 Per-phase total-pair cap

A phase invocation with > **250,000** narrowed pairs triggers a BLOCKING-severity review issue `MATCHING_RUN_TOO_LARGE` and HOLDS the phase. This protects against pathological clusters that would block the run for hours.

User action paths:
1. Split the run into smaller periods (recommended).
2. Manually override the cap (Owner-only; emits `MATCHING_RUN_CAP_OVERRIDDEN` HIGH audit; one-time).
3. Cancel the run and re-design the matching window.

The 250,000 ceiling is calibrated against the 50-minute pathological tier — beyond it, the run-blocking cost exceeds the value.

### 5.3 Combinatorial-detection timeout

Per `split_payment_combinatorial_bounds.md` (BOOK-188 anchor): the split-payment detection has its own 10-second per-group timeout with greedy fallback. This safety valve is INSIDE the `matching.detect_split_payments` tool and doesn't interact with the cross-product caps — combinatorial explosion happens at split detection, not at per-pair scoring.

---

## 6. Performance regression detection

The fixture-based performance test `tests/perf/matching_phase.perf.ts` runs the typical-scale case (200 tx × 400 candidates) on every PR. Budget: < 90s P95 per the §4 table.

A 10% regression triggers a soft warning in PR review. A 25% regression blocks merge per `fixture_performance_budget.md`.

The perf test runs against the canonical multi-tenant fixture (BOOK-226 §2) extended with a synthetic 200-transaction × 400-candidate population for `Acme A`. The fixture is reset between test runs to ensure deterministic timing.

---

## 7. Cross-references

- `match_signal_weights.md` §"Performance bounds" — per-pair budget source
- `matching_index_schema.md` — index definitions backing §2.1-§2.3 narrowing
- `matching_tools_io_schemas.md` — `matching.score_pair` invocation contract (BOOK-228)
- `matching_phase_definitions.md` — phase-level execution context (BOOK-229)
- `income_matching_signal_weighting.md` §2.3 — asymmetric window for IN-side (BOOK-218)
- `split_payment_combinatorial_bounds.md` — combinatorial timeout (§5.3, BOOK-188 anchor)
- `audit_log_policies.md` — aggregated audit-emission rule (§3 per-pair budget)
- `fixture_performance_budget.md` — regression budget source (§6)
- `tenant_isolation_test_suite_policy.md` §2 — canonical fixture extended for perf test (BOOK-226)
- `audit_event_taxonomy.md` — `MATCHING_CANDIDATE_EXPLOSION` (HIGH) + `MATCHING_RUN_TOO_LARGE` (BLOCKING) + `MATCHING_RUN_CAP_OVERRIDDEN` (HIGH) — 3 NEW events for B05·P02
- Block 10 Phase 02 — scoring engine (per-pair invocation site)
- Block 10 Phase 09 — workflow phase registration (owning phase; this doc is its perf reference)
- Block 14 — review queue (progress-indicator consumer §4 + safety-valve review issues)
- Stage 1 decision — synchronous per-pair invocation (no parallelisation) for audit-ordering predictability
