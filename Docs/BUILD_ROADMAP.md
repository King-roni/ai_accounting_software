# Build Roadmap — Cyprus Bookkeeping SaaS

**As of:** 2026-05-29 · **Branch:** `build/full-snapshot-2026-05-29` · **Supabase:** `noxvmnxrqlzsdfngfiww` (eu-west-1)

This is the authoritative, dependency-ordered plan for the work that remains. Follow it top to bottom. It supersedes the Plane "Stage-3 sub-doc walk" framing — see "How Plane maps to this" at the end.

> **Progress — updated 2026-05-30 (build session 3):** ✅ **Done:** R0.1–R0.4, R1.1–R1.3, **all of R2 (R2.1–R2.8)**, **all of R3**, **all of R5 — the TimeFuserBooks "Quiet-Luxury Light" UI overhaul** (R5.0–R5.6: token foundation, shell, primitives, dashboard+periods flagships, all screens, polish + dark mode). Mockup at `Docs/design/timefuserbooks-mockup/`. ▶ **Only R4 remains** (productionization: real Anthropic/Document AI/Vault/TSA/OAuth integrations + export/statement workers + security review + deploy — needs credentials/decisions). 1Password secrets setup done (`Docs/ENV_SETUP.md`). Run E2E: `cd web && pnpm test:e2e` (26 specs green). Branch merged to **`main`** + pushed. **Frontend feature-complete AND on-brand.** **R2.6** Clients (`/clients`), Invoices + Recurring tab (`/invoices`), Workflow runs (`/periods`). **R2.7** finalization readiness checklist + step-up + Archive tab on `/periods`. **R2.8** dashboard (11 cards + drill-down, `/dashboard`) + Reports/exports (`/reports`). Deferred (engine/storage-coupled → R4): statement upload→parse viewer, adjustment re-finalization, export file-generation + signed-URL download, rich dashboard charts (→ R3). Commits: session-2 `63fc014`; session-3 R2.6 `add0932`, R2.7 `e4b735d`, R2.8 next. Test business "Demo Trading Ltd" (login `admin@admin.com`/`admin123`).

---

## 1. Verified current state (checked 2026-05-29, not assumed)

| Layer | State | Evidence |
|---|---|---|
| **Database** | ✅ BUILT + LIVE | 240 migrations applied to `noxvmnxrqlzsdfngfiww`; reference data seeded (permission_matrix 138, tool_registry 50, gate_registry 38, issue_type_registry 72, workflow_type_definitions 4, redaction_policies 16, prompt_registry 7, dashboard_card_definitions 11, matching/ledger/review/finalization/dashboard fixture registries populated, 125 audit events). All 16 blocks' schemas present across `public`, `audit`, `keys`, `secrets`, `gdpr`, `alerts`, `archive`, `auth_runtime`, `backups`. |
| **Backend logic** | ✅ BUILT | Lives in Postgres RPCs (SECURITY DEFINER) across B02–B16, including the B16 dashboard/export/pdf definition tables. |
| **API (FastAPI)** | ◑ THIN | Only `health` + `me` routes; auth/RBAC/AI-integration/hashing/secure-http libs present. 139 unit tests pass. Most logic is in the DB, not HTTP. |
| **Frontend (Next.js)** | ❌ MOSTLY UNBUILT | Only B02 surfaces exist (auth / account / team / integrations). No dashboard, review queue, invoice, ledger, or reporting UI. **This is the dominant remaining work.** |
| **Repo ↔ DB** | ⚠ DRIFT | 138 migration files in repo (several header-stubs, esp. B16) vs 240 applied in the live DB — the repo cannot currently rebuild the DB from scratch. |
| **Security** | ⚠ 17 RLS-OFF | See §2. |
| **Git** | ✅ COMMITTED | Full snapshot on `build/full-snapshot-2026-05-29` (not pushed to a remote). |

**Bottom line: the backend is ~done; the build that remains is the frontend (+ a few hardening tasks).** The 543 open Plane tickets are sub-doc *spec* deliverables, not build work — every phase-level build ticket is already Done.

---

## 2. Known issues to clear before/while building

- **RLS disabled on 17 tables** (Supabase advisor, critical). Most are fixture/reference tables; two are security-config (`secrets.secret_policies`, `auth_runtime.sensitive_surfaces`). Do NOT blanket-enable — enabling RLS without policies blocks all access. Decide per table: add a read policy, restrict to service role, or accept (reference data). Tables: `auth_runtime.sensitive_surfaces`, `secrets.secret_policies`, `public.pipeline_fixtures(+_runs)`, `classifier_fixtures(+_runs)`, `matching_fixtures(+_runs)`, `ledger_fixtures(+_runs)`, `out_workflow_fixture_registry`, `in_workflow_fixture_registry`, `review_queue_fixture_registry`, `finalization_fixture_registry`, `dashboard_card_definitions`, `export_catalogue_definitions`, `pdf_generator_registry`.
- **Repo can't reproduce the DB** — run `supabase db pull` (or dump applied migrations) into `supabase/migrations/` so the repo is the source of truth again. No rollback scripts exist either.
- **Placeholder integrations** still in placeholder mode: RFC 3161 TSA (audit chain anchoring = `PLACEHOLDER_LOCAL`), Vault (KEK/DEK), Google Document AI (OCR), Anthropic (Tier 3 AI). Real wiring needed at production cutover.

---

## 3. The remaining build — dependency-ordered

### R0 · Foundation hardening *(do first; everything sits on this)*
- **R0.1** `supabase db pull` → commit real migrations so the repo reproduces the live DB.
- **R0.2** Resolve the 17 RLS-disabled tables (policies or documented exceptions).
- **R0.3** Wire env/secrets for local + deploy: web `.env` (Supabase URL + anon key), api `.env` (service role, JWT), and confirm which integrations stay placeholder for MVP.
- **R0.4** Boot `web` (`pnpm dev`) + `api` (`uv run`) against the live DB; smoke-test the existing auth flow end to end.

### R1 · Frontend foundation *(blocks all screens)*
- **R1.1** Design system / tokens — implement `B16·P03` spec (colours, spacing, typography, Lucide icons, CSS/TS token export).
- **R1.2** Component library — `B16·P04` (buttons, inputs, tables, cards, modals, toasts; Storybook; focus-trap/a11y primitives).
- **R1.3** App shell — `B16·P05` (layout, nav, business switcher, command palette, refresh state). Auth UI already exists and plugs in here.

### R2 · Domain screens *(against existing RPCs; user-journey order)*
- **R2.1** Bank statement upload + transaction list (consumes B07 RPCs, B08 classifications).
- **R2.2** Document intake + extraction views (B09).
- **R2.3** Matching review surface (B10).
- **R2.4** Ledger / Cyprus-VAT views (B11).
- **R2.5** Review Queue UI — the 6 buckets, resolution actions, bulk preview/apply, notes/assignment, snooze (B14).
- **R2.6** OUT workflow run UI (B12) · IN workflow + **invoice generator** UI (B13: drafts, numbering, PDF, recurring, credit notes, clients).
- **R2.7** Finalization & secure-archive UI — gates, step-up, lock, archive browser (B15).
- **R2.8** Dashboard cards + drill-downs (B16·P06–P08) · exports / VAT-VIES / accountant pack / reports (B16·P09–P11).

### R3 · Cross-cutting frontend
- **R3.1** Accessibility, i18n, mobile read-only, performance (B16·P12).
- **R3.2** E2E tests + visual regression (B16·P13).

### R4 · Productionization *(superseded — detailed into the phased Pre-Testing roadmap below; the `[R4]` Plane ticket points to P2+P3)*

---

## 3b. Pre-Testing Roadmap (P0 → P3) — **the work-off order to reach the testing phase**

> Created 2026-05-31 after a full Plane + architecture scan. **Done so far:** R0–R3 foundation+screens · R5 UI · **R6 analytics** (incl. auto-refresh A6.6). The scan found R7–R9 had assumed an **execution spine that doesn't exist** → added **P0** (must come first). Four ordered Plane cycles, one per phase. **Start at P0.1.** Minimum to run a local end-to-end test = **P0 + P1**; real testing adds P2; testing on the VPS adds P3.
>
> **Env:** local `.env` set — Supabase service-role + `INTEGRATION_TOKEN_ENC_KEY` + `ANTHROPIC_API_KEY` (+ optional `GEMINI_API_KEY`). No Document AI / Vault / TSA needed to test.
> **OCR decision:** Claude vision is the default extractor (optional Gemini Flash for cheap bulk) — **Google Document AI dropped** (cost). See R8.2.

### 🔴 P0 · Execution Spine & Self-Serve  *(Plane cycle "★ Pre-Testing P0" — the missed foundation, blocks everything)*
- **P0.1** Pipeline orchestrator/worker — consume the outbox + run state, sequence the existing `start_/record_/complete_/evaluate_*_gate/transition_run` RPCs to drive a run end-to-end. *(THE big one; decide runtime: Supabase Edge Fn vs api worker vs standalone consumer.)*
- **P0.2** Client byte-upload — actually PUT file bytes to the signed URL after `request_raw_upload` + emit the completion event (statement + document drawers).
- **P0.3** Org + business creation + first-run onboarding — `create_organization`/`create_business` RPCs + onboarding route so a fresh signup self-serves (today orgs exist only via dev `seed.sql`).
- **P0.4** Scheduler — install `pg_cron` + schedule `recurring_run_daily_scheduler` / pro-forma expiry / worker ticks.
- **P0.5** Export-artifact bucket + signed-download wiring.

### 🟠 P1 · Local end-to-end completeness  *(cycle "★ Pre-Testing P1 (R7)" — buildable now, no keys)*
- **R7.1** export generation worker · **R7.2** statement parse→viewer (CSV) · **R7.3** notifications · **R7.4** personal audit feed · **R7.5** /account-in-shell · **R7.6** real VIES · **R7.7** perf budgets + visual-regression · **R7.8** adjustment re-finalization · **R7.9** demo seed + housekeeping.

### 🟡 P2 · Real integrations  *(cycle "★ Pre-Testing P2 (R8)" — keys injected)*
- **R8.1** Anthropic · **R8.2** document OCR via LLM vision (Claude default + optional Gemini; **no Document AI**) · **R8.3** Google OAuth Gmail/Drive finders · **R8.4** Vault KEK/DEK · **R8.5** RFC-3161 TSA · **R8.6** secrets + health · **R8.8** email provider · **R8.7** real-integration e2e verify.

### 🟢 P3 · Deploy & hardening  *(cycle "★ Pre-Testing P3 (R9)")*
- **R9.1** security / RLS sweep · **R9.2** backup/DR drill · **R9.3** VPS + Coolify + storage + DB · **R9.4** Tailscale + Caddy · **R9.5** deploy + smoke · **R9.6** observability.

---

## 4. How Plane maps to this

**Encoded in Plane 2026-05-29:**
- **Backend block cycles** `#02 B02 … #16 B16` are ordered by build position and reflect the *backend* build (done). Backlog spec-debt was moved out (see below), so #02–#15 now show only their Done phase tickets.
- **★ Remaining Build (R0–R4) cycle** + **module `#17 · Remaining Build`** hold the 17 actionable build tickets (R0.1 … R4). **This is the board to follow.**
- **⏸ Spec-debt (deferred · post-MVP) cycle** holds the **416** transferred `·SD` spec tickets (out of ~503). Not build work; parked for reference.
- **Residual:** B16's 87 `·SD` could not be transferred (Plane blocks transfer from the active cycle) — they remain in the `#16 B16` cycle, labeled as spec-debt. The real dashboard build is tracked in R2.8 + R3, not those tickets.

---

## 5. One-glance "what's left"
1. Capture the live DB into repo migrations (R0.1).
2. Lock down the 17 RLS tables (R0.2).
3. Build the frontend: design system → components → shell → domain screens → dashboard/reports (R1–R2). ← **~80% of remaining effort**
4. A11y/i18n/perf + E2E (R3).
5. Wire real integrations + deploy (R4).
