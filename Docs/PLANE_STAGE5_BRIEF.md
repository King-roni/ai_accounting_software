# Stage 5 — Plane Setup: Claude Code Execution Brief

**For:** Claude Code (CLI)  
**Purpose:** Execute Stage 5 of the Cyprus Bookkeeping SaaS elaboration — translate the locked specification into actionable build units inside the self-hosted Plane workspace.  
**Last updated:** 2026-05-18  
**Prerequisite:** Stages 1–4 are complete. 637 sub-docs written, all scans clean, Stage 4 signed off 2026-05-17.

---

## 0. Before you start — orientation checklist

1. Confirm your Plane MCP tools are available. Look for tools with a `plane` prefix (or similar — the exact prefix depends on how the MCP was registered in your Claude Code config). Key capabilities you need: create project, create module/cycle/label, create issue, create sub-issue or child issue.
2. Confirm the target Plane workspace URL. The user's self-hosted Plane instance is at **timefuser.plane.so** (or equivalent — confirm with the user if unsure).
3. Do NOT create anything in Plane until you have confirmed MCP connectivity by listing existing projects or workspaces.
4. Read `Docs/HANDOFF.md` for full project context before proceeding.

---

## 1. What Stage 5 must produce

| Plane object | Count | Maps to |
|---|---|---|
| **Project** | 1 | The Cyprus Bookkeeping SaaS build |
| **Module** | 16 | One per block (see Section 3) |
| **Issue** | ~165 | One per phase doc, under its module |
| **Sub-issue / child task** | ~637 | One per sub-doc deliverable, under its phase issue |

**Order is the critical constraint.** Everything must be sequenced in strict chronological build order — no issue should be start-able before its upstream dependencies are done. The ordering is already defined by: (a) the block build order in Section 2, and (b) the phase number within each block (Phase 01 always before Phase 02, etc.).

---

## 2. Block build order (strict — do not change)

Create modules and populate issues in this exact sequence. The order is determined by the dependency graph: identity before everything, schemas before tools, audit infra before features emit events, engine before workflows, AI before classifiers.

| Build position | Block # | Module name |
|---|---|---|
| 1 | 01 | Core Principles & Design Constraints |
| 2 | 02 | Tenancy & Access Control |
| 3 | 04 | Data Architecture & Storage Zones |
| 4 | 05 | Security & Audit Layer |
| 5 | 03 | Workflow Engine |
| 6 | 06 | AI Layer |
| 7 | 07 | Bank Statement Pipeline |
| 8 | 08 | Transaction Classification & Tagging |
| 9 | 09 | Document Intake & Extraction |
| 10 | 10 | Matching Engine |
| 11 | 11 | Ledger & Cyprus VAT Engine |
| 12 | 12 | OUT / Write-Off Workflow |
| 13 | 13 | IN / Income Workflow + Invoice Generator |
| 14 | 14 | Review Queue & Human Review |
| 15 | 15 | Finalization & Secure Archive |
| 16 | 16 | Dashboard & Reporting |

> Note: Block 03 (Workflow Engine) is built AFTER Block 04 (Data Architecture) and Block 05 (Security & Audit) even though it is numbered 03. The block numbers are identifiers, not build order.

---

## 3. Complete phase inventory (issues to create per module)

Create one issue per phase, in phase number order, under the module for that block. The issue title should follow the pattern: `[B{block}·P{phase}] {phase name}`.

For example: `[B02·P01] Schema Scaffolding`

### Module 1 — Block 01: Core Principles & Design Constraints
Phase docs are at: `Docs/phases/01_core_principles/`

> **Action:** List the actual files in that directory. If no phase files exist, create a single issue titled `[B01·P00] Design Constraints & Principles Reference` pointing to `Docs/blocks/01_core_principles.md`. Block 01 is the constitution document — it may have no separate phases.

### Module 2 — Block 02: Tenancy & Access Control
Phase docs at: `Docs/phases/02_tenancy_and_access/`

| Issue | Title |
|---|---|
| B02·P01 | Schema Scaffolding |
| B02·P02 | Authentication Baseline |
| B02·P03 | Multi-Factor Authentication |
| B02·P04 | Role Model & Permission Matrix |
| B02·P05 | Row-Level Security Policies |
| B02·P06 | Step-Up Authentication |
| B02·P07 | User Invitation & Management |
| B02·P08 | OAuth Integration Foundation |
| B02·P09 | Role Change Propagation |
| B02·P10 | Tenant Isolation Invariant Tests |
| B02·P11 | Account Settings |

### Module 3 — Block 04: Data Architecture & Storage Zones
Phase docs at: `Docs/phases/04_data_architecture/`

| Issue | Title |
|---|---|
| B04·P01 | Hashing & ID Utilities |
| B04·P02 | Bank Statement & Transaction Schema |
| B04·P03 | Document & Matching Schema |
| B04·P04 | Ledger & Review Schema |
| B04·P05 | Raw Upload Zone |
| B04·P06 | Processing Zone |
| B04·P07 | Finalized Secure Archive Zone |
| B04·P08 | Zone Promotion Pipeline |
| B04·P09 | Analytics Zone |
| B04·P10 | Retention Engine |
| B04·P11 | Legal Hold |

### Module 4 — Block 05: Security & Audit Layer
Phase docs at: `Docs/phases/05_security_and_audit/`

| Issue | Title |
|---|---|
| B05·P01 | TLS & At-Rest Encryption Baseline |
| B05·P02 | Audit Log Schema & Emission API |
| B05·P03 | Audit Log Tamper Resistance |
| B05·P04 | Vault Setup & DEK Hierarchy |
| B05·P05 | pgcrypto Field-Level Encryption |
| B05·P06 | Access Control Runtime |
| B05·P07 | Secrets Management |
| B05·P08 | Backup Encryption & DR |
| B05·P09 | GDPR Data Subject Rights |
| B05·P10 | Security Alerting (Internal) |

### Module 5 — Block 03: Workflow Engine
Phase docs at: `Docs/phases/03_workflow_engine/`

| Issue | Title |
|---|---|
| B03·P01 | Workflow Run Schema |
| B03·P02 | Workflow Type Registry & Per-Business Config |
| B03·P03 | Tool Registration Framework |
| B03·P04 | State Machine & Lifecycle Controls |
| B03·P05 | Gate Evaluation Framework |
| B03·P06 | Phase Execution Engine |
| B03·P07 | Resumability & Idempotency |
| B03·P08 | Failure Policy & Retry |
| B03·P09 | Trigger Engine |
| B03·P10 | Concurrency Control |
| B03·P11 | Adjustment Runs |

### Module 6 — Block 06: AI Layer
Phase docs at: `Docs/phases/06_ai_layer/`

| Issue | Title |
|---|---|
| B06·P01 | Tier Classification & Routing |
| B06·P02 | Privacy Gateway Pipeline |
| B06·P03 | Redaction Policy & Engine |
| B06·P04 | Prompt Management |
| B06·P05 | Tier 3 (Anthropic Claude) Integration |
| B06·P06 | Tier 2 (Local LLM) Integration |
| B06·P07 | AI Usage Logging & Cost Tracking |
| B06·P08 | Cost Ceiling Enforcement |
| B06·P09 | AI Cache (Within Run) |
| B06·P10 | Plain-Language Pipeline |
| B06·P11 | End-Scan Engine |

### Module 7 — Block 07: Bank Statement Pipeline
Phase docs at: `Docs/phases/07_bank_statement_pipeline/`

| Issue | Title |
|---|---|
| B07·P01 | Upload Pipeline & File Intake |
| B07·P02 | CSV Parser & Revolut Format |
| B07·P03 | PDF Parser via Google Document AI |
| B07·P04 | Row Normalization |
| B07·P05 | Deduplication Engine |
| B07·P06 | Evidence PDF Generation |
| B07·P07 | INGESTION Workflow Phase Registration |
| B07·P08 | Partial Upload Handling & Period Validation |
| B07·P09 | Event-Driven Workflow Trigger |
| B07·P10 | End-to-End Pipeline Tests |

### Module 8 — Block 08: Transaction Classification & Tagging
Phase docs at: `Docs/phases/08_transaction_classification_and_tagging/`

| Issue | Title |
|---|---|
| B08·P01 | Schema for Classification & Tagging |
| B08·P02 | Type Classifier Layer 1 (Deterministic Rules) |
| B08·P03 | Recurring Vendor Memory Layer 2 |
| B08·P04 | AI Fallback Classifier Layer 3 |
| B08·P05 | Tag System & Default Taxonomy |
| B08·P06 | Per-Business Custom Tags |
| B08·P07 | Confidence Scoring & Auto-Confirm |
| B08·P08 | Tag Taxonomy Versioning |
| B08·P09 | CLASSIFICATION Workflow Phase Registration |
| B08·P10 | End-to-End Classifier Tests |

### Module 9 — Block 09: Document Intake & Extraction
Phase docs at: `Docs/phases/09_document_intake_and_extraction/`

| Issue | Title |
|---|---|
| B09·P01 | Schema for Documents & Source Mappings |
| B09·P02 | Document Lifecycle State Machine |
| B09·P03 | OCR Pipeline |
| B09·P04 | Field Extraction (Deterministic + AI Fallback) |
| B09·P05 | Email Finder (Gmail) |
| B09·P06 | Drive Finder |
| B09·P07 | Manual Upload Path |
| B09·P08 | Cross-Source Document Deduplication |
| B09·P09 | EVIDENCE_DISCOVERY Workflow Phase Registration |
| B09·P10 | End-to-End Intake Tests |

### Module 10 — Block 10: Matching Engine
Phase docs at: `Docs/phases/10_matching_engine/`

| Issue | Title |
|---|---|
| B10·P01 | Schema for Matching |
| B10·P02 | Match Scoring Engine |
| B10·P03 | Strong Probable Auto-Confirm Rule |
| B10·P04 | Split-Payment Combinatorial Detection |
| B10·P05 | Duplicate Detection |
| B10·P06 | Rejection Memory |
| B10·P07 | Match Reason Generation |
| B10·P08 | Income Matching Variant |
| B10·P09 | MATCHING + INCOME_MATCHING Workflow Phase Registration |
| B10·P10 | End-to-End Matching Tests |

### Module 11 — Block 11: Ledger & Cyprus VAT Engine
Phase docs at: `Docs/phases/11_ledger_and_cyprus_vat_engine/`

| Issue | Title |
|---|---|
| B11·P01 | Schema for Ledger Entries & Chart of Accounts |
| B11·P02 | Default Cyprus-Friendly Chart of Accounts |
| B11·P03 | Per-Business Chart Customization & Versioning |
| B11·P04 | Counterparty Country & VAT Number Resolution |
| B11·P05 | VAT Treatment Classifier |
| B11·P06 | Reverse Charge & VIES Relevance |
| B11·P07 | Type-Aware Ledger Preparation Paths |
| B11·P08 | VAT Amount, Evidence & Accountant-Review Flags |
| B11·P09 | LEDGER_PREPARATION Workflow Phase Registration |
| B11·P10 | End-to-End Ledger Tests |

### Module 12 — Block 12: OUT / Write-Off Workflow
Phase docs at: `Docs/phases/12_out_workflow/`

| Issue | Title |
|---|---|
| B12·P01 | Schema & Per-Business OUT Config |
| B12·P02 | OUT_MONTHLY Workflow Type Definition |
| B12·P03 | OUT_FILTER Phase |
| B12·P04 | OUT/IN Parallel Coordination |
| B12·P05 | Gate-Function Library |
| B12·P06 | MANUAL_UPLOAD_HOLD Phase |
| B12·P07 | HUMAN_REVIEW_HOLD Phase |
| B12·P08 | Triggers — Manual + Event |
| B12·P09 | OUT_ADJUSTMENT Workflow Type |
| B12·P10 | End-to-End OUT Workflow Tests |

### Module 13 — Block 13: IN / Income Workflow + Invoice Generator
Phase docs at: `Docs/phases/13_in_workflow_and_invoice_generator/`

| Issue | Title |
|---|---|
| B13·P01 | Invoice Schema & Numbering |
| B13·P02 | Client Database |
| B13·P03 | Invoice Composition & Lifecycle State Machine |
| B13·P04 | PDF Rendering & VAT-Aware Text |
| B13·P05 | Recurring Templates & Daily Scheduler |
| B13·P06 | Pro-Forma Conversion, Credit Notes & Write-Off |
| B13·P07 | IN_MONTHLY Workflow Type Definition |
| B13·P08 | IN_FILTER Phase |
| B13·P09 | IN Gate Library + HUMAN_REVIEW_HOLD |
| B13·P10 | Income Matching Integration & Multi-Invoice Allocation |
| B13·P11 | IN_ADJUSTMENT Workflow Type |
| B13·P12 | End-to-End IN Workflow & Invoice Generator Tests |

### Module 14 — Block 14: Review Queue & Human Review
Phase docs at: `Docs/phases/14_review_queue/`

| Issue | Title |
|---|---|
| B14·P01 | Schema Extensions for review_issues |
| B14·P02 | Issue Groups, Routing & Severity |
| B14·P03 | Issue Card Rendering & Plain-Language |
| B14·P04 | Resolution Actions |
| B14·P05 | Bulk Actions |
| B14·P06 | Notes & Assignment |
| B14·P07 | Snooze & Cross-Run Carry-Forward |
| B14·P08 | Re-Scan on Resolution |
| B14·P09 | Mobile Read-Only UX |
| B14·P10 | End-to-End Review Queue Tests |

### Module 15 — Block 15: Finalization & Secure Archive
Phase docs at: `Docs/phases/15_finalization_and_secure_archive/`

| Issue | Title |
|---|---|
| B15·P01 | Schema for Archive Package & Locked Ledger |
| B15·P02 | Finalization Preconditions & Gates |
| B15·P03 | Approval Modality & Step-Up Auth |
| B15·P04 | The Lock Sequence |
| B15·P05 | Archive Package Construction |
| B15·P06 | Manifest Versioning for Adjustments |
| B15·P07 | Storage Object Lock & Three-Layer Immutability |
| B15·P08 | Re-Finalization for Adjustment Runs |
| B15·P09 | Failure Handling & Rollback |
| B15·P10 | End-to-End Finalization Tests |

### Module 16 — Block 16: Dashboard & Reporting
Phase docs at: `Docs/phases/16_dashboard_and_reporting/`

| Issue | Title |
|---|---|
| B16·P01 | Schema, Preferences & Analytics Consumption |
| B16·P02 | Drill-Down Routing & Permissions |
| B16·P03 | Design System MASTER |
| B16·P04 | Component Library |
| B16·P05 | Dashboard Shell |
| B16·P06 | Default Dashboard Cards |
| B16·P07 | Multi-Business View, Refresh State & Customization |
| B16·P08 | Drill-Down List & Detail Views |
| B16·P09 | Export Pipelines & Format Dispatcher |
| B16·P10 | PDF Generators |
| B16·P11 | Accountant Pack & VIES Regulator XML |
| B16·P12 | Accessibility, i18n, Mobile Read-Only, Performance |
| B16·P13 | End-to-End Tests & Visual Regression |

---

## 4. Sub-doc tasks (child issues under each phase issue)

Each phase issue gets child tasks — one per sub-doc that belongs to that phase.

### How to discover sub-docs per phase

The sub-docs live at `Docs/sub/` in 9 category folders:
- `tools/` — LLM-callable tool specs
- `schemas/` — database schema sub-docs
- `policies/` — decision policy docs
- `runbooks/` — operational runbooks
- `ui/` — UI/UX specs
- `fixtures/` — test fixture corpora
- `guides/` — developer guides
- `reference/` — canonical reference docs (taxonomies, enums)
- `integrations/` — external API contracts

**Method:** For each phase issue you create, scan the corresponding phase doc (`Docs/phases/<block>/<NN>_<name>.md`) and look for its `## Sub-doc Hooks (Stage 4)` section — this lists the exact sub-docs that belong to that phase. Then confirm the file exists under `Docs/sub/<category>/<name>.md`.

You can also use the locked sub-doc list at `outputs/stage3_locked_subdocs.json` (634 base entries) — each entry has an `owning_block` field and most have a `phases` or `source_citations` field that ties it to specific phases.

### Sub-doc task naming convention

`[B{block}·P{phase}·SD] {sub-doc name}` — for example:
- `[B02·P01·SD] auth_schema`
- `[B05·P02·SD] audit_log_emission_api`
- `[B06·P03·SD] redaction_policies`

### Cross-block sub-docs

Some sub-docs are cross-block (they serve multiple blocks). Place these as child tasks under the **earliest phase that consumes them**. The `co_owning_blocks` field in `stage3_locked_subdocs.json` lists the secondary owners. Examples of key cross-block sub-docs:
- `audit_event_taxonomy` → place under B05·P02 (Audit Log Schema)
- `permission_matrix` → place under B02·P04 (Role Model & Permission Matrix)
- `tool_naming_convention_policy` → place under B03·P03 (Tool Registration Framework)
- `data_layer_conventions_policy` → place under B04·P01 (Hashing & ID Utilities)

---

## 5. Issue descriptions

Each issue (phase) should have a description that includes:
1. One-line summary of what the phase builds
2. Link to the spec file: `Docs/phases/<block>/<file>.md`
3. Number of sub-doc tasks attached

Example description for B02·P01:
```
Builds the foundational Postgres schema: organizations, business_entities, users, bank_accounts, and the key constraint that every row is isolated by organization_id + business_id.

Spec: Docs/phases/02_tenancy_and_access/01_schema_scaffolding.md
Sub-docs: ~8 tasks attached
```

---

## 6. Project and module metadata

### Project
- **Name:** Cyprus Bookkeeping SaaS
- **Identifier:** BOOK (or whatever Plane auto-assigns)
- **Description:** Build tracker for the Cyprus-focused private bookkeeping SaaS. Stages 1–4 (specification) complete. Stage 5+ is implementation.
- **Network:** Secret (internal only)

### Module metadata (apply to each)
Each module description should include:
- Block number and one-line scope summary (copy from Section 3 headers above)
- Reference to the block architecture doc: `Docs/blocks/<NN>_<name>.md`
- Phase count and sub-doc count (you can estimate from the tables above)

---

## 7. Execution strategy — recommended approach

Given the volume (16 modules, ~165 issues, ~637 tasks), run this in batches to avoid hitting API rate limits or context limits:

### Pass 1 — Create the project and all 16 modules (sequential, in build order)
Create all 16 modules before creating any issues. This lets you reference module IDs when creating issues.

### Pass 2 — Create phase issues, 4 modules at a time
Work in groups of 4 modules. For each group:
1. Create all issues for those 4 modules
2. Verify they were created correctly before moving on

Suggested groups:
- Group A: Modules 1–4 (B01, B02, B04, B05)
- Group B: Modules 5–8 (B03, B06, B07, B08)
- Group C: Modules 9–12 (B09, B10, B11, B12)
- Group D: Modules 13–16 (B13, B14, B15, B16)

### Pass 3 — Create sub-doc tasks
For each phase issue, read the phase doc's `## Sub-doc Hooks (Stage 4)` section and create child tasks. Work block by block.

### Pass 4 — Verify and sign off
- Confirm module count = 16
- Confirm issue count ≈ 165
- Confirm task count ≈ 637
- Update `Docs/elaboration_roadmap.md` Stage 5 checkboxes to ticked
- Add a Stage 5 section to `Docs/outline.md` mapping blocks → Plane module IDs and phases → issue IDs

---

## 8. Hard conventions to carry into every title and description

These are non-negotiable — they appear in docs and must stay consistent in Plane:

| Convention | Value |
|---|---|
| Severity enum | `LOW · MEDIUM · HIGH · BLOCKING` — never CRITICAL |
| run_status enum | `CREATED · RUNNING · PAUSED · REVIEW_HOLD · AWAITING_APPROVAL · FINALIZING · FINALIZED · FAILED · CANCELLED · COMPENSATING` — never COMPLETED |
| invoice_status | `DRAFT · SENT · PARTIALLY_PAID · PAID · OVERDUE · VOID` — never ISSUED |
| dedup_status | `NEW · DUPLICATE_EXACT · DUPLICATE_PROBABLE · NEEDS_REVIEW` |
| match_level | `EXACT · STRONG_PROBABLE · WEAK_POSSIBLE · NO_MATCH` |
| PK pattern | `gen_uuid_v7()` on business PKs |
| FK target | `business_entities(id)` never `businesses(id)` |
| Rounding | `HALF_UP` always |
| Gate names | `engine.gate_<phase_descriptor>` — 2-part only |
| Audit events | `DOMAIN_PAST_VERB` pattern |

---

## 9. Reference files

| File | Purpose |
|---|---|
| `Docs/HANDOFF.md` | Full project meta-context — read first |
| `Docs/elaboration_roadmap.md` | 7-stage checklist — update Stage 5 when done |
| `Docs/outline.md` | Master navigation hub — add Plane mapping at end |
| `Docs/decisions_log.md` | All locked design decisions — treat as binding |
| `Docs/sub/reference/audit_event_taxonomy.md` | Canonical audit event list |
| `Docs/sub/reference/stage4_signoff.md` | Stage 4 sign-off record |
| `outputs/stage3_locked_subdocs.json` | Full 634-entry sub-doc list with owning_block |
| `outputs/stage4_layer2_signoff.md` | Stage 4 Layer 2 sign-off summary |

---

## 10. Stage 5 sign-off criteria

Stage 5 is complete when:
- [ ] Plane project "Cyprus Bookkeeping SaaS" exists
- [ ] 16 modules created in chronological build order
- [ ] ~165 phase issues created, each under its correct module
- [ ] ~637 sub-doc tasks created as child issues under their phase
- [ ] `Docs/elaboration_roadmap.md` Stage 5 checkboxes all ticked
- [ ] `Docs/outline.md` updated with Plane module/issue ID mapping
- [ ] Brief written summary added to `Docs/outline.md` Scan Log section: what was created, final counts

---

**Stage 6 (Pre-Build Final Scan) follows immediately after Stage 5 sign-off.**
