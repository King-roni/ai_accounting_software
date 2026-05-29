# Block 06 — AI Layer (Privacy Gateway + End-Scan)

## Role in the System

This block is the only path through which any AI model — local or external — interacts with the system's data. It contains two tightly coupled components:

1. **AI Privacy Gateway** — the gate every AI call passes through. It tiers the call, redacts sensitive content, validates schemas, logs usage, and refuses unsafe calls.
2. **AI End-Scan Engine** — the consumer of the gateway responsible for the post-matching anomaly review. It generates the issues that populate Block 14 (Review Queue) in plain language.

Both live here because they share infrastructure: routing, prompt management, schema validation, redaction, and usage logging. Splitting them would force constant cross-references; keeping them together preserves a single chokepoint for AI policy.

---

## Scope

### In scope
- Three-tier AI routing (no AI / local LLM / external LLM with redaction)
- Privacy Gateway pipeline: redaction, payload minimization, schema validation, output validation
- Prompt management: versioned, reviewed, tested
- AI usage logging
- The End-Scan engine: when it runs, what it checks, how it produces issues
- Plain-language translation of technical findings (Principle 5)

### Out of scope (covered elsewhere)
- Field-level encryption and key management → Block 05
- Storage of AI payloads and responses → Block 04 (Processing zone, pruned post-run)
- The actual matching, classification, extraction logic — those blocks (07–11) call this gateway when they need AI; their internal logic is theirs

---

## The Three Tiers

### Tier 1 — No AI

Used for any task where deterministic logic suffices. The gateway plays no role here; this tier is documented for clarity about what NOT to send to AI.

Examples: arithmetic totals, exact-match deduplication, file hashing, schema validation, deterministic VAT-treatment lookups, report aggregation.

### Tier 2 — Local LLM / Local AI

Used for narrow, structured tasks against minimized inputs that the system prefers not to send off-device. **The Tier 2 model runs on a dedicated machine the operator owns** (provided by Ronni). The hosted backend reaches it over a private channel; the model never receives unminimized data.

Examples: supplier name normalization, OCR text cleanup, first-pass invoice field extraction from already-OCR'd text, basic transaction-type classification fallback after deterministic rules fail, summarization of structured findings into plain language.

The local model does not need to be large. Narrow prompts plus structured inputs plus output schemas allow modest models to perform well. The specific model choice is deferred to the AI sub-doc once the hardware specs are confirmed.

### Tier 3 — External LLM with Redaction

Used only for tasks where Tier 2 produces poor results — typically complex reasoning, ambiguous match explanation, or anomaly write-ups that require strong language ability. **Tier 3 routes to Anthropic Claude**, using the EU-residency / zero-retention API endpoint. Every Tier 3 call goes through the full Privacy Gateway pipeline and produces an audit event.

Examples: generating a plain-language explanation for a weak match the user must review, writing a careful description of a possible VAT issue, drafting an issue summary for a bundle of related findings.

---

## Privacy Gateway Pipeline

Every AI call (Tier 2 and Tier 3) follows the same pipeline:

```text
Caller produces a typed AI request
  → Gateway validates the input schema
  → Gateway minimizes the payload (drop fields not declared as needed)
  → Gateway redacts PII per a redaction policy
  → Gateway selects the model based on tier classification + caller preferences
  → Gateway issues the call
  → Gateway validates the response against the declared output schema
  → Gateway records a usage event (Block 05)
  → Gateway returns the response (or a structured error) to the caller
```

If validation fails at any stage (input schema, output schema, response sanity), the gateway returns a structured error and the calling phase decides whether to fall back to deterministic logic or surface a review issue.

### Redaction policy

The redaction layer operates on a strict allowlist: only fields explicitly declared as safe for the chosen tier may pass through. Implicit fields — anything the caller forgot to declare — are dropped.

Default redactions for Tier 3:
- Full IBAN → masked (last 4)
- Full account number → masked
- Full counterparty identifier → masked
- Personal addresses → omitted unless the calling phase declares a justified need
- Email content → omitted; only structured extracted fields pass through
- Free-text descriptions → kept only if the caller declares them in scope and they pass a PII-pattern scan

The policy is versioned. Policy changes go through the same review process as code.

### Schema validation

- Every AI call has a typed input schema and a typed output schema, both versioned.
- Output validation is strict: parsing failures produce a structured error, not a "best effort" interpretation.
- Schemas are stored alongside prompts; the prompt + schema + tier choice forms the unit of "an AI capability".

---

## Prompt Management

- Prompts are stored as **versioned artifacts in the repo**, reviewed with the same rigour as application code.
- Each prompt has a declared purpose, declared inputs, declared output schema, and a known-good test corpus.
- **Automated regression tests run against the corpus** before any prompt change is deployed; a regression failure blocks the change.
- Production AI calls reference a specific prompt version; rolling back is a config change, not a code change.

## Cost Control & Caching

- **Cost ceiling per workflow run:** soft ceiling — the system tracks Tier 3 spend and warns the user when a run approaches the threshold. The user can approve continuation. Hard stops are not used in MVP because monthly closeout should not be blocked by an automatic cost cut-off.
- **Caching:** AI calls are cached by input hash within a single workflow run. Identical calls (e.g., normalizing the same supplier name twice in one run) return the cached result. No cross-run cache in MVP — that's deferred until prompt versioning is mature enough to invalidate cleanly.

---

## AI Usage Logging

Every gateway call (success or failure) emits a structured event captured by Block 05:

- `prompt_version`, `tier`, `model_id`, `caller_phase`, `caller_run_id`
- `input_schema_version`, `output_schema_version`
- `payload_size`, `response_size` (no payload contents)
- `validation_outcome`, `latency`, `cost_estimate`
- `redactions_applied` (count and categories)

This log enables: cost tracking, drift detection, prompt regression analysis, and incident response when a model output looks wrong.

---

## The End-Scan Engine

The End-Scan engine runs as a phase inside both the OUT and IN workflows, after matching and ledger preparation, before human review. Its job is to surface every issue the deterministic phases either could not resolve or that warrants user attention.

### What it checks

The full list lives in the core concept doc (Sections 8.16 and 9.5). The categories:

- Missing or weak evidence (no invoice, no receipt, no contract where required)
- Match quality concerns (weak score, duplicate-on-multiple-transactions, amount/currency mismatch)
- VAT and tax red flags (unclear treatment, possible VIES issue, possible reverse charge issue, missing VAT number)
- Suspect transaction shapes (very large, recurring without supporting agreement, refund not connected to original)
- Type-classification concerns (internal transfer treated as expense, bank fee requiring invoice, etc.)

### What it produces

For each finding, the engine generates a structured issue with:

- `issue_type` (technical taxonomy, internal use)
- `issue_group` (one of the six review buckets — Principle 5)
- `severity` (LOW / MEDIUM / HIGH / BLOCKING)
- `plain_language_title` and `plain_language_description` (Tier 2 or Tier 3 LLM call, schema-validated)
- `recommended_action`
- pointers to the transaction(s), document(s), and run involved

Block 14 (Review Queue) consumes these issues and presents them grouped by `issue_group`.

### What it does not do

- It never resolves issues. It only flags them.
- It never advances workflow state. Block 03 owns advancement.
- It never writes to ledger entries. Issues are advisory; resolutions happen in Block 14.

---

## Interfaces

### Inputs (consumed by the gateway from other blocks)
- Typed AI requests from Blocks 07–13 (with input/output schemas and tier classifications)
- Workflow run state for the End-Scan engine

### Outputs
- Validated AI responses to the calling phase
- Structured Review Issue records to Block 14
- Usage events to Block 05

---

## Operating Rules

- **Principle 3 (AI Assists, Rules Decide):** the gateway never makes finalization decisions; the End-Scan never advances state.
- **Principle 4 (Security by Design):** no AI call bypasses the gateway; redaction is allowlist-based, not blocklist-based.
- **Principle 5 (Simple Interface):** the End-Scan is responsible for plain-language output; it must not surface raw `issue_type` codes to users.

---

## Stage 1 Resolutions

Most initially-open questions have been resolved (see `Docs/decisions_log.md`):

- **External LLM provider:** Anthropic Claude, EU residency / zero-retention — covered in Tier 3.
- **Local LLM placement:** operator-owned dedicated machine — covered in Tier 2.
- **Cost ceiling:** soft ceiling per run — covered in Cost Control & Caching.
- **Caching:** by input hash within a run — covered in Cost Control & Caching.
- **Prompt management:** versioned + automated regression tests — covered in Prompt Management.

### Deferred to AI sub-doc (Stage 4)

- **Specific local LLM model and runtime** — depends on the dedicated machine's hardware specs, which are confirmed when the AI sub-doc is written.
- **Specific cost-ceiling thresholds** — soft-ceiling values per workflow type are calibrated against real run cost data.
- **Test corpus content** — the corpus is defined when the first prompts are designed.
