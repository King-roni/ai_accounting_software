# Block 08 — Transaction Classification & Tagging

## Role in the System

This block makes the first substantive accounting decision for every transaction: what type is it, and what business-friendly tag describes it. The decision is consequential — different transaction types require different evidence, follow different ledger paths, and carry different VAT implications. Getting this split right upstream prevents downstream corruption.

Classification is deterministic-first. Rules run before any AI; AI is consulted only for rows that deterministic logic cannot resolve confidently. Both layers feed the same `(transaction_type, system_tag, confidence_score)` triple, and low-confidence outputs go to the review queue.

---

## Scope

### In scope
- The 12-type transaction-type classifier
- Business-friendly tag system (system suggestion + user confirmation/override)
- Recurring vendor memory
- Per-business tagging rules
- Confidence scoring and the auto-confirm threshold
- Routing of low-confidence classifications to the review queue

### Out of scope (covered elsewhere)
- Producing the normalized transaction in the first place → Block 07 (Bank Statement Pipeline)
- Searching for invoices/receipts based on the assigned tag → Block 09 (Document Intake & Extraction)
- Matching documents to transactions → Block 10 (Matching Engine)
- Translating type + tag into ledger account codes → Block 11 (Ledger & Cyprus VAT Engine)

---

## The 12 Transaction Types

```text
OUT_EXPENSE
IN_INCOME
INTERNAL_TRANSFER
FX_EXCHANGE
BANK_FEE
REFUND_IN
REFUND_OUT
CHARGEBACK
LOAN_OR_SHAREHOLDER_MOVEMENT
PAYROLL_OR_TEAM_PAYMENT
TAX_PAYMENT
UNKNOWN
```

The taxonomy is closed for MVP. Adding a new type is a deliberate change because every downstream block has type-aware logic. `UNKNOWN` is the safety valve when neither rules nor AI can decide.

---

## Classification Layers

### Layer 1 — Deterministic Rules (always first)
Rule examples:

- Same-owner account on both sides → `INTERNAL_TRANSFER`
- Counterparty marked as a known Revolut fee line → `BANK_FEE`
- Negative amount + counterparty matches a known supplier → `OUT_EXPENSE`
- Positive amount + counterparty matches a known client → `IN_INCOME`
- Description contains an FX-exchange marker → `FX_EXCHANGE`
- Description contains "refund" + opposite direction to original transaction → `REFUND_IN` / `REFUND_OUT`
- Counterparty matches the configured tax authority → `TAX_PAYMENT`

Rules can be:

- Global (apply to all businesses)
- Per-business (taught from prior confirmations or set explicitly)

A rule match produces a high confidence score. Multiple rule matches against different types are themselves a flag (something is configured wrong).

### Layer 2 — Recurring Vendor Memory
For transactions where Layer 1 is silent or weak, the system checks whether the same counterparty has been classified before for this business. The promotion rule is **tiered**:

- **1 confirmation** → suggestion with **medium** confidence (still routes to review).
- **3+ confirmations** → suggestion with **high** confidence (auto-confirmable, subject to per-type thresholds).

This avoids the failure mode where a single mis-classification poisons future runs while still rewarding consistent patterns.

### Layer 3 — AI Fallback (Block 06 Tier 2 first, Tier 3 only if needed)
For transactions where Layers 1 and 2 are still unresolved, an AI call is made through the Privacy Gateway. The model receives a minimized payload (date, amount, currency, direction, normalized merchant, description) and returns a typed JSON: chosen type, chosen tag, confidence, brief reason. The gateway validates the schema before the result is used.

---

## Tagging

The tag is the human-readable label users actually see. Examples from the core plan:

- Business subscription
- Software tool
- Contractor payment
- Team member invoice
- Marketing expense
- Office expense
- Travel expense
- Transfer between own accounts
- Bank fee
- Tax payment
- Unknown expense

Tag assignment follows the same three-layer pattern: deterministic rules first, recurring memory second, AI third. Tags can be confirmed by the user, overridden, or supplemented with a custom tag.

The system is shipped with a default tag set; per-business custom tags are allowed and **each custom tag maps to exactly one of the 12 transaction types** so Block 11 can derive the correct ledger logic without ambiguity.

**Multi-tag support:** a transaction has **one primary tag** (which drives the ledger path in Block 11) and **optional secondary tags** (which carry no ledger implications and are used for cross-cutting reporting and analytics in Block 16).

**Tag taxonomy versioning:** the tag taxonomy is versioned. Finalized periods preserve the version active at the time of finalization, so historical reports remain accurate even after tag definitions change. New runs use the latest taxonomy.

---

## Confidence and Auto-Confirm

Each classification carries a `confidence_score` in `[0, 1]`. The handling rule:

- Above the auto-confirm threshold → marked `AUTO_CONFIRMED`, no user prompt
- At or below the threshold → `NEEDS_CONFIRMATION`, surfaced to Block 14 in the "Needs Confirmation" bucket

The threshold is calibrated per type — `INTERNAL_TRANSFER` and `BANK_FEE` should auto-confirm aggressively; `LOAN_OR_SHAREHOLDER_MOVEMENT` and `UNKNOWN` should rarely auto-confirm.

A user-confirmed classification feeds Layer 2 (recurring memory) for future runs.

---

## Interfaces

### Inputs
- Normalized transactions from Block 07
- Per-business classification rules and recurring vendor memory (operational DB)
- AI Privacy Gateway calls when fallback is triggered (Block 06)

### Outputs
- Transactions with assigned `transaction_type`, `system_tag`, `confidence_score`, and `classification_status`
- Review issues for `NEEDS_CONFIRMATION` items (consumed by Block 14)
- Updates to recurring vendor memory after user confirmation

---

## Operating Rules

- **Principle 3 (AI Assists, Rules Decide):** Layer 1 rules run first; AI is a fallback, never a replacement.
- **Principle 5 (Simple Interface):** users see tags ("Software tool"), never type codes (`OUT_EXPENSE`); the type code is internal.
- **Principle 1 (Workflow-First):** classification runs as a registered phase; ad-hoc reclassification by UI is a workflow action, not a direct DB write.
- **AI cache (Stage 1 decision):** identical AI classification calls within a single run return cached results.

---

## Stage 1 Resolutions

All initially-open questions have been resolved (see `Docs/decisions_log.md`):

- **Recurring vendor memory:** tiered (1 confirmation = medium, 3+ = high) — covered in Layer 2.
- **Custom tags:** one type per tag — covered in Tagging.
- **Multi-tag support:** primary + optional secondary — covered in Tagging.
- **Tag taxonomy versioning:** versioned per finalized period — covered in Tagging.

### Deferred

- **Auto-confirm thresholds per type** — starting values calibrated during phase decomposition and tuned in operation.

