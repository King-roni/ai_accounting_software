# Implementation session — start prompt

For the Stage 5 implementation track (writing migrations + API + Web code,
NOT the Stage 4 sub-doc corpus work — that prompt is in
`NEXT_SESSION_START_PROMPT.md`).

Paste the block below into a new session and let the agent bootstrap
itself from mempalace before doing anything.

---

```
I'm continuing the Stage 5 implementation track of the Cyprus Bookkeeping
SaaS project. Previous sessions shipped all of Block 04 (Data Architecture,
11 phases), the Block 04 cross-block audit + 6 fixes, B05·P01 (TLS &
At-Rest Encryption Baseline), and B05·P02 (Audit Log Schema & Emission
API). The next phase to implement is **B05·P03 — Audit Log Tamper
Resistance** (hash chain into audit.audit_events, RFC 3161 timestamping,
periodic integrity scan).

Before doing anything else, bootstrap your context from mempalace —
DON'T re-read the specs from scratch. They're already there.

Bootstrap sequence (run in order, in parallel where possible):

1. mempalace_status                                   — palace health + memory protocol
2. mempalace_list_drawers(wing="cyprus_bookkeeping", room="project-meta")
                                                       — IDs, schema names, conventions
3. mempalace_search("hash chain audit emit prev_event_hash",
                    wing="cyprus_bookkeeping", limit=8)
                                                       — surfaces B04·P01 hashing contract +
                                                         B05·P02 audit drawer + relevant patterns
4. mempalace_search("audit then raise rollback",
                    wing="cyprus_bookkeeping", limit=3)
                                                       — the rollback hazard pattern you'll need
5. mempalace_search("CREATE OR REPLACE hook swap",
                    wing="cyprus_bookkeeping", limit=3)
                                                       — the pattern for swapping in the real
                                                         hash chain over the B05·P02 placeholder
6. mempalace_kg_query(entity="B05·P03")               — what's already planned for the phase
7. mempalace_kg_query(entity="audit.emit_audit")      — current contract + scheduled replacement
8. mempalace_diary_read(agent="claude", last=5)       — recent session arc

After bootstrap, retrieve the Plane work item (BNN·PNN identifier `26`):
- mcp__plane__retrieve_work_item_by_identifier(project_identifier="BOOK",
                                               issue_identifier=26)

Read the phase spec:
- Docs/phases/05_security_and_audit/03_audit_log_tamper_resistance.md

Project facts (verify via mempalace; reproduced here as a backup):
- Supabase project: noxvmnxrqlzsdfngfiww — "Cyprus Bookkeeping SaaS"
  (the OLD gbdltagzakhkuibhdsol "AI accounting software" is a different
  project; do not touch it)
- Region: eu-west-1
- Plane project: BOOK (28b250c0-d991-4dcb-a48c-51af27aa17dd)
- Plane state IDs: Backlog=06b2fd3b-5d0c-486a-9a37-fe086b725315,
  In Progress=d349cb35-77f8-45f8-bbf7-98b6fbf39329,
  Done=6e8dcd01-8ef8-4f8f-a3c4-99e73bb5ec98
- Repo root: /Users/pep_o23kd/Desktop/Cursor/boekhoudings_Ai_software
- Migrations: supabase/migrations/
- API (Python/FastAPI): api/src/cyprus_bookkeeping_api/
- Web (Next.js/TypeScript): web/src/

Critical constraints (carry over from prior sessions — verify in
mempalace patterns + contracts rooms):
- All writes blocked from `authenticated` role; SECURITY DEFINER RPCs
  are the only writers (Workflow-First)
- consume_step_up_token returns (consumed, reason) — MUST check, never PERFORM
- audit-then-raise rolls back the audit; use return-on-fail OR
  audit-before-delete instead
- now() is frozen per transaction; use clock_timestamp() for monotonic advance
- SHA-256 hex, 64 chars, lowercase; canonical JSON parity Python ↔ TS ↔ SQL
  with golden 40c3929457af2429a2a701cd95aa3c28781f141f190bd4440f62334f30c512b5
- Hash chain seed = repeat('0', 64) for first entry per chain
- DOMAIN_PAST_VERB action naming enforced by CHECK in audit.audit_events
- Migration drift on disk vs remote is expected (~50 remote / ~30 disk);
  the disk file is the canonical end-state, the remote history is finer-grained

Working pattern (established over the prior sessions):
- One phase at a time; user says "let's continue" or "let's move to BNN·PNN"
- Per phase: read spec → set Plane to In Progress → write migration →
  apply → write DB-level lifecycle assertions in a DO block that ends
  with RAISE EXCEPTION 'TEST_PASS_ROLLBACK' (clean fixtures, no commit) →
  verify N/N PASS → close Plane with a rich DoD comment
- For API/web work: tests must pass; typecheck must be clean (uuid7.ts
  BigInt errors are pre-existing — ignore those)
- After the phase: file mempalace drawer in `phases` room; if new patterns
  emerged, add a `patterns` drawer; if gotchas, a `gotchas` drawer;
  always add KG triples (depends_on, ships_rpc, uses_pattern); write one
  AAAK diary entry

Tone:
- Concise, no preamble, no recap
- Acknowledge user with one short sentence, then do the work
- Use Plane DoD comments for the audit trail (rich) and mempalace
  drawers for the cross-phase reasoning (also rich, verbatim)
- Don't ask permission before each individual tool call; batch where
  possible

What I want this session: implement B05·P03. After the bootstrap reads
above, propose the implementation shape in 5-8 bullets and wait for me
to say "go". Then ship it.
```

---

## What this prompt actually buys you

- The new session loads ~20 of the most relevant cyprus_bookkeeping
  drawers via `mempalace_search` — patterns, contracts, project-meta —
  in ~5 seconds instead of re-reading the codebase.
- It knows the project IDs without grep'ing the codebase.
- It knows every cross-block pattern that was painful to discover the
  first time, so it doesn't re-discover them.
- It knows the working pattern (the test-rollback DO block style, the
  Plane state IDs, the migration drift convention) so it doesn't ask
  about them.

## Maintenance

When a new pattern or gotcha is discovered in a future session:
1. File a drawer in the appropriate room
2. Add KG triples
3. **Do NOT update this prompt** — the prompt directs the agent to query
   mempalace, which now contains the new pattern. The prompt is
   intentionally short and stable.

Only update this prompt if:
- Project IDs change
- The working pattern changes
- The bootstrap sequence proves insufficient (and the fix is to add a
  query, not to dump more facts inline)
