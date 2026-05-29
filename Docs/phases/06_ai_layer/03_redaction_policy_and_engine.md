# Block 06 — Phase 03: Redaction Policy & Engine

## References

- Block doc: `Docs/blocks/06_ai_layer.md` (Redaction policy section)
- Block doc: `Docs/blocks/01_core_principles.md` (Principle 4 — Security by Design; data minimization sub-rule)
- Block doc: `Docs/blocks/05_security_and_audit.md` (`mask_field` from Phase 05 used for masking)

## Phase Goal

Build the redaction layer that runs inside the gateway pipeline. The policy is **allowlist-based**: only fields the caller explicitly declared as in-scope pass through. Default redactions for Tier 3 are configured here; they can be overridden per call only by explicit declaration in the tool's input schema. After this phase, accidentally leaking sensitive data via an AI call becomes a code-review-visible event because adding a new field to a Tier 3 input requires an explicit schema change.

## Dependencies

- Phase 02 (gateway invokes redaction inside the pipeline)
- Block 05 Phase 05 (`mask_field` used for masking when fields are kept in masked form)

## Deliverables

- **Redaction policy as data:**
  - `redaction_policies` table (or versioned config file) — `id`, `version`, `tier`, `field_kind`, `default_action`, `created_at`, `created_by`.
  - `default_action` is one of: `DROP`, `MASK_LAST_N`, `MASK_FIXED`, `KEEP_IF_DECLARED`.
- **Default Tier 3 policy:**
  - IBAN → `MASK_LAST_N(4)` (uses `mask_field`).
  - Account number → `MASK_LAST_N(4)`.
  - Counterparty identifier (full) → `MASK_LAST_N(4)`.
  - Personal addresses → `DROP` unless explicitly declared.
  - Email body content → `DROP`; only structured extracted fields can pass.
  - Free-text descriptions → `KEEP_IF_DECLARED` and pass the PII-pattern scan.
  - Names → kept (no default redaction; covered separately by GDPR pseudonymization where appropriate).
- **Default Tier 2 policy:**
  - Less restrictive than Tier 3 because the model runs on operator-controlled hardware, but still allowlist-based — implicit fields are dropped.
  - IBAN → `KEEP_IF_DECLARED`; addresses → `KEEP_IF_DECLARED`. Block 06 architecture is explicit that Tier 2 is for tasks against minimized inputs the system prefers not to send off-device.
- **Tier 1 policy:** no AI, no redaction. Tier 1 calls don't reach the gateway at all.
- **Allowlist enforcement:**
  - Fields not declared in the tool's input schema are dropped before the model dispatch step in Phase 02.
  - A field declared in the schema but matching a sensitive `field_kind` whose policy is `DROP` is dropped with a warning logged in the audit event.
- **PII-pattern scan:**
  - Regex-based detection for IBANs, common bank account number formats, credit cards, EU national IDs, social security numbers.
  - Runs on every free-text field that's been declared `KEEP_IF_DECLARED`.
  - On match in a non-declared-as-IBAN field: returns `REDACTION_REJECTED` from the gateway. The call never reaches the model.
- **Policy versioning:**
  - Every gateway call records the policy version used (in `AI_USAGE_RECORDED` from Phase 07).
  - Policy changes go through code review and a sub-doc-tracked changelog.
- **Audit events:** `AI_REDACTION_APPLIED` (with field counts and categories — never the values), `AI_REDACTION_REJECTED` (with the reason), `AI_PII_DETECTED_IN_NON_DECLARED_FIELD` (CRITICAL — likely a code bug at the calling phase).

## Definition of Done

- The default Tier 3 policy is configured and the gateway applies it on every Tier 3 call.
- An attempt to send a payload with a full IBAN in a non-IBAN field is rejected by the PII-pattern scan (verified by test).
- A field not declared in the input schema is dropped silently, with a count audited.
- The policy version used is recorded on every `AI_USAGE_RECORDED` event.
- A policy change deploys via the versioned-artifact path; rollback is a version pointer change.
- Tests cover every `field_kind` and every `default_action`.

## Sub-doc Hooks (Stage 4)

- **Redaction policy versioning sub-doc** — full version history, change-review process, rollback procedure.
- **PII pattern catalogue sub-doc** — exact regex patterns per pattern type, false-positive rates, geographic considerations.
- **Per-tier policy sub-doc** — full Tier 2 and Tier 3 default tables, override semantics, business-level customisation hooks.
- **Allowlist enforcement sub-doc** — exact dropping behaviour, warning audit shape, interaction with the schema validator in Phase 02.
