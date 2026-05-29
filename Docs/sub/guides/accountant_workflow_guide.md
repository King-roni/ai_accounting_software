# Accountant Workflow Guide

**Namespace:** N/A (cross-cutting)  
**Audience:** Accountants using the system day-to-day  
**Status:** Active  
**Last Updated:** 2026-05-17

---

## Overview

This guide walks through the standard monthly accounting workflow and explains how to handle common exceptions. It is written for accountants, not developers. You do not need to understand the technical internals to use this guide.

If something in the system behaves differently from what is described here, contact your system administrator.

---

## Monthly Workflow

Each calendar month follows the same sequence. The system enforces the order — you cannot finalize a period before completing the earlier steps.

### Step 1: Upload Bank Statements

At the start of each month, upload the previous month's bank statements.

- Go to **Bank Feeds** in the sidebar.
- If you have a connected bank account (Nordigen integration), transactions are pulled automatically each day. Check that the feed is current — the last sync date is shown next to each account.
- If your bank is not connected, use **Upload Statement** and select the exported file (CSV or MT940 format). The system accepts Revolut, Alpha Bank Cyprus, and Bank of Cyprus exports.
- After upload, the system runs OCR on any PDF statements and extracts transaction rows automatically. This takes 1–3 minutes for most statements.
- Review the imported rows in **Bank Statement Review**. Mark any rows the system misread as needing correction before proceeding.

### Step 2: Review OCR Results

For uploaded documents (invoices, receipts, expense claims):

- Go to **Documents → Pending Review**.
- Each document shows the OCR-extracted fields: vendor name, date, total amount, VAT amount.
- Confirm fields that are correct. Correct fields that are wrong by clicking the field and typing the correct value.
- If a document is unreadable (e.g., a blurry photo), mark it as **Cannot Process** and keep the original for your records.

OCR accuracy is generally high for typed invoices in English, Greek, or Dutch. Handwritten receipts are not supported — enter these manually.

### Step 3: Review Classification

The system automatically suggests a ledger account category for each transaction and document.

- Go to **Classification → Review Queue**.
- Each item shows the suggested category, the confidence score, and the AI's reasoning.
- Items with a confidence score above 85% are pre-approved and shown in grey — you can spot-check these but they do not require your action.
- Items with a confidence score below 85% are highlighted and require your explicit approval or correction.
- To reclassify an item: click the category field and select the correct account from the chart of accounts. The system remembers vendor-level corrections and applies them to future transactions from the same vendor automatically.

### Step 4: Match Payments

Payment matching links bank transactions to invoices and expenses.

- Go to **Matching → Unmatched**.
- The system proposes matches automatically. A green badge means high confidence; an orange badge means you should review before accepting.
- Accept a match by clicking **Confirm**. Reject a match by clicking **Not a Match** — the system will not suggest the same pair again.
- For payments that have no matching invoice (e.g., an ad-hoc bank fee), select **No Invoice — Classify as Expense** and assign a category.
- Payments that cannot be identified after 3 matching attempts are sent to the **Exceptions** queue (see Handling Exceptions below).

### Step 5: Finalize Period

Once all transactions are matched and the review queue is clear:

- Go to **Periods → [Month Name]**.
- The system shows a preflight checklist. All items must show a green tick before you can finalize:
  - [ ] All bank statement rows matched or explicitly disposed of
  - [ ] Review queue empty (no outstanding items)
  - [ ] No open exceptions requiring escalation
  - [ ] Ledger balance check passed
- Click **Finalize Period**. If step-up authentication is enabled for your account, you will be prompted to confirm with your second factor.
- Once finalized, the period is locked. No changes can be made without an admin unlocking it.

### Step 6: Generate VAT Return

After finalization, generate the VAT return for the period.

- Go to **Reports → VAT Return**.
- Select the finalized period.
- Review the figures. The VAT return pulls from the finalized ledger entries — you cannot edit it directly. If a figure is wrong, you must unlock the period (admin action), correct the source data, and re-finalize.
- Click **Export to XML** to download the file for submission to the Cyprus Tax Department portal. There is no direct API to the Tax Department — submission is manual.

---

## Handling Common Exceptions

### Duplicate Detected

The system has flagged a transaction or document as a potential duplicate of an existing record.

- Open the duplicate alert from the Review Queue.
- The alert shows both the original record and the suspected duplicate side by side.
- If they are genuinely the same transaction: click **Confirm Duplicate — Discard New**.
- If they are different transactions that happen to look similar: click **Not a Duplicate — Keep Both** and add a note explaining why.

Duplicate detection uses amount, date, and counterparty. Small amounts (under €5) are not checked for duplicates.

### Unmatched Payment

A bank transaction has no matching invoice after the automatic matching pass.

- Check whether an invoice exists but has a slightly different amount (e.g., a rounding difference or partial payment).
- If a partial payment: use **Split Match** to allocate the payment across two invoices or to mark it as a partial payment on one invoice.
- If no invoice exists: check with the business owner whether an invoice was issued. If not, categorise as an unmatched expense with an appropriate ledger account.
- If the payment origin is genuinely unknown: escalate to admin (see Escalation below).

### Classification Dispute

The AI has classified a transaction in a way you believe is wrong, but you are uncertain which account is correct.

- Mark the item as **Disputed** in the Review Queue. This holds it without blocking finalization (disputed items are excluded from the finalization preflight for up to 7 days).
- Attach a note with your question.
- The system will prompt you to resolve the dispute before the 7-day hold expires. If unresolved, it escalates automatically to admin.

---

## Reading the Review Queue

The review queue is your daily work list. Items are sorted by priority:

- **Blocking** — must be resolved before period finalization. Shown in red.
- **High** — significant confidence issue or a compliance-relevant classification. Shown in orange.
- **Medium** — lower-confidence classification or a match that needs a second look. Shown in yellow.
- **Low** — informational, no action required. Shown in grey.

Use filters to focus on a specific period, document type, or issue type. The **Assigned to Me** filter shows only items that have been explicitly routed to your user account.

Bulk actions are available for Low and Medium items: you can approve multiple items at once if you have reviewed them individually.

---

## When to Escalate to Admin

Escalate to your system administrator when:

- A period needs to be unlocked after finalization (e.g., to correct an error).
- An unmatched payment with an unknown origin appears and cannot be resolved after investigation.
- A VAT return figure appears incorrect and you need to identify the source transaction.
- You need to export audit log data for a legal or tax authority request.
- A bank feed connection is broken and standard reconnection steps have not resolved it.

To escalate, use the **Escalate to Admin** button on any Review Queue item, or send a message directly through the in-app notification system.

---

## Related Documents

- `guides/cyprus_vat_compliance_guide.md` — VAT rules specific to Cyprus
- `policies/review_queue_policy.md` — How items enter and leave the review queue
- `policies/matching_policy.md` — Matching confidence thresholds and rules
- `policies/period_lock_policy.md` — What happens when a period is locked
- `policies/deduplication_policy.md` — How duplicate detection works
- `reference/permission_matrix.md` — What actions require admin role
