# Mempalace integration for Cyprus Bookkeeping SaaS

**Goal:** make the "why" behind every implementation survive across chat
sessions. Plane already captures the "what" (DoD comments per phase).
Mempalace is where the cross-phase reasoning, patterns, and gotchas live so
the next session rebuilds context in seconds, not minutes.

---

## 1. Why mempalace (and not just Plane + Docs/)

| Store              | Good at                                | Weak at                              |
|--------------------|-----------------------------------------|---------------------------------------|
| Plane comments     | per-phase deliverables + DoD            | cross-phase patterns; ad-hoc gotchas  |
| `Docs/phases/*.md` | specification (immutable contracts)     | living lessons learned                |
| Migration files    | exact schema state                       | reasoning behind the schema           |
| Chat context       | recent decisions, sharp recall           | dies at compaction; not queryable     |
| **Mempalace**      | **searchable, tunnel-linked memory**     | not great for raw spec text           |

Mempalace fills the gap. Drawers store verbatim text; tunnels link related
drawers across rooms (and across projects, via cross-wing tunnels). The KG
captures entity-relationships ("RPC X uses helper Y"). The agent diary
captures session-level intent in compressed AAAK.

---

## 2. Mempalace mental model (as actually exposed)

- **Wing** — top-level container, project-typed. Convention: `wing_<slug>`.
- **Room** — hyphenated slug within a wing; represents a named idea or
  category (e.g. `architecture-decisions`, `cross-block-patterns`).
- **Drawer** — one piece of verbatim content filed in a (wing, room).
  Has an ID. Created via `mempalace_add_drawer`.
- **Tunnel** — directional link between two (wing, room) locations or
  specific drawers. Use for "this depends on that", "this replaces that",
  "this applies that pattern".
- **Diary** — per-agent or per-wing session journal in AAAK (compressed).
- **KG** — `(subject, predicate, object[, valid_from])` triples; queryable
  by entity.

**Storage rules:**
- Drawers = verbatim text (never summarised). The exact decision wording,
  the literal code pattern, the actual error message.
- Diary = compressed AAAK. Agent intent, session arc, what we worked on.
- KG = structured facts you'd want to filter/join.

---

## 3. This project's wing + rooms

**Single wing:** `cyprus_bookkeeping`

(No `wing_` prefix — the user's existing wings are `chatbot_2` /
`munk_media`. AAAK spec docs show the `wing_` form as metaphor; the literal
storage convention is bare names.)

Cross-project patterns (e.g. SecureClient pin verification) can later be
promoted to a shared wing (e.g. `engineering`) with cross-wing tunnels.
Don't pre-create — let them emerge when a second project actually adopts
the pattern.

### Canonical rooms (aligned with user's existing taxonomy)

| Room slug             | Origin               | What lives here                                                                                            |
|-----------------------|-----------------------|------------------------------------------------------------------------------------------------------------|
| `decisions`           | reused from `munk_media` | Stage 1-style choices: "additive-only adjustment runs", "5-bucket issue_group", "hash chain seed 64 zeros", "Workflow-First (writes blocked from authenticated)" |
| `architecture`        | reused from `munk_media` | High-level architecture: 5-zone data architecture, schema separation (`public` / `archive` / `analytics` / `audit`), service-role-only writer pattern |
| `phases`              | reused from `munk_media` | One drawer per `BNN·PNN` containing the Plane DoD summary + key file paths. Cross-reference point.        |
| `patterns`            | new — this project   | Patterns that recur across blocks: audit-before-delete, audit-then-raise rollback hazard, clock_timestamp vs now(), consume_step_up_token tuple return, session-level advisory lock, partial-UNIQUE for "one active per X", CREATE OR REPLACE as hook-swap, JSONB-snapshot archive, immutability trigger + delete-guard session var. |
| `audit-findings`      | new                  | Cross-block audit results. The 6 findings + their fixes (Block 04 audit). New audits append.              |
| `gotchas`             | new                  | Things that bit us mid-implementation: Supabase blocks DELETE on storage.objects, ALTER TYPE ADD VALUE in same tx, transaction-frozen now(), advisory_xact_lock reentry rules, etc. |
| `contracts`           | new                  | RPC signatures we treat as stable cross-phase contracts: `emit_audit(...)`, `consume_step_up_token(...)`, `legal_hold_status(...)`, `hash_chain_append(...)`. Swappable-placeholder notes included. |
| `production-cutover`  | new                  | "MUST do before prod" items: replace PLACEHOLDER pins, set APP_ENV=production, HSTS preload submission, Object Lock retention config, manual SPKI capture procedure. |
| `project-meta`        | new                  | Project IDs, region, env vars, where to look. The "I just opened this project, where am I?" room. |

### Anti-rooms (don't create these)

- ❌ `phase-04-data-architecture` — phases go in `phases`, not their own room. The room IS phases.
- ❌ `bugs` — solved bugs go in commit history. Patterns that taught us
  something become drawers in `patterns` or `gotchas`.
- ❌ `random-notes` / `misc` — every drawer needs a categorical home.
- ❌ Re-named existing rooms — don't introduce `architecture-decisions`
  alongside the existing `architecture` + `decisions`. Reuse what's there.

---

## 4. What we file when (rituals)

### 4.1 Per-phase ritual

Every time we ship a `BNN·PNN`:

1. **BEFORE the phase**:
   - `mempalace_search` for relevant pattern keywords from
     `cross-block-patterns` (e.g. before B05·P03, search "hash chain audit
     emit" to surface the B04·P01 hash helper drawer and the
     audit-then-raise pattern).
   - `mempalace_kg_query` on entities the phase will touch
     (`emit_audit`, `audit_events`, `consume_step_up_token`).

2. **DURING the phase**: implement (Plane + migrations as today).

3. **AFTER the phase**:
   - Add a `phases` drawer with the verbatim Plane DoD comment HTML (or
     the Markdown distillation).
   - For each *new pattern* surfaced: add a `patterns` drawer with the
     verbatim explanation + a "first observed in BNN·PNN" tag.
   - For each *gotcha*: `gotchas` drawer with the exact error message +
     symptom + fix.
   - For each *contract* established: `contracts` drawer with the RPC
     signature + the calling convention.
   - For each *production cutover* item: `production-cutover` drawer.
   - Add KG triples:
     - `(BNN·PNN, depends_on, BMM·PMM)` for each upstream phase.
     - `(BNN·PNN, uses_pattern, <pattern-name>)` per cross-block-pattern.
     - `(BNN·PNN, defines_contract, <contract-name>)` per new RPC.
     - `(BNN·PNN, ships_rpc, <rpc-name>)`.
     - `(<placeholder>, replaced_by, <real-impl>, valid_from=…)` when a
       phase swaps in a real implementation over a placeholder.
   - Create tunnels for "applies-pattern" / "replaces" / "depends-on" so
     `mempalace_find_tunnels` can answer "which phases use this pattern?".

4. **Diary entry** (AAAK, agent-named) — one line summarising the session:
   ```
   SESSION:2026-05-20|BNN·PNN.shipped+audit.findings.fixed:N|★★★★
   ```

### 4.2 Per-session ritual

- **Start of session**: `mempalace_status` + `mempalace_get_taxonomy` +
  `mempalace_search` for the upcoming phase. Read recent diary entries
  (`mempalace_diary_read` last 5) to recover prior session arc.
- **During session**: file gotchas as they happen — not at the end.
  Don't wait until the phase is done if a 20-minute detour taught
  something useful (e.g. "Supabase blocks DELETE on storage.objects").
- **End of session**: write one diary entry. Run
  `mempalace_check_duplicate` if you're unsure something was already filed.

---

## 5. Naming conventions

- **Wings**: `wing_<project_slug>` (per AAAK convention).
- **Rooms**: lowercase, hyphenated, noun phrase. Don't drift —
  `architecture-decisions` not `decisions` or `decision-log` or
  `arch-decisions`.
- **Drawer content**:
  - **Spec/decision drawers**: title-style first line, then prose. Verbatim.
  - **Pattern drawers**: format `# Pattern: <name>` then explanation + example + first observed.
  - **Phase drawers**: format `# BNN·PNN — <phase name>` then the DoD bullets verbatim.
- **KG predicates** (closed vocabulary — extend deliberately):
  - `depends_on`, `replaces`, `uses_pattern`, `defines_contract`,
    `ships_rpc`, `lives_in_schema`, `applies_to_block`, `verified_by`,
    `production_cutover_for`, `documented_in`.
- **KG entity IDs**: use canonical names. `BNN·PNN` (with the ·) for
  phases. Function names with schema (`archive.set_legal_hold`,
  `public.emit_audit`). Table names with schema. Patterns get a
  hyphenated slug (`audit-before-delete`, `audit-then-raise-rollback`).

---

## 6. AAAK use (when to use, when not)

- **DRAWERS**: never AAAK. Drawer content is verbatim — the literal Plane
  comment, literal SQL, literal error message. AAAK loses fidelity.
- **DIARY**: always AAAK. One line per session, compressed, entity-coded.
- **KG triples**: not AAAK. Predicate vocabulary is fixed.

Don't compress spec text. Don't compress code. Don't compress error
strings. AAAK is for *agent intent*, not *system state*.

---

## 7. Examples (templates to copy)

### 7.1 New pattern drawer (room: patterns)

```markdown
# Pattern: audit-before-delete

When a function INSERTs into an audit table whose FK references a row about
to be deleted (ON DELETE SET NULL), emit the audit row FIRST. The FK is
satisfied at INSERT time; the post-delete SET NULL cascade nulls the
reference but leaves the audit row in place. Reversing the order
(delete then audit) violates the FK.

First observed: B04·P10 (retention engine deleting archive_runs while
emitting RETENTION_DELETION_EXECUTED with archive_run_id).

Applies to: any DEFINER function that audits then mutates state where the
audit row carries a FK to the mutated entity.

Counter-pattern: audit-then-raise rollback — see that drawer.
```

### 7.2 New gotcha drawer

```markdown
# Gotcha: now() is frozen per transaction

PostgreSQL's now() = transaction_timestamp(). Inside a single transaction
(including a DO block), now() returns the same value on every call.

Symptom: multi-statement updates to a `last_refreshed_at` or `updated_at`
column show identical timestamps, breaking tests that expect monotonic
advance within one session.

Fix: use clock_timestamp() in RPCs that may be called multiple times in a
single transaction by the same caller. Especially: refresh / rebuild RPCs.

Confirmed in B04·P09 (analytics.refresh_business test), B04·P10 (retention
re-entry test), B05·P02 (audit occurred_at).
```

### 7.3 New KG triples (after shipping B05·P02)

```
(B05·P02, ships_rpc, audit.emit_audit, 2026-05-20)
(B05·P02, ships_rpc, audit.record_forensic_query, 2026-05-20)
(B05·P02, defines_contract, emit_audit-signature, 2026-05-20)
(B05·P02, depends_on, B02·P01, 2026-05-20)
(B05·P02, uses_pattern, immutability-trigger, 2026-05-20)
(B05·P02, uses_pattern, delete-guard-session-var, 2026-05-20)
(audit.emit_audit, lives_in_schema, audit, 2026-05-20)
(B05·P03, replaces, audit.emit_audit, valid_from=<next session>)
```

### 7.4 New diary entry (B05·P02)

```
SESSION:2026-05-20|B05·P02.audit.log.shipped+12.assertions.PASS+tx.coupling.verified|patterns.applied:immutability.trigger,delete.guard.session.var|★★★★
```

---

## 8. Backfill plan

Phases already shipped that need drawers (in `phases`):

- B04·P01 hashing & UUID v7 — Plane HTML body + cross-platform golden info
- B04·P02 bank statement schema
- B04·P03 document + matching schema
- B04·P04 ledger + review schema
- B04·P05 raw upload zone
- B04·P06 processing zone
- B04·P07 finalized archive zone
- B04·P08 zone promotion pipeline
- B04·P09 analytics zone
- B04·P10 retention engine
- B04·P11 legal hold
- B05·P01 TLS & at-rest encryption baseline
- B05·P02 audit log schema & emission API

Patterns to extract into `patterns`:
1. audit-then-raise rollback hazard (and the audit-before-raise OR
   return-on-fail mitigations)
2. audit-before-delete (FK-satisfaction ordering)
3. clock_timestamp vs now() for in-transaction monotonicity
4. session-level advisory lock with explicit unlock for in-test re-entry
5. partial-UNIQUE for "at most one ACTIVE per X" enforcement
6. consume_step_up_token returns (consumed, reason) — must check, not PERFORM
7. immutability trigger + delete-guard session-var (B04·P07, B05·P02)
8. CREATE OR REPLACE function as a hook-swap mechanism (B04·P10 placeholder
   → B04·P11 real)
9. ALTER TYPE ADD VALUE in same migration as use site — values aren't
   visible until commit; safe in function bodies (parsed late), unsafe in
   immediate INSERTs.
10. Storage protect_delete trigger — DB functions can't DELETE from
    storage.objects; must signal via audit event for worker
11. JSONB-snapshot archive (vs column-by-column mirror) — robust to
    operational schema evolution

Audit findings to file in `audit-findings`:
- #1 step-up enforcement bypass (`PERFORM` instead of checking tuple)
- #2 adjustment chain delete RESTRICT blocking
- #3 processing prune missing per-business legal hold check
- #4 retention_policies missing updated_at trigger
- #6 dual legal-hold concepts (per-run vs per-business) — deferred
- #7 step-up surface naming inconsistency — deferred
- #12 unindexed FK batch

Production cutover items:
- Replace PLACEHOLDER:* SPKI pins in both api/secure_http and
  web/src/lib/secure-http
- Set APP_ENV=production
- Submit to hstspreload.org
- Configure archive-bundles Object Lock retention at Supabase storage layer
- Wire `verify_security_baseline()` into FastAPI lifespan (done)

Contracts to file:
- `audit.emit_audit(...)` — signature + transactional-coupling rule
- `public.consume_step_up_token(...)` — returns (consumed, reason); MUST
  check, never PERFORM
- `archive.legal_hold_status(business_id) → jsonb` — swappable hook
  (placeholder B04·P10 → real B04·P11)
- `public.hash_text_sha256`, `public.hash_chain_append` — IMMUTABLE
- `public.gen_uuid_v7` — VOLATILE
- `public.current_org`, `public.current_user_id`, `public.current_user_businesses` —
  STABLE SECURITY DEFINER

Project-meta drawer:
- Project ID: `noxvmnxrqlzsdfngfiww` (Cyprus Bookkeeping SaaS — created
  2026-05-18; the OLD `gbdltagzakhkuibhdsol` "AI accounting software" is
  not touched)
- Region: EU (eu-west-1)
- Repo root: `/Users/pep_o23kd/Desktop/Cursor/boekhoudings_Ai_software`
- Migrations: `supabase/migrations/`
- Plane project: `BOOK` (`28b250c0-d991-4dcb-a48c-51af27aa17dd`)
- Plane states: Backlog `06b2fd3b-5d0c-486a-9a37-fe086b725315`, In Progress
  `d349cb35-77f8-45f8-bbf7-98b6fbf39329`, Done
  `6e8dcd01-8ef8-4f8f-a3c4-99e73bb5ec98`

Estimated backfill time: ~30 minutes of mostly-mechanical filing.

---

## 9. Failure modes — what NOT to do

- **Don't file twice.** Use `mempalace_check_duplicate` (threshold ~0.85)
  before adding a drawer that overlaps something already filed.
- **Don't drift rooms.** If you find yourself typing `architecture-choices`,
  stop and use `architecture-decisions`. Drift fragments memory.
- **Don't compress drawers.** Drawer content is the source of truth. AAAK
  is for diary only.
- **Don't file plans, only landed work.** If you said "I'm going to do X"
  but X didn't ship, that's not a memory yet. Diary captures intent;
  drawers capture facts.
- **Don't bury commit-grade detail in mempalace.** "Fixed typo on line 42"
  belongs in the git commit, not a drawer.
- **Don't skip the search before a phase.** The whole point is to surface
  prior patterns. If you skip the search, mempalace becomes write-only and
  pointless.

---

## 10. Session-start cheat-sheet (paste this when picking up the project)

```
1. mempalace_status                                 # palace healthy + protocol reminder
2. mempalace_list_drawers(wing="cyprus_bookkeeping",room="project-meta")
3. mempalace_search("<upcoming phase keywords>", wing="cyprus_bookkeeping")
4. mempalace_diary_read(agent=claude, last=5)
5. Read Plane work item for BNN·PNN.
6. Begin phase.
```

---

## 11. Open questions for next iteration

- **Do we want a `wing_engineering` shared wing** for cross-project patterns
  (SecureClient, audit-before-delete) that other projects could pull from?
  Suggested: yes, once a *second* project adopts one of our patterns.
- **Diary cadence — per session or per phase?** Suggested: per session
  (lower friction), with the diary entry mentioning all phases shipped that
  session.
- **AAAK entity codes for our domain?** Could add: AUD=audit, ARC=archive,
  ANL=analytics, PUB=public, RAW=raw-uploads, PRZ=processing-zone. Defer
  until we feel the friction of typing them out long.

---

Last updated: 2026-05-20. Owner: whoever's currently picking up the
project — this doc evolves.
