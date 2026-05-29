# invoice_pdf_policies

**Category:** Policies · **Owning block:** 13 — IN Workflow + Invoice Generator · **Co-owner:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 1 cross-block policy)

Two sub-policies bound together: deterministic invoice PDF rendering, and retention of superseded invoice PDF renders. Per the Layer 0 compression merge of `pdf_renderer_determinism_policy` + `superseded_pdf_render_retention_policy`.

Invoice PDFs are user-facing legal documents — once sent to a client, the bytes must be reproducible for audit and immutable from the renderer's perspective. The same input always renders to the same bytes.

---

## Section 1 — Renderer determinism

Same `invoice_id` + same `lifecycle_state` → byte-identical PDF.

### Determinism mechanism

| Component | Pinning method |
| --- | --- |
| Fonts | Inter / Inter Display / JetBrains Mono SHA-pinned per `pdf_font_pinning_policy` (now part of `pdf_generation_policies` cluster) |
| Layout library | Version-pinned in `csv_xlsx_pdf_library_integration` |
| Layout templates | Versioned per Block 13 Phase 04; the invoice's `pdf_template_version` column pins which version it was rendered with |
| Timestamps in PDF metadata | Zeroed (no `now()` in metadata fields; only the invoice's declared issue date appears in the body) |
| Compression / encoding | Deterministic per the PDF library settings (PDF/A-2a per `pdf_generation_policies`) |

### Reproducibility test

Per Block 13 Phase 12's end-to-end tests: each invoice's PDF is rendered twice and bytes are compared. Any drift fails CI.

Per `pdf_determinism_fixtures` (Layer 2, Block 16): the test corpus includes invoices with:

- Single-line and multi-line content
- Domestic / EU-reverse-charge / non-EU-service VAT treatments
- Multi-currency invoices (currency locked at creation per Stage 1)
- Different Cyprus customer types (B2C / B2B / EU B2B)

### Sign + send vs draft

A draft invoice's PDF is regeneratable — drafts aren't legally binding, so non-deterministic edits to layout templates are acceptable.

A sent invoice's PDF is the legal source of record:

1. At first `SENT` transition: PDF is rendered + stored in `invoice_pdf_renders` table + Object-Lock the bytes
2. Subsequent reads return the stored bytes — never re-render
3. Per Block 13 Phase 04's `INVOICE_PDF_RENDERED` audit event: captures the renderer version, template version, font SHAs

If the layout template needs updating (e.g., a new tax regulation requires new disclosures), new invoices use the new template. Old invoices retain their old template. A backfill render is NOT performed — old invoices remain on their original template.

## Section 2 — Superseded PDF retention

When a sent invoice's PDF needs to be replaced (rare — typo correction before client sees it, or template-mandated re-render under regulator instruction):

### Retention rules

- The superseded PDF is RETAINED, not deleted
- A new PDF is rendered + stored as a new `invoice_pdf_renders` row
- The old PDF row's `superseded_at` column is set
- `superseded_by_render_id` points at the new render

```sql
CREATE TABLE invoice_pdf_renders (
  id                      uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  invoice_id              uuid NOT NULL REFERENCES invoices(id),
  pdf_object_uri          text NOT NULL,
  pdf_hash                text NOT NULL,
  template_version        text NOT NULL,
  font_bundle_sha         text NOT NULL,
  rendered_at             timestamptz NOT NULL DEFAULT now(),

  -- Supersession
  superseded_at           timestamptz,
  superseded_by_render_id uuid REFERENCES invoice_pdf_renders(id),
  superseded_reason       text
);
```

### Audit trail

Each supersession emits:

```ts
emitAudit("INVOICE_PDF_SUPERSEDED", {
  invoice_id,
  old_render_id,
  new_render_id,
  superseded_at,
  superseded_reason,
  actor_user_id,
  actor_role
});
```

Per `audit_log_policies`: the actor and reason are recorded so future investigations can reconstruct why a superseded render exists.

### Retention period

Superseded PDFs are retained for the same retention window as the parent invoice — typically 6 years per Cyprus VAT books retention. Per `retention_policies_schema`:

- A superseded PDF older than 6 years from `rendered_at` AND with the parent invoice expired is eligible for deletion
- Legal hold per `legal_hold_policies` defers deletion

### Cleanup

Per `retention_policies_schema`'s background scan: eligible-for-deletion superseded PDFs are removed monthly. The audit log entry recording the supersession is retained per audit-log retention rules — separate from the PDF bytes themselves.

### Audit visibility

Per `permission_matrix`: Owner / Admin / Accountant can view superseded PDFs alongside the current PDF in the invoice detail view. The UI surfaces the chain:

```
Current PDF (v2)            [View] [Download]
  ↑ superseded 2026-04-15
Superseded PDF (v1)         [View] [Download]
  rendered 2026-04-10
```

Bookkeeper has `REVIEW_QUEUE_VIEW` access to invoice basics but the superseded-PDF history is gated to Owner / Admin / Accountant per the invoice-history `REVIEW_QUEUE_RESOLVE`-tier surface.

## Cross-block contract

Block 13 owns invoice PDFs end-to-end. Block 16's invoice export pipeline reads the most-recent non-superseded render for the "current" view. Block 16's accountant pack pulls both current and superseded renders if the export's audit-trail option is enabled.

## PDF re-render edge cases

When an invoice is amended after its first PDF has been generated (e.g., a line-item correction before the invoice is sent, or a regulatory-mandated template update for a DRAFT invoice), the following rules apply:

- **DRAFT invoice amended:** A new PDF is re-rendered on the next read or on explicit regeneration. Because the invoice has not been sent, the prior render has no legal standing and is overwritten in-place (no supersession row created — supersession only applies to SENT invoices).
- **SENT invoice amended (rare):** A sent invoice may only be amended under specific operational circumstances (see Block 13 Phase 06 for credit note and write-off paths). If amendment is authorized, a new `invoice_pdf_renders` row is created, the old row is marked `superseded_at`, and `INVOICE_PDF_SUPERSEDED` is emitted. The `superseded_reason` must be populated; an empty reason is rejected.
- **Template-version change while invoice is DRAFT:** If the template version is incremented and a DRAFT invoice has a cached PDF from the old template version, the next render uses the new template. The old bytes are not retained (DRAFT status — no supersession).

## Cross-references

- `pdf_generation_policies` (consolidated) — font pinning + PDF/A-2a
- `csv_xlsx_pdf_library_integration` — version pinning
- `archive_bundle_policies` — same determinism principles
- `invoice_pdf_schema` — `invoice_pdf_renders` table definition; `superseded_at`, `superseded_by_render_id`, `superseded_reason` columns
- `retention_policies_schema` — retention engine
- `legal_hold_policies` — hold-driven deletion deferral
- `permission_matrix` — superseded-PDF visibility
- `audit_log_policies` — `INVOICE_PDF_*` events
- `pdf_determinism_fixtures` (Block 16) — CI test corpus
- Block 13 Phase 04 — PDF rendering & VAT-aware text
- Block 13 Phase 06 — pro-forma conversion, credit notes & write-off (consumer)
- Block 16 Phase 09 — export pipelines
