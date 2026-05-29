# Block 09 — Phase 05: Email Finder (Gmail)

## References

- Block doc: `Docs/blocks/09_document_intake_and_extraction.md` (Phase 9.1 — Email Finder)
- Decisions log: `Docs/decisions_log.md` (fixed library of query patterns; Gmail spam labels + per-business sender allowlist)

## Phase Goal

Build the scoped Gmail search that finds invoice and receipt attachments matching a transaction's context. After this phase, OUT_EXPENSE transactions can have their evidence located via the user's connected Gmail without ingesting the inbox — the search is query-driven, the spam labels and the sender allowlist are honoured, and discovered candidates flow into the document lifecycle (Phase 02).

## Dependencies

- Phase 01 (`gmail_search_query_templates`, `business_sender_allowlist`, `document_source_links`)
- Phase 02 (state machine — `null → DISCOVERED → INGESTED`)
- Phase 03 (OCR pipeline downstream)
- Phase 04 (field extraction downstream)
- Block 02 Phase 08 (Gmail OAuth tokens, refresh by any Owner/Admin per Stage 1)
- Block 05 Phase 05 (token decryption via `decrypt_field`)
- Block 05 Phase 07 (Google API credentials via `getSecret`)

## Deliverables

- **Default query template library** seeded at deployment in `gmail_search_query_templates` (rows with `business_id IS NULL`):
  - `invoice_by_amount_and_supplier_domain` — `has:attachment from:{supplier_domain} subject:(invoice OR receipt) newer_than:{date_min} older_than:{date_max}`.
  - `invoice_by_amount_keyword` — `has:attachment subject:({supplier_name} OR invoice) "{amount}"`.
  - `recurring_supplier_recent` — `has:attachment from:{supplier_domain}` (used for known recurring vendors when the amount might vary slightly).
  - `receipt_by_merchant_short_window` — `has:attachment from:{merchant_email} newer_than:{txn_date - 2d} older_than:{txn_date + 2d}`.
  - Each template carries declared parameter slots and a documented purpose.
- **Email finder service** — `findEmailDocumentsFor(transaction, businessId) → DiscoveredDocument[]`:
  1. Resolve enabled templates for the business (per-business overrides + globals).
  2. For each template, substitute parameters from transaction context (amount, currency, counterparty name, transaction date, supplier-registry domain if known).
  3. Build the Gmail query string and execute via the Gmail API.
  4. Filter results (see below).
  5. For each surviving result, fetch attachments and create `Document` candidates (transitions `null → DISCOVERED` per Phase 02).
- **Spam + allowlist filtering** (Stage 1):
  - Skip emails carrying Gmail labels `SPAM` or `TRASH`.
  - **Allowlist gate** — for emails not from a `business_sender_allowlist` entry AND not from a sender already in the platform's known-supplier registry: skip with `EMAIL_FINDER_RESULT_REJECTED_NOT_ALLOWLISTED` audit event.
  - Allowlist matching honours both `EMAIL_DOMAIN` (e.g., `google.com`) and `EMAIL_ADDRESS` (e.g., `billing@example.com`); domain match is case-insensitive, address match is case-insensitive on the local part too.
- **Idempotent discovery:**
  - For each candidate Gmail message, compute `source_external_id = "gmail:{message_id}"`. Check `document_source_links` — if already present for the business, skip without re-fetching attachments.
  - When a new attachment is discovered, create a `Document` row and a `document_source_links` row in the same transaction.
- **Attachment handling:**
  - One Gmail message can produce multiple `Document` candidates (one per attachment).
  - Each attachment is converted (per Phase 03) and OCR'd (Phase 03) and field-extracted (Phase 04).
  - Attachment file types not supported by Phase 03 produce a `DOCUMENT_FORMAT_UNSUPPORTED` review issue.
- **Confidence at discovery time:**
  - Each `DiscoveredDocument` carries a `discovery_confidence` based on how strongly the email matched the transaction (amount-exact match, supplier domain match, recurring vendor, date proximity).
  - This confidence is consumed by Block 10's matching engine to break ties.
- **Rate limiting:**
  - Gmail API quota awareness — exponential backoff on 429s; the calls map to `MODEL_ERROR transient: true` per Block 03 Phase 08's retry policy when the quota is briefly exhausted.
- **Audit events:** `EMAIL_FINDER_QUERY_EXECUTED` (with template id and parameters — never the resolved query string if it contains sensitive data), `EMAIL_FINDER_RESULT_FOUND`, `EMAIL_FINDER_RESULT_REJECTED_SPAM`, `EMAIL_FINDER_RESULT_REJECTED_NOT_ALLOWLISTED`, `EMAIL_FINDER_RESULT_DUPLICATE_SOURCE` (already discovered).

## Definition of Done

- A transaction with a known supplier-domain match produces email candidates from a representative test inbox; the candidates flow to the document lifecycle.
- Spam-labelled emails are skipped with the right audit event.
- A non-allowlisted email from an unknown sender is skipped; the same email from a sender in the allowlist proceeds.
- Re-running the finder for the same transaction does not re-discover already-known Gmail messages (idempotency verified).
- Rate-limit responses retry with backoff per Block 03 Phase 08.
- The discovery_confidence on each candidate reflects the strength of the match.
- Tests cover: each query template happy path, spam filter, allowlist filter, idempotent re-run, attachment-with-unsupported-format.

## Sub-doc Hooks (Stage 4)

- **Default query template library sub-doc** — exact templates with parameter substitution rules, evolution policy.
- **Allowlist precedence sub-doc** — interaction between `business_sender_allowlist` and the platform's known-supplier registry (Block 08 Phase 02 forward note).
- **Rate-limit handling sub-doc** — Gmail API quota model, backoff curves, alerts when rate-limited persistently.
- **Attachment-depth limit sub-doc** — how many attachments per email are processed; what happens beyond the limit.
- **Discovery confidence rubric sub-doc** — exact weights per signal (amount-exact, supplier-domain, recurring, date-proximity).
