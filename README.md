# Cyprus Bookkeeping SaaS

Cyprus-focused private bookkeeping SaaS — Stage 7 implementation.

## Repo layout

```
.
├── Docs/            ← Stage 1-6 spec corpus (locked)
├── supabase/        ← Postgres migrations + local-dev seed (Supabase CLI format)
├── web/             ← Next.js 16 (App Router, TypeScript, Tailwind 4) frontend
├── api/             ← FastAPI (Python 3.12+, uv) backend
└── outputs/         ← Stage 4-5 scan + hook artefacts
```

## Stack (chosen Stage 7-2)

- **Frontend:** Next.js 16 (App Router, TypeScript, Tailwind v4, Turbopack)
- **Backend:** FastAPI (Python 3.12+, `uv`, Pydantic v2)
- **Database:** Supabase (Postgres 17, EU-west-1)
- **Auth:** Supabase Auth (email/password baseline; MFA in B02·P03)
- **AI:** Anthropic Claude (EU/zero-retention) + local LLM (B06)

## Local development

### Prerequisites

- Node.js ≥ 20.9, pnpm ≥ 10
- Python ≥ 3.12, uv ≥ 0.9
- Supabase project: `noxvmnxrqlzsdfngfiww` (eu-west-1)

### One-time setup

```bash
# Web
cd web
cp .env.local.example .env.local
pnpm install

# API
cd ../api
uv sync
```

### Run

```bash
# Terminal 1 — Next.js dev server (http://localhost:3000)
cd web && pnpm dev

# Terminal 2 — FastAPI (http://localhost:8000)
cd api && uv run cyprus-bookkeeping-api
```

### Database

The Supabase project's Postgres is the source of truth. Migrations live in
`supabase/migrations/`. Apply via:

```bash
# Apply to the linked Supabase project (production-bound — currently the only env)
cd supabase && supabase db push --linked

# OR via the Supabase MCP (what we've been using during Stage 7)
```

## Stage 7 progress

- **Stage 7-1 (B02·P01) — Schema Scaffolding:** ✓ Done 2026-05-19. 6 tenancy
  tables, 6 ENUMs, helpers (`gen_uuid_v7`, `set_updated_at`).
- **Stage 7-2 (B02·P02) — Authentication Baseline:** ✓ Done 2026-05-19.
  Supabase Auth via `@supabase/ssr`, sign-up / login / forgot-password /
  reset-password / signout flows, `auth.users` → `public.users` sync trigger,
  FastAPI JWT verification.

## Reference

- Roadmap: `Docs/elaboration_roadmap.md`
- Master outline + scan log: `Docs/outline.md`
- Decisions log: `Docs/decisions_log.md`
- Plane project: `BOOK` / Cyprus Bookkeeping SaaS (workspace `timefuser.plane.so`)
