# Block 13 — Phase 04: PDF Rendering & VAT-Aware Text

## References

- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (Capabilities — VAT-aware rendering; PDF rendering; pro-forma vs tax invoice distinction)
- Block doc: `Docs/blocks/01_core_principles.md` (Principle 2 — structured first, PDF second; PDF is generated, never re-parsed)
- Block doc: `Docs/blocks/04_data_architecture.md` (Phase 05 — Raw Upload zone; PDF storage)
- Block doc: `Docs/blocks/11_ledger_and_cyprus_vat_engine.md` (Phase 05 — VAT treatments; Phase 06 — reverse-charge text)

## Phase Goal

Render the human-facing PDF for every invoice and credit note from the structured record. Cyprus-friendly default layout, VAT-treatment-aware text (the legally-required reverse-charge disclosure on EU B2B invoices, etc.), pro-forma watermark, multi-language readiness (Stage 1 ships English; sub-doc tracks Greek). The PDF is a deterministic projection of the structured invoice — Principle 2 forbids ever re-parsing the PDF back to structured data; the structured row is always the source of truth.

## Dependencies

- Phase 01 (`invoices`, `invoice_lines`, `credit_notes`)
- Phase 02 (`clients` — pulled into the rendered "Bill To" block)
- Phase 03 (lifecycle — only invoices in `SENT` or later have a "rendered" PDF; `DRAFT` previews are allowed but flagged as drafts)
- Block 04 Phase 05 (Raw Upload zone — PDF storage)
- Block 05 Phase 02 (audit log)
- Block 11 Phase 05 / Phase 06 (the VAT-treatment values and reverse-charge applicability the rendered text mirrors)

## Deliverables

- **PDF rendering pipeline** — `invoice.renderPdf({ invoice_id, render_kind: 'DRAFT_PREVIEW' | 'FINAL' }) → { pdf_storage_object_id }`:
  - **Deterministic** — same structured input always renders the same PDF byte-for-byte (Stage 1 default; sub-doc tracks anti-determinism levers like fonts that may need pinning).
  - **`DRAFT_PREVIEW`** — invoice is in `DRAFT` lifecycle status; the PDF shows a `DRAFT — NOT FOR DISTRIBUTION` watermark; not stored in Raw Upload (returned as a stream the user previews and discards).
  - **`FINAL`** — invoice has transitioned out of `DRAFT` (`SENT` or later); PDF stored in Raw Upload zone; `invoices.pdf_storage_object_id` and `pdf_rendered_at` populated.
  - **Re-render after edit:** for invoices still in `DRAFT`, re-rendering simply produces a new preview. For non-`DRAFT` invoices, composition is locked (Phase 03), so the rendered PDF doesn't change.
- **Layout sections** (Cyprus-friendly default; sub-doc owns the exact templates):
  - **Header:** business name, address, VAT number; logo (sub-doc tracks the per-business logo upload path).
  - **Invoice metadata:** `INVOICE` / `PRO-FORMA INVOICE` / `CREDIT NOTE` heading; `invoice_number` (or `credit_note_number`); `issue_date`; `supply_date` (when distinct from issue date); `due_date`.
  - **Bill-to block:** `clients.legal_name OR display_name`, billing address, VAT number (when present).
  - **Line items table:** `line_number`, `description`, `quantity`, `unit_price`, `subtotal_amount`. When `vat_treatment_per_line = true`, additional columns for per-line `vat_rate_pct` and `vat_amount`.
  - **Totals block:** `subtotal_amount`, `vat_amount` (broken down by rate when mixed-rate), `total_amount`, currency.
  - **Payment terms:** computed from `due_date - issue_date`; payment methods and the business's bank account details (sub-doc tracks the per-business bank-detail block).
  - **VAT-aware text block (legally significant):** rendered conditionally per `vat_treatment` (see "VAT-aware text" below).
  - **Pro-forma watermark:** when `invoice_type = PRO_FORMA`, the PDF carries a watermark `PRO-FORMA — NOT A TAX INVOICE` and a footer note: `This document is a pro-forma invoice and does not constitute a tax invoice. A tax invoice will be issued upon payment.` (Stage 1 default text; sub-doc owns the canonical wording.)
- **VAT-aware text rules** (Stage 1 ships English; sub-doc owns canonical wording per language):

  | `vat_treatment` | Required text on the PDF |
  | --- | --- |
  | `DOMESTIC_CYPRUS_VAT` | Standard VAT line; nothing extra. |
  | `EU_REVERSE_CHARGE` (IN-side, supplier issues) | `Reverse charge — Article 196 of Council Directive 2006/112/EC. The customer is liable for VAT.` Plus the customer's VAT number prominently. |
  | `NON_EU_SERVICE` (export of services) | `Outside the scope of Cyprus VAT — supply of services to a non-EU customer.` |
  | `EXEMPT` | `VAT exempt — [category reference, e.g., Article XX].` (sub-doc owns the per-category text.) |
  | `NO_VAT` | No VAT line; a brief note `No VAT charged.` |
  | `OUTSIDE_SCOPE` | `Outside the scope of Cyprus VAT.` |
  | `IMPORT_OR_ACQUISITION` | The renderer **rejects** with `INVOICE_PDF_RENDER_REJECTED_INAPPLICABLE_VAT_TREATMENT` — this treatment is OUT-side only (acquisition reverse-charge accounting); it has no legitimate use on issued invoices. Phase 03's composition API also rejects `IMPORT_OR_ACQUISITION` at write time on `default_vat_treatment` and `invoice_lines.vat_treatment` (cross-block invariant). |
  | `UNKNOWN` | The renderer **rejects** with `INVOICE_PDF_RENDER_REJECTED_UNKNOWN_VAT_TREATMENT` — invoices with `UNKNOWN` treatment cannot be rendered as `FINAL`. The user must resolve the treatment first.
- **Mixed-rate VAT handling:**
  - When `vat_treatment_per_line = true`, the totals block shows a per-rate breakdown (e.g., `VAT 19%: EUR 12.34` + `VAT 9%: EUR 5.67`).
  - When the invoice has lines under different `vat_treatment` values (e.g., one line domestic, another reverse-charge), each line's required text appears in a per-line note column or the VAT-aware text block lists all applicable disclosures. Sub-doc owns the exact rendering choice.
- **Storage of rendered PDF** (cross-block contract with Block 04 Phase 05):
  - On `FINAL` render, the PDF bytes are written to the Raw Upload zone with content-addressable storage; the storage object id is returned and persisted on `invoices.pdf_storage_object_id`.
  - The PDF is **not stored in the Processing zone**; it is the canonical artefact.
  - **Re-render produces a new storage object** (sub-doc tracks the retention of superseded renders — Stage 1 default: superseded renders are kept until the period finalizes, then garbage-collected).
- **Send mechanism (out of MVP scope; this phase commits the contract):**
  - The PDF is the deliverable. Stage 1 does NOT auto-email the PDF — the user downloads it from the dashboard and sends manually. Sub-doc tracks the future `invoice.send_email` integration.
- **Multi-language readiness:**
  - The renderer accepts a `language_code` parameter (default `'en'`). All static strings (headings, VAT-text disclosures, etc.) are sourced from a translations table keyed by `language_code`. Stage 1 ships only `en`; Greek (`el`) is a Stage 2+ addition; sub-doc tracks Greek-text rendering, font support, and Cyprus-bilingual-document conventions.
- **Idempotency:**
  - Re-calling `renderPdf` on an unchanged invoice returns the existing `pdf_storage_object_id` without producing a new storage object (sub-doc tracks the equality check — Stage 1 default: hash the structured invoice + the language code + the renderer version; equal hash → reuse).
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `INVOICE` or `CREDIT_NOTE`):
  - `INVOICE_PDF_RENDERED` (with `render_kind`, `language_code`, `renderer_version`, `pdf_storage_object_id`)
  - `INVOICE_PDF_RENDER_REJECTED_UNKNOWN_VAT_TREATMENT`
  - `INVOICE_PDF_RENDER_REJECTED_INAPPLICABLE_VAT_TREATMENT` (e.g., `IMPORT_OR_ACQUISITION` on an issued invoice)
  - `INVOICE_PDF_RENDER_REJECTED_NO_LINES` (cannot render an invoice with zero `invoice_lines` rows)
  - `CREDIT_NOTE_PDF_RENDERED`

## Definition of Done

- A `DRAFT` invoice renders a preview PDF with the watermark; not stored.
- A `SENT` tax invoice renders a final PDF and the storage object id is persisted.
- A pro-forma invoice renders with the pro-forma watermark and footer text.
- Each VAT treatment renders the right disclosure text exactly per the table above.
- An invoice with `vat_treatment = UNKNOWN` is rejected with the right audit event.
- A mixed-rate invoice renders the per-rate breakdown.
- Re-rendering an unchanged invoice reuses the stored PDF (idempotency).
- Re-rendering after a `DRAFT` line edit produces a new preview.
- Tests cover: each VAT treatment's text; pro-forma watermark; multi-rate breakdown; rejection paths; the structured-first invariant (no parser code anywhere reads PDFs back to structured data — verified by repository audit).

## Sub-doc Hooks (Stage 4)

- **PDF template sub-doc** — exact layout, fonts, spacing, brand color tokens.
- **VAT-aware text canonical wording sub-doc** — per-treatment, per-language exact strings; Cyprus legal references.
- **Per-business header sub-doc** — logo upload, address customization, bank-detail block.
- **Multi-language sub-doc (Greek deferred)** — translation table, font support, bilingual rendering.
- **Renderer determinism sub-doc** — font pinning, library version pin, reproducibility tests.
- **Superseded-render retention sub-doc** — garbage collection rules, audit trail of historical renders.
