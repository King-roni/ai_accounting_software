# HANDOFF — Cyprus Bookkeeping SaaS Elaboration

**Purpose.** Meta-context for a new session continuing the elaboration work. The project content lives in the workspace docs (read those first); this file explains the working pattern, the conventions, and where we are in the 7-stage roadmap.

If you're a new agent reading this for the first time: spend 5 minutes here, then start with the four canonical files below.

---

## Where we are

**Stage 4 COMPLETE. Stage 5 (Plane Setup) is next. Last session: 2026-05-17.**

| Stage | Status |
| --- | --- |
| 1 — Block Architecture | ✓ Complete |
| 2 — Phase Decomposition (16 blocks × ~10 phases each) | ✓ Complete |
| 3 — Sub-Doc Identification (master scan across all docs) | ✓ Complete (634 locked sub-docs; `outputs/stage3_locked_subdocs.json` is the original artefact — **superseded by the actual `Docs/sub/` corpus (638 files) and the Stage-5 hook map at `/tmp/hook_to_file_matches.json`**) |
| 4 — Sub-Doc Creation | ✓ **Complete** — 637 sub-docs written, 9 scans run, all findings fixed, signed off 2026-05-17 |
| 5 — Plane Setup (project tracking integration) | **Next** |
| 6 — Pre-Build Final Scan | Pending |
| 7 — Build (implementation) | Pending |

---

## Stage 4 completion summary

Stage 4 Layer 1 (93 cross-block foundational sub-docs) was completed in a prior session. Stage 4 Layer 2 (all remaining per-block sub-docs) was completed in the 2026-05-17 session via 8 write cycles (Cycles 12–19), each dispatching 4 parallel agents.

**Final corpus: 637 sub-docs** across `/Docs/sub/` in 9 categories: tools, schemas, policies, runbooks, ui (UI specs), fixtures, guides, reference, integrations.

**Scans run during Stage 4 Layer 2:**

| Scan | Corpus at scan | BLOCKING | HIGH | MED | LOW | Result |
| --- | --- | --- | --- | --- | --- | --- |
| #5 | 413 | 2 | 14 | 31 | 0 | All fixed |
| #6 | 480 | 2 | 26 | 8 | 0 | All fixed |
| #7 | 529 | 0 | 7 | 12 | 1 | All fixed |
| #8 | 606 | 0 | 26 | 18 | 1 | All fixed |
| #9 | 637 | 0 | 0 | 0 | 1 | 1 monitored-only LOW |

The single remaining LOW (S9-004): `SOFT_DUPLICATE` in `deduplication_fingerprint_schema.md` is an intentional conceptual-model mapping label, explicitly annotated in the file. Not an operational enum violation.

**Sign-off file:** `Docs/sub/reference/stage4_signoff.md`

**All invariants clean at sign-off:**
- All 637 files ≥ 140 lines
- No invalid enum values (COMPLETED in run_status, ISSUED on tax invoices, CRITICAL severity, HALF_EVEN rounding, DUPLICATE_POSSIBLE/CONFIRMED dedup values)
- All FK targets use `business_entities(id)` — never `businesses(id)`
- All audit events in tools exist in `reference/audit_event_taxonomy.md`
- All WRITES_AUDIT tools have a `## Mobile` section
- No duplicate DDL across files
- No 3-part gate names
- No stale forward references

---

## The four canonical files (read in this order)

1. **`Docs/elaboration_roadmap.md`** — the 7-stage process. Stages 1–4 are complete; Stage 5 is next.
2. **`Docs/bookkeeping_software_core_plan.md`** — the product. Cyprus-focused private bookkeeping SaaS. Multi-business accounting platform for Owners / Admins / Bookkeepers / Accountants / Reviewers / Read-only roles.
3. **`Docs/outline.md`** — the master navigation hub. Lists every block + every phase doc + the full Scan Log.
4. **`Docs/decisions_log.md`** — every Stage 1 design decision + ~14 Stage 2 amendments that pin cross-block contracts. **Treat the amendments section as binding.**

After those four, the sub-doc corpus is at `Docs/sub/`. The taxonomy is at `Docs/sub/reference/audit_event_taxonomy.md`.

---

## The 16 blocks (one-line summaries)

| # | Block | Owns |
| --- | --- | --- |
| 01 | Core Principles | The 5 design principles every block obeys |
| 02 | Tenancy & Access | Identity, roles, RLS, MFA, step-up auth, permission matrix |
| 03 | Workflow Engine | State machines, gates, tool registration, resumability |
| 04 | Data Architecture | All operational + archive schemas; 5 storage zones; retention |
| 05 | Security & Audit | Encryption, hash-chained audit log, RFC 3161 timestamping |
| 06 | AI Layer | 3-tier routing, Privacy Gateway, plain-language pipeline, End-Scan |
| 07 | Bank Statement Pipeline | Upload, parse (CSV/PDF), normalize, dedup, evidence PDF |
| 08 | Transaction Classification | 12 transaction types, tag system, recurring vendor memory |
| 09 | Document Intake | Email + Drive + manual upload; OCR + extraction |
| 10 | Matching Engine | Score-based matching, 4 levels, split-payment, duplicate detection |
| 11 | Ledger & Cyprus VAT | Type-aware ledger paths, 8 VAT treatments, VIES, reverse charge |
| 12 | OUT Workflow | `OUT_MONTHLY` + `OUT_ADJUSTMENT` workflow definitions |
| 13 | IN Workflow + Invoice Generator | Invoice CRUD + lifecycle + IN_MONTHLY workflow |
| 14 | Review Queue | 5 actionable buckets, severity, 13 resolution actions, snooze |
| 15 | Finalization & Secure Archive | 8-step lock sequence, 3-layer immutability, manifest versioning |
| 16 | Dashboard & Reporting | UI design system, 11 cards, 13 exports, accountant pack |

---

## Stage 5 — Plane Setup

**Plane** is the project-management tool (plane.so — similar to Linear). The goal is to translate the locked specification into actionable build units inside Plane, sequenced in strict chronological build order.

### What Stage 5 produces

- One **module per block** (16 modules) in a Plane project
- One **issue per phase** under its module (~165 phase docs → ~165 issues)
- One **sub-issue / task per sub-doc deliverable** (~637 sub-docs → ~637 tasks)
- Everything **sequenced chronologically end-to-end** — no issue should be openable before its upstream dependencies are marked done

### Approach

The sequencing is the hard part. The blocks have a natural build order that mirrors the dependency graph:

1. Block 01 (Core Principles — cross-cutting, first)
2. Block 02 (Tenancy & Access — identity must exist before anything else)
3. Block 04 (Data Architecture — schemas before tools that use them)
4. Block 05 (Security & Audit — audit infra before any feature emits events)
5. Block 03 (Workflow Engine — engine before workflows)
6. Block 06 (AI Layer — AI before classifiers)
7. Block 07 (Bank Statement Pipeline)
8. Block 08 (Transaction Classification)
9. Block 09 (Document Intake)
10. Block 10 (Matching Engine)
11. Block 11 (Ledger & Cyprus VAT)
12. Block 12 (OUT Workflow)
13. Block 13 (IN Workflow + Invoice Generator)
14. Block 14 (Review Queue)
15. Block 15 (Finalization & Secure Archive)
16. Block 16 (Dashboard & Reporting — last, depends on everything)

Within each block, phases are already in chronological build order (Phase 01 → Phase NN). Sub-docs within a phase share the phase's position.

### Plane MCP

There is a Plane MCP available in this workspace (check `mcp__pejo__*` tools — "pejo" is the Plane integration). Before writing any issues, verify the MCP is connected and check what workspace/project exists. The key tools are:
- `pejo__workspace_get` — confirm connection
- `pejo__pipeline_list_stages` — see existing stages
- `pejo__scope_create` — create a module/epic
- `pejo__task_create` — create an issue/task

Read the tool schemas carefully before using — parameter names may differ from Linear conventions.

---

## Hard conventions (non-negotiable — carry into Stages 5–7)

1. **Audit-event naming:** `DOMAIN_PAST_VERB` — e.g., `MATCHING_AUTO_CONFIRMED`, `LEDGER_VAT_TREATMENT_DECIDED`. Past tense, single domain prefix.
2. **Severity enum:** `{LOW, MEDIUM, HIGH, BLOCKING}` — exactly four values. No `CRITICAL`.
3. **run_status_enum:** `CREATED · RUNNING · PAUSED · REVIEW_HOLD · AWAITING_APPROVAL · FINALIZING · FINALIZED · FAILED · CANCELLED · COMPENSATING` — never `COMPLETED`.
4. **invoice_status (tax invoices):** `DRAFT, SENT, PARTIALLY_PAID, PAID, OVERDUE, VOID` — never `ISSUED` (ISSUED is only for `credit_note_status_enum` and `pro_forma_invoices.status`).
5. **dedup_status_enum:** `NEW, DUPLICATE_EXACT, DUPLICATE_PROBABLE, NEEDS_REVIEW` — never DUPLICATE_POSSIBLE/CONFIRMED/UNIQUE.
6. **match_level_enum:** `EXACT, STRONG_PROBABLE, WEAK_POSSIBLE, NO_MATCH`.
7. **PK pattern:** `gen_uuid_v7()` on all business PKs. Exceptions (use `gen_random_uuid()`): session IDs, invitation tokens, password reset tokens, step-up MFA tokens, OAuth state IDs.
8. **FK target:** `REFERENCES business_entities(id)` always — never `REFERENCES businesses(id)`.
9. **Rounding:** `HALF_UP` for all monetary arithmetic — never HALF_EVEN (Cyprus VAT Act requirement).
10. **Mobile writes:** All WRITES_RUN_STATE / WRITES_AUDIT tools reject mobile writes. `client_form_factor = MOBILE` → reject.
11. **Gate names:** `engine.gate_<phase_descriptor>` — 2-part only, never 3-part.
12. **Namespace allowlist (14):** `auth, engine, data, security, ai, intake, classification, matching, ledger, out_workflow, in_workflow, review_queue, archive, report`.
13. **Closed enums:** don't extend without a decisions-log amendment.

---

## Quality bar

**Stripe / Linear / Mercury / Pleo polish** throughout. This is a serious financial/compliance product for a Cyprus-based one-person operator. Dense, trust-conveying, clean. No AI purple/pink gradients, no playful design, no emojis as icons, no removing focus rings.

---

## What NOT to do

- Don't rewrite existing phase docs or sub-docs unless a scan finding requires it.
- Don't propose alternative architectures — Stage 1's 16-block split is locked.
- Don't extend closed enums without a decisions-log amendment.
- Don't propose new tech stack choices without checking Stage 1 foundation decisions (Supabase + Postgres + EU regions; Anthropic Claude EU/zero-retention for Tier 3; locally-operated machine for Tier 2; etc.).

---

## Key output files (reference)

| File | What it is |
| --- | --- |
| `Docs/sub/reference/audit_event_taxonomy.md` | Canonical list of all audit events — grouped by domain |
| `Docs/sub/reference/stage4_signoff.md` | Stage 4 sign-off record with scan history |
| `outputs/stage3_locked_subdocs.json` | Original Stage 3 locked sub-doc list (634 entries) — **not present in repo; superseded by `Docs/sub/` (638 files) + hook map** |
| `outputs/stage4_layer2_scan9_findings.json` | Final scan findings (clean) |
| `outputs/stage4_layer2_signoff.md` | Stage 4 sign-off summary |

---

**Last session sign-off: 2026-05-17. Stages 1–4 complete. Stage 5 (Plane Setup) is next.**
