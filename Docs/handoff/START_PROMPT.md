# START PROMPT — Paste this into the next session

Copy everything below this line into the new Claude Code session as the first user message.

---

You are picking up the **Cyprus Bookkeeping SaaS** project (multi-tenant accounting platform with Cyprus VAT, accountant pack, finalization archive). The previous session ended 2026-05-26 after closing all of **Block 16** and completing **Stage 2** (block + phase decomposition for all 16 blocks, BOOK-1..160). We are now starting **Stage 3 — the sub-doc backlog walk** (BOOK-164..881, 718 tickets remaining).

## Your first move (do these in parallel, single message)

1. `mempalace_status` — loads palace overview + protocol
2. `mempalace_get_drawer(drawer_id="drawer_cyprus_bookkeeping_project-meta_3425d21389e8094e778df48c")` — the canonical "where am I" drawer (Blocks 04–16 summaries + critical conventions)
3. `mempalace_get_drawer(drawer_id="drawer_cyprus_bookkeeping_project-meta_65279d75e77494c9a6fb15c9")` — build-order roadmap
4. `Read("/Users/pep_o23kd/Desktop/Cursor/Personal/boekhoudings_Ai_software/Docs/handoff/2026-05-26_session_handoff_to_stage3.md")` — full operating cadence + gotcha pin list (REQUIRED — do not skip)
5. `mcp__plane__retrieve_work_item_by_identifier(project_identifier="BOOK", issue_identifier=164)` — next ticket to process

## Project facts you must know before doing anything

- **Repo root:** `/Users/pep_o23kd/Desktop/Cursor/Personal/boekhoudings_Ai_software`
- **Supabase project:** `noxvmnxrqlzsdfngfiww` (EU eu-west-1, Postgres 17.6.1.121, 38 migrations applied)
- **Plane project:** `BOOK` · `project_id = 28b250c0-d991-4dcb-a48c-51af27aa17dd`
- **Plane states:** Backlog `06b2fd3b-5d0c-486a-9a37-fe086b725315` · In Progress `d349cb35-77f8-45f8-bbf7-98b6fbf39329` · Done `6e8dcd01-8ef8-4f8f-a3c4-99e73bb5ec98`
- **Sub-doc corpus:** 639 `.md` files already exist in `Docs/sub/` across 11 categories — most Stage 3 tickets are verify-and-close, NOT new writes

## The Stage 3 cadence — internalize this before touching a ticket

Every Plane ticket points to a candidate sub-doc path in `Docs/sub/<category>/<slug>.md` and a hook description from its parent phase's "Sub-doc Hooks (Stage 4)" section. Two paths:

### 🟢 VERIFY-ONLY (~80% of tickets) — no proposal, no wait, just close

1. Check candidate file exists at the path the ticket lists.
2. If it does: read it; confirm coverage matches the hook description.
3. Set ticket In Progress → post DoD trace comment summarizing what the doc covers → close to Done → file 1–2 KG triples.
4. **NO bullet proposal. NO "waiting for go" cycle.** Just close.

### 🟠 WRITE-REQUIRED (~20% of tickets) — propose, wait, then write

1. Set ticket In Progress.
2. Read parent phase doc to understand hook scope.
3. Propose 5–10 bullets describing the sub-doc structure you'll write.
4. **STOP. Wait for user's "go".**
5. After go: write the file under `Docs/sub/<category>/<slug>.md` (NEVER project root). Post DoD trace → close → file 2–3 KG triples.

### 🚨 The Pass-3 staleness trap (critical)

Many tickets say `"Sub-doc spec: no file match found in Docs/sub/"`. **This is often wrong** — the Pass-3 indexer missed files under different slugs. **Before assuming write-required:**
- Search by hook keyword: `Bash("ls Docs/sub/*/ | grep -i <keyword>")`
- Check sibling sub-docs' "Cross-references" sections — the canonical file is usually pointed to from there
- Example from last session: BOOK-162's ticket said "no file match found" but `Docs/sub/schemas/tenancy_schema_definition.md` existed (182 lines, fully canonical). It was a verify-only close.

## Operating rules (don't deviate)

- **Verify next phase against Plane — never say "likely" about the next phase.** Use `mcp__plane__retrieve_work_item_by_identifier(BOOK, N)`.
- **NEVER save files to project root.** Use `Docs/sub/` · `Docs/design-system/` · `Docs/handoff/` · `Docs/phases/` · `supabase/migrations/`.
- **Migrations:** rare in Stage 3, but if needed — apply via `mcp__claude_ai_Supabase__apply_migration` then mirror a header-only stub to `supabase/migrations/YYYYMMDDHHMMSS_<phase>.sql` (FORWARD-ONLY; fix-ups are NEW files).
- **KG triples:** `mempalace_kg_add` — object field is capped at 128 chars; split long facts.
- **MemPalace drawers:** `update_drawer` sometimes returns `noop:true` (server-side dedup). KG triples are the authoritative state record; rely on them.
- **No build/test runs needed for verify-only tickets** — these are doc verifications, not code changes.
- **Concurrency:** batch parallel tool calls in one message wherever possible.

## Top gotchas already learned (don't re-discover)

- `audit.emit_audit` signature: `p_after_state jsonb, p_request_context jsonb` — NO `p_payload`.
- `audit_events_actor_kind_chk`: xor — USER+actor_user_id OR SYSTEM+actor_system, never both.
- Postgres lowercases unquoted function names (`_compose_manifest_vN_json` → `_compose_manifest_vn_json`).
- PG nested aggregates forbidden — SUM inside string_agg fails; flatten via CTE.
- `pgcrypto.digest` lives in `extensions` schema — SECURITY DEFINER funcs must add `extensions` to search_path.
- `ALTER TYPE ADD VALUE` has deferred visibility — split into two migrations when used in the same one.
- `business_entities` PK = `id` (no separate `business_id` column).
- `vat_treatment_enum` uses `UNKNOWN` sentinel; column NOT NULL; never `IS NULL`.
- Mobile-write rejection (B16·P12) is UX guard NOT security event — no audit emit.
- Stage 5 build-time used MCP `apply_migration` (no local Supabase CLI available); production engineers will use CLI per `supabase_migration_tooling_policy.md`. Both paths mirror to `supabase/migrations/*.sql` forward-only.

## How I want you to report back after loading context

In your **first response after the parallel reads complete**, give me exactly this:

1. **One sentence** confirming context loaded (drawer + handoff + Plane).
2. **The next ticket's identity:** `BOOK-164 — [B##·P##·SD] <hook title>` plus the candidate sub-doc path.
3. **Your disposition:** "verify-only" or "write-required" with the one-line reason.
4. **If verify-only:** proceed to close it (no bullets, no waiting).
5. **If write-required:** propose 5–10 bullets and wait for my "go".

Don't recap the previous session. Don't restate the handoff doc. Just orient and execute.

## Tone

Terse status updates. Complete sentences for any user-facing text. Do NOT narrate internal deliberation. End each ticket with one sentence: ticket closed, KG triples filed, next ticket up.

When in doubt about which path (verify vs write), default to checking the file system first — `Bash("ls -la <candidate-path>")` settles it in one call.

Go.
