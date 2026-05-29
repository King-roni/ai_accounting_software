# Block 13 — Phase 02: Client Database

## References

- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (Capabilities — Client database; Multi-Currency Invoicing)
- Block doc: `Docs/blocks/11_ledger_and_cyprus_vat_engine.md` (Phase 04 — counterparty resolution; vendor/client registry consumer)
- Block doc: `Docs/blocks/08_transaction_classification_and_tagging.md` (Phase 03 — recurring vendor memory shape; the same registry pattern is reused for clients)

## Phase Goal

Provision the `clients` table and its supporting CRUD surface. Clients carry the per-counterparty defaults the Invoice Generator pulls into new invoices: country, VAT number, billing address, default currency, default payment terms, default reverse-charge applicability. The same registry is the canonical IN-side source for Block 11 Phase 04's counterparty resolution. After this phase, Phase 03 can compose invoices with sensible defaults and the IN-side counterparty resolver has a populated registry.

## Dependencies

- Phase 01 (`invoices.client_id` FK)
- Block 02 Phase 01 (tenancy schema)
- Block 02 Phase 04 (permission matrix — Owner / Admin / Bookkeeper can create / edit clients; Accountant / Reviewer can read; Read-only can read)
- Block 02 Phase 05 (RLS template)
- Block 11 Phase 04 (consumer — counterparty resolver pulls from this registry on the IN side, parallel to how it pulls from `recurring_vendor_memory` on the OUT side)

## Deliverables

- **`clients` table:**
  - `id` (UUID v7), `organization_id`, `business_id`
  - `display_name` (text; required) — the user-visible name shown on invoices.
  - `legal_name` (text; nullable) — the formal entity name when distinct from display name.
  - **Counterparty identification (consumed by Block 11 Phase 04):**
    - `country` (text; ISO-3166 alpha-2; nullable but strongly recommended for VAT classification)
    - `vat_number` (text; nullable; canonicalised per Block 11 Phase 04's rules — country prefix uppercased, internal whitespace stripped)
    - `vat_number_format_valid` (boolean; computed at write time using the same format check as Block 11 Phase 04)
  - **Billing details:**
    - `billing_address_line_1`, `billing_address_line_2`, `billing_city`, `billing_postal_code`, `billing_country` (text; nullable)
    - `billing_email` (text; nullable; used for invoice-send notifications — sub-doc tracks the send mechanism)
  - **Defaults pulled into new invoices:**
    - `default_currency` (text; ISO-4217; required; defaults to the business's bookkeeping currency on first creation — typically EUR for Cyprus businesses)
    - `default_payment_terms_days` (integer; required; default `30`)
    - `default_reverse_charge_applicable` (boolean; default `false` — true for EU B2B clients with valid VAT numbers; auto-suggested when `country` ∈ EU and `vat_number_format_valid = true`, but the user must confirm)
    - `default_vat_treatment` (enum: one of Block 11 Phase 05's eight values; nullable; auto-suggested per `country` + VAT-number presence; user-confirmable; pulled into new invoices but per-line override is allowed at invoice composition time)
  - **Lifecycle / soft-delete:**
    - `disabled_at` (timestamp; nullable) — disabling a client prevents new invoices but preserves existing references.
    - `disabled_by` (FK to `users`; nullable)
  - `created_at`, `created_by`, `updated_at`, `updated_by`
  - **Indexes:** `(business_id, display_name)`, `(business_id, country, vat_number)`, `(business_id, disabled_at)`.
  - **Unique constraint:** `(business_id, vat_number)` where `vat_number IS NOT NULL` — a single business cannot have two clients with the same VAT number; sub-doc tracks edge cases (e.g., a parent company and subsidiary sharing a VAT number — Stage 1 default: split into two clients with distinct names; Stage 2+ may relax).
- **CRUD surface** (Block 02 Phase 11's settings + invoice-creation UI):
  - `client.create(...)`, `client.update(...)`, `client.disable(...)` — Owner / Admin / Bookkeeper only via the `WORKFLOW_TRIGGER`-adjacent permission surface (sub-doc names the canonical surface — e.g., `CLIENT_MANAGE`).
  - `client.get(...)`, `client.list(...)` — readable by Owner / Admin / Bookkeeper / Accountant / Reviewer / Read-only.
- **Auto-suggest helpers** (called from the create / update form; deterministic — no AI):
  - `suggestVatTreatment({ country, vat_number, business_country })` → returns the Block 11 Phase 05 value the rules would pick if the client were the counterparty; the user accepts or overrides. The same logic the OUT-side classifier uses.
  - `suggestReverseChargeApplicable({ country, vat_number_format_valid })` → boolean.
  - `suggestPaymentTerms({ country, business_default })` → integer days.
  - The auto-suggest layer is rules-only — Principle 3.
- **Cross-block contract for Block 11 Phase 04 (durable; requires a coordinated Phase 04 amendment):**
  - Block 11 Phase 04's resolution chain (matched-document → vendor memory → transaction metadata → unresolved) is OUT-side oriented. **For IN-side runs, a new Step 1.5 must be added to Phase 04's chain**: between "matched-document extracted fields" and "vendor memory," resolve via the `clients` registry keyed by `(business_id, normalized_client_name)` and `(business_id, vat_number)`. The cross-block amendment is pinned here:
    - **Helper Phase 02 commits to exposing:** `getClientByName({ business_id, normalized_client_name }) → Client | null` and `getClientByVatNumber({ business_id, vat_number }) → Client | null`.
    - **Confidence mapping:** an exact `display_name` match → `HIGH`; a fuzzy / canonicalized match → `MEDIUM`; a `vat_number`-only match (no name) → `MEDIUM`. The `IBAN`-based fallback is Stage 2+ and not in this phase's scope.
    - **Phase 04 amendment requirement:** Phase 04 of Block 11 must add this IN-side branch ahead of vendor memory. Without the amendment, the IN-side resolver falls through to vendor memory (which is OUT-side). Block 13 phase docs are written against the post-amendment Phase 04; the amendment is enumerated in Block 11 Phase 04's deliverables in a coordinated edit alongside this phase.
    - **OUT-side behavior unchanged:** the new Step 1.5 is conditional on the run type (`IN_MONTHLY` / `IN_ADJUSTMENT`); OUT-side runs skip it.
  - Block 13 Phase 02 is the single source of truth for the helper signatures; Block 11 Phase 04 calls into them.
- **Recurring-client memory write-back:**
  - When Block 11 Phase 04's resolver succeeds via the document path (e.g., a customer name extracted from an inbound payment reference confidently maps to an existing `client`), the helper updates the client's `last_seen_at` (an additional column tracked by sub-doc) for ranking purposes. No automatic creation of new `client` rows from incoming payments — Phase 04 raises a review issue instead.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `CLIENT`):
  - `CLIENT_CREATED`
  - `CLIENT_UPDATED` (with field-level diff)
  - `CLIENT_DISABLED`
  - `CLIENT_VAT_NUMBER_FORMAT_INVALID_DETECTED` (when a write produces a format-invalid VAT number — surfaces as a review issue)

## Definition of Done

- The `clients` table exists with the right columns, FKs, constraints, and indexes; RLS isolates per business.
- A user creates a client; the auto-suggest helpers produce sensible defaults; the user accepts or overrides; the row is persisted.
- Disabling a client preserves existing invoice references (FK valid; `clients.disabled_at` set).
- Block 11 Phase 04's `getClientByName` query returns the right row with the documented confidence mapping (verified once Block 11 sub-docs are written).
- A duplicate VAT number within one business is rejected by the unique constraint.
- A non-Owner / Admin / Bookkeeper attempting to create / update is denied.
- An invalid-format VAT number raises the right review issue.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Auto-suggest rules sub-doc** — exact derivation logic for `suggestVatTreatment` etc.
- **Permission surface sub-doc** — naming and matrix entry for `CLIENT_MANAGE`.
- **Counterparty-resolver contract sub-doc** — the canonical statement of Block 11 Phase 04 ↔ Block 13 Phase 02 lookup.
- **Multi-name-per-client sub-doc (deferred)** — what Stage 2+ would need to handle aliases, name changes.
- **Bulk-import sub-doc** — CSV / contact-list import path (out of MVP scope).
