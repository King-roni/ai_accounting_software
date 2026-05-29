# Cyprus Bookkeeping Software — Core Concept Plan

## 1. Product Vision

This software is a private, AI-assisted bookkeeping and document-matching platform built for multiple businesses operated from Cyprus. The product is designed to simplify monthly bookkeeping by importing bank statements, structuring every transaction, matching invoices and supporting documents, checking for inconsistencies, and finalizing each period into a highly secured archive.

The software should feel simple for the user, but the backend must be highly structured, secure, auditable, and compliant with Cyprus bookkeeping, VAT, and record-keeping requirements.

The core principle is:

> The workflow is the product.

The software is not just a dashboard, not just an invoice manager, and not just an AI tool. It is a workflow engine that moves bookkeeping data through a clear sequence of phases. Each phase can call specialized tools, agents, validators, and human review steps.

The AI supports the bookkeeping workflow by extracting, tagging, matching, classifying, checking, and explaining. The AI does not replace the accounting system of record. Final accounting data must be deterministic, auditable, and approved before being locked.

---

## 2. Core Goals

The software must achieve the following goals:

1. Import monthly bank statements, mainly from Revolut, in CSV or PDF format.
2. Convert every bank statement row into a structured transaction record.
3. Generate a clean PDF evidence page for every transaction, while keeping structured data as the true source of truth.
4. Automatically tag and classify transactions.
5. Separate outgoing expenses, incoming income, internal transfers, FX movements, refunds, bank fees, and unknown transactions.
6. Match outgoing transactions to invoices or receipts found in connected email accounts.
7. Match remaining outgoing transactions to invoices or receipts found in Google Drive folders.
8. Allow manual upload of missing invoices, contracts, or supporting documents.
9. Match incoming payments to invoices created inside the software.
10. Run an AI-assisted end-scan to detect inconsistencies, missing documents, VAT risks, contract requirements, duplicate documents, and other review items.
11. Present all issues in a simple, clean, easy-to-understand review queue.
12. Allow the user to resolve issues manually.
13. Finalize the monthly run only when required documents, classifications, and confirmations are complete.
14. Move finalized accounting data into a highly secured archive area.
15. Update dashboards, reports, VAT summaries, VIES-related exports, and accountant-ready outputs.
16. Protect sensitive financial data with strong security, tenant isolation, encryption, PII routing, and strict LLM controls.

---

## 3. Non-Negotiable Design Principles

### 3.1 Workflow-First Architecture

The bookkeeping workflow is the core of the application. Everything else is a tool, module, or sub-agent called by the workflow.

The system should not be designed as a collection of disconnected features. It should be designed as a controlled pipeline:

```text
Input
→ Parsing
→ Structuring
→ Classification
→ Evidence Matching
→ Ledger Preparation
→ AI Review
→ Human Review
→ Finalization
→ Secure Archive
→ Reports
```

Each workflow phase must have clear inputs, outputs, validation rules, and audit logging.

### 3.2 Structured Data Is the Source of Truth

Uploaded bank statements, generated PDFs, invoices, receipts, and contracts are evidence documents. They are important, but they are not the primary data model.

The true source of truth is the structured transaction and ledger data stored in the database.

PDF transaction pages should be generated from structured data. They should not become the main object the system relies on.

### 3.3 AI Assists, Rules Decide, User Finalizes

The AI can suggest, classify, explain, extract, match, and flag.

The AI should not silently finalize accounting decisions.

Finalization must only happen after:

```text
required evidence exists
required validations pass
blocking alerts are resolved
user approval is recorded
audit logs are written
period is locked
```

### 3.4 Security by Design

The software handles sensitive financial data, including bank statements, invoices, names, addresses, email content, VAT numbers, IBANs, contracts, and business records.

Security must be designed from the beginning, not added later.

### 3.5 Simple Interface, Advanced Backend

The user interface must stay simple. The system may detect many types of issues, classifications, and risks, but the user should see them grouped clearly.

The review experience should not overwhelm the user with technical accounting language unless necessary.

---

## 4. High-Level System Overview

The platform consists of the following main blocks:

```text
1. Organization & Business Entity Management
2. User, Role & Access Management
3. Bank Statement Import Engine
4. Transaction Parser & Normalizer
5. Transaction PDF Evidence Generator
6. Transaction Type Classifier
7. Tagging & Category Engine
8. Email Invoice Finder
9. Google Drive Invoice Finder
10. Manual Document Upload System
11. Document OCR & Extraction Engine
12. Matching Engine
13. Ledger Preparation Layer
14. Cyprus VAT & Tax Classification Layer
15. AI Privacy Gateway
16. AI Review / End-Scan Engine
17. Human Review Queue
18. Finalization Engine
19. Secure Archive
20. Dashboard & Reporting Layer
21. Invoice Generator
22. Income Matching Workflow
23. Audit Logging System
24. Security & Compliance Layer
```

---

## 5. Multi-Business Structure

The software must support multiple businesses under one user or organization.

A suggested hierarchy:

```text
User
→ Organization
→ Business Entity
→ Bank Account
→ Accounting Period
→ Workflow Run
→ Transaction
→ Evidence Documents
→ Ledger Entries
```

Each business entity must be isolated. A transaction, invoice, bank account, document, or report must always belong to a specific business entity.

Every database query must be scoped by:

```text
organization_id
business_id
```

This prevents accidental cross-business data exposure.

---

## 6. Core Data Objects

### 6.1 Business Entity

A business entity represents one company or business being managed in the software.

Suggested fields:

```text
business_id
organization_id
legal_name
trading_name
company_registration_number
vat_number
tax_identification_number
country
base_currency
accounting_method
vat_registered
vat_registration_date
vat_period_type
created_at
updated_at
```

### 6.2 Bank Account

A bank account represents a Revolut or other financial account connected to a business.

Suggested fields:

```text
bank_account_id
business_id
provider
account_name
currency
masked_iban
iban_encrypted
account_number_encrypted
status
created_at
updated_at
```

### 6.3 Statement Upload

A statement upload is the original file uploaded by the user.

Suggested fields:

```text
statement_upload_id
business_id
bank_account_id
file_id
source_type
file_format
statement_period_start
statement_period_end
original_filename
file_hash
upload_status
uploaded_by
uploaded_at
```

### 6.4 Transaction

A transaction is the normalized representation of one bank statement row.

Suggested fields:

```text
transaction_id
business_id
bank_account_id
statement_upload_id
source_row_index
source_row_hash
transaction_date
booking_date
amount
currency
direction
transaction_type
raw_description
normalized_description
counterparty_name
counterparty_country
counterparty_identifier_masked
counterparty_identifier_encrypted
reference
bank_category_original
system_tag
user_tag
classification_status
match_status
ledger_status
review_status
confidence_score
created_at
updated_at
```

### 6.5 Transaction Evidence PDF

This is a generated PDF page representing a single transaction in a clean human-readable format.

Suggested fields:

```text
evidence_pdf_id
transaction_id
business_id
file_id
generated_from_transaction_version
file_hash
generated_at
```

### 6.6 Document

A document can be an invoice, receipt, contract, proof of payment, bank evidence file, or other supporting document.

Suggested fields:

```text
document_id
business_id
source
source_location
file_id
original_filename
document_type
supplier_or_client_name
invoice_number
invoice_date
due_date
amount_total
currency
vat_amount
vat_rate
vat_number_found
country_detected
extraction_status
ocr_text_reference
document_hash
created_at
updated_at
```

### 6.7 Match Record

A match record connects a transaction to one or more supporting documents.

Suggested fields:

```text
match_id
business_id
transaction_id
document_id
match_type
match_method
match_score
match_reason
matched_by
requires_user_confirmation
user_confirmation_status
confirmed_by
confirmed_at
created_at
```

### 6.8 Ledger Entry

The ledger entry is the accounting layer generated after classification and evidence matching.

Suggested fields:

```text
ledger_entry_id
business_id
accounting_period_id
transaction_id
entry_type
account_code
account_name
debit_amount
credit_amount
currency
vat_treatment
input_vat_reclaimable
output_vat_due
reverse_charge_relevant
vies_relevant
counterparty_country
supporting_document_status
approval_status
finalization_status
created_at
updated_at
```

### 6.9 Review Issue

A review issue represents something the system needs the user to check.

Suggested fields:

```text
review_issue_id
business_id
workflow_run_id
transaction_id
document_id
issue_group
issue_type
severity
blocking
plain_language_title
plain_language_description
recommended_action
status
resolved_by
resolved_at
created_at
updated_at
```

### 6.10 Workflow Run

A workflow run represents one monthly processing run.

Suggested fields:

```text
workflow_run_id
business_id
workflow_type
period_start
period_end
status
started_by
started_at
completed_at
finalized_at
finalized_by
summary_json
created_at
updated_at
```

---

## 7. Transaction Types

The system should not treat every bank row equally.

Every transaction must first be classified into a transaction type.

Core transaction types:

```text
OUT_EXPENSE
IN_INCOME
INTERNAL_TRANSFER
FX_EXCHANGE
BANK_FEE
REFUND_IN
REFUND_OUT
CHARGEBACK
LOAN_OR_SHAREHOLDER_MOVEMENT
PAYROLL_OR_TEAM_PAYMENT
TAX_PAYMENT
UNKNOWN
```

This first split is critical because different transaction types require different evidence and accounting treatment.

Examples:

- An OUT_EXPENSE usually requires an invoice or receipt.
- An INTERNAL_TRANSFER usually does not require an invoice.
- An FX_EXCHANGE requires exchange movement evidence, not a supplier invoice.
- A BANK_FEE may only need bank-generated evidence.
- A REFUND should connect to the original transaction.
- A PAYROLL_OR_TEAM_PAYMENT may require an invoice, contract, payroll record, or service agreement depending on the situation.
- A TAX_PAYMENT needs tax authority evidence or payment confirmation.

---

## 8. OUT / Write-Off Workflow

The OUT workflow handles outgoing transactions, write-offs, expense evidence, VAT classification, and final expense ledger preparation.

### 8.1 OUT Workflow Overview

```text
Upload monthly bank statement
→ Parse statement
→ Normalize transactions
→ Deduplicate transactions
→ Generate transaction evidence PDFs
→ Classify transaction types
→ Filter OUT-related transactions
→ Auto-tag transactions
→ Search connected email for invoices
→ Extract invoice data
→ Match email invoices to transactions
→ Search Google Drive for remaining invoices
→ Extract Drive invoice data
→ Match Drive invoices to transactions
→ Move unmatched transactions to review queue
→ User uploads missing documents manually
→ Run ledger preparation phase
→ Run Cyprus VAT/tax classification phase
→ Run AI end-scan
→ Present review issues simply
→ User resolves issues
→ Finalize run
→ Lock finalized data in secure archive
→ Update dashboard and reports
```

### 8.2 Phase 1: Statement Upload

The user uploads a monthly bank statement.

Supported formats:

```text
.csv
.pdf
```

CSV is preferred because it gives more reliable structured data. PDF support should exist, but PDF extraction may require OCR or table extraction.

The system stores the original upload in the Raw Upload Zone and calculates a file hash.

### 8.3 Phase 2: Statement Parsing

The parser converts statement rows into raw transaction candidates.

Parsing must handle:

```text
date formats
amount columns
debit/credit columns
currency
counterparty fields
description fields
reference fields
fees
exchange movements
multi-currency rows
```

For Revolut specifically, the parser should support Revolut export structures and allow future support for updated export formats.

### 8.4 Phase 3: Transaction Normalization

Every parsed row becomes a normalized transaction object.

The system must create:

```text
source_row_hash
normalized date
normalized amount
currency
direction
counterparty candidate
clean description
transaction fingerprint
```

The transaction fingerprint helps with deduplication.

### 8.5 Phase 4: Deduplication

Before processing continues, the system checks whether rows were already imported before.

Deduplication should use:

```text
business_id
bank_account_id
transaction_date
amount
currency
description
source_row_hash
provider transaction id if available
```

Possible statuses:

```text
NEW
DUPLICATE_EXACT
DUPLICATE_POSSIBLE
NEEDS_REVIEW
```

### 8.6 Phase 5: Transaction Evidence PDF Generation

For every accepted transaction, the system generates a clean PDF evidence page.

The PDF should include:

```text
business name
bank account name
statement period
transaction date
booking date
amount
currency
direction
counterparty
description
reference
transaction ID
source statement ID
hash/reference metadata
```

Important: this PDF is not the source of truth. It is a human-readable evidence artifact generated from the structured transaction object.

### 8.7 Phase 6: Transaction Type Classification

The system classifies each transaction into a transaction type.

Classification should use deterministic rules first, then AI fallback if needed.

Examples:

```text
same owner account movement → INTERNAL_TRANSFER
Revolut fee line → BANK_FEE
negative amount to supplier → OUT_EXPENSE
positive amount from client → IN_INCOME
currency conversion text → FX_EXCHANGE
refund keyword + positive amount → REFUND_IN
```

Low-confidence classifications go to the review queue.

### 8.8 Phase 7: Tagging & Category Classification

Each OUT-related transaction receives a business-friendly tag.

Examples:

```text
Business subscription
Software tool
Contractor payment
Team member invoice
Marketing expense
Office expense
Travel expense
Transfer between own accounts
Bank fee
Tax payment
Unknown expense
```

The tagging system should support:

```text
system suggested tag
user confirmed tag
user custom tag
recurring tag memory
business-specific tagging rules
```

The interface should show tags in simple language.

### 8.9 Phase 8: Email Invoice Finder

The system searches connected email accounts for invoices, receipts, and supporting documents.

Search strategy should be sequential and precise.

Search inputs:

```text
transaction amount
currency
transaction date
counterparty name
normalized merchant name
description keywords
invoice number if present
email domain if known
payment reference
```

Search should prioritize:

```text
exact amount matches
same supplier name
same month
attachments containing invoice/receipt keywords
known supplier email domains
recurring vendor patterns
```

The email finder should not blindly ingest all emails. It should query only what is relevant to the transaction or workflow run.

### 8.10 Phase 9: Document Extraction

When candidate invoices are found, the document extraction engine extracts structured fields.

Fields to extract:

```text
supplier name
supplier address
supplier country
supplier VAT number
invoice number
invoice date
due date
service period
line item summaries
subtotal
VAT rate
VAT amount
total amount
currency
payment reference
client/business name
```

Extraction may use OCR, parsing rules, local AI, or external AI through the privacy gateway.

### 8.11 Phase 10: Matching Engine

Matching must be deterministic-first and AI-second.

Matching levels:

```text
Level 1: Exact match
- same amount
- same currency
- supplier name match
- date within accepted window
- invoice number or reference match if available

Level 2: Strong probable match
- amount and currency match
- supplier fuzzy match
- date close
- recurring pattern exists

Level 3: Weak possible match
- some evidence aligns
- requires user confirmation

Level 4: No match
- send to review queue
```

Each match must store a match reason.

Example match reason:

```text
Matched because the invoice amount is EUR 49.00, the transaction amount is EUR 49.00, the supplier is Google Ireland Ltd, and the invoice date is one day before the bank transaction.
```

### 8.12 Phase 11: Google Drive Invoice Finder

After email matching, the system searches Google Drive folders for remaining unmatched transactions.

This is especially important for the business that has many team member invoices stored in Drive.

Search strategy:

```text
supplier/team member name
amount
month/year
invoice number
folder path rules
file name patterns
OCR text search
```

Drive search should be business-scoped. It should not scan unrelated folders unless explicitly connected and approved.

### 8.13 Phase 12: Manual Missing Document Upload

After email and Drive matching, some transactions will remain unmatched.

These go to the review queue as missing evidence.

The user can:

```text
upload invoice
upload receipt
upload contract
mark as internal transfer
mark as bank fee
mark as no invoice available
mark as non-deductible
add explanation note
ask accountant later
```

### 8.14 Phase 13: Ledger Preparation Layer

This is a full workflow phase, not an add-on.

The ledger preparation phase converts matched and classified transactions into accounting-ready ledger entries.

It should call different tools depending on transaction type.

Examples:

```text
OUT_EXPENSE → expense ledger tool
INTERNAL_TRANSFER → inter-account movement tool
FX_EXCHANGE → currency movement tool
BANK_FEE → bank fee tool
REFUND_IN → refund reconciliation tool
PAYROLL_OR_TEAM_PAYMENT → contractor/team payment tool
TAX_PAYMENT → tax payment classification tool
```

The ledger preparation layer should produce draft ledger entries, not finalized entries.

### 8.15 Phase 14: Cyprus VAT & Tax Classification

This phase applies Cyprus-related tax and VAT logic.

Fields to determine:

```text
vat_treatment
counterparty_country
counterparty_vat_number
vies_relevant
reverse_charge_relevant
input_vat_reclaimable
requires_contract
requires_invoice
requires_receipt
requires_accountant_review
```

Possible VAT treatments:

```text
DOMESTIC_CYPRUS_VAT
EU_REVERSE_CHARGE
NON_EU_SERVICE
EXEMPT
NO_VAT
OUTSIDE_SCOPE
IMPORT_OR_ACQUISITION
UNKNOWN
```

This layer should be rules-first and accountant-review-friendly. It should not pretend to replace professional accounting judgment.

### 8.16 Phase 15: AI End-Scan

The AI end-scan reviews the completed workflow run after documents are matched and draft ledger entries are prepared.

The scan checks for:

```text
missing invoices
missing receipts
missing contracts
weak matches
duplicate invoices
same invoice attached to multiple transactions
amount mismatch
currency mismatch
invoice date outside expected period
supplier country unclear
VAT number missing
VAT treatment unclear
possible reverse charge issue
possible VIES issue
possible personal expense
possible non-deductible expense
large unusual transaction
recurring payment missing supporting agreement
team member payment missing invoice or contract
internal transfer incorrectly treated as expense
bank fee incorrectly requiring invoice
refund not connected to original transaction
```

Even though many issue types exist, the UI must group them simply.

Suggested simple UI groups:

```text
Missing Documents
Needs Confirmation
Possible Tax/VAT Issue
Possible Wrong Match
Unusual Transaction
Ready to Finalize
```

Each issue should be written in plain language.

### 8.17 Phase 16: Human Review

The user reviews all open issues.

Each issue should have a simple action.

Examples:

```text
Upload document
Confirm match
Change tag
Mark as internal transfer
Add note
Mark as not deductible
Send to accountant review
Ignore with reason
```

Blocking issues must be resolved before finalization.

### 8.18 Phase 17: Finalization

The OUT workflow can only be finalized when:

```text
all transactions are classified
all required evidence exists or exceptions are documented
all blocking review issues are resolved
draft ledger entries are generated
VAT/tax classification is complete or marked for accountant review
user approval is recorded
finalization audit log is written
```

After finalization:

```text
transactions become locked
matched evidence becomes locked
ledger entries become locked
archive package is created
dashboards are updated
reports become available
```

---

## 9. IN / Income Workflow

The IN workflow handles incoming payments and invoices created inside the software.

### 9.1 IN Workflow Overview

```text
Create invoices inside software
→ Upload monthly bank statement
→ Parse statement
→ Normalize transactions
→ Filter IN transactions
→ Generate transaction evidence PDFs
→ Match incoming payments to created invoices
→ Detect partial/over/duplicate/unpaid cases
→ Run VAT/VIES validation
→ Run AI end-scan
→ Present review issues
→ User resolves issues
→ Finalize run
→ Lock finalized income data in secure archive
→ Update dashboard and reports
```

### 9.2 Invoice Generator

The invoice generator must include all required invoice lifecycle and compliance fields.

The invoice generator should support:

```text
client database
client country
client VAT number
invoice numbering sequence
invoice issue date
supply/service date
payment terms
due date
line items
currency
VAT treatment
reverse charge text where relevant
subtotal
VAT amount
total amount
invoice PDF generation
invoice status tracking
credit notes
recurring invoices
pro-forma vs tax invoice distinction
```

Invoice lifecycle:

```text
DRAFT
SENT
PAYMENT_EXPECTED
PARTIALLY_PAID
PAID
OVERPAID
CREDITED
REFUNDED
WRITTEN_OFF
FINALIZED
```

### 9.3 Incoming Bank Statement Processing

The same statement upload and parsing engine used for OUT should also support IN.

The IN workflow filters transactions classified as:

```text
IN_INCOME
REFUND_IN
UNKNOWN_POSITIVE
```

The system should not blindly treat every incoming payment as sales income. Some incoming payments may be refunds, internal transfers, shareholder loans, or corrections.

### 9.4 Income Matching Engine

Incoming transactions are matched to invoices created inside the software.

Matching signals:

```text
invoice amount
currency
client name
payment reference
invoice number
payment date
due date
client bank/account information if known
partial payment patterns
```

Possible match outcomes:

```text
FULL_MATCH
PARTIAL_PAYMENT
OVERPAYMENT
MULTIPLE_INVOICES_ONE_PAYMENT
ONE_INVOICE_MULTIPLE_PAYMENTS
NO_MATCH
POSSIBLE_REFUND_OR_TRANSFER
```

### 9.5 Income End-Scan

The IN workflow end-scan checks for:

```text
invoice created but unpaid
payment received without invoice
invoice paid with wrong amount
payment in wrong currency
duplicate payment
late payment
missing client VAT number
VIES relevance
reverse charge text missing
credit note required
refund not connected
unusual income transaction
```

### 9.6 IN Finalization

The IN workflow can only be finalized when:

```text
all incoming payments are classified
all created invoices have correct status
all payment matches are confirmed
all blocking review issues are resolved
VAT/VIES fields are complete or marked for accountant review
user approval is recorded
```

After finalization, the system updates:

```text
income dashboard
accounts receivable overview
VAT summaries
VIES-related export data
client payment history
accountant export packs
```

---

## 10. Review Queue Design

The review queue is a core part of the product.

It must make complex bookkeeping issues simple.

### 10.1 Main Review Categories

Instead of showing 20+ technical issue types directly, the UI should group issues into simple categories.

Recommended groups:

```text
1. Missing Documents
2. Needs Confirmation
3. Possible Wrong Match
4. Possible Tax/VAT Issue
5. Unusual Transaction
6. Ready to Finalize
```

### 10.2 Issue Card Structure

Each issue card should show:

```text
plain title
short explanation
transaction amount
transaction date
supplier/client
current tag
attached document if any
recommended action
severity
one-click actions
```

Example:

```text
Missing invoice for Google Workspace payment
EUR 49.00 paid on 3 April 2026 to Google Ireland Ltd.
No matching invoice was found in email or Drive.
Recommended action: upload invoice or mark as no invoice available.
```

### 10.3 Severity Levels

```text
LOW
MEDIUM
HIGH
BLOCKING
```

Blocking issues prevent finalization.

### 10.4 Resolution Actions

Possible actions:

```text
Upload document
Confirm match
Reject match
Change tag
Mark as internal transfer
Mark as bank fee
Mark as non-deductible
Add explanation note
Send to accountant review
Ignore with reason
```

Every resolution action must be audit logged.

---

## 11. AI / LLM Security Architecture

The AI layer must be privacy-controlled.

The system should never send full sensitive financial data to external AI providers by default.

### 11.1 AI Privacy Gateway

All AI calls must pass through an AI Privacy Gateway.

The gateway is responsible for:

```text
redacting PII
masking IBANs
masking account numbers
masking personal addresses
minimizing document text
removing unnecessary email content
structuring input payloads
validating output schema
logging AI usage
routing tasks to local or external models
blocking unsafe AI calls
```

### 11.2 AI Routing Tiers

The system should use three processing tiers.

```text
Tier 1: No AI
- calculations
- exact matching
- deduplication
- deterministic classification
- report totals
- file hashing

Tier 2: Local LLM / Local AI
- basic classification
- supplier normalization
- OCR cleanup
- invoice summarization
- sensitive extraction where possible
- first-pass anomaly checks

Tier 3: External LLM with Redaction
- complex reasoning
- ambiguous match explanation
- difficult anomaly explanation
- plain-language issue generation
```

The local LLM does not need to be huge. It can handle smaller structured tasks if prompts are narrow and inputs are clean.

### 11.3 LLM Input Rules

The AI should receive only the minimum required information.

Bad AI input:

```text
full bank statement
full invoice
full email thread
full IBAN
full address
full contract
```

Good AI input:

```json
{
  "transaction": {
    "date": "2026-04-03",
    "amount": 49.00,
    "currency": "EUR",
    "direction": "OUT",
    "merchant": "Google Ireland Ltd",
    "description_masked": "GOOGLE *Workspace"
  },
  "invoice_candidate": {
    "supplier": "Google Ireland Ltd",
    "invoice_date": "2026-04-02",
    "amount": 49.00,
    "currency": "EUR",
    "country": "IE",
    "vat_number_present": true,
    "line_summary": "Business software subscription"
  },
  "task": "classify_match_and_flag_risks"
}
```

### 11.4 LLM Output Rules

All AI output must be structured JSON.

Example:

```json
{
  "decision": "LIKELY_MATCH",
  "confidence": 0.91,
  "reasons": [
    "Amount and currency match exactly",
    "Supplier name matches transaction merchant",
    "Invoice date is one day before payment date"
  ],
  "risks": [],
  "requires_user_confirmation": false
}
```

The system must validate AI output against schemas before using it.

---

## 12. Security Architecture

Security is a top-level requirement.

### 12.1 Storage Zones

The system should use separate logical storage zones.

```text
Raw Upload Zone
Processing Zone
Operational Database
Finalized Secure Archive
Analytics / Dashboard Layer
```

### 12.2 Raw Upload Zone

Contains:

```text
original bank statements
original invoice files
original receipt files
original contracts
```

Rules:

```text
restricted access
encrypted at rest
file hashes required
no direct public access
signed temporary URLs only
```

### 12.3 Processing Zone

Contains temporary extracted data.

Examples:

```text
OCR text
parsed invoice fields
candidate matching data
temporary AI payloads
```

Rules:

```text
minimize sensitive data
expire temporary artifacts where possible
separate from finalized archive
log access
```

### 12.4 Operational Database

Contains active workflow data.

Examples:

```text
transactions
tags
match records
review issues
workflow statuses
user approvals
```

Rules:

```text
tenant isolation
row-level security
field-level encryption for sensitive fields
strict access control
```

### 12.5 Finalized Secure Archive

Contains locked monthly accounting data.

Examples:

```text
finalized transactions
finalized ledger entries
approved evidence files
finalization reports
audit packs
```

Rules:

```text
highly restricted access
immutable or append-only design where possible
separate encryption scope
document hashes
access logs
retention policy
```

### 12.6 Analytics / Dashboard Layer

Contains summarized data for dashboard performance.

Rules:

```text
prefer aggregated numbers
avoid raw sensitive document content
allow drill-down only with permission
separate from archive where possible
```

### 12.7 Encryption

The system should use:

```text
encryption in transit
encryption at rest
field-level encryption for IBAN/account numbers/VAT numbers where needed
separate encryption keys per business or organization
key rotation
secure secrets management
```

### 12.8 Access Control

Recommended role model:

```text
Owner
Admin
Bookkeeper
Accountant
Reviewer
Read-only
```

Permissions should control:

```text
business access
bank account access
document viewing
workflow running
issue resolving
finalization
report exporting
user management
```

### 12.9 Audit Logs

Audit logs must record:

```text
user login
file upload
file view
file download
transaction creation
transaction update
tag change
document match
document unmatch
AI suggestion accepted
AI suggestion rejected
issue resolved
period finalized
report generated
permission changed
```

Audit logs should be tamper-resistant.

---

## 13. Cyprus Tax, VAT & Compliance Layer

The software must be built around Cyprus bookkeeping needs.

Important: the software should assist with bookkeeping and reporting preparation, but final legal/tax decisions may still require accountant approval.

### 13.1 Core Compliance Data Fields

Each transaction and invoice should support:

```text
counterparty_country
counterparty_vat_number
vat_treatment
input_vat_reclaimable
output_vat_due
reverse_charge_relevant
vies_relevant
requires_contract
requires_invoice
requires_receipt
requires_accountant_review
```

### 13.2 VAT Treatments

Supported VAT treatment values:

```text
DOMESTIC_CYPRUS_VAT
EU_REVERSE_CHARGE
NON_EU_SERVICE
EXEMPT
NO_VAT
OUTSIDE_SCOPE
IMPORT_OR_ACQUISITION
UNKNOWN
```

### 13.3 Report Types

The reporting layer should eventually support:

```text
monthly expense overview
monthly income overview
VAT summary
VIES-related export
supplier overview
client overview
unmatched document report
missing evidence report
accountant export pack
profit/loss overview
cashflow overview
finalized period archive export
```

### 13.4 Retention

The system should be designed for long-term record retention.

The finalized archive must support at least a 6-year retention policy for VAT/books/records, unless future accounting advice requires a longer period.

---

## 14. Matching Engine Design

The matching engine is one of the most important parts of the software.

### 14.1 Matching Inputs

For each transaction:

```text
amount
currency
transaction date
counterparty name
description
reference
transaction type
tag
business entity
bank account
```

For each document:

```text
supplier/client name
invoice number
invoice date
amount
currency
VAT number
country
file name
source
email sender or Drive path
OCR text
```

### 14.2 Match Score Components

Suggested scoring:

```text
amount exact match
currency match
supplier/client exact match
supplier/client fuzzy match
date proximity
invoice number/reference match
known recurring vendor
email sender domain match
Drive folder relevance
business name appears on invoice
VAT number relevance
```

### 14.3 Match Statuses

```text
MATCHED_CONFIRMED
MATCHED_AUTO_HIGH_CONFIDENCE
MATCHED_NEEDS_CONFIRMATION
POSSIBLE_MATCH
NO_MATCH
REJECTED_MATCH
```

### 14.4 Duplicate Detection

The system must detect:

```text
same invoice attached to multiple transactions
same transaction matched to multiple invoices without reason
duplicate uploaded invoice file
same document from email and Drive
duplicate statement upload
same bank transaction imported twice
```

---

## 15. Finalization Engine

Finalization is the point where active workflow data becomes locked accounting data.

### 15.1 Finalization Preconditions

A run can only be finalized when:

```text
all transactions are parsed and normalized
all duplicates are resolved
all transaction types are classified
all required evidence is attached or documented as missing with reason
all ledger entries are prepared
all VAT/tax classifications are complete or marked for accountant review
all blocking review issues are resolved
user approval is captured
audit log is written
```

### 15.2 Finalization Output

Finalization creates:

```text
locked transaction set
locked evidence set
locked ledger entries
finalization summary
period report
archive package
reporting updates
```

### 15.3 Locked Period Rules

After finalization:

```text
transactions cannot be silently edited
documents cannot be silently replaced
matches cannot be silently changed
ledger entries cannot be silently changed
```

If changes are needed later, the system should create an adjustment or reopening workflow with full audit logging.

---

## 16. Dashboard & Reporting

The dashboard should be simple and practical.

### 16.1 Main Dashboard Views

```text
Monthly overview
Income overview
Expense overview
Missing documents
Review issues
VAT summary
Business subscriptions
Team member costs
Client invoice status
Cash movement
Finalized periods
```

### 16.2 Report Downloads

Users should be able to download:

```text
transaction report
expense report
income report
VAT preparation report
VIES preparation report
missing evidence report
invoice match report
accountant export pack
finalized archive package
```

### 16.3 Drill-Down

From dashboards, the user should be able to drill down into:

```text
transaction
attached invoice
match reasoning
ledger entry
review issues
finalization status
```

Access should depend on permissions.

---

## 17. Build Scope Decision

The first build will not be a tiny MVP.

The initial planned build should include:

```text
OUT workflow
IN workflow
bank statement upload
transaction structuring
PDF evidence generation
tagging
email invoice finder
Google Drive invoice finder
manual document upload
matching engine
ledger preparation phase
Cyprus VAT/tax classification phase
AI end-scan
review queue
invoice generator
secure archive
dashboards
reports
security layer
AI privacy gateway
```

Because the project will be elaborated deeply before development, the goal is to plan everything clearly enough that the full MVP-1 scope can be built without losing details.

---

## 18. Open Design Questions for Elaboration Phase

These questions must be answered in the next phase.

### 18.1 Accounting Questions

```text
Which exact Cyprus company types will be supported first?
Will the businesses be VAT registered from day one?
Which VAT periods apply?
Which chart of accounts should be used?
Will accountant approval be required before finalization?
Should the app support accrual accounting, cash accounting, or both?
How should owner/director/shareholder movements be treated?
How should team member invoices be handled?
How should non-deductible expenses be represented?
```

### 18.2 Technical Questions

```text
Which backend framework will be used?
Which database will be used?
Which object storage provider will be used?
Will the app be hosted in the EU?
Which OCR engine will be used?
Which local LLM will run on the PC?
Which external LLM provider, if any, will be used?
How will email connection permissions be handled?
How will Google Drive folder access be scoped?
```

### 18.3 Security Questions

```text
What encryption/key management provider will be used?
Will each business have separate encryption keys?
How will audit logs be made tamper-resistant?
What roles are needed from day one?
Will two-factor authentication be mandatory?
How will backups be encrypted?
How will access to finalized archive documents be controlled?
```

### 18.4 Product Questions

```text
What should the user see immediately after uploading a bank statement?
How simple should the review queue be?
What are the required dashboard cards?
What reports are needed first?
What should the accountant export look like?
How should finalization be presented to the user?
```

---

## 19. Next Phase: Elaboration Plan

The next phase should break this core concept into detailed implementation documents.

Recommended next documents:

```text
1. Workflow Engine Specification
2. OUT Workflow Detailed Specification
3. IN Workflow Detailed Specification
4. Database Schema Specification
5. Security Architecture Specification
6. AI Privacy Gateway Specification
7. Matching Engine Specification
8. Review Queue UX Specification
9. Cyprus VAT & Tax Classification Specification
10. Invoice Generator Specification
11. Finalization & Secure Archive Specification
12. Dashboard & Reporting Specification
13. API Specification
14. Developer Implementation Roadmap
```

The first document to elaborate should be the Workflow Engine Specification, because every other system block depends on it.

---

## 20. Final Core Concept Summary

This product is a secure, Cyprus-focused bookkeeping workflow platform for multiple businesses.

The user uploads monthly bank statements. The software structures every transaction, classifies transaction types, generates evidence PDFs, finds invoices from email and Google Drive, matches documents to transactions, prepares ledger entries, applies Cyprus VAT/tax logic, runs an AI-assisted end-scan, shows issues in a simple review queue, and allows the user to finalize the monthly run into a highly secured archive.

The software has two main workflows:

```text
OUT / Write-Off Workflow
IN / Income Workflow
```

Both workflows share the same core infrastructure:

```text
statement import
transaction normalization
document extraction
matching engine
ledger preparation
AI review
human review
finalization
secure archive
reporting
```

The software should be simple to use, but advanced in structure. AI is used carefully and securely. Sensitive data is protected through encryption, tenant isolation, PII minimization, local model routing where possible, external LLM redaction, audit logging, and locked finalized archives.

The next step is to elaborate the Workflow Engine Specification in detail.

