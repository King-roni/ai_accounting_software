# Block 12 — OUT / Write-Off Workflow

## Role in the System

This block defines the OUT workflow — the end-to-end pipeline that turns outgoing bank transactions into a finalized monthly expense ledger. The block is not an engine and contains no parsing, classifying, matching, or VAT logic of its own. It is a **workflow definition**: an ordered sequence of phases that the Workflow Engine (Block 03) registers and runs, with each phase invoking tools from the domain engines (07–11), the AI Layer (06), and the Review Queue (14).

OUT is one of two flagship workflow types in MVP. It scopes to one business and one accounting period per run, processes outgoing transactions only, and ends with a locked OUT ledger in the Finalized Archive.

---

## Scope

### In scope
- The `OUT_MONTHLY` workflow type definition
- Phase sequence, gate functions, and tool invocations
- Type-aware routing (which transaction types need which evidence)
- Per-business config points that can enable/disable optional phases
- The `OUT_ADJUSTMENT` variant for corrections to finalized periods

### Out of scope (covered elsewhere)
- Engine mechanics, run lifecycle, gate evaluation infrastructure → Block 03
- Parsing, classification, extraction, matching, ledger logic → Blocks 07–11
- AI calls and End-Scan → Block 06
- Review queue UI → Block 14
- Finalization lock semantics and archive structure → Blocks 04 + 15

---

## Workflow Type Registration

`OUT_MONTHLY` is a **static workflow type** compiled into the engine. Per-business config can toggle optional phases (e.g., disable the Drive finder for a business that doesn't keep invoices in Drive) without changing the type definition.

**Triggers:**
- **Manual.** A user with appropriate role selects business + period and clicks Start.
- **Event.** A successful statement upload (Block 07's INGESTION output) auto-starts `OUT_MONTHLY` for the corresponding period. Both OUT and IN workflows can be triggered by the same upload — the engine deduplicates the shared ingestion work.

---

## Phase Sequence

```text
1.  INGESTION                  → Block 07 (parse, normalize, dedupe, evidence PDFs)
2.  CLASSIFICATION             → Block 08 (assign type, tag, confidence)
3.  OUT_FILTER                 → select OUT-relevant transaction types
4.  EVIDENCE_DISCOVERY_EMAIL   → Block 09 (Gmail finder)
5.  EVIDENCE_DISCOVERY_DRIVE   → Block 09 (Drive finder)
6.  MATCHING                   → Block 10 (deterministic-first scoring + duplicate detection)
7.  MANUAL_UPLOAD_HOLD         → gated; only enters if unmatched OUT_EXPENSE remain
8.  LEDGER_PREPARATION         → Block 11 (type-aware ledger paths)
9.  VAT_CLASSIFICATION         → Block 11 (Cyprus VAT, VIES, reverse charge)
10. AI_END_SCAN                → Block 06 (anomaly + plain-language issue generation)
11. HUMAN_REVIEW_HOLD          → gated; only enters if blocking issues are open
12. FINALIZATION               → Block 15 (lock + archive)
```

INGESTION and CLASSIFICATION are shared between `OUT_MONTHLY` and `IN_MONTHLY` when both are triggered from the same upload. The engine deduplicates: a single set of transactions is produced once, then both workflows filter their relevant subsets in their respective `*_FILTER` phases. After the shared phases, **OUT and IN run in parallel** — neither blocks the other, and the user sees a unified progress indicator.

`INTERNAL_TRANSFER` transactions pass through **both** `OUT_FILTER` and `IN_FILTER`. Block 11's inter-account movement tool emits a single deduplicated ledger entry per transfer regardless of which workflow's filter encountered it first.

---

## Type-Aware Evidence Rules

The OUT_FILTER and downstream phases route each transaction by its type. Evidence requirements differ:

| Transaction type | Evidence required to advance |
| --- | --- |
| `OUT_EXPENSE` | Invoice or receipt; OR documented exception with reason |
| `INTERNAL_TRANSFER` | None — the transaction itself is the evidence |
| `FX_EXCHANGE` | Bank-generated FX evidence (auto-derived from the FX leg) |
| `BANK_FEE` | Bank-generated evidence (auto-generated) |
| `REFUND_OUT` | Reference to the original transaction being refunded |
| `PAYROLL_OR_TEAM_PAYMENT` | Invoice OR contract OR payroll record |
| `TAX_PAYMENT` | Tax authority confirmation OR documented as expected payment |
| `LOAN_OR_SHAREHOLDER_MOVEMENT` | Contract or shareholder agreement |
| `CHARGEBACK` | Bank-generated evidence + dispute record |
| `UNKNOWN` | Cannot advance — must be reclassified first |

`REFUND_IN` is processed by IN_FILTER (Block 13), not by OUT_FILTER. Refund routing is symmetric across the two workflows — each refund is handled by the workflow that matches its money-flow direction.

When a phase encounters a transaction whose evidence requirement is not met, it raises a review issue rather than blocking the whole run. The HUMAN_REVIEW_HOLD gate is what prevents finalization with unresolved blocking issues.

---

## Gate Conditions (per phase exit)

- **INGESTION exit:** every row processed (`NEW`, `DUPLICATE_*`, or `NEEDS_REVIEW`); ambiguous duplicates flagged.
- **CLASSIFICATION exit:** every transaction has a `transaction_type`; `UNKNOWN` cases flagged.
- **OUT_FILTER exit:** OUT-relevant subset identified and marked.
- **EVIDENCE_DISCOVERY_EMAIL / DRIVE exit:** every OUT_EXPENSE has had its evidence search executed; candidates produced (zero is allowed).
- **MATCHING exit:** every OUT transaction has a match status.
- **MANUAL_UPLOAD_HOLD exit:** every OUT transaction either has matched evidence OR a documented exception OR a type that doesn't need evidence. **Hold timeout policy:** the system sends a reminder after **7 days** of inactivity; there is no auto-fail or auto-finalize. The run sits indefinitely until the user acts.
- **LEDGER_PREPARATION exit:** every transaction has draft ledger entries OR is typed as no-ledger-needed.
- **VAT_CLASSIFICATION exit:** every draft entry has a VAT treatment OR is flagged `requires_accountant_review`.
- **AI_END_SCAN exit:** end-scan complete; review issues generated and grouped.
- **HUMAN_REVIEW_HOLD exit:** zero blocking issues open AND user approval recorded.
- **FINALIZATION exit:** archive package built, dashboard refresh enqueued.

Gates are implemented as **registered functions per phase** (per Block 03's pattern); the engine calls them and uses their output to decide whether to advance, hold, or route to a side phase.

---

## Failure Modes

- **Transient external error** (Gmail rate limit, OCR vendor blip, Anthropic timeout) → bounded retry; if still failing, surface a HIGH-severity review issue and pause the phase. The engine resumes from the same phase boundary when the user takes action.
- **Schema or contract violation** (e.g., a tool returns an output that fails schema validation) → fail the phase immediately and produce a review issue with diagnostic detail.
- **Crash mid-phase** → the engine resumes from the last persisted phase boundary; tool invocations are idempotent or wrapped with deduplication keys.

---

## OUT_ADJUSTMENT Variant

Adjustments to a finalized OUT period are processed as a separate workflow type, `OUT_ADJUSTMENT`:

```text
1. ADJUSTMENT_INTAKE       (user specifies what to amend; uploads new evidence if needed)
2. ADJUSTMENT_LEDGER_PREP  (Block 11 produces adjustment ledger entries)
3. ADJUSTMENT_VAT          (Block 11 reapplies VAT classification)
4. ADJUSTMENT_AI_REVIEW    (Block 06)
5. ADJUSTMENT_HUMAN_REVIEW
6. ADJUSTMENT_FINALIZATION (Block 15 — adjustments interleaved into the existing archive, additive)
```

Adjustment records carry an explicit reason and a structured delta against the original (per the Stage 1 decision). The original finalized records are never modified.

**Historical cap:** any period within the **6-year legal retention window** is amendable via OUT_ADJUSTMENT. Periods beyond retention cannot be amended.

**Concurrency with monthly runs:** an open OUT_ADJUSTMENT **does not block** the next OUT_MONTHLY run. Both can be active at the same time. The audit trail records both run identifiers so amendments and forward progress remain traceable.

---

## Interfaces

### Inputs
- A workflow start request (manual or event) carrying business, period, and the originating Statement Upload
- Per-business config (which optional phases are enabled)
- Tool registrations from Blocks 06–11

### Outputs
- A `Workflow Run` record (Block 03) progressing through the phase sequence
- Phase-output records: classified transactions, match records, draft ledger entries, review issues
- A finalized OUT archive package (via Block 15) when the run completes
- Audit events for every state transition (via Block 05)

---

## Operating Rules

- **Principle 1 (Workflow-First):** OUT is the orchestrator. UI does not bypass phases.
- **Principle 3 (AI Assists, Rules Decide):** every gate is deterministic; AI suggestions feed gates as inputs, not as gate logic.
- **Principle 5 (Simple Interface):** the user sees a single OUT progress indicator and a single review queue grouped by Block 14's six buckets, regardless of the 12 phases happening underneath.
- **Stage 1 decisions applied:** static + per-business config registry; manual + event triggers; bounded retry then notify; gates as registered functions per phase; adjustments interleaved with explicit reason + delta.

---

## Stage 1 Resolutions

All initially-open questions have been resolved (see `Docs/decisions_log.md`):

- **OUT/IN trigger order:** parallel after shared phases — covered in Phase Sequence.
- **INTERNAL_TRANSFER routing:** through both filters with a single deduplicated ledger entry — covered in Phase Sequence.
- **MANUAL_UPLOAD_HOLD timeout:** 7-day reminder, no auto-action — covered in Gate Conditions.
- **OUT_ADJUSTMENT historical cap:** 6-year legal retention window — covered in OUT_ADJUSTMENT Variant.
- **Adjustment concurrency:** open adjustment does not block the next monthly run — covered in OUT_ADJUSTMENT Variant.

No open questions remain at the architecture level. Phase docs will define exact reminder copy, audit-trail shape for concurrent runs, and the UI treatment of "pending adjustment" status on a finalized period.
