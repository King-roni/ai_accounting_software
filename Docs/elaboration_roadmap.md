# Elaboration Roadmap — Cyprus Bookkeeping Software

## Purpose

This roadmap controls the elaboration phase: turning the core concept document into a complete, build-ready specification. Each stage produces specific artifacts and ends with a scan that must pass before the next stage starts. Nothing moves forward with open inconsistencies.

Guiding principle: **elaborate the docs the same way the product works — controlled gates, deterministic checks, no silent advancement.**

---

## Stage 1 — Block Architecture ✓

Decompose the core concept into its major blocks (workflows, infrastructure, security, AI layer, etc.) and produce one architecture document per block.

- [x] Identify and list all blocks from the core concept doc
- [x] Create one architecture file per block (`/Docs/blocks/<block-name>.md`)
- [x] Cross-block compatibility scan — every block knows what it gives to and receives from other blocks
- [x] Fix all inconsistencies found in the scan
- [x] Stage 1 sign-off

---

## Stage 2 — Phase Decomposition (per block, sequential) ✓

Break each block into chronological build phases. Done block-by-block — finish one block completely (including its scan) before starting the next.

For each block, in order:

- [x] List all phases in chronological build order
- [x] Create one file per phase (`/Docs/phases/<block>/<NN>-<phase-name>.md`)
- [x] Run full scan over this block's phases — internal order, dependencies, gaps
- [x] Fix every bug/inconsistency found
- [x] Block sign-off, then move to next block

- [x] **Stage 2 sign-off (all 15 backend / domain / workflow / UX blocks fully phase-decomposed; 14 per-block scans signed off; ~14 cross-block decisions-log amendments captured) — 2026-05-09**

---

## Stage 3 — Sub-Doc Identification (one master scan) ✓

Before writing any sub-docs, do ONE comprehensive scan across every architecture file and phase file to find every place a sub-doc is needed — LLM-callable tools, parsers, schemas, prompt specs, integration contracts, etc.

- [x] Master scan complete — full list of required sub-docs produced
- [x] Sub-docs categorized (tools, schemas, prompts, integrations, etc.)
- [x] Sub-doc list locked
- [x] Stage 3 sign-off (634 locked sub-docs across 9 categories; output `outputs/stage3_locked_subdocs.json`; Scan Log entry in `Docs/outline.md` — 2026-05-09)

---

## Stage 4 — Sub-Doc Creation ✓

Write every sub-doc on the locked list, sequentially. These are not uniform like the architecture/phase docs — each is shaped to its specific subject.

- [x] Create each sub-doc (`/Docs/sub/<category>/<name>.md`)
- [x] Final compatibility scan after all sub-docs are written
- [x] Fix every gap, contradiction, or unresolved reference
- [x] Stage 4 sign-off (documentation set is build-ready)

- [x] **Stage 4 sign-off (637 sub-docs written across 9 categories; 9 cross-corpus scans run; 0 BLOCKING / 0 HIGH / 0 MEDIUM violations at sign-off; sign-off record at `Docs/sub/reference/stage4_signoff.md`) — 2026-05-17**

---

## Stage 5 — Plane Setup ✓

Translate the locked specification into actionable units inside Plane, in strict chronological build order. **Order is the critical piece here.**

- [x] Decide module structure in Plane (mirroring blocks)
- [x] Create modules
- [x] Create issues for each phase under its module
- [x] Create tasks/sub-issues for each sub-doc deliverable
- [x] Sequence everything chronologically end-to-end
- [x] **Stage 5 sign-off (16 modules + 160 phase issues + 721 sub-doc child issues = 897 Plane work-items in project `BOOK` / Cyprus Bookkeeping SaaS; all child issues description-enriched with phase-doc + sub-doc spec file paths in Pass 3b; 4 Stage-6 follow-ups captured in Scan Log) — 2026-05-18**

---

## Stage 6 — Pre-Build Final Scan ✓

One last pass before code is written. Walk the Plane backlog top-to-bottom and verify every item maps cleanly to a finished spec.

- [x] Every Plane item traced back to a locked spec
- [x] All last-minute inconsistencies resolved
- [x] **Stage 6 sign-off (5 parallel scanning agents + 2 fix agents + main-thread reconciliation; 0 BLOCKING outstanding; 16 audit events added to canonical taxonomy, 4 renamed; 5 dangling refs fixed + 8 flagged for Stage-7 incremental fill; 15 tool-name prefix violations renamed across 8 files; banker's-rounding → HALF_UP in B11 P08; 721 child issues attached to Plane modules; ~25 spec files edited; full findings in `Docs/outline.md` Scan Log) — 2026-05-18**

---

## Stage 7 — Build

Implementation starts. Specs are locked; changes require a documented amendment.

- [ ] Build phase begins

---

## Working Rules

- No stage advances until its checkboxes are fully ticked.
- Every scan produces a short written summary: what was checked, what was found, what was fixed.
- Inconsistencies are fixed at the stage where they're discovered — never deferred.
- This roadmap is the living checklist; keep it updated as we move.
