# Environment & secrets setup

Single source of truth: **1Password**. The committed templates carry public config
inline and `op://` references for secrets; a one-liner materialises the real,
gitignored `.env` files. Nothing secret is committed or hand-copied.

| File | Committed? | Holds |
|---|---|---|
| `web/.env.local.example`, `api/.env.example` | ✅ yes | public values + `op://` refs (the templates) |
| `web/.env.local`, `api/.env` | ❌ gitignored | the resolved, runnable values |

**Public vs secret** (the only classification that matters):
- 🌐 Public — `NEXT_PUBLIC_*`, `SUPABASE_URL`, publishable/anon key, project ref, JWT audience. Safe in the browser bundle; RLS protects the data.
- 🔴 Secret — `SUPABASE_SERVICE_ROLE_KEY` (bypasses RLS), `INTEGRATION_TOKEN_ENC_KEY` (encrypts OAuth tokens, 32-byte hex). Server-only, 1Password-managed, never `NEXT_PUBLIC_`.

The API authenticates via **JWKS** — there is no JWT signing secret to manage.

---

## One-time setup

```bash
# 1. Install + sign in to the 1Password CLI (macOS)
brew install 1password-cli
op signin                      # or: enable the CLI in the 1Password app → Developer

# 2. Seed the vault from your existing local secrets (reads web/.env.local + api/.env,
#    creates the 'Boekhoudings-Dev' vault + items, never prints values; also mints
#    INTEGRATION_TOKEN_ENC_KEY if you don't have one yet)
OP_VAULT=Boekhoudings-Dev ./scripts/bootstrap-1password.sh

# 3. Generate the runnable env files from 1Password
./scripts/sync-env.sh
```

Then run as usual — Next.js and pydantic read the normal `.env` files:

```bash
cd web && pnpm dev
cd api && uv run uvicorn cyprus_bookkeeping_api.main:app --app-dir src
```

Rotating a secret = change it in 1Password, then `./scripts/sync-env.sh`.

### Zero-secrets-on-disk variant (optional)
Skip step 3 and inject secrets only into the process at launch:
```bash
op run --env-file=web/.env.local.example -- pnpm dev
op run --env-file=api/.env.example       -- uv run uvicorn cyprus_bookkeeping_api.main:app --app-dir src
```

---

## Production

No `.env` files in prod — inject from the platform's secret store:
- **Web → Vercel**: add the same keys as project env vars; mark `SUPABASE_SERVICE_ROLE_KEY` and `INTEGRATION_TOKEN_ENC_KEY` **Sensitive**, scope to Production. (1Password can push these via a Service Account in CI.)
- **API → host secret manager** (or `op run` in the start command via a 1Password Service Account token).

Use a **vault per environment** — `Boekhoudings-Dev` / `-Staging` / `-Prod` — so dev access never implies prod access. Set `OP_VAULT` (and the `op://` refs in the templates) per environment.

---

## R4 secrets to provision (when those integrations go live)
Add as items in the env's vault and reference them from the templates as you wire each one:

| Secret | For |
|---|---|
| `ANTHROPIC_API_KEY` | Tier-3 AI (Block 06) |
| Google **Document AI** service-account JSON + processor id | OCR (Block 09) |
| **Vault** address / token / transit key | KEK/DEK envelope encryption |
| **RFC 3161 TSA** endpoint + credentials | audit-chain timestamp anchoring (Block 01) |
| Google **OAuth** client id + secret | Gmail/Drive evidence finders (tokens stored encrypted via `INTEGRATION_TOKEN_ENC_KEY`) |
