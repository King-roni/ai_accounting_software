# Session start prompt — paste this into a fresh Claude session

(Copy everything between the `---` lines and paste as your first message in the new session.)

---

You're picking up the **Cyprus Bookkeeping SaaS** project (multi-tenant accounting platform, Cyprus VAT, accountant pack, finalization archive). We're mid-**Stage 3** — the sub-doc backlog walk. Prior session ended 2026-05-28 with **15 Plane cycles created** and **48 of 880 tickets closed**.

## Your first move (do these in parallel, single message)

1. `mempalace_status` — palace overview + protocol
2. `mempalace_get_drawer(drawer_id="drawer_cyprus_bookkeeping_project-meta_3425d21389e8094e778df48c")` — canonical "where am I" drawer
3. `Read("/Users/pep_o23kd/Desktop/Cursor/Personal/boekhoudings_Ai_software/Docs/handoff/2026-05-28_session_handoff_cycles_provisioned.md")` — full session-handoff doc (REQUIRED — do not skip)
4. `mcp__plane__retrieve_cycle(project_id="28b250c0-d991-4dcb-a48c-51af27aa17dd", cycle_id="381c73b1-4d67-42bb-8d01-5ac691218f76")` — Cycle B02 (the in-flight one; 15 backlog tickets to finish)

## Project facts you must know

- **Repo root:** `/Users/pep_o23kd/Desktop/Cursor/Personal/boekhoudings_Ai_software`
- **Supabase project:** `noxvmnxrqlzsdfngfiww` (EU eu-west-1)
- **Plane project:** `BOOK` · `project_id = 28b250c0-d991-4dcb-a48c-51af27aa17dd`
- **Plane states:** Backlog `06b2fd3b-5d0c-486a-9a37-fe086b725315` · In Progress `d349cb35-77f8-45f8-bbf7-98b6fbf39329` · Done `6e8dcd01-8ef8-4f8f-a3c4-99e73bb5ec98`

## Plane cycles (UUIDs — also in KG triples)

| Cycle | Block | Cycle UUID | Backlog (start) |
|---|---|---|---|
| **B02 · Tenancy & Access** | 02 | `381c73b1-4d67-42bb-8d01-5ac691218f76` | **15** (in-flight) |
| B03 · Workflow Engine | 03 | `430809b2-3204-4401-8bf9-833c7e2de000` | 43 |
| B04 · Data Architecture | 04 | `1de935db-12b4-4eb9-aa0b-4731cdf56725` | 54 |
| B05 · Security & Audit | 05 | `14cf9a0f-24d0-4c60-9883-c3e363c3d6c6` | 47 |
| B06 · AI Layer | 06 | `c1dc65f4-8cd8-479c-90a0-e7234af73147` | 47 |
| B07 · Bank Statement Pipeline | 07 | `8c9854e0-48d8-4b15-a75a-99abae48b994` | 44 |
| B08 · Classification & Tagging | 08 | `4138ad1c-e8a6-4b79-bb7c-9be6b3f59fdb` | 38 |
| B09 · Document Intake & Extraction | 09 | `34fe7710-0ff4-4b06-8023-76d7061d0857` | 39 |
| **B10 · Matching Engine** | 10 | `2b0d88ce-3bf2-4e9c-b9fe-91d91fe08985` | **12** (in-flight) |
| B11 · Ledger & Cyprus VAT Engine | 11 | `a6fb501c-8ff3-4754-991a-e9839d636f0a` | 43 |
| B12 · OUT Workflow | 12 | `ac437187-e9df-4725-8a2b-10b66b6ee189` | 43 |
| B13 · IN Workflow + Invoice Generator | 13 | `91c1c6ba-2a2a-4ca3-83e2-0dd0406e26a0` | 52 |
| B14 · Review Queue & Human Review | 14 | `174814ff-75bf-4d92-aafa-0405d84c31a9` | 54 |
| B15 · Finalization & Secure Archive | 15 | `f07310c0-7e1e-4142-93b9-5eaed044a8fd` | 52 |
| B16 · Dashboard & Reporting | 16 | `d06a5244-c620-4a18-ab6c-bdea26766ee9` | 87 |

**Execution order:** B02 → B10 → B03 → B04 → B05 → B06 → B07 → B08 → B09 → B11 → B12 → B13 → B14 → B15 → B16 → Cycle-16 reconciliation.

## Cadence — adaptive batching

| Ticket type | Per-turn cadence |
|---|---|
| **Easy verify-only** (clear canonical doc + hook matches) | 5-10 per turn, batched; one-line DoD comments |
| **Verify-only with drift** | 3-5 per turn, terser comments |
| **Routine write-required** (derivative pattern) | Write directly, ~120 lines / 8-10 sections, NO propose-wait |
| **Novel write-required** (new mechanism / anchor doc) | Keep propose-wait, ~180 lines / 10 sections max |

## Cross-reference discipline — LOAD-BEARING, never cut

The user's binding rule: *"if we build A and after 2 weeks B is also done, but then A doesn't work because you didn't listen to the cross reference, everything will break."*

1. Every new sub-doc ends with a Cross-references section (5-15 entries — the actual dependencies).
2. New audit event / column / RPC / migration → flag in DoD comment as **"Cross-block coordination flagged for B##·P## implementation"** + file a KG triple.
3. Anchor docs (e.g., BOOK-198 dedup-pattern-ownership-map, BOOK-208 GCP setup) get FULL scope. Routine derivative docs get tighter scope but KEEP complete cross-refs.
4. Drift items captured per-ticket via KG triples + DoD comments — they feed Cycle-16 reconciliation.
5. Per-cycle wrap-up: when a cycle is done, produce a 1-page summary at `Docs/handoff/<date>_cycle_B##_complete.md` listing cross-block coordination items.

## Quality bar

The user's explicit instruction: *"I would rather have longer building time than shorter with bad quality."* Quality is KING. Cross-references are LOAD-BEARING. Speed is secondary.

## Stage-3 ticket cadence (per-ticket workflow)

For each ticket:

1. `retrieve_work_item_by_identifier(project_identifier="BOOK", issue_identifier=N)` — get the hook scope + candidate sub-docs.
2. Check if a canonical doc exists at the listed path. If candidate-list is stale, search by hook keyword.
3. **Disposition:**
   - **Verify-only:** read the canonical doc, post a DoD comment summarising coverage + any drift flags, close to Done, file 1-3 KG triples.
   - **Write-required:** for routine pattern, write directly under `Docs/sub/<category>/<slug>.md` with tighter scope; for novel mechanism, propose 5-10 bullets and wait for "go".
4. **NEVER save files to project root** — only under `Docs/sub/`, `Docs/handoff/`, `Docs/phases/`, `supabase/migrations/`.

## Pinned MemPalace queries

```
mempalace_kg_query(subject_prefix="stage3_cycle")           # cycle UUIDs + roadmap
mempalace_kg_query(subject_prefix="BOOK-", limit=50)        # ticket-closure facts
mempalace_kg_query(subject_prefix="match_scoring_docs")     # B10 5-way drift items
mempalace_kg_query(subject_prefix="b02p07_migration")       # B02·P07 cross-block deps
mempalace_kg_query(subject_prefix="b10p06_implementation")  # B10·P06 cross-block deps
```

## How to report back after loading context

In your first response after the parallel reads complete, give me exactly this:

1. One sentence confirming context loaded (drawer + handoff + Cycle B02).
2. "Cycle B02 has N backlog tickets remaining. Lowest sequence_id in backlog is BOOK-X."
3. Proceed to process BOOK-X per the disposition cadence.

Don't recap the prior session. Don't restate the handoff doc. Just orient and execute.

## Tone

Terse status updates. Complete sentences for any user-facing text. Don't narrate internal deliberation. End each ticket with one sentence: ticket closed, KG triples filed, next ticket up.

## Where I'm coming back in

When in doubt about which path (verify vs write), default to checking the file system first. The Pass-3 ticket candidate-list is often stale; the file usually exists under a different slug.

**Quality is KING. Cross-references are LOAD-BEARING. Speed is secondary.**

Go.

---

(End of paste content.)
