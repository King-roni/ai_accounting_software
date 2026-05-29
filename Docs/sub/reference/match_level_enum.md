# Match Level Enum

**Category:** Reference data · **Owning block:** 10 — Matching Engine · **Co-owners:** 04, 14 · **Stage:** 4 sub-doc (Layer 1 taxonomy)

The closed 4-value match-level enum every matching outcome maps to. Per the Stage 1 decision: matching is deterministic-first; level is computed from a weighted signal score, not from AI judgment. Adding a level requires a `Docs/decisions_log.md` amendment.

This taxonomy applies to OUT-side `MATCHING` and IN-side `INCOME_MATCHING`. The IN side carries an additional `income_outcome` enum on `match_records` (per the 2026-05-08 amendment) — that's orthogonal to match level and lives in `Docs/sub/reference/income_outcome_enum.md` (Layer 2).

---

## The 4 values

| Value | Score range | Date proximity (default) | Auto-confirm eligibility | Review-queue group |
| --- | --- | --- | --- | --- |
| `EXACT` | ≥ 0.95 | ±3 days | Yes (always) | — (no issue raised) |
| `STRONG_PROBABLE` | 0.80 – 0.95 | ±10 days | Yes (only if recurring-vendor signal high) | Needs Confirmation (when not auto-confirmed) |
| `WEAK_POSSIBLE` | 0.55 – 0.80 | ±30 days | No | Possible Wrong Match |
| `NO_MATCH` | < 0.55 | any | No | Missing Documents (OUT) / Needs Confirmation (IN) |

Score and date-proximity values are Stage 1 defaults from the decisions log:
- "Date proximity windows (defaults): ±3 days for Exact, ±10 days for Strong Probable, ±30 days for Weak Possible"
- "Strong-Probable auto-confirm rule: Auto-confirm only when the recurring-pattern signal is strong; otherwise route to review"

## Auto-confirm rules

`EXACT` — auto-confirmed by `matching.score_pair` with `MATCHING_AUTO_CONFIRMED`. The user can override in review by rejecting the match (rejection stored in `match_rejection_memory` per Stage 1: "Remember forever for the same (transaction, document) pair").

`STRONG_PROBABLE` — auto-confirmed only if `recurring_vendor_signal ≥ 0.88` per `match_signal_weights`. Otherwise routes to review under `Needs Confirmation`. The threshold is pinned in `strong_probable_threshold_policy` (Block 10, with planned move to a symbolic tier reference per the Block 10 scan).

`WEAK_POSSIBLE` — never auto-confirmed. Always routes to review.

`NO_MATCH` — on OUT side: triggers `Missing Documents` issue (a payment without an invoice). On IN side: triggers `Needs Confirmation` (a deposit without a matched invoice — could be a new client, refund, or transfer).

## Score composition

Per `match_signal_weights` (Reference data, Block 10), the score combines:

| Signal | Default weight | Notes |
| --- | --- | --- |
| Amount match | 0.30 | Strict equality at 1.0; tolerance-graded below |
| Date proximity | 0.20 | Decays linearly within the level's window |
| Counterparty name / VAT number | 0.20 | Normalized comparison; vendor-memory boost |
| Document type / direction | 0.10 | Invoice ↔ OUT expense; receipt ↔ paid invoice |
| Recurring vendor signal | 0.15 | Per Block 08 Phase 03's vendor-memory tier |
| Reference field match | 0.05 | Invoice number / order ID in transaction description |

Weights and per-signal calibration are deferred to `match_signal_weights`. This enum sub-doc commits to the structure; weights live in their own sub-doc.

## Review-queue routing (Block 14 binding)

| Match level | Issue group | Default severity |
| --- | --- | --- |
| `EXACT` (rejected by user) | Possible Wrong Match | MEDIUM |
| `STRONG_PROBABLE` (not auto-confirmed) | Needs Confirmation | MEDIUM |
| `WEAK_POSSIBLE` | Possible Wrong Match | MEDIUM |
| `NO_MATCH` on OUT | Missing Documents | HIGH |
| `NO_MATCH` on IN | Needs Confirmation | HIGH |

`issue_group` mapping is canonical in `issue_type_to_group_mapping` (Block 14 Reference data). The mapping above is binding.

## Storage

`match_records.match_level` column. Postgres ENUM:

```sql
CREATE TYPE match_level_enum AS ENUM ('EXACT', 'STRONG_PROBABLE', 'WEAK_POSSIBLE', 'NO_MATCH');
```

The `match_status` enum is separate (`PROPOSED`, `CONFIRMED`, `REJECTED`, `AUTO_CONFIRMED`, `SUPERSEDED`, `EXCEPTION_DOCUMENTED`) — defined in `Docs/sub/reference/match_status_enum.md` (Layer 2, Block 04).

## Cross-block usage

| Block | Use |
| --- | --- |
| 04 — Data Architecture | `match_records.match_level` column |
| 10 — Matching Engine | Computed by `tool_matching_score_pair`; consumed by every matching tool |
| 14 — Review Queue | Routes to issue groups per the table above |

## Cross-references

- `match_signal_weights` — score composition and weights
- `issue_type_to_group_mapping` — Block 14 routing
- `strong_probable_threshold_policy` — the 0.88 cutoff
- `match_records` schema — in `Docs/sub/schemas/match_records_schema.md` (Layer 2, Block 04)
- Block 10 Phase 02 — match scoring engine (architecture)
- Block 10 Phase 03 — strong-probable auto-confirm rule
- Block 14 Phase 02 — issue routing

---

## Narrative descriptions

### `EXACT` (score ≥ 0.95)

Amount, counterparty, and reference field all align within tolerance; the date falls within ±3 days of the invoice date. The matching engine treats this as a deterministic result — no probabilistic reasoning is needed. The run's `matching.score_pair` tool auto-confirms the match and records `MATCHING_AUTO_CONFIRMED`; no review-queue issue is raised. The user may still reject the match manually (the rejection is persisted in `match_rejection_memory` per Stage 1 decision: "Remember forever for the same (transaction, document) pair"). A rejected EXACT match surfaces as a `Possible Wrong Match` issue at `MEDIUM` severity.

Typical example: the business's bank account shows a €1,200.00 debit on 2026-04-03; the matched invoice carries the exact amount, the vendor's IBAN, and an invoice date of 2026-04-02.

### `STRONG_PROBABLE` (score 0.80–0.95)

Strong signal across most dimensions but at least one signal falls below EXACT threshold — most commonly a date drift of 4–10 days or a reference-field mismatch. Auto-confirm fires only when `recurring_vendor_signal ≥ 0.88` (pinned in `strong_probable_threshold_policy`). Below that threshold, the match is surfaced as `Needs Confirmation` at `MEDIUM` severity.

Typical example: a recurring SaaS subscription — invoice arrives on the 1st, the bank debit posts on the 5th. Amount and vendor are exact; the date drift pushes the score to 0.83. Because the vendor is known-recurring, `recurring_vendor_signal` is 0.91, and the match auto-confirms.

Counter-example: a one-time vendor with the same date drift and no prior payment history. `recurring_vendor_signal` is 0.0; the match routes to review.

### `WEAK_POSSIBLE` (score 0.55–0.80)

Some signals align, but the evidence is not strong enough for auto-confirmation under any condition. This typically occurs when the amount partially matches (e.g., a split payment), the date is 11–30 days apart, or the counterparty name resembles but does not exactly match the vendor. Always routes to `Possible Wrong Match` review at `MEDIUM` severity. The user must confirm or reject before the run can finalize.

Typical example: a partial payment of €600 on an invoice of €1,200; the other €600 was paid in a prior period. The matching engine identifies a plausible candidate but cannot confirm at score above 0.80.

### `NO_MATCH` (score < 0.55)

No candidate document scores above 0.55 for this transaction. On the OUT side, this generates a `Missing Documents` issue at `HIGH` severity — the payment happened but no invoice or receipt has been linked. On the IN side, this generates a `Needs Confirmation` issue at `HIGH` severity — the deposit may be from a new client, a refund, a transfer, or simply a late document.

`NO_MATCH` does not block the filter phase; it blocks finalization. The run advances to review with the unmatched transaction flagged.

---

## Review queue routing — operational notes

The `match_level` field is the primary signal Block 14 uses to route matching outcomes to the correct bucket. The routing happens at the point where `matching.score_pair` writes the `match_records` row; the issue is created in the same write transaction.

When the engine re-scores a match (e.g., after a user uploads a late document), the old `match_records` row is transitioned to `SUPERSEDED`; a new row is created with the updated level and status. If the new level is `EXACT` or `STRONG_PROBABLE` (auto-confirmed), any open review issue against the old match is auto-resolved per Block 14 Phase 08's re-scan.

The `WEAK_POSSIBLE → EXACT` upgrade path is important for workflows where documents arrive late: the transaction initially sits in review, the user uploads the document, the re-score fires, the issue clears, and the run can proceed to finalization.

---

## Cross-references (extended)

- `match_record_schema` — `match_level` column definition, `match_status` orthogonal axis
- `match_scoring_weights_policy` — per-signal weight calibration table
- `strong_probable_threshold_policy` — the 0.88 recurring-vendor cutoff
- `match_rejection_memory` — persistent rejection storage per (transaction, document) pair
- `issue_group_enum` — bucket routing from match level
- `income_outcome_enum` — orthogonal IN-side field on `match_records`

---

## Change history

| Date | Change | Author |
| --- | --- | --- |
| 2026-05-08 | Added IN-side `income_outcome` enum reference; clarified orthogonality | Block 10 scan |
| Stage 1 lock | Score ranges, date-proximity windows, auto-confirm rule pinned | Architecture decision |
| Stage 4 | Narrative descriptions, routing notes, extended cross-references added | Documentation pass |
