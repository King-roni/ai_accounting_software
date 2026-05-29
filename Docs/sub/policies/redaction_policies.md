# Redaction Policies

**Category:** Policies · **Owning block:** 06 — AI Layer · **Stage:** 4 sub-doc (Layer 1 convention)

Two sub-policies bound together: how redaction policies are versioned, and how the redactor handles fields outside the allowlist. Redaction is the gate between user data and AI providers — it's the thing that turns "this product sends invoices to a third party" into "this product sends de-identified shapes to a third party." Conservative defaults; explicit allowlisting; auditable behaviour.

Block 06 Phase 03 owns the redaction engine; Phase 02 owns the gateway pipeline that invokes it.

---

## Section 1 — Pipeline position

Redaction's place in the gateway pipeline is fixed:

```
input
  → minimization (drop fields not needed for this prompt)
  → redaction      ← this policy governs this step
  → schema validation (output of redaction conforms to prompt input schema)
  → cost ceiling check
  → cache lookup
  → routing & dispatch (Tier 2 / Tier 3)
  → response handling
```

The order is locked by `gateway_pipeline_ordering_policy` (Block 06). Redaction always follows minimization (so the redactor sees a smaller surface) and always precedes routing (so the same redacted payload is sent regardless of which tier handles it).

## Section 2 — Allowlist behaviour

The redactor operates on an **allowlist**, not a denylist. Fields whose path is not in the allowlist are dropped — never passed through with a "we didn't know what to do" fallback.

### Drop rules

- Field path matches an allowlist entry exactly → passed through
- Field path matches an allowlist entry's wildcard prefix (e.g., `line_items.*.description`) → passed through
- Field path does not match → **dropped**, plus warning audit event

### Warning audit event

Dropped fields emit `AI_REDACTION_ALLOWLIST_DROP` with payload:

```json
{
  "prompt_name": "classification.tier_3_classifier",
  "prompt_version": "2.1.0",
  "redaction_policy_version": "1.4.0",
  "dropped_field_path": "transaction.counterparty_iban",
  "drop_reason": "not_in_allowlist",
  "business_id": "..."
}
```

The event payload itself does NOT include the dropped value. The point of redaction is to keep that value out of every downstream system, including audit.

### Schema-validator interaction

After redaction, the resulting payload is validated against the prompt's `output_schema.json` (per `prompt_management_policies`). If a required field was dropped by redaction, the validator surfaces `AI_REDACTION_VALIDATION_FAILED`:

```json
{
  "prompt_name": "...",
  "missing_required_field": "transaction.amount_signed",
  "redaction_policy_version": "1.4.0",
  "remediation": "Add field to allowlist OR mark as optional in schema OR drop prompt"
}
```

Followed by the prompt invocation failing with a structured error. The gateway never sends a payload to the provider that doesn't conform to the prompt's declared schema.

### The "no fallback" rule

Redaction never silently substitutes a placeholder for a dropped field. There is no "redacted_value" / "[REDACTED]" / null-replacement behaviour. A dropped field is gone from the payload structurally. This is intentional — substitution behaviour creates ambiguity at the prompt level (the model can't distinguish "field absent" from "field redacted").

## Section 3 — Versioning

Semver with three parts: `major.minor.patch`. Same general scheme as `prompt_management_policies`, with these specific definitions:

| Bump | When | Risk direction |
| --- | --- | --- |
| `major` | Drops a previously-allowed field; loosens the allowlist (allows a new field type that previously was redacted); changes the dropping mechanism | **Higher risk** — required Privacy lead sign-off |
| `minor` | Adds a new field type to redaction (tightens — fewer fields pass) | **Lower risk** — safer direction |
| `patch` | Regex tweak, comment, formatting; no scope change | None |

Loosening the allowlist (a major bump) is the highest-risk redaction change. The change-review process below is mandatory for these.

### Change-review process

Every redaction policy change requires:

1. **Test corpus run** — the redactor's regression set runs to zero new leaks. The corpus is `redaction_test_corpus` (Stage 4 sub-doc, Block 06).
2. **Operator sign-off** — Owner-level role on the affected business (or system-level if global change) approves
3. **Privacy lead sign-off** — second pair of eyes on every major bump
4. **Decisions-log amendment** — every Stage 1+ change is recorded in `Docs/decisions_log.md` with rationale

A major bump rejected by the test corpus may not deploy. Period.

### Rollback

Prior policy versions remain in the runtime registry for 30 days. Rollback is a config flag (`active_redaction_policy_version`), not a code change. Audit event `AI_REDACTION_POLICY_ROLLED_BACK` records the rollback with rationale.

The 30-day window matches `Docs/decisions_log.md` retention for amendments. Rollbacks beyond 30 days require restoring from version control.

## Section 4 — Cross-tier asymmetry

Tier 2 (locally-operated machine) and Tier 3 (Anthropic Claude EU) carry different allowlists.

| Tier | Default allowlist scope | Rationale |
| --- | --- | --- |
| Tier 2 — Local | Wider — operator-controlled environment, the data never leaves operator infrastructure | Operator owns the machine, owns the model weights, owns the inference. Less restrictive default acceptable. |
| Tier 3 — External (Anthropic) | Narrower — third-party processor under DPA, EU-residency, zero-retention API options | Third party in the trust boundary; conservative default mandatory. |

Block 06 Phase 01 declares the asymmetry. Per-prompt overrides may tighten Tier 2 (a prompt that handles especially sensitive data may use the Tier 3 allowlist on Tier 2 too) but never loosen Tier 3.

## Section 5 — Per-prompt overrides

A prompt may declare `redaction.md` in its version directory (per `prompt_management_policies`) to override the default allowlist for that prompt only. Override examples:

- A `vat_treatment_explanation_prompt` allows the VAT amount and treatment kind
- A `match_reason_prompt` allows transaction amount + counterparty signature (after canonicalization)
- A `tier_3_classifier_prompt` allows the normalized description but not the raw bank statement description

Per-prompt overrides may NOT loosen the global Tier 3 allowlist for fields the global policy explicitly excludes (PII like full IBAN, full counterparty name, OAuth tokens, pgcrypto-encrypted values).

## Cross-references

- `prompt_management_policies` — version directory layout and registry mirror
- `ai_cache_policies` — cache key includes `redaction_policy_version`
- `audit_log_policies` — `AI_REDACTION_*` event naming
- Block 06 Phase 02 — gateway pipeline ordering
- Block 06 Phase 03 — redaction engine implementation
- Block 06 Phase 04 — prompt registry interaction
- `gateway_bypass_detection_policy` (Block 06 / 07) — protects against direct provider calls that skip redaction

## Enforcement example

**Before redaction** (raw extraction payload, `classification.tier_3_classifier` prompt):
```json
{
  "transaction": {
    "amount_signed": -12500,
    "counterparty_name": "Acme Ltd",
    "counterparty_iban": "CY12345678901234567890123456",
    "description": "INV-2026-0041 payment",
    "transaction_date": "2026-03-14"
  }
}
```

**After redaction** (using Tier 3 allowlist — `counterparty_iban` and `counterparty_name` not in allowlist):
```json
{
  "transaction": {
    "amount_signed": -12500,
    "description": "INV-2026-0041 payment",
    "transaction_date": "2026-03-14"
  }
}
```

`counterparty_iban` and `counterparty_name` are dropped; they are not structurally replaced with placeholders. `AI_REDACTION_ALLOWLIST_DROP` is emitted twice (once per dropped field path). The prompt's `output_schema.json` must not require either dropped field or `AI_REDACTION_VALIDATION_FAILED` fires.

## Cross-references

- `prompt_management_policies` — version directory layout and registry mirror
- `redaction_field_map` — per-field allowlist entries; the definitive list of which field paths are permitted per tier
- `redaction_at_write_policy` — redaction that occurs at the write layer before data enters the Processing zone (distinct from AI-pipeline redaction governed here)
- `ai_cache_policies` — cache key includes `redaction_policy_version`
- `audit_log_policies` — `AI_REDACTION_*` event naming
- Block 06 Phase 02 — gateway pipeline ordering
- Block 06 Phase 03 — redaction engine implementation
- Block 06 Phase 04 — prompt registry interaction
- `gateway_bypass_detection_policy` (Block 06 / 07) — protects against direct provider calls that skip redaction

## Open items deferred to later sub-docs

- The actual default allowlist contents (list of field paths) — `redaction_test_corpus` and the per-block redaction allowlist sub-docs (Stage 4)
- Specific Tier 2 vs Tier 3 deltas — Block 06 Phase 01 deferral
- Post-MVP cross-language redaction patterns (Greek-language fields, etc.) — out of scope for MVP
