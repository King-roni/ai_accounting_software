# Block 08 — Phase 03: Recurring Vendor Memory (Layer 2)

## References

- Block doc: `Docs/blocks/08_transaction_classification_and_tagging.md` (Layer 2 — Recurring Vendor Memory)
- Decisions log: `Docs/decisions_log.md` (tiered promotion: 1 confirmation = medium, 3+ = high)

## Phase Goal

Implement the second classifier layer: per-business memory of how prior transactions from the same counterparty were classified. After this phase, the second time the same supplier appears in a business's statements, the system suggests the previously confirmed classification with medium confidence; after three or more confirmations, it auto-confirms with high confidence.

## Dependencies

- Phase 01 (`recurring_vendor_memory` table)
- Phase 02 (Layer 1 runs first and produces an in-memory proposal; **Layer 2 runs always**, regardless of whether Layer 1 fired — its output is corroboration when Layer 1 has a proposal, or the primary proposal when Layer 1 was silent. The exception is a Layer 1 `rule_conflict` outcome, which suppresses both Layer 2 and Layer 3 until resolved.)

## Deliverables

- **Counterparty signature computation** — `signatureFrom(transaction) → string`:
  - Normalize the counterparty name: lowercase, trim whitespace, remove POS/CARD/STRIPE/PP-style prefixes, collapse multiple spaces, strip trailing transaction-id suffixes (e.g., `*ABCD1234`).
  - If a counterparty identifier (IBAN-shaped or merchant id) is present, append it after a separator. The identifier disambiguates suppliers with the same display name.
  - The output is the lookup key into `recurring_vendor_memory`.
- **Memory lookup** — `lookup(businessId, signature) → VendorSuggestion | null`:
  - Returns the active memory row matching `(business_id, counterparty_signature)` if one exists.
  - Returns null when no memory or the row is `REVOKED`.
- **Tiered confidence per Stage 1:**
  - `confirmations_count = 1` → confidence `0.60` (medium). Suggestion is offered to Layer 3 / review queue but not auto-confirmed.
  - `confirmations_count = 2` → confidence `0.72`.
  - `confirmations_count >= 3` → confidence `0.88` (high). Eligible for auto-confirm via Phase 07's threshold.
- **Confirmation tracking:**
  - When a user confirms a classification (or it auto-confirms via Phase 07), the memory row is upserted: increment `confirmations_count`, set `last_confirmation_at = now()`.
  - First confirmation creates the row with `confirmations_count = 1`.
- **Revocation:**
  - The user can mark a vendor memory as wrong from the review queue or settings UI.
  - Sets `status = REVOKED`. Future lookups for that signature skip it (treated as no memory).
  - Subsequent confirmations of a different classification for the same signature create a fresh row (with `confirmations_count = 1`) — the revoked row stays for audit history but is not a lookup target.
- **Layer 2 output (in-memory only):**
  - On a hit: returns a `Layer2Result` carrying the proposed `transaction_type` (and `system_tag` when carried), proposed `classification_method = VENDOR_MEMORY`, and the tier-derived confidence.
  - On a miss (no memory or `REVOKED` row): returns null. Layer 3 may run for cases where Layer 1 was also silent.
  - **The actual writes to `transactions` happen in Phase 09's `assign_status` tool.** Layer 2 is `READ_ONLY` (it does not mutate `transactions`; it only reads `recurring_vendor_memory`). The increment to `confirmations_count` happens later — at confirmation time (auto-confirm in Phase 07 or user confirm via Block 14) — not during Layer 2's lookup.
- **Audit events:** `VENDOR_MEMORY_CREATED`, `VENDOR_MEMORY_HIT`, `VENDOR_MEMORY_CONFIRMED` (with new count), `VENDOR_MEMORY_PROMOTED_TO_HIGH` (the explicit moment a row crosses 3 confirmations), `VENDOR_MEMORY_REVOKED`.

## Definition of Done

- Two transactions from the same counterparty produce one `recurring_vendor_memory` row with `confirmations_count = 1` after the first confirmation, and `2` after the second.
- The third confirmation emits `VENDOR_MEMORY_PROMOTED_TO_HIGH` and the next transaction from that counterparty receives a confidence of `0.88` from Layer 2.
- A `REVOKED` row is not returned by `lookup`; a different classification for the same signature creates a fresh row.
- Tests cover the full promotion path, the revocation path, and the disambiguation case (two suppliers with the same display name but different identifiers stay separate).

## Sub-doc Hooks (Stage 4)

- **Signature normalization sub-doc** — exact rules per provider (Revolut's `POS *MERCHANT` patterns, Wise patterns, etc.), test fixture catalogue.
- **Tier promotion thresholds sub-doc** — exact confidence values per `confirmations_count`, calibration approach against early production data.
- **Revocation flow sub-doc** — UX for marking memory wrong, audit trail, recovery if a revocation was a mistake.
- **Cross-business memory consideration (post-MVP) sub-doc** — should well-known global suppliers (Google, AWS) be a shared registry rather than per-business memory? Deferred.
