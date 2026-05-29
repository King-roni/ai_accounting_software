# Decisions Log

This log is the single source of truth for design decisions made during elaboration. Each entry records the decision, the blocks it affects, and the date it was made. Decisions are binding for downstream phase docs and sub-docs unless formally amended at the bottom of this document.

When a block's architecture refers to "the chosen stack" or "the resolved policy", that reference points here.

---

## Stage 1 — Foundation Block Decisions

### Foundational Stack

- **Hosting region:** EU only (strict). No exceptions for databases, storage, processing, or AI calls.
  - _Affects:_ Blocks 04, 05, 06
- **Primary database:** PostgreSQL via Supabase. Managed, EU regions, native row-level security used as the tenant isolation layer.
  - _Affects:_ Blocks 02, 04, 05
- **Object storage:** Supabase Storage for both Raw Upload and Finalized Archive zones.
  - _Affects:_ Block 04
- **External LLM provider (Tier 3):** Anthropic Claude, using EU-residency / zero-retention API options.
  - _Affects:_ Block 06
- **Local LLM placement (Tier 2):** User-operated dedicated machine. The Tier 2 model runs on hardware the operator owns.
  - _Affects:_ Block 06

### Security & Audit

- **MFA factors:** TOTP + WebAuthn/passkeys.
  - _Affects:_ Blocks 02, 05
- **Field-level encryption:** Supabase Vault holds keys; Postgres pgcrypto performs the encryption for sensitive fields (IBANs, account numbers, OAuth tokens, etc.).
  - _Affects:_ Block 05
- **Audit log tamper resistance:** Hash-chained log with periodic RFC 3161 third-party timestamping of chain heads.
  - _Affects:_ Block 05
- **Audit log replica:** Live log only in MVP. Read replica deferred until query volume justifies it.
  - _Affects:_ Block 05
- **Security alerting:** Internal-only in MVP (ops/security channel). User-facing alerts deferred.
  - _Affects:_ Block 05
- **GDPR right-to-erasure:** Recorded intent at request time; pseudonymize immediately and anonymize fully after retention period ends. The erasure event itself is preserved as a historical record.
  - _Affects:_ Block 05

### Tenancy & Access

- **Roles in MVP:** Six base roles only — Owner, Admin, Bookkeeper, Accountant, Reviewer, Read-only. No External Auditor role and no custom-role builder.
  - _Affects:_ Block 02
- **Accountant approval before finalization:** Not required in MVP. Owner/Admin approval suffices. The Accountant role still exists for review purposes.
  - _Affects:_ Blocks 02, 15
- **Role change propagation:** Apply to new actions only. Active workflow runs continue with the principal context they started under.
  - _Affects:_ Blocks 02, 03
- **Gmail/Drive token refresh authority:** Any Owner or Admin of the business may refresh integration tokens.
  - _Affects:_ Blocks 02, 09

### Workflow Engine

- **Workflow type registry:** Static (compiled-in workflow types) + per-business config that can enable/disable specific phases or tools.
  - _Affects:_ Block 03
- **Gate evaluation pattern:** Registered functions per phase. The engine invokes them; gate logic lives next to the phase it guards.
  - _Affects:_ Block 03
- **Run triggers:** Manual + event-based (e.g., automatic trigger on statement upload). No scheduled (cron-like) triggers in MVP.
  - _Affects:_ Block 03
- **Failure policy on transient external errors:** Bounded retry, then notify the user (surface a review issue and pause the phase).
  - _Affects:_ Block 03
- **Adjustment diffing model:** Adjustment records carry an explicit reason and a structured delta against the original finalized data.
  - _Affects:_ Blocks 03, 04, 15

### Data Architecture

- **Finalized Archive physical model:** Separate Postgres schema with stricter RLS + Supabase Storage Object Lock for archive files.
  - _Affects:_ Blocks 04, 15
- **Adjustment-run record placement:** Interleaved with original finalized records, additive only — original records are never modified.
  - _Affects:_ Block 04
- **Analytics layer refresh:** Eventual consistency via background jobs. Dashboards may lag a few minutes after finalization.
  - _Affects:_ Blocks 04, 16
- **Legal hold mechanism:** Per-business flag. When set, automated retention deletion is suspended for the entire business until the hold is lifted.
  - _Affects:_ Block 04

### AI Layer

- **AI cost ceiling:** Soft ceiling per workflow run — system warns the user at threshold and allows override.
  - _Affects:_ Block 06
- **AI caching:** Cache by input hash within a single workflow run. No cross-run cache in MVP.
  - _Affects:_ Block 06
- **Prompt management:** Prompts versioned in the repo, with automated regression tests against a maintained test corpus before deploy.
  - _Affects:_ Block 06

### Core Principles

- **Data minimization:** Stays as a sub-rule under Principle 4 (Security by Design). Not promoted to a sixth core principle.
  - _Affects:_ Block 01
- **Accountant principle:** Not added. Consistent with the decision that accountant approval is not required for finalization in MVP.
  - _Affects:_ Block 01

---

## Stage 1 — Domain Engine Decisions

### Cross-cutting (Blocks 07, 09, 11)

- **OCR engine:** Google Document AI (managed, EU regions). Used by Block 07 for PDF statements and Block 09 for image/scanned documents.
  - _Affects:_ Blocks 07, 09
- **Accounting method:** Accrual only in MVP. Cash mode is not supported.
  - _Affects:_ Blocks 11, 13, 16
- **Default chart of accounts:** Adopt a Cyprus-friendly standard chart shipped with the product; allow per-business customization.
  - _Affects:_ Blocks 11, 16
- **FX exchange representation:** One transaction with paired legs. Block 11 derives multiple ledger entries from a single FX transaction.
  - _Affects:_ Blocks 07, 10, 11

### Block 07 — Bank Statement Pipeline

- **Partial uploads:** Accept and warn. Process what's parseable; raise a HIGH-severity review issue describing the gap.
- **Statement period boundaries:** Trust user's declared period; warn when rows fall outside it.

### Block 08 — Transaction Classification & Tagging

- **Custom tags:** Each per-business custom tag maps to exactly one of the 12 transaction types.
- **Multi-tag support:** One primary tag (drives ledger path) + optional secondary tags (reporting/analytics only).
- **Recurring vendor memory promotion:** Tiered — 1 confirmation = medium-confidence suggestion (still routes to review); 3+ confirmations = high-confidence auto-confirmable suggestion.
- **Tag taxonomy versioning:** Versioned. Finalized periods preserve the tag taxonomy version active at finalization; new runs use the latest version.

### Block 09 — Document Intake & Extraction

- **Email search queries:** Fixed library of query patterns per supplier type and transaction context. No per-call generative queries in MVP.
- **Drive folder mapping:** User explicitly connects a single root invoice folder per business; the operator's convention is **2-week date subfolders**, which Block 09's Drive finder uses to scope searches by transaction date.
- **Non-PDF attachments:** Convert and OCR all common types (PDF, DOCX, JPG/PNG, HEIC, etc.).
- **Spam/phishing filtering:** Trust Gmail's spam labels + per-business sender allowlist. Senders outside the allowlist that aren't already-known suppliers don't reach the matching engine.

### Block 10 — Matching Engine

- **Strong-Probable auto-confirm rule:** Auto-confirm only when the recurring-pattern signal is strong; otherwise route to review.
- **Date proximity windows (defaults):** ±3 days for Exact, ±10 days for Strong Probable, ±30 days for Weak Possible.
- **Split-payment detection:** Proactive — engine attempts combinations of unmatched invoices that sum to the transaction amount, surfaces candidates as review issues for user confirmation.
- **Cross-period matching:** The engine looks back 1–2 months for unmatched documents (covers invoices issued late in one period and paid early in the next).
- **FX rate source:** Bank-recorded rate from the FX leg (Revolut's own rate). ECB daily rate as fallback when the bank rate is missing.
- **Rejected matches memory:** Remember forever for the same `(transaction, document)` pair; never re-suggest a pair the user has rejected.

### Block 11 — Ledger & Cyprus VAT Engine

- **Owner / director / shareholder movements:** Dedicated equity and loan accounts in the chart (Director's Loan Account, Shareholder Capital, etc.) plus the `LOAN_OR_SHAREHOLDER_MOVEMENT` transaction type.
- **Non-deductible expenses:** Separate sub-accounts per expense category (e.g., "Travel — deductible" / "Travel — non-deductible"), so reports preserve category visibility.
- **VIES scope in MVP:** Full VIES file export to the current specification — not just a data model and summary report.
- **Multi-line invoices:** One consolidated ledger entry per invoice; line items preserved on the underlying document record for drill-down.

---

## Stage 1 — Workflow Block Decisions

### Block 12 — OUT / Write-Off Workflow

- **OUT/IN trigger order:** when a single statement upload triggers both, they run **in parallel** after the shared INGESTION and CLASSIFICATION phases. The engine deduplicates the shared work; the user sees a unified progress indicator.
- **INTERNAL_TRANSFER routing:** passes through both `OUT_FILTER` and `IN_FILTER`; Block 11's inter-account movement tool produces a **single deduplicated ledger entry**. Catches transfers visible on either statement direction.
- **MANUAL_UPLOAD_HOLD timeout:** **reminder after 7 days, no auto-action**. The run sits indefinitely until the user uploads or documents an exception.
- **OUT_ADJUSTMENT historical cap:** up to **6 years** (matching the legal retention window for Cyprus VAT and books). Any finalized period within retention is amendable.
- **Adjustment concurrency:** an open adjustment **does not block** the next monthly run. Both can run concurrently.

### Block 13 — IN / Income Workflow + Invoice Generator

- **Invoice numbering format:** strict sequential per business — `INV-YYYY-NNNN` (e.g., `INV-2026-0001`).
- **Recurring invoice cadence trigger:** **background scheduler runs daily** and generates invoices whose recurrence date has fallen due. Decoupled from the IN_MONTHLY run.
- **Credit note numbering:** **separate per-business sequence** — `CN-YYYY-NNNN`.
- **Multi-currency invoicing:** invoices are **locked in their issued currency at creation** through the entire lifecycle. No mid-flight repricing.
- **Multiple-invoices-one-payment allocation:** the engine proposes the most likely allocation and **always requires user confirmation** before applying. No silent auto-allocation.
- **Pro-forma invoices in matching:** pro-forma invoices **cannot match against incoming payments**. Conversion to a tax invoice is required first.
- **WRITTEN_OFF invoice ledger treatment:** posted as a **bad debt expense** (standard Cyprus practice).

---

## Stage 1 — UX & Closeout Block Decisions

### Block 14 — Review Queue & Human Review

- **Bulk actions:** supported in MVP, with a confirmation step before applying. One audit event per affected issue.
- **Per-issue notes:** single free-text notes field per issue, captured in the audit log alongside the resolution.
- **Issue assignment:** Owner/Admin can assign an issue to a Bookkeeper or Accountant; assignee receives a notification.
- **Issue snooze:** non-blocking issues (LOW or MEDIUM) can be snoozed with an explicit reason. Snoozed issues reappear in the next run.
- **Re-scan after resolution:** End-Scan auto-re-runs only on issues affected by the resolved record (transaction, document, match) — not full re-scan.
- **Mobile UX in MVP:** desktop-first with mobile read-only views (dashboards, drill-down, queue browsing). Resolutions are desktop-only in MVP.

### Block 15 — Finalization & Secure Archive

- **Approval step-up auth:** the same TOTP/passkey factor used for login is challenged again before finalization.
- **Lock-sequence failure recovery:** auto-retry once on transient failure; if it fails again, raise a HIGH-severity review issue and require user intervention.
- **Archive package format:** a **single sealed zip bundle** with the manifest embedded inside the bundle. The bundle itself is the immutable object under Storage Object Lock.
- **Manifest versioning on re-finalization:** increment a version number and preserve all prior manifests under Object Lock. Each adjustment-finalization writes a new manifest version; old versions remain queryable.

### Block 16 — Dashboard & Reporting

- **Default dashboard cards:** ship all 11 cards as defaults; users can hide what they don't need.
- **Report formats in MVP:** PDF + CSV + XLSX from day one. XLSX is essential for accountant handoff in Cyprus.
- **Multi-business consolidated view:** included in MVP with **full drill-down across businesses** for users who hold roles on multiple businesses inside an organization. Permission checks per business apply transparently in the drill-down.
- **Dashboard customization:** per-user hide/show of cards. Layout itself is fixed in MVP; rearranging and saved presets are deferred.
- **Scheduled report delivery:** **deferred to post-MVP**. Email infrastructure, recipient management, and reliable scheduling are not on the critical path for monthly closeout.
- **Accountant export pack composition:** **configurable per business** — each business sets its own pack composition once in settings; subsequent exports follow that configuration.

---

## Deferred Decisions (resolved later in elaboration)

These are intentionally left for sub-doc Stage 4, when their context is clearer:

- **Specific local LLM model and runtime** — depends on hardware specs of the operator's dedicated machine. Resolved during AI sub-docs.
- **Specific cost-ceiling thresholds** — soft-ceiling values per workflow type. Resolved during AI sub-docs and rates table.
- **Specific retention dates per business** — base default ≥ 6 years; per-business overrides handled in sub-docs.
- **Specific prompt-test corpus structure** — defined when the first AI prompts are designed.

---

## Amendments

Amendments to any decision above require: a written rationale, the date, and re-review of every affected block.

### 2026-05-08 — Stage 2 amendments from per-block scans

- **Pro-forma invoice numbering** — `PRO-YYYY-NNNN` is a third per-business sequence, distinct from `INV-YYYY-NNNN` (tax invoices) and `CN-YYYY-NNNN` (credit notes). Pro-formas are never re-used as tax-invoice numbers; conversion to a tax invoice consumes a fresh `INV` number. Rationale: keeping pro-formas in their own sequence preserves the gap-free strictness of the `INV` sequence (Cyprus auditability requirement) without consuming tax-invoice numbers for pro-formas that may never convert.
  - _Affects:_ Block 13 (Phases 01, 06)
- **Severity-enum drift correction** — Block 12 Phase 05 / Phase 07 and Block 13 Phase 09 mistakenly used `CRITICAL` as a severity value. Block 14's canonical severity enum is `{LOW, MEDIUM, HIGH, BLOCKING}` — `CRITICAL` does not exist. Phase docs amended to use `severity ∈ {HIGH, BLOCKING}` for blocking gates. Rationale: gate logic against a non-existent enum value is silently non-functional.
  - _Affects:_ Blocks 12 (Phases 05, 07), 13 (Phase 09), 14 (canonical source)
- **Block 11 Phase 04 IN-side counterparty resolver branch** — Phase 04's resolution chain extends with a Step 1.5 (`CLIENTS_REGISTRY` source) ahead of vendor memory for `IN_MONTHLY` / `IN_ADJUSTMENT` runs. The `clients` registry (Block 13 Phase 02) is the IN-side analog of `recurring_vendor_memory`; the helpers `getClientByName` and `getClientByVatNumber` are exposed by Block 13 Phase 02. Rationale: the OUT-side-only resolver was unilaterally extending Block 11 contracts; pinning the branch makes the cross-block contract explicit.
  - _Affects:_ Blocks 11 (Phase 04), 13 (Phase 02)
- **Block 11 Phase 07 lifecycle-driven dispatcher path** — `prepareInvoiceLifecycleEntries` added as a top-level path alongside the per-type dispatcher. Invoked by lifecycle transitions that produce ledger entries without a corresponding new transaction (Stage 1: `WRITTEN_OFF` → bad-debt expense). Rationale: the existing dispatcher is transaction-keyed; write-off is invoice-lifecycle-keyed; the previous Stage 1 decision "WRITTEN_OFF → bad debt expense" was unimplementable without this path.
  - _Affects:_ Blocks 11 (Phase 07), 13 (Phase 06)
- **Permission-matrix surface decomposition for review queue** — Block 02 Phase 04's `ISSUE_RESOLVE` surface is decomposed into three more granular surfaces: `REVIEW_QUEUE_VIEW` (read-only access to the review queue; default grants Owner / Admin / Bookkeeper / Accountant / Reviewer / Read-only), `REVIEW_QUEUE_RESOLVE` (invoke resolution actions; default grants Owner / Admin / Bookkeeper / Accountant), `REVIEW_ASSIGN` (assign issues to other users; default grants Owner / Admin only). Plus `REVIEW_REGENERATE` (Owner / Admin only — manual card-content regeneration). The existing `WORKFLOW_TRIGGER` surface (used by Block 12 Phases 07/08 and Block 13 Phases 07/09) is a separate canonical surface. Rationale: granular surfaces let the queue's read-only Reviewer flow coexist with action-restricted resolutions; the prior single `ISSUE_RESOLVE` couldn't express the role-table commitment that Reviewer can read but not resolve.
  - _Affects:_ Blocks 02 (Phase 04), 14 (Phase 01, 03, 04, 06)
- **`review_issues` schema reconciliation** — Block 04 Phase 04 (canonical owner) is amended to add the columns Block 14's phase docs need: `card_payload_json`, `card_content_generated_at`, `card_content_tier_used`, `card_content_fallback_applied` (Phase 03), `assignment_notification_sent_at` (Phase 06), `snoozed_at`, `snoozed_by` (Phase 07), `auto_resolution_trigger_issue_id` (Phase 08); the status enum is extended with `AUTO_RESOLVED_BY_RESCAN` (Phase 08); the existing `SNOOZED` value is canonical and Block 14 uses it for snoozed issues. The `issue_group` ENUM is reduced from six values to five (the actionable buckets); `Ready to Finalize` is a queue-state projection, not a row value (per Phase 02 H8 fix).
  - _Affects:_ Blocks 04 (Phase 04), 14 (Phases 01, 02, 03, 07, 08)
- **VIES export file format inside the archive bundle** — the `vies_export.csv` file inside the Block 15 archive bundle is **CSV format** in Stage 1 (the export-friendly form for archival and audit purposes). The actual Cyprus VIES return that gets filed to the tax authority is generated separately by Block 16 (the regulator-required format may be XML; deferred to Block 16's phase decomposition). The two artefacts serve different purposes: the bundle CSV is for archive integrity and accountant access; the Block 16 export is for regulatory filing.
  - _Affects:_ Blocks 11 (Phase 06), 15 (Phase 05), 16 (deferred phase decomposition)
- **`report.generatePeriodReport` cross-block contract** — Block 16 commits to providing a deterministic, side-effect-free `report.generatePeriodReport({ workflow_run_id }) → pdf_bytes` function callable synchronously by Block 15 during finalization (lock-sequence step 3). The function's input is the run id; output is the PDF bytes; failure is reported via standard exception. Failure path during finalization is the standard auto-retry-once contract; persistent failure raises a HIGH `finalization.period_report_failed` review issue. The contract is forward-pinned for Block 16's eventual phase decomposition.
  - _Affects:_ Blocks 15 (Phase 05), 16 (deferred phase decomposition)
- **`ARCHIVE_PROMOTION_COMPLETED` canonical cross-block trigger event** — Block 15's lock sequence (Phase 04 step 7) and adjustment-finalization (Phase 06) emit `ARCHIVE_PROMOTION_COMPLETED` as the canonical event consumed by Block 04 Phase 09's analytics-rebuild subscriber, Block 16 dashboard refresh, and any other archive consumer. The act of writing this audit event IS the analytics-enqueue mechanism (event-bus subscription model; no separate queue infrastructure). Payload: `{ archive_package_id, manifest_version_number, business_id, period_start, period_end }`.
  - _Affects:_ Blocks 04 (Phase 09), 15 (Phases 04, 06), 16 (deferred phase decomposition)
- **Lock-sequence audit emission as separate transaction** — step 7 of Block 15's lock sequence (audit-event emission) runs as a SEPARATE short transaction from steps 1-6 (which run inside a single Postgres transaction). Rationale: append-only hash-chain writes (Block 05 Phase 03) work best as their own short transactions to avoid chain-head contention with concurrent writers. The lock sequence's true commit point is the end of step 7. A crash-window between step 6's commit and step 7's audit write is handled by Block 03 Phase 07's resumability framework + a recovery emission `FINALIZATION_LOCK_AUDIT_RECOVERED`.
  - _Affects:_ Blocks 03 (Phase 07), 05 (Phases 02, 03), 15 (Phases 04, 09)

### 2026-05-09 — Stage 2 amendments from Block 16 scan

- **Permission-matrix decomposition for dashboard & reporting** — Block 02 Phase 04's `REPORT_EXPORT` surface is decomposed into two more granular surfaces: `REPORT_EXPORT_BASIC` (transaction CSV / expense / income / missing evidence / invoice match / supplier overview / P&L / cashflow / client outstanding; default grants Owner / Admin / Bookkeeper / Accountant) and `REPORT_EXPORT_FULL` (VAT preparation / VIES file / finalized archive package / accountant export pack; default grants Owner / Admin / Accountant — Bookkeeper denied for the regulator-grade exports). Plus three new surfaces: `DASHBOARD_VIEW` (default grants every role), `DASHBOARD_REFRESH_MANUAL` (default grants every role — read intent), `BUSINESS_SETTINGS_EDIT` (default grants Owner / Admin only — gates the accountant-pack config edit and other per-business settings). Rationale: the original single `REPORT_EXPORT` surface couldn't express the role-table commitment that Bookkeeper sees operational reports but not regulator-grade exports; granular surfaces let the queue's read flows coexist with action-restricted exports. Mirrors the 2026-05-08 `ISSUE_RESOLVE` decomposition pattern.
  - _Affects:_ Blocks 02 (Phase 04), 16 (Phases 01, 02, 09, 11)
- **`report.generatePeriodReport` snapshot-input contract** — the function consumes the deterministic structured-data snapshot already prepared at lock-sequence step 1 (per Block 15 Phase 04's "Snapshot operational records" step), NOT raw DB state. Function signature is now `report.generatePeriodReport({ workflow_run_id, period_snapshot }) → pdf_bytes` where `period_snapshot` is the structured snapshot. This pins determinism (same snapshot → byte-identical PDF) and resolves the "live during lock reads draft, after lock reads locked" ambiguity. For the `period_report_v2.pdf` adjustment-finalization path, the snapshot includes both the original (locked) entries AND the adjustment (draft, in step 1's snapshot) entries. Re-rendering a finalized period (rare; user-triggered "regenerate") consumes a re-built snapshot from `archive.locked_ledger_entries`.
  - _Affects:_ Blocks 15 (Phases 04, 05, 06), 16 (Phase 10)

### 2026-05-09 — Stage 4 Layer 1 convention amendments

- **Tool name `report.generate_period_report`** — the cross-block contract previously written as `report.generatePeriodReport` (in the 2026-05-09 amendment above) is renamed to `report.generate_period_report` to conform to `tool_naming_convention_policy` (snake_case throughout). The rename is editorial — the contract signature `({ workflow_run_id, period_snapshot }) → pdf_bytes` is unchanged. Every other tool in the project uses snake_case actions; the camelCase form was a one-off drift caught when the convention sub-doc was being written. Block 15 Phase 04 / 05 / 06 and Block 16 Phase 10 references update to the snake_case form at sub-doc write time.
  - _Affects:_ Blocks 15 (Phases 04, 05, 06), 16 (Phase 10)

### 2026-05-15 — Stage 4 Layer 2 amendments

- **`run_status_enum` extended — `PAUSED` and `COMPENSATING` added** — `PAUSED` materialises the manual-hold state that Block 03 Phase 04's transition graph (`RUNNING ↔ PAUSED ↔ RUNNING`) already specified architecturally; the physical enum previously lacked the value despite `paused_at` / `paused_by_user_id` columns existing on `workflow_runs`. `COMPENSATING` materialises the rollback-in-progress state used by Block 15 Phase 09's failure-handling sequence when the finalization lock encounters a partial-write failure. Both additions are forward-compatible — no existing row needs to change value. `ABORTED` (used informally in Block 03 Phase 04's architecture doc) is treated as synonymous with `CANCELLED` (the locked Layer 1 value); no schema migration is required. Canonical `run_status_enum` is now 10 values: `CREATED · RUNNING · PAUSED · REVIEW_HOLD · AWAITING_APPROVAL · FINALIZING · FINALIZED · FAILED · CANCELLED · COMPENSATING`. Two new audit events added to `audit_event_taxonomy.md`: `WORKFLOW_RUN_COMPENSATING_STARTED`, `WORKFLOW_RUN_COMPENSATING_COMPLETED` (both under the `WORKFLOW` domain).
  - _Affects:_ Blocks 03 (Phases 01, 04), 15 (Phase 09), Layer 1 `workflow_run_schema.md`, Layer 2 `workflow_state_enum.md`, `audit_event_taxonomy.md`

### 2026-05-15 — Gate function naming convention (Stage 4 Layer 2 scan fix)
Gate function names registered in the `gate_function_library` follow the `engine.gate_<phase_descriptor>` pattern — `engine` namespace, 2-part snake_case, consistent with `tool_naming_convention_policy`. The non-allowlisted `gate` prefix and 3-part `gate.<direction>.<descriptor>` convention documented in the initial `gate_function_library_schema.md` draft were incorrect and are superseded by this amendment. All gate names in `gate_function_library_schema.md` have been updated accordingly.

### 2026-05-15 — Step-up token UUID v4 exception (Stage 4 sub-doc fix)

- **Step-up token IDs use UUID v4** — `step_up_tokens.id` uses UUID v4 (via `gen_random_uuid()`), not UUID v7. Rationale: same as password-reset tokens and invitation tokens — step-up tokens are short-lived, unpredictable security tokens where temporal ordering is irrelevant and a time-ordered prefix would leak the approximate creation time to anyone who can read the column. `data_layer_conventions_policy` updated to document this exception in the UUID v4 exceptions table. `step_up_validity_window_policy` corrected from `gen_uuid_v7()` to `gen_random_uuid()`. `workflow_approval_schema` citation to `data_layer_conventions_policy` is now valid.
  - _Affects:_ `data_layer_conventions_policy`, `step_up_validity_window_policy`, `workflow_approval_schema`
