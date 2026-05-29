# Known Limitations

**Namespace:** N/A (cross-cutting)  
**Status:** Active  
**Last Updated:** 2026-05-17

---

## Overview

This document lists known limitations and constraints of the current system. Each entry describes the limitation, any available workaround, and the planned resolution timeframe where one exists.

Limitations are grouped by area. An entry marked **No planned resolution** means the limitation is accepted for the foreseeable future, either because a fix is out of scope or because upstream dependencies do not support it.

---

## AI Classification

### 1. EUR-denominated invoices only for AI classification

**Description:** The AI classification pipeline assumes amounts are in EUR. Documents with amounts in other currencies are parsed but the extracted amount is treated as EUR, which produces incorrect ledger entries.

**Workaround:** Before uploading non-EUR documents, manually note the EUR-converted amount. After OCR, correct the extracted amount field in the review step before confirming classification.

**Planned resolution:** Multi-currency classification support is tracked for v0.7. The OCR extraction model will be updated to detect and flag the currency, and the classification pipeline will apply the relevant ECB exchange rate before mapping to ledger accounts.

---

### 2. Handwritten receipts are not supported

**Description:** The OCR engine does not reliably extract fields from handwritten or partially handwritten receipts. Confidence scores are typically below 30%, causing all such documents to land in the review queue with no usable pre-filled fields.

**Workaround:** Enter handwritten receipts manually using the **New Manual Entry** form rather than uploading as a document. Attach a photo of the receipt as a supporting attachment.

**Planned resolution:** Handwriting support requires a dedicated OCR model variant. This is under evaluation but has no committed timeline.

---

### 3. AI classification is unavailable for documents with more than 50 pages

**Description:** The OCR engine enforces a 50-page limit per document. Documents exceeding this limit are rejected at intake with error code `OCR_PAGE_LIMIT_EXCEEDED`.

**Workaround:** Split large documents into chunks of 50 pages or fewer before uploading. Most bank statements and supplier invoices are well under this limit.

**Planned resolution:** Page limit increase to 200 pages planned for v0.8 pending OCR provider capacity upgrade.

---

### 4. Classification confidence is lower for Greek-language invoices

**Description:** The LLM used for classification was primarily trained on English and Dutch financial documents. Greek-language invoices produce confidence scores approximately 15–20 points lower on average, leading to more items entering the review queue.

**Workaround:** After the first few corrections for a given vendor, vendor memory applies the corrections automatically and confidence improves for subsequent documents from the same vendor.

**Planned resolution:** Fine-tuning on a Greek invoice dataset is planned for H2 2026.

---

## Bank Feeds

### 5. Nordigen integration covers Cyprus banks only

**Description:** The current Nordigen bank feed adapter supports Bank of Cyprus, Alpha Bank Cyprus, and Revolut Cyprus accounts. Banks in other EU countries are not supported even though Nordigen technically provides access.

**Workaround:** For non-Cyprus bank accounts, use the manual CSV or MT940 upload option. Revolut EU (non-Cyprus entity) exports are accepted via the `CSV_REVOLUT` format.

**Planned resolution:** Multi-country bank feed support is planned for v0.7 starting with Greece (Eurobank, Piraeus Bank) and the Netherlands (ING, Rabobank).

---

### 6. Bank feed re-authentication is required every 90 days

**Description:** Nordigen Open Banking consents expire after 90 days by regulation. When a consent expires, the bank feed stops syncing and the accountant must reconnect the account by re-authorising through the Nordigen flow.

**Workaround:** The system sends an email reminder 7 days before consent expiry. Reconnect via **Bank Feeds → Reconnect** before expiry to avoid a gap in transaction history.

**Planned resolution:** Automatic consent renewal notifications are in place. Fully automated re-consent is not possible under PSD2 — the accountant must re-authorise manually. This is a regulatory constraint with no planned change.

---

## VIES Integration

### 7. VIES submission is manual — no direct API to Cyprus Tax Department

**Description:** The system generates a VIES-compliant XML file for the quarterly VIES submission, but submission to the Cyprus Tax Department TaxisNet portal is manual. There is no machine-to-machine API available.

**Workaround:** Download the XML from **Reports → VIES Submission**, then upload it to TaxisNet manually. Record the submission reference number in the system using **Log Submission Reference**.

**Planned resolution:** The Cyprus Tax Department has announced API access for certified software providers. Integration is planned once the API is available (estimated H1 2027 based on published roadmap).

---

### 8. VIES validation is unavailable during EU VIES service downtime

**Description:** The VIES service operated by the European Commission experiences periodic downtime, typically for maintenance. During downtime, VAT number validation requests fail and the system falls back to an unvalidated state with a warning in the review queue.

**Workaround:** Re-trigger validation after downtime ends using **Counterparties → Re-validate**. The VIES staleness policy will also re-trigger validation automatically on the next sync cycle.

**Planned resolution:** No change planned. This is an upstream dependency constraint.

---

## Multi-Currency

### 9. EUR is the primary ledger currency; FX conversion is read-only

**Description:** All ledger entries are stored in EUR. Foreign currency transactions are converted to EUR using the ECB daily rate at the time of the transaction. The original currency amount is stored as metadata but does not affect ledger balances. There is no support for maintaining sub-ledgers in a foreign currency.

**Workaround:** For businesses with significant non-EUR transactions, exported reports include both the original currency amount and the EUR-converted amount. Manual FX reconciliation is required outside the system.

**Planned resolution:** A functional currency setting per business entity is planned for v1.0, enabling ledgers to be maintained in a non-EUR currency where applicable.

---

## Mobile

### 10. Write operations are disabled on mobile

**Description:** The mobile web interface (viewport width below 768px) blocks all write operations: document upload, classification approval, matching confirmation, period finalization. Read operations (view statements, reports, audit log) are available.

**Workaround:** Use a desktop or tablet browser for any operation that modifies data.

**Planned resolution:** A mobile-first write interface for document upload and review queue approval is planned for v0.8. Finalization and period-lock actions will remain desktop-only for the foreseeable future.

---

## Archive

### 11. No S3-compatible export for archive bundles

**Description:** Archive bundles are stored in Supabase Storage and can be downloaded as individual ZIP files via the UI. There is no bulk export to an S3-compatible bucket or other external storage destination.

**Workaround:** Download bundles individually from **Archive → [Period] → Download Bundle**. For compliance purposes, the downloaded ZIPs are self-contained and include the hash-chain verification file.

**Planned resolution:** An S3-compatible export target for bulk archive transfers is planned for v0.9.

---

## Performance

### 12. OCR throughput is limited to 50 pages per document

**Description:** See Limitation 3 above. The per-document page limit also acts as a throughput constraint: a 50-page document occupies the OCR queue slot for approximately 45–90 seconds.

**Workaround:** Upload large statements as multiple smaller files.

**Planned resolution:** See Limitation 3.

---

### 13. Bulk classification endpoint is limited to 50 items per request

**Description:** The `POST /api/classification/bulk` endpoint accepts a maximum of 50 items per call. Requests exceeding this limit return `422 BULK_SIZE_EXCEEDED`.

**Workaround:** Split large classification batches into multiple calls. The TypeScript SDK client handles this automatically via chunking.

**Planned resolution:** Limit increase to 200 items per request planned for v0.7 after queue infrastructure is upgraded.

---

## Reporting

### 14. VAT return cannot be submitted directly — manual portal upload required

**Description:** The generated VAT return XML must be uploaded manually to the Cyprus Tax Department portal. This limitation is shared with the VIES workflow (see Limitation 7).

**Workaround:** Download the XML from **Reports → VAT Return → Export** and upload to the TaxisNet portal. The submission reference should be recorded in **Reports → VAT Return → Log Submission**.

**Planned resolution:** Awaiting API access from the Cyprus Tax Department (see Limitation 7).

---

### 15. Report generation does not support custom date ranges shorter than one calendar month

**Description:** All built-in report templates (VAT return, profit/loss summary, ledger trial balance) are period-bound. Generating a report for an arbitrary date range (e.g., two weeks or a rolling 90 days) is not supported.

**Workaround:** Export the underlying ledger entries as CSV and filter by date in a spreadsheet application.

**Planned resolution:** Custom date range reports are planned for v0.9 as part of a general reporting engine upgrade.

---

## Related Documents

- `reference/changelog.md` — Version history including features that resolved earlier limitations
- `reference/error_code_catalog.md` — Error codes referenced in limitation descriptions
- `guides/accountant_workflow_guide.md` — Workarounds for common operational constraints
- `reference/mobile_write_rejection_endpoints.md` — Full list of endpoints blocked on mobile viewports
