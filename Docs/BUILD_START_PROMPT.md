# Build Session — Start Prompt (Cyprus Bookkeeping SaaS)

Read this to begin the next session. **Goal: build the remaining work (frontend + hardening), following the roadmap.** No spec-writing.

## Read first (in order)
1. **`Docs/BUILD_ROADMAP.md`** — the dependency-ordered plan (R0–R4). The source of truth.
2. This file.
3. `Docs/handoff/2026-05-29_build_correction_and_roadmap.md` — what changed and why.

## The one critical rule
The **backend is built and LIVE**. Plane's per-block "backlog" was a sub-doc SPEC walk, **NOT** a build to-do list — every build/phase ticket is already Done, and the spec tickets are parked in the `⏸ Spec-debt` cycle. **Do NOT write sub-docs. Do NOT treat Plane block backlogs as unbuilt work. Before assuming anything is unbuilt, check the codebase + the live Supabase DB.** (A prior session wasted itself writing 50 redundant spec `.md` files — they were deleted.)

## Verified current state (2026-05-29)
- **DB:** ✅ live on Supabase `noxvmnxrqlzsdfngfiww` (eu-west-1) — 240 migrations applied, reference data seeded; backend logic in Postgres RPCs across B02–B16.
- **API:** thin FastAPI in `api/` (only `health` + `me` routes); **139 unit tests pass** (`uv run pytest`).
- **Frontend:** ❌ only B02 (auth/account/team/integrations) exists in `web/` (Next 16 + Supabase SSR). **Everything else is unbuilt — this is the work.**
- **Repo:** committed on branch `build/full-snapshot-2026-05-29` (local only — push to a remote for safety).
- **Working dir:** `/Users/pep_o23kd/Desktop/Cursor/Personal/boekhoudings_Ai_software` — NOT the empty decoy at `.../Cursor/boekhoudings_Ai_software`.

## What to build, in order — work the ★ Remaining Build cycle / #17 module
- **R0.1** `supabase db pull` → repo migrations (repo currently can't rebuild the DB). ⚠ `supabase` CLI is NOT installed — install it first.
- **R0.2** Resolve the 17 RLS-disabled tables (live security exposure; list in roadmap §2). Don't blanket-enable.
- **R0.3** Wire env/secrets: `web/.env` (Supabase URL + anon key), `api/.env` (service role, JWT). Never commit secrets.
- **R0.4** Boot `web` (`pnpm dev`) + `api` (`uv run`) against the live DB; smoke-test the existing auth flow.
- **R1.1 → R1.3** Frontend foundation: design system/tokens → component library → app shell (nav, business switcher, command palette).
- **R2.1 → R2.8** Domain screens against existing RPCs: bank upload → documents → matching → ledger/VAT → review queue → OUT/IN workflows + invoicing → finalization → dashboard/reports.
- **R3** a11y / i18n / E2E + visual regression. **R4** productionization (real TSA/Vault/Document AI/Anthropic) + security review + deploy.

The specs for every screen already exist in `Docs/sub/` (`ui/`, `schemas/`, `policies/`) — **read them to build; do not rewrite them.**

## Key IDs
- Plane project: `28b250c0-d991-4dcb-a48c-51af27aa17dd`
- ★ Remaining Build cycle: `dfa151b2-002a-43f1-b865-a211a275a971`
- `#17` Remaining Build module: `2ff2aeba-596f-48c7-9cd4-47818dbbc9d2`
- ⏸ Spec-debt cycle (ignore for build): `de30e6cc-8d27-404a-864e-cab68b7a0ac1`
- Supabase project: `noxvmnxrqlzsdfngfiww`
- Plane states: Backlog `06b2fd3b-5d0c-486a-9a37-fe086b725315` · In Progress `d349cb35-77f8-45f8-bbf7-98b6fbf39329` · Done `6e8dcd01-8ef8-4f8f-a3c4-99e73bb5ec98`
- Cycle owner / created_by: `9be5a517-db19-48e5-aefd-c43fe2258cae`

## How to work
- Take an R-ticket → set **In Progress** → build → verify (run it / test it) → set **Done**. One ticket at a time, top-down.
- **Verify, don't assume.** Quality > speed. Cross-references are load-bearing.
- Run tests after changes (`api`: `uv run pytest` · `web`: `pnpm lint`). Never commit secrets or `.env`.
- Commit/push only when the lead asks.

## Toolchain
`node` / `npm` / `pnpm` / `uv` / `python3` present. **`supabase` CLI NOT installed** (needed for R0.1). MCP servers: Plane (`mcp__plane__`), Supabase (`mcp__claude_ai_Supabase__`), mempalace.
