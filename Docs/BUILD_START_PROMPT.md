# Build Session — Start Prompt (Cyprus Bookkeeping SaaS)

Read this to begin the next session. **Goal: build the remaining work (frontend + hardening), following the roadmap.** No spec-writing.

## Read first (in order)
1. **`Docs/handoff/2026-05-29_session2_frontend_R0_R1_R2.md`** — what the last session built, the patterns to reuse, seeded test data, and where to resume. **Most important.**
2. **`Docs/BUILD_ROADMAP.md`** — the dependency-ordered plan (R0–R4).
3. This file.
4. Scan: the codebase (`web/src/components/{ui,shell,…}`, `web/src/app/(app)/`), the live Supabase DB (via MCP), and Plane (★ Remaining Build / #17) before assuming anything.

## The one critical rule
The **backend is built and LIVE**. Plane's per-block "backlog" was a sub-doc SPEC walk, **NOT** a build to-do list. **Do NOT write sub-docs. Do NOT treat Plane block backlogs as unbuilt work. Verify against the codebase + live DB before assuming anything is missing.**

## Verified current state (2026-05-29, end of session 2)
- **DB:** ✅ live on `noxvmnxrqlzsdfngfiww`; 240 migrations; reference data seeded; **+ test data seeded** for business "Demo Trading Ltd" (see handoff). R0.2 RLS lockdown applied (advisors clean of `rls_disabled`).
- **API:** thin FastAPI (`health` + `me`, JWKS auth). Run: `cd api && uv run uvicorn cyprus_bookkeeping_api.main:app --app-dir src`. 139 unit tests pass.
- **Frontend:** ✅ **foundation + 5 of 8 domain screens built** (Next 16 + Supabase SSR). Done: R0.1–R0.4, R1.1–R1.3, R2.1 transactions, R2.2 documents, R2.3 matching, R2.4 ledger/VAT, R2.5 review queue — all verified in-browser. Routes live under `web/src/app/(app)/`. Component lib in `web/src/components/ui/`, shell in `web/src/components/shell/`, design tokens in `web/src/theme/` + `globals.css`.
- **Committed:** session-2 work is committed as `63fc014` on `build/full-snapshot-2026-05-29` (no secrets). **Not pushed** to a remote — push for offsite safety.
- **Test login:** `admin@admin.com` / `admin123` → owns "Demo Trading Ltd" with seeded data. Web :3000, API :8000.
- **Working dir:** `/Users/pep_o23kd/Desktop/Cursor/Personal/boekhoudings_Ai_software` — NOT the empty decoy at `.../Cursor/boekhoudings_Ai_software`.

## Where to resume — work the ★ Remaining Build cycle / #17 module
Next ticket: **R2.6 — OUT + IN workflow run UI + Invoice generator (B12/B13)** — the largest remaining (run views: phases/holds/gates/approvals; invoice generator: drafts, numbering, PDF, recurring, credit notes, clients). The statement upload→parse→results viewer belongs here too.
Then **R2.7** finalization & archive (B15) · **R2.8** dashboard cards + exports (B16·P06–P11) · **R3** a11y/i18n/E2E + visual regression · **R4** productionization (real TSA/Vault/Document AI/Anthropic) + security review + deploy.

Screen specs live in `Docs/sub/ui/` — read them to build; don't rewrite them.

## Reusable patterns (from session 2 — see handoff for detail)
- **Data screen:** client page → `useSWR(['key', currentBusiness.id, …], fetcher)` with `createSupabaseBrowserClient()` (RLS-scoped); filter by `useShell()` business + `periodRange(period)`. Compose R1 `web/src/components/ui` primitives.
- **Write actions:** `supabase.rpc(fn, { p_actor_user_id: user.id, … })`. **Many B10/B14 RPCs return `{decision, status_after, reason}` — check `data.decision !== 'ALLOW'`, not just `error`.**
- **Seeding** (Supabase MCP `execute_sql`): inspect NOT-NULL-no-default cols + CHECK/FK constraints first; use fixed UUIDs; multi-statement inserts are atomic (rollback on any failure).
- New base CSS goes in `@layer base` (so utilities override).

## Key IDs
- Plane project: `28b250c0-d991-4dcb-a48c-51af27aa17dd` · ★ cycle: `dfa151b2-002a-43f1-b865-a211a275a971` · #17 module: `2ff2aeba-596f-48c7-9cd4-47818dbbc9d2` · ⏸ Spec-debt (ignore): `de30e6cc-8d27-404a-864e-cab68b7a0ac1`
- Plane states: Backlog `06b2fd3b-5d0c-486a-9a37-fe086b725315` · In Progress `d349cb35-77f8-45f8-bbf7-98b6fbf39329` · Done `6e8dcd01-8ef8-4f8f-a3c4-99e73bb5ec98` · actor `9be5a517-db19-48e5-aefd-c43fe2258cae`
- Supabase: `noxvmnxrqlzsdfngfiww` · Test business id `0e000000-0000-4000-8000-0000000000b1` · admin public.users.id `019e751a-0eda-7c6e-9c79-7e2c4ea9bff7`
- R2.6 ticket: `e9c85d73-3be9-453e-bbc3-e7026ba064a0` · R2.7 `9b8cb3f5-0f89-4404-ba17-4490ee29dfe2` · R2.8 `b279a3f4-8a57-40ef-a1a1-3469cb151b96` · R3 `730d961f-750e-4198-b682-0c04e3697028` · R4 `7cd93c04-a3f9-4ee2-88a0-a233004ec148`

## How to work
- Take an R-ticket → **In Progress** → seed data via MCP if needed → build against existing RPCs/tables → **verify in browser** (Playwright: navigate, screenshot, console, exercise one write-path) → **Done**. One ticket at a time, top-down.
- **Verify, don't assume.** Quality > speed. Be economical with reads (spec tables are self-describing; avoid the ~900KB advisor dump).
- `web`: `pnpm lint` + `npx tsc --noEmit` (scope to new files). Commit/push only when the lead asks; never commit secrets/`.env`.

## Toolchain
`node`/`pnpm`/`uv`/`python3`/`pg_dump`(libpq) present. **`supabase` CLI does NOT work here** (brew CLT too old; v2.102 binary crashes) — use the Supabase MCP + `pg_dump`. MCP: Plane (`mcp__plane__`), Supabase (`mcp__claude_ai_Supabase__`), Playwright, mempalace.
