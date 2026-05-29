# Tool Naming Convention Policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 1 convention)

This is the single binding source for how workflow-engine-registered tools are named, structured, versioned, and registered. Every Tools sub-doc references this policy. Lint rules in CI enforce the format; commits that introduce a tool failing these rules are blocked at PR time.

The shape of a tool name carries semantic meaning — readers of phase docs and downstream sub-docs should be able to predict where a tool lives and what it does from the name alone.

---

## Naming pattern

```
<block_short_name>.<action>
```

- `block_short_name` — snake_case, taken from the binding allowlist below
- `action` — snake_case verb phrase, present-tense imperative

Examples (canonical):
- `matching.score_pair`
- `intake.ocr_and_extract`
- `ledger.prepare_entries`
- `report.generate_period_report`
- `archive.lock_period`
- `review_queue.unsnooze_at_run_start`

Anti-examples:
- `match_auto_confirm` — missing namespace
- `Matching.scorePair` — capitalization wrong
- `matching.scores` — action is a noun, not a verb
- `matching.score-pair` — kebab-case rejected
- `MATCHING.SCORE_PAIR` — uppercase reserved for audit-event names (see `audit_log_policies`)

## Block short-name allowlist (binding)

| Short name | Block | Notes |
| --- | --- | --- |
| `auth` | 02 — Tenancy & Access | Identity, role, MFA, OAuth |
| `engine` | 03 — Workflow Engine | Run / phase / gate / trigger primitives |
| `data` | 04 — Data Architecture | Hash, ID, zone-promotion, retention |
| `security` | 05 — Security & Audit | Encryption, audit, alerts |
| `ai` | 06 — AI Layer | Gateway, redaction, prompts, end-scan |
| `intake` | 07, 09 (shared) | Bank-statement intake AND document intake |
| `classification` | 08 — Transaction Classification | Layers 1–3, vendor memory writes |
| `matching` | 10 — Matching Engine | Score, split, dedup, reasons |
| `ledger` | 11 — Ledger & Cyprus VAT | Counterparty, VAT, entries |
| `out_workflow` | 12 — OUT Workflow | OUT_MONTHLY / OUT_ADJUSTMENT |
| `in_workflow` | 13 — IN Workflow + Invoice Generator | IN_MONTHLY / IN_ADJUSTMENT, invoice lifecycle |
| `review_queue` | 14 — Review Queue | Resolution, snooze, regenerate |
| `archive` | 15 — Finalization & Secure Archive | Lock sequence, manifest, bundle |
| `report` | 16 — Dashboard & Reporting | Exports, period reports, accountant pack |

Block 01 (Core Principles) registers no tools — it is constitutional. New short names require a `Docs/decisions_log.md` amendment.

The `intake` namespace is intentionally shared between Blocks 07 and 09 because Block 09's document intake operates inside Block 07's INGESTION workflow phase; users of these tools think of them as one intake surface.

## Side-effect class

Every tool declares one or more side-effect classes from the closed enum:

| Class | Meaning |
| --- | --- |
| `READ_ONLY` | No DB writes; pure compute, read, or proposer pattern |
| `WRITES_PROCESSING_ZONE` | Writes to Processing-zone tables only (extraction results, classifier outputs, pre-finalization scratch) |
| `WRITES_RUN_STATE` | Writes to operational-DB tables (`transactions`, `documents`, `match_records`, `review_issues`, etc.) |
| `WRITES_AUDIT` | Writes to the audit log via `emitAudit()` (almost every tool does this; declared explicitly so dependency analysis can find them) |
| `WRITES_ARCHIVE` | Writes to the Finalized Archive zone — only Block 15 finalization tools and the `re-finalization` adjustment tool carry this |
| `EXTERNAL_CALL` | Invokes an external API (Document AI, Anthropic Claude, Vault, RFC 3161 TSA, Gmail, Drive, ECB rate API). Composable with the write classes |

A tool may carry multiple classes — for example, `intake.ocr_and_extract` is `WRITES_PROCESSING_ZONE | EXTERNAL_CALL | WRITES_AUDIT`. The proposer pattern from `tool_atomicity_policy` is preferred wherever feasible: the proposer carries `READ_ONLY | EXTERNAL_CALL | WRITES_AUDIT`, and a separate single-writer tool carries the `WRITES_*` class.

The `WRITES_ARCHIVE` class is reserved. Code review rejects any tool outside Block 15 attempting to register with this class.

## AI tier

Every tool declares one tier from the closed enum (matches Block 06 Phase 01):

| Tier | Meaning |
| --- | --- |
| `NONE` | No AI invocation in this tool's call path |
| `LOCAL` | May invoke the locally-operated Tier 2 model |
| `EXTERNAL` | May invoke Anthropic Claude (Tier 3) — declared as the **maximum** reachable tier even when escalation is rare |

Tools that may escalate from `LOCAL` to `EXTERNAL` (e.g., classifier Layer 3, plain-language pipeline) declare `EXTERNAL`. Per Block 06 Phase 01, escalation is two distinct gateway invocations; the tier declaration covers the gateway's authorization scope, not the typical-path tier.

Tools that wrap a downstream AI-invoking tool but do not themselves invoke AI declare `NONE` (the gateway records the downstream tier separately). Example: `out_workflow.upload_invoice` is `NONE`; the `intake.ocr_and_extract` it eventually drives carries the tier.

## Schema versioning

Tool input/output schemas use `major.minor` versioning declared in the registration call.

- **Major bump** — input or output shape changes (param added/removed, type changed, side-effect class changed, AI tier widened). Old version remains registered for one full workflow-run cycle (typically 30 days) before removal. Audit event: `WORKFLOW_TOOL_REGISTRATION_DEPRECATED`.
- **Minor bump** — implementation change with no shape impact (lookup source added, deterministic algorithm refinement, performance improvement). No deprecation period.

Schema language and shared type fragments are deferred to `tool_schema_definition_language` (Block 03 Phase 03 sub-doc). This policy commits only to the version-bump rules.

## Registration shape

Boot-time registration via Block 03 Phase 03's `engine.registerTool`. Canonical call shape:

```ts
engine.registerTool({
  name: "matching.score_pair",
  schema_version: "1.0",
  side_effect_class: ["READ_ONLY", "WRITES_AUDIT"],
  ai_tier: "NONE",
  input_schema_ref: "tool_matching_score_pair#v1.input",
  output_schema_ref: "tool_matching_score_pair#v1.output",
  audit_events: ["MATCHING_PAIR_SCORED"],
  description_ref: "Docs/sub/tools/tool_matching_score_pair.md",
});
```

Name collisions at boot are fatal — the engine refuses to start. This is intentional: ambiguous tool resolution at runtime would be far worse than a fail-fast boot.

## Lint rules (CI-enforced)

A pre-commit lint pass and CI job enforce the following:

1. **Format regex.** Tool names match `^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$`. Two name parts, snake_case, lowercase, no double underscores, no trailing underscores.
2. **Block short-name allowlist.** The first part of the name is in the binding allowlist above.
3. **Side-effect class enum.** Every declared class is in the closed enum. Multi-class declarations validate per-element.
4. **AI-tier enum.** Declared tier is in `{NONE, LOCAL, EXTERNAL}`.
5. **Audit event reference.** Every audit event name in the `audit_events` array passes `audit_log_policies` event-naming regex AND is present in the canonical `audit_event_taxonomy` catalogue.
6. **Schema version format.** Matches `^\d+\.\d+$`.
7. **Description reference exists.** The `description_ref` path resolves to an actual sub-doc in `Docs/sub/tools/`.

Failures block the commit. Override requires an amendment ticket referenced in the commit message.

## Cross-references

- `audit_log_policies` — audit-event name conventions referenced in registration
- `tool_atomicity_policy` (Block 03) — proposer + single-writer pattern for atomicity
- `tool_ai_tier_metadata` (Block 03 / Block 06) — how the tier flows through the gateway
- Block 03 Phase 03 — `engine.registerTool` framework
- Block 03 Phase 06 — phase execution engine that calls tools
- Block 03 Phase 07 — resumability + idempotency interactions

## Open items deferred to later sub-docs

- Schema definition language: `tool_schema_definition_language` (Block 03 Phase 03)
- Per-tool failure-semantics taxonomy: `tool_atomicity_policy` carries the canonical pattern

## Resolved items

- The naming reconciliation from `report.generatePeriodReport` (2026-05-09 Block 16 amendment) to canonical snake_case `report.generate_period_report` was ratified via the 2026-05-09 Stage 4 Layer 1 amendment in `Docs/decisions_log.md`. The snake_case form is now canonical.
