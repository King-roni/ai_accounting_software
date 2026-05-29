# Block 08 — Phase 07: Confidence Scoring & Auto-Confirm

## References

- Block doc: `Docs/blocks/08_transaction_classification_and_tagging.md` (Confidence and Auto-Confirm section)
- Block doc: `Docs/blocks/14_review_queue.md` (consumer of `NEEDS_CONFIRMATION` issues — "Needs Confirmation" bucket)

## Phase Goal

Merge the confidence outputs from the three classifier layers into a single per-transaction `classification_confidence` and decide whether to auto-confirm or route to the review queue. After this phase, every transaction has a definitive classification status (`AUTO_CONFIRMED` or `NEEDS_CONFIRMATION`) and the review queue carries the items the user actually has to look at — not noise from the long tail of confident decisions.

## Dependencies

- Phase 02 (Layer 1 confidence)
- Phase 03 (Layer 2 confidence — already calibrated to tier per Stage 1)
- Phase 04 (Layer 3 confidence — already calibrated per tier multiplier)
- Block 04 Phase 04 (`review_issues` table)
- Block 14 (consumer — surface the "Needs Confirmation" bucket)

## Deliverables

- **Confidence merging:**
  - When multiple layers produce a result, take the highest-confidence layer's decision as the suggested type.
  - **Multi-layer agreement boost:** when Layer 1 and Layer 2 (or Layer 2 and Layer 3) independently agree on the type, the merged confidence is `min(0.95, max_layer_confidence + 0.10)`. This rewards corroborated decisions without breaking a hard cap below 1.0.
  - When two layers disagree on the type, the higher-confidence layer wins, but a `classification.layer_disagreement` review issue is raised at severity `LOW` with both decisions in the issue payload, and the merged confidence is reduced by 0.10. (LOW because the run still proceeds with the higher-confidence answer; the issue exists for telemetry and for the user to optionally look at.)
- **Per-type auto-confirm thresholds:**
  - `INTERNAL_TRANSFER` — 0.80
  - `BANK_FEE` — 0.75
  - `FX_EXCHANGE` — 0.80
  - `OUT_EXPENSE` — 0.85
  - `IN_INCOME` — 0.85
  - `REFUND_IN` — 0.85
  - `REFUND_OUT` — 0.85
  - `CHARGEBACK` — 0.85
  - `PAYROLL_OR_TEAM_PAYMENT` — 0.90
  - `TAX_PAYMENT` — 0.90
  - `LOAN_OR_SHAREHOLDER_MOVEMENT` — 0.95
  - `UNKNOWN` — never auto-confirms (always routed to review).
  - All thresholds are stored in a `classification_thresholds` table (or equivalent config), tunable per business if a future Stage 4 sub-doc adds the override surface.
- **Classification status outcomes:**
  - `confidence ≥ threshold` → `transactions.classification_status = AUTO_CONFIRMED`. The classifier's confirmation path also increments the relevant `recurring_vendor_memory.confirmations_count` (from Phase 03).
  - `confidence < threshold` → `transactions.classification_status = NEEDS_CONFIRMATION`. A review issue is created in `review_issues` with:
    - `issue_type = 'classification.needs_confirmation'`
    - `issue_group = 'Needs Confirmation'` (Block 14 bucket)
    - `severity` derived from how far below threshold (LOW if within 0.10, MEDIUM if within 0.30, HIGH if below 0.40).
- **User confirmation flow** (resolution actions on the review issue):
  - **Confirm** — accepts the suggested type/tag; increments vendor memory; transitions transaction to `AUTO_CONFIRMED`.
  - **Override** — user picks different type/tag; updates classification; if the new classification is consistent with the counterparty signature, creates a fresh `recurring_vendor_memory` row at `confirmations_count = 1`.
  - **Reject (mark as wrong)** — explicitly marks the suggestion as wrong; if a vendor memory row was suggesting the wrong type, that row is `REVOKED` (Phase 03 path).
- **Audit events:** `CLASSIFICATION_AUTO_CONFIRMED` (with merged confidence), `CLASSIFICATION_NEEDS_CONFIRMATION`, `CLASSIFICATION_USER_CONFIRMED`, `CLASSIFICATION_USER_OVERRIDDEN`, `CLASSIFICATION_USER_REJECTED`, `CLASSIFICATION_MULTI_LAYER_AGREEMENT_BOOST`, `CLASSIFICATION_LAYER_DISAGREEMENT_FLAGGED`.

## Definition of Done

- A transaction with merged confidence at or above its type's threshold transitions to `AUTO_CONFIRMED` and increments the matching vendor-memory row.
- A transaction below threshold lands in the review queue under "Needs Confirmation" at the right severity tier.
- Two-layer agreement on the same type produces a confidence boost; the boost has a hard cap of 0.95.
- Two-layer disagreement raises a LOW issue while the run still proceeds with the higher-confidence answer.
- The user-confirmation flow correctly increments vendor memory; override creates a fresh memory row; reject revokes when applicable.
- Tests cover threshold-just-met, just-below-threshold, multi-layer agreement, multi-layer disagreement, override-creates-memory, reject-revokes-memory.

## Sub-doc Hooks (Stage 4)

- **Threshold calibration sub-doc** — initial values, calibration methodology, tuning cadence.
- **Multi-layer agreement boost sub-doc** — exact formula, edge cases, A/B testing for the boost magnitude.
- **Layer-disagreement issue card sub-doc** — review-queue layout, both-decision rendering, resolution choices.
- **Per-business threshold override sub-doc** — post-MVP feature; default vs override semantics.
- **Severity-tier derivation sub-doc** — rules for LOW/MEDIUM/HIGH on `NEEDS_CONFIRMATION` issues.
