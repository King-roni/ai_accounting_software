# adjustment_reason_text_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Co-owners:** 12 — OUT Workflow, 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2)

The content + validation contract for `adjustment_records.reason_text` — the free-form rationale a user MUST supply on every adjustment record. The reason text is the audit-grade explanation that survives in the archive bundle indefinitely; it is what an auditor reads years later to understand why a finalized record was amended. This policy pins length bounds, content rules, localisation, PII handling, and the UI affordances that help users write meaningful reasons.

The column is defined in `adjustment_record_schema` with a `CHECK (length(reason_text) >= 10 AND length(reason_text) <= 4000)` constraint; this policy expands on the validation rules the application enforces above that floor.

---

## Length bounds (DB-enforced)

| Bound | Value | Enforcement | Rationale |
| --- | --- | --- | --- |
| Minimum | 10 characters | DB CHECK constraint | Too-short reasons ("typo", "fix") are not auditable rationale; 10 chars forces a sentence fragment minimum |
| Maximum | 4000 characters | DB CHECK constraint | Roughly 600 English words; long enough for complex rationale, short enough to fit cleanly in archive PDFs |

These are hard bounds — the engine rejects out-of-range INSERTs with `ADJUSTMENT_REASON_LENGTH_VIOLATION`. Application code does NOT bypass the DB check; client-side validation matches but cannot be authoritative.

## Content rules (application-enforced)

Beyond the DB length CHECK, the engine applies these rules at INSERT time via `engine.validate_adjustment_reason(text) RETURNS validation_result` (SECURITY DEFINER, IMMUTABLE):

1. **Non-whitespace minimum** — at least 10 characters that are NOT whitespace, NOT control chars, NOT punctuation-only. Length-after-`regexp_replace(text, '[\s\p{P}\p{C}]', '', 'g') >= 10` enforced.
2. **No boilerplate-only strings** — a blocklist of obvious filler phrases is rejected:
   - `"see above"`, `"see notes"`, `"as discussed"`, `"per email"`, `"per conversation"`, `"adjustment"`, `"correction"` (alone or with only punctuation/whitespace)
   - The blocklist is case-insensitive; Greek equivalents are included (`"βλέπε ανωτέρω"`, `"όπως συζητήθηκε"`, etc.)
   - The blocklist is maintained in `engine.adjustment_reason_blocklist` table; rule-set version is part of the `tool_invocations` dedup_key
3. **Must contain a verb** — at least one tokenised word matches a pre-computed list of common Greek and English verbs. The list lives in `engine.adjustment_reason_verb_list` (computed at boot from a stemming pass over a corpus; not a hand-maintained list). A reason without a verb is almost always a noun fragment ("VAT typo", "wrong account") which fails to explain the change.
4. **No URLs / file paths** — the audit record should describe rationale, not link to external sources that may rot. Reject regex `https?://`, file:// paths, and obvious vendor portal patterns.
5. **No control characters** — except `\n` (newline) and `\t` (tab). Rejects null bytes, BEL, and other ASCII control chars that indicate copy-paste from binary sources.

Each rule returns a specific error code (`REASON_TOO_THIN_BOILERPLATE`, `REASON_MISSING_VERB`, etc.) so the UI can render specific guidance.

Rule 3 is the most aggressive — it WILL produce false positives (e.g., a valid Greek reason that uses only nouns is rare but possible). The UI mitigates by offering an "I confirm this reason is complete despite the warning" override that bypasses rule 3 only (other rules cannot be overridden). The override is logged with `WORKFLOW_ADJUSTMENT_REASON_OVERRIDE` (LOW informational).

## Localisation

| Aspect | Behaviour |
| --- | --- |
| Permitted scripts | English + Greek (per Cyprus locale); Latin extended characters allowed (e.g., German umlauts in vendor names) |
| Mixed-language reasons | Permitted — a reason may mix EN + EL freely; the blocklist + verb list cover both |
| Right-to-left scripts | NOT supported in MVP — rejected with `REASON_UNSUPPORTED_SCRIPT` |
| Emoji | Permitted — emojis don't aid auditability but don't harm it either; they pass through |
| Locale of validation | The validator detects the dominant script (EN vs EL) by character class and applies the appropriate blocklist + verb list. Detection is per-reason, not per-user-locale-setting (a Greek-locale user may write an English reason and vice versa) |

The reason text is stored as-is (no normalisation) and rendered with the user's display locale's right-to-left handling rules in the UI.

## PII handling

The reason text is INTENTIONALLY in plain text. It is NOT subject to `audit_pii_redaction_policy` — the reason is a deliberate disclosure by the user of why they amended a record, and redacting it would defeat the audit purpose.

Consequence: users MAY include PII (customer name, IBAN, invoice number) in the reason text. The audit and archive layers store it as-is. The personal-feed projection (per `personal_audit_feed_policy`) does NOT mask reason_text content even when it contains PII referring to others.

This is documented to users via tooltip on the reason text field: "This text becomes part of the permanent audit record. Do not include sensitive details that the auditor should not see." The product team agreed that this is the correct trade-off — auditors NEED to see the rationale, and self-redaction is the user's responsibility.

## Validation enforcement path

```ts
// In engine.create_adjustment_record():
const validation = await db.query(
  `SELECT * FROM engine.validate_adjustment_reason($1)`,
  [reasonText]
);

if (!validation.passed) {
  return {
    error_code: validation.error_code,           // e.g., 'REASON_TOO_THIN_BOILERPLATE'
    error_message: localisedMessage(validation.error_code, userLocale),
    details: { matched_rule: validation.matched_rule, dominant_script: validation.dominant_script }
  };
}

await db.query(
  `INSERT INTO adjustment_records (..., reason_text, ...) VALUES (..., $1, ...)`,
  [reasonText]
);
```

The validator runs INSIDE the engine transaction; if it fails, no row is written. The DB CHECK is a defense-in-depth fallback — the application validator should catch all violations before the CHECK fires, but the CHECK ensures no path bypasses the rules.

## UI affordances

The reason text field in the adjustment intake UI:

- **Placeholder text** (locale-aware): "Explain why this record needs to be adjusted. Include the trigger event and the impact." / "Εξηγήστε γιατί χρειάζεται προσαρμογή της εγγραφής."
- **Character counter** with thresholds at 10 (minimum), 1000 (recommended depth), 4000 (maximum)
- **Real-time validation** — runs the same `engine.validate_adjustment_reason` RPC client-side via debounced typing (500 ms); shows inline warnings BEFORE submit
- **Example bank** — 5-7 canonical example reasons per `delta_kind` category, accessible via "Show examples" link. Examples are NOT auto-inserted (that would defeat the purpose) — they're reference text users can read for inspiration.
- **Boilerplate-rule override** for rule 3 only (missing-verb) — checkbox "I confirm this reason is complete despite the warning"; logged via `WORKFLOW_ADJUSTMENT_REASON_OVERRIDE`

The character counter colour-shifts: red below 10, yellow 10-50, green 50-3000, yellow 3000-4000, red above 4000.

## Audit shape

The reason text is captured in the standard `OUT_ADJUSTMENT_RECORD_CREATED` / `IN_ADJUSTMENT_RECORD_CREATED` event payload per `adjustment_record_schema` §8. Override events:

```ts
emitAudit("WORKFLOW_ADJUSTMENT_REASON_OVERRIDE", {
  adjustment_record_id,
  workflow_run_id,
  business_id,
  override_rule: "REASON_MISSING_VERB",
  reason_text_truncated: substring(reason_text, 1, 200),
  actor_user_id,
  evaluated_at
});
```

Severity `LOW`. Rate-monitored at the daily aggregate level — if override rate exceeds 30% in a 30-day window, ops review whether the verb-list is too aggressive.

## Localised messages

Error code → localised message mapping lives in `Docs/templates/reason_validation_messages/{code}.{en,el}.md`. Each error code has both EN and EL versions. The UI resolves at render time per user locale.

## Idempotency interaction

The adjustment record's dedup_key (per `dedup_key_generator_policy` for adjustment tools, if registered) includes `reason_text_hash = sha256_hex(reason_text)`. Two identical reason texts on the same adjustment scope produce the same dedup key; the engine cache-hits the prior write. A user who edits a reason text between submit attempts gets a new dedup_key and a new record write.

## Cross-block contract

- **Block 03 Phase 11** owns the engine-side validation.
- **Block 03 Phase 01** owns the DB CHECK constraint on the column.
- **Block 12 + Block 13** UIs implement the affordances.
- **Block 16 dashboard** renders the reason text in the archive-history drill-down view.

## Cross-references

- `adjustment_record_schema` — column definition + DB CHECK
- `dedup_key_generator_policy` — `reason_text_hash` participates in adjustment-tool dedup keys
- `audit_pii_redaction_policy` — explicit exemption for reason_text
- `personal_audit_feed_policy` — reason_text NOT masked in personal feeds
- `audit_event_payload_schemas` (Stage-6 catalog) — `OUT/IN_ADJUSTMENT_RECORD_CREATED` + `WORKFLOW_ADJUSTMENT_REASON_OVERRIDE` payloads
- `adjustment_six_year_cap_policy` — sibling B03·P11 policy
- `out_adjustment_policies` / `in_adjustment_policies` — workflow-level adjustment rules
- Block 03 Phase 01 — table host
- Block 03 Phase 11 — owning phase
- Block 12 / 13 — UI consumers
- Cyprus locale — bilingual EN/EL requirement
