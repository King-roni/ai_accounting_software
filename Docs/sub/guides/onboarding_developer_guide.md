# Developer Onboarding Guide

**Namespace:** N/A (cross-cutting)  
**Audience:** Engineers joining the project  
**Status:** Active  
**Last Updated:** 2026-05-17

---

## Overview

This guide gets a new engineer to a running local environment and explains the conventions required to contribute. Work through it top to bottom on your first day. If anything is missing or wrong, update this file and open a PR.

---

## Repository Structure

```
/
├── supabase/
│   ├── functions/       # Edge Functions (one directory per function)
│   ├── migrations/      # SQL migrations, ordered by timestamp prefix
│   └── seed.sql         # Seed data for local development
├── src/
│   ├── app/             # Next.js App Router pages and layouts
│   ├── components/      # Shared React components
│   ├── lib/             # Shared utilities (supabase client, formatters, hooks)
│   ├── tools/           # AI tool definitions (JSON schema + handler)
│   └── types/           # Generated TypeScript types and hand-written interfaces
├── Docs/
│   └── sub/             # System documentation (policies, schemas, guides, reference)
├── docker-compose.yml   # Local services: Supabase stack, Redis (Upstash emulator)
├── .env.example         # Template for required environment variables
└── package.json
```

Edge Functions are the primary backend execution layer. Database logic lives in migrations (functions, triggers, RLS policies). The `src/` directory is the Next.js frontend and thin API surface.

---

## Running Locally

### Prerequisites

- Docker Desktop 4.x or later
- Node.js 20 LTS
- Supabase CLI (`npm install -g supabase` or via Homebrew)
- `pnpm` package manager (`npm install -g pnpm`)

### Start the Stack

```bash
# 1. Install dependencies
pnpm install

# 2. Start Supabase local stack (Postgres, Auth, Storage, Edge Functions runtime)
supabase start

# 3. Start remaining services (Redis emulator, any local proxies)
docker compose up -d

# 4. Start the Next.js dev server
pnpm dev
```

The Supabase Studio UI is available at `http://localhost:54323`. The local API runs on `http://localhost:54321`.

---

## Environment Variable Setup

Copy `.env.example` to `.env.local`:

```bash
cp .env.example .env.local
```

Required variables and where to get them:

| Variable | Source |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | Output of `supabase start` (local) or project settings (staging/prod) |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Output of `supabase start` |
| `SUPABASE_SERVICE_ROLE_KEY` | Output of `supabase start` — never expose client-side |
| `OPENAI_API_KEY` | Team 1Password vault → "OpenAI Dev Key" |
| `NORDIGEN_SECRET_ID` | Team 1Password vault → "Nordigen Dev" |
| `NORDIGEN_SECRET_KEY` | Team 1Password vault → "Nordigen Dev" |
| `UPSTASH_REDIS_REST_URL` | Output of `docker compose up` (local emulator endpoint) |
| `UPSTASH_REDIS_REST_TOKEN` | Static value `local-dev-token` for local emulator |
| `ECB_RATE_CACHE_TTL_HOURS` | Default `24` — override to `1` locally if testing FX logic |

Access to staging and production secrets requires a separate request to the team lead. Production `SERVICE_ROLE_KEY` is only available in CI/CD and on-call engineers.

---

## Running Migrations

Migrations apply automatically when running `supabase start` from a clean state. To apply new migrations to an already-running local instance:

```bash
supabase db reset        # Drops and rebuilds from scratch (use when schema changes are large)
# or
supabase migration up    # Applies only pending migrations
```

To create a new migration:

```bash
supabase migration new descriptive_migration_name
```

Migration files follow the naming convention `{timestamp}_{snake_case_description}.sql`. Never edit an already-applied migration; create a new one instead. See `policies/supabase_migration_tooling_policy.md` for guardrails.

---

## Seeding Test Data

`supabase/seed.sql` provides a minimal dataset: one business entity, one org member with OWNER role, sample bank statements, and a set of classified documents across multiple periods.

```bash
supabase db reset   # Applies migrations then runs seed.sql automatically
```

If you need a richer fixture set for a specific feature area, check `fixtures/` in the repository root. Fixture files are prefixed with the relevant namespace (e.g., `matching_fixtures.sql`, `archive_fixtures.sql`).

---

## Running Tests

```bash
pnpm test             # Unit tests (Vitest)
pnpm test:e2e         # End-to-end tests (Playwright, requires dev server running)
pnpm test:db          # pgTAP tests against the local Supabase database
```

Unit tests live alongside source files in `__tests__/` directories. E2E tests live in `tests/e2e/`. Database tests live in `supabase/tests/`.

All tests must pass on `main`. CI runs all three suites on every pull request.

---

## Code Conventions

### TypeScript

- Strict mode is enabled. `"strict": true` in `tsconfig.json`. There are no exceptions.
- The `no-any` ESLint rule is enforced. Use `unknown` and type narrowing, or create a typed interface.
- All async functions must handle errors explicitly. No unhandled promise rejections.

### File Naming

- Components: `PascalCase.tsx`
- Utilities and hooks: `camelCase.ts`
- API route handlers: `route.ts` in the relevant App Router directory
- Edge Functions: `index.ts` inside a `snake_case` directory under `supabase/functions/`
- Migrations: `{timestamp}_{snake_case}.sql`

### Imports

- Use the `@/` path alias for `src/` imports (configured in `tsconfig.json`).
- No default exports from utility files. Named exports only.

### Database Conventions

- All business PKs use `gen_uuid_v7()`. See the header rules in each schema doc under `Docs/sub/schemas/`.
- FKs to the business entity always reference `business_entities(id)` — never `businesses(id)`.
- RLS is required on every table. No table ships to production without RLS policies.

---

## How Docs/sub Relates to Code

`Docs/sub/` contains the authoritative specification for every system component. When you write code, find the relevant schema or policy doc first. If something in the code contradicts a doc, the doc is right unless there is a deliberate reason to deviate — in that case update the doc in the same PR.

The directory structure maps to namespaces defined in the top-level architecture overview. The `schemas/` subdirectory documents every table; the `policies/` subdirectory documents every business rule and enforcement mechanism; `guides/` provides operational guides for engineers and accountants; `reference/` holds enumerations, catalogs, and changelogs.

---

## PR Review Checklist

Before requesting review, verify:

- [ ] TypeScript compiles without errors (`pnpm tsc --noEmit`)
- [ ] All tests pass (`pnpm test && pnpm test:db`)
- [ ] New tables have RLS policies and are documented in `Docs/sub/schemas/`
- [ ] New business rules have a corresponding entry in `Docs/sub/policies/`
- [ ] Audit events follow `DOMAIN.PAST_VERB` naming convention
- [ ] No secrets committed (pre-commit hook enforces this, but double-check)
- [ ] Migration is reversible or its irreversibility is noted in the PR description
- [ ] PR description links to the relevant doc(s) from `Docs/sub/`

---

## Related Documents

- `reference/technical_architecture_overview.md` — System architecture overview
- `policies/supabase_migration_tooling_policy.md` — Migration conventions
- `policies/row_level_security_policies.md` — RLS requirements
- `policies/audit_event_naming_convention_policy.md` — Event naming rules
- `reference/error_code_catalog.md` — Error codes to use in new endpoints
- `reference/permission_matrix.md` — Role permissions for new feature areas
