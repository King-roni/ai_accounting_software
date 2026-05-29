# Block 01 — Core Principles & Design Constraints

## Status

This block is the constitution of the product. It defines the non-negotiable rules that every other block, every workflow, and every implementation decision must obey. Where any other block appears to contradict this one, the contradiction is the bug.

The five principles below are not aspirations — they are constraints on what the system is allowed to do. Each is stated, justified, and translated into concrete enforcement points in other blocks.

This block has no phases of its own. It is referenced by every other block, and every architecture, phase, and sub-doc must remain consistent with it.

---

## Principle 1 — Workflow-First Architecture

**Statement.** The bookkeeping workflow is the product. Every feature exists as a tool, validator, or sub-agent that the workflow engine calls. The system is not a collection of features stitched together.

**Why it matters.** Bookkeeping is a sequential process where the cost of getting an upstream step wrong compounds downstream. A feature-driven architecture lets data slip past gates. A workflow-driven architecture forces every record through the same audited pipeline.

**Enforcement points.**
- Block 03 (Workflow Engine) is the only component that advances workflow state.
- No domain block writes to the operational database without a workflow phase invoking it.
- Block 05 (Security & Audit Layer) records every state transition with the phase, run, and actor that caused it.

**What violation looks like.** A "quick action" button that finalizes a single transaction outside a workflow run. A domain function that writes to the ledger without being called by Block 03. A direct database mutation by a UI handler.

---

## Principle 2 — Structured Data Is the Source of Truth

**Statement.** The structured row in the database is canonical. Uploaded files (statements, invoices, receipts, contracts) and generated files (transaction evidence PDFs) are evidence artifacts — important, hashed, retained, but not the data model.

**Why it matters.** When the document is the source of truth, every change requires regenerating, re-signing, and re-storing files. When the structured row is the source of truth, documents are reproducible at any time, the database is queryable, the audit trail is exact, and integrity checks become hash comparisons.

**Enforcement points.**
- Block 07 (Bank Statement Pipeline) generates evidence PDFs from normalized transaction rows, never the other way around.
- Block 09 (Document Intake & Extraction) treats incoming documents as evidence to be linked to transactions, with extracted fields written to structured records.
- Block 15 (Finalization & Secure Archive) locks both rows and evidence files, but only rows are queryable; files are addressed by hash.

**What violation looks like.** Storing only the PDF and parsing it on demand. Treating an OCR'd field as authoritative without writing it into the structured record. Using a file path or filename as a primary key.

---

## Principle 3 — AI Assists, Rules Decide, User Finalizes

**Statement.** AI may suggest, classify, explain, extract, match, and flag. AI never silently finalizes accounting decisions. Finalization requires deterministic validation, resolution of all blocking issues, and explicit recorded user approval.

**Why it matters.** Financial records have legal and tax consequences. A non-deterministic decision path that no human reviewed creates audit risk and tax risk. Deterministic rules are testable; user approval is auditable; AI suggestions are useful but provisional.

**Enforcement points.**
- Block 06 (AI Layer) returns suggestions with confidence scores and reasons; it never writes finalized state.
- Block 10 (Matching Engine) is deterministic-first; AI is consulted only when deterministic logic produces ambiguity, and any AI-influenced match below a threshold goes to Block 14 (Review Queue).
- Block 15 (Finalization & Secure Archive) requires an explicit user approval record before the period locks.

**What violation looks like.** AI auto-resolving a `MATCHED_NEEDS_CONFIRMATION` to `MATCHED_CONFIRMED`. AI silently advancing a workflow run from review to finalization. A finalization that proceeds without an approval row in the audit log.

---

## Principle 4 — Security by Design

**Statement.** Sensitive financial data — bank statements, invoices, IBANs, VAT numbers, contracts, email content — is protected from the first line of code, not bolted on later. Encryption, tenant isolation, audit logging, and PII minimization are foundational, not features.

**Why it matters.** A bookkeeping platform that holds multi-business financial records is a high-value target. Retrofit security creates gaps. Greenfield security creates a defensible baseline.

**Enforcement points.**
- Block 02 (Tenancy & Access Control) enforces row-level isolation via `organization_id` + `business_id` on every query.
- Block 04 (Data Architecture) separates raw uploads, processing data, operational data, and finalized archive into distinct zones with their own access and encryption rules.
- Block 05 (Security & Audit Layer) handles encryption in transit, at rest, and at the field level for IBANs, account numbers, and VAT numbers.
- Block 06 (AI Layer) routes through the AI Privacy Gateway — no external AI call may receive raw sensitive data.

**What violation looks like.** A query that omits `business_id`. A finalized archive item readable by an analytics service account. An AI prompt that includes a full IBAN. A backup written without encryption.

---

## Principle 5 — Simple Interface, Advanced Backend

**Statement.** The user sees grouped, plain-language issues and one-click actions. The backend may track twenty distinct technical issue types, multiple match levels, and complex VAT classifications, but the surface area presented to the user collapses these into a small, fixed set of categories.

**Why it matters.** This product is operated by business owners, not accountants. Exposing accounting jargon and engine internals turns the product into an accountant tool. Hiding them turns it into something a non-specialist can run end-to-end while still producing accountant-grade output.

**Enforcement points.**
- Block 14 (Review Queue & Human Review) groups all issue types into the six fixed buckets (Missing Documents / Needs Confirmation / Possible Wrong Match / Possible Tax/VAT Issue / Unusual Transaction / Ready to Finalize).
- Block 06 (AI Layer) is responsible for translating technical findings into plain-language issue titles and descriptions.
- Block 16 (Dashboard & Reporting) presents summarized cards by default; technical drill-down is gated by role.

**What violation looks like.** A review queue UI that exposes raw issue type codes. A dashboard card titled `EU_REVERSE_CHARGE_MISMATCH`. A required field in the review form labelled `vat_treatment`.

---

## How This Block Is Used

Every other block in this project includes an "Operating Rules" section that traces specific rules back to one or more of the five principles above. When a phase doc, sub-doc, or implementation decision conflicts with a principle, the principle wins and the conflicting decision must be revised.

If a principle itself needs to change, that is a constitutional amendment: it must be made here, with rationale, and every affected block must be re-reviewed before any code change.

---

## Stage 1 Resolutions

The two open questions raised during the initial draft are now resolved (see `Docs/decisions_log.md`):

- **Data minimization** stays as a sub-rule under Principle 4 (Security by Design), not a sixth principle. Enforcement points for data minimization live in Block 06 (AI Privacy Gateway) and Block 05 (field-level encryption + payload minimization in the Processing zone).
- **No "Accountant" principle** is added. This is consistent with the MVP decision that accountant approval is not required for finalization. The Accountant role still exists in Block 02 for review purposes, but does not warrant constitutional status.
