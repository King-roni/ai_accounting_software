# redaction_field_map

**Category:** Reference data · **Owning block:** 06 — AI Layer · **Stage:** 4 sub-doc (Layer 2)

This sub-doc is the canonical map of every field that must be redacted before any AI gateway invocation. Redaction runs inside the `ai` gateway layer (Block 06 Phase 03) after payload minimization and before routing or model dispatch. Original field values are never sent to an external AI endpoint. The map is the binding reference for `redaction_policies`; the Phase 03 engine loads this catalogue at boot time.

---

## Redaction methods

| Method | Behaviour |
|---|---|
| `MASK` | Replace the entire field value with the literal string `[REDACTED]`. Used when no stable reference to the original value is needed downstream. |
| `TOKENISE` | Replace the field value with a stable pseudonym derived from a per-business HMAC. For the same business and the same input value, the pseudonym is always identical across invocations. Allows the model to reason about identity ("this vendor appears three times") without seeing the raw value. |
| `TRUNCATE` | Retain only the first N characters of the field value and discard the remainder. Used for fields where partial context is useful but the full value is sensitive (not currently used for any field in this map — reserved for future additions). |

---

## Field catalogue

Fields are organised by category. For each field: source table, column name, redaction method, and whether redaction is **mandatory** (always applied regardless of value) or **conditional** (applied only when the stated condition is met).

---

### Personal identifiers

| Source table | Column | Method | Mandatory / Conditional |
|---|---|---|---|
| `users` | `email` | `MASK` | Mandatory |
| `users` | `display_name` | `MASK` | Mandatory |
| `clients` | `email` | `MASK` | Mandatory |
| `clients` | `legal_name` | `MASK` | Mandatory |
| `counterparties` | `name` | `MASK` | Mandatory |

**Rationale:** personal identifiers are always PII regardless of context. No business justification exists for sending a user's email address or a client's legal name to an external model. Masking (not tokenising) is applied because the model has no legitimate need to correlate these identifiers across invocations.

---

### Financial narrative fields

| Source table | Column | Method | Mandatory / Conditional |
|---|---|---|---|
| `transactions` | `description` | `TOKENISE` | Mandatory |
| `invoices` | `notes` | `MASK` | Conditional — apply when the field is non-null |

**Rationale:** `transactions.description` contains the raw bank narrative. It frequently embeds partial counterparty names, bank reference codes, and account fragments. Tokenisation (not masking) is used so the model can detect that the same pseudonymous vendor string appears in multiple transactions — this signal is valuable for classification and matching. The pseudonym is stable per-business, so cross-invocation correlation within one business is preserved.

`invoices.notes` is an unstructured free-text field that may contain payment references, personal notes, or client-identifying content. Masking is applied when non-null; null fields are left as null (no substitution needed).

---

### VAT numbers

| Source table | Column | Method | Mandatory / Conditional |
|---|---|---|---|
| `clients` | `vat_number` | `TOKENISE` | Conditional — apply when non-null |
| `businesses` | `vat_number` | `TOKENISE` | Mandatory |

**Rationale:** VAT numbers are quasi-identifiers that can uniquely identify a company in public VIES registries. Tokenisation allows the model to reason about whether two records share the same VAT number without learning the actual number. The per-business HMAC key means a pseudonymised VAT number for business A cannot be correlated with the same VAT number pseudonymised for business B.

---

### Address fields

| Source table | Column | Method | Mandatory / Conditional |
|---|---|---|---|
| `clients` | `address_json` | `MASK` | Conditional — apply when non-null |
| `businesses` | `address_json` | `MASK` | Mandatory |

**Rationale:** addresses are PII under GDPR and are irrelevant to the classification and matching tasks the AI performs. The entire JSON blob is masked when the field is populated. Masking (not tokenising) is appropriate because address-level cross-invocation correlation provides no model utility.

---

### Bank reference codes

| Source table | Column | Embedded field | Method | Mandatory / Conditional |
|---|---|---|---|---|
| `transactions` | `description` | Embedded bank reference codes within the narrative | `TOKENISE` | Mandatory (applied as part of the description tokenisation pass) |

**Rationale:** bank reference codes (e.g., SWIFT reference numbers, IBAN fragments, internal bank-assigned identifiers) are embedded in the `transactions.description` field and are covered by the tokenisation of that field. No separate extraction step is needed because the description tokenisation pseudonymises the entire narrative string, including any embedded codes. A separate structural reference code column, if added in a future schema version, would require its own entry in this map.

---

## Redaction execution

Redaction is applied in the privacy gateway pipeline (Block 06 Phase 03) after the tool input has been validated and minimized but before routing to the model. The sequence is:

1. The gateway receives the typed tool input.
2. Payload minimization drops fields not declared in the tool's input schema (allowlist-based).
3. The redaction engine iterates over this catalogue and applies the method to each present field.
4. The redacted payload proceeds to tier routing and model dispatch.

No original field value leaves the gateway after step 3. The redaction result is not stored — it is an ephemeral in-memory transformation. If `redacted_before_send = false` appears on an `ai_invocation_records` row, the `AI_PRIVACY_GATEWAY_BYPASS_DETECTED` event is raised and an operator alert fires.

---

## Redaction failures and bypass detection

When the redaction engine detects a field that matches a known PII shape (email address format, VAT number pattern, IBAN fragment) in the post-minimization payload but the field is not present in this catalogue, it raises `AI_REDACTION_ALLOWLIST_DROP`. This event is MEDIUM severity and prompts an operator review to determine whether the field should be added to this catalogue or whether the tool's input schema should be narrowed to exclude the field.

`AI_PRIVACY_GATEWAY_BYPASS_DETECTED` (MEDIUM) is emitted when an `ai_invocation_records` row is created with `redacted_before_send = false`. This should be impossible in normal operation; the gateway sets `redacted_before_send = true` after the redaction step regardless of whether any fields were actually masked or tokenised. A `false` value indicates the redaction step was skipped — this is a code-path anomaly that must be investigated immediately.

The `AI_REDACTION_VALIDATION_FAILED` event is raised when the post-redaction payload fails schema validation (i.e., redaction corrupted a field that the tool's input schema expects to be non-null). In this case the gateway returns `REDACTION_REJECTED` to the caller and does not proceed to model dispatch.

---

## TOKENISE pseudonym stability guarantee

The `TOKENISE` method produces a pseudonym that is stable per `(business_id, field_name, original_value)`. Two invocations for the same business, same field, and same value always produce the same pseudonym. The HMAC key is derived from the business's data encryption key (DEK) hierarchy per Block 05 Phase 04. This means:

- Pseudonyms are not portable across businesses. Business A and Business B with the same VAT number get different pseudonyms.
- Pseudonyms survive key rotation only if the HMAC key derivation inputs remain the same. DEK rotation that changes the derivation input invalidates existing pseudonyms; affected vendor memory and classification cache entries must be rebuilt.
- Pseudonyms are deterministic within a business's lifetime but must not be treated as identifiers outside the AI context — they are ephemeral labels for within-prompt cross-reference, not persistent system identifiers.

---

## Adding or modifying entries

Changes to this map require:
1. A `Docs/decisions_log.md` amendment explaining the classification decision.
2. A test-corpus addition demonstrating the field is correctly redacted in the Phase 03 engine.
3. A CI lint check verifying the new entry is covered by the redaction engine's field catalogue.

No field may be removed from this map in MVP. Removal would require confirmation that the field no longer exists or is no longer reachable by any tool's input schema.

---

## Mobile write rejection

This catalogue is read-only at runtime; no write path is exposed to clients. Mobile clients have no access to modify or bypass the redaction field map. All redaction enforcement is server-side only. See `mobile_write_rejection_endpoints.md`.

---

## Cross-references

- `redaction_policies` (Block 06) — governing policy; this sub-doc is the field-level implementation of that policy
- `redaction_at_write_policy` (Block 05 / Block 06) — write-time field encryption for fields in this map that are also encrypted at rest
- `ai_gateway_schema` — `redacted_before_send` column on `ai_invocation_records`; records whether this map was applied
- `prompt_management_policies` (Block 06 Phase 04) — prompt templates must not embed raw field values for fields listed in this map
- `audit_log_policies` — `AI_REDACTION_*` domain; `AI_REDACTION_ALLOWLIST_DROP`, `AI_REDACTION_VALIDATION_FAILED` events
- `audit_event_taxonomy` — `AI_PAYLOAD_REDACTED`, `AI_PRIVACY_GATEWAY_BYPASS_DETECTED`
- Block 06 Phase 02 — privacy gateway pipeline; execution site for this map
- Block 06 Phase 03 — redaction policy and engine; implementation owner
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
