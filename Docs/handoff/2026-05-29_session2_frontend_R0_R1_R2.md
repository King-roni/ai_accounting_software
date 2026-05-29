# Handoff — Frontend Build Session (R0 + R1 + R2.1–R2.5)

**Date:** 2026-05-29 (build session 2) · **Branch:** `build/full-snapshot-2026-05-29` · **Supabase:** `noxvmnxrqlzsdfngfiww`

Continues `2026-05-29_build_correction_and_roadmap.md`. That session corrected the framing (backend is built; the work is the frontend) and produced `Docs/BUILD_ROADMAP.md`. **This session built the foundation + the first 5 domain screens.**

---

## ⚠️ Read this first
- **The entire session's work is UNCOMMITTED** (~19 changes: the whole `web/src/app/(app)/` route group, `web/src/components/{ui,shell,transactions,documents,matching,ledger,reviews}`, `web/src/theme`, `web/src/lib/cn.ts`, plus `supabase/migrations/_baseline/` + the R0.2 RLS migration). **Commit early next session** (lead hasn't been asked yet — ask before committing).
- **Live DB was seeded with test data** (see below). Test login `admin@admin.com` / `admin123` now owns a populated business.

---

## What was completed (12 Plane tickets, all verified in-browser)

| Ticket | Result |
|---|---|
| **R0.1** Live DB → repo | MCP-introspected baseline `supabase/migrations/_baseline/20260529T000000_live_schema_baseline.sql` (5724 stmts, all object counts match live) + README. Not replay-tested on a scratch DB (documented). `pg_dump` supersedes it once a DB URL exists. |
| **R0.2** RLS lockdown | 17 tables secured on live + repo migration `20260529000001_*` + rollback. Advisor `rls_disabled` → 0. |
| **R0.3** Env/secrets | `api/.env` + `web/.env.local` wired (value-blind). **API uses JWKS, not a JWT secret.** |
| **R0.4** Boot + auth e2e | web `pnpm dev` + api `uv run uvicorn cyprus_bookkeeping_api.main:app --app-dir src`. Verified login→`/me` 200. |
| **R1.1** Design system | `web/src/app/globals.css` (tokens, Tailwind 4 `@theme`), `web/src/theme/{tokens.ts,icons.tsx}`, Inter+JetBrains Mono, light/dark via `[data-theme]` + no-flash script in `layout.tsx`. |
| **R1.2** Component library | `web/src/components/ui/` — Button, Badge, Alert, Card, Skeleton, Empty/Error, Input, Textarea, Select, Tabs, Modal, Drawer, Table, Toast, Popover (+ `cn`). Gallery at `/ui-gallery`. |
| **R1.3** App shell | `web/src/components/shell/` + `(app)/layout.tsx`: top nav, collapsible sidebar, business switcher (live), period switcher (shell state), theme toggle, Cmd+K command palette, notifications drawer, mobile bottom nav, skip link. `/` → `/dashboard`. |
| **R2.1** Transactions | `(app)/transactions` — list + stats + filters + detail drawer + upload drawer (`request_raw_upload`). |
| **R2.2** Documents | `(app)/documents` — intake list + extraction review (per-field confidence) + upload drawer. |
| **R2.3** Matching | `(app)/matching` — card review, signal bars, plain-language reasons, **Confirm/Reject wired to `user_confirm_match`/`user_reject_match` (verified working)**. |
| **R2.4** Ledger / VAT | `(app)/ledger` — VAT summary (input/output/net), reverse-charge/VIES flags, accountant-review, chart-of-accounts name resolution, detail drawer. |
| **R2.5** Review queue | `(app)/reviews` — 5 buckets, severity-sorted plain-language cards, resolution routing, **Assign/Snooze wired to `review_queue_assign`/`snooze_apply` (verified, with decision-object handling)**. |

Domain screens: **5 of 8 done.** Remaining: R2.6, R2.7, R2.8.

---

## Patterns established (reuse for R2.6+)
- **Data screen pattern:** client component → `useSWR(['key', businessId, ...], fetcher)` with `createSupabaseBrowserClient()` (RLS-scoped by the user's session) → filter by `useShell().currentBusiness.id` + period (`periodRange(period)` in `transaction-helpers`). Reactive to business/period switches; no page reload.
- **R1 components** compose every screen (Table generic, Badge severity/status, Drawer for detail, EmptyState/ErrorState/Skeleton, Select/Input filters).
- **Write actions** call RPCs via `supabase.rpc(fn, args)`; **many B14/B10 RPCs return a `{decision, status_after, reason}` payload instead of throwing** — check `data.decision !== 'ALLOW'` (see `(app)/reviews/page.tsx`), not just the `error`.
- **Actor id**: RPCs want `p_actor_user_id` = `useShell().user.id` (public.users.id, now on the shell context).
- **Seeding test data** (per screen, via Supabase MCP `execute_sql`): inspect NOT-NULL-no-default cols + CHECK/FK constraints first. Learned gotchas: signed amounts (txn IN>0/OUT<0), 64-hex hashes (`md5()||md5()`), single-sided ledger entries (`dle_exactly_one_side_chk`), match XOR (`matched_by_system`), chart_of_accounts FK on ledger account codes.

## Important fixes / notes
- **CSS cascade-layer fix:** base element styles in `globals.css` are now in `@layer base` so Tailwind utilities override them (an unlayered `a{color}` was making `<a>`-as-button labels invisible). Keep new base element rules inside `@layer base`.
- **`uv run` needs `--app-dir src`** for the API (src layout).
- **supabase CLI doesn't work here** (brew CLT too old; v2.102 prebuilt crashes). Use the MCP + `pg_dump` (libpq present).

## Deferred (noted in each ticket, not yet built)
- Document/PDF **image render** pane (needs storage + PDF renderer); Gmail/Drive **finder run** UI (workflow-driven); re-OCR.
- Statement **upload→parse→dedup results** viewer (workflow-coupled, lives in R2.6 OUT/IN run UI).
- Matching split-payment + manual invoice search; review-queue **bulk** actions + generic resolve-with-note/escalate (no single RPC — dispatches to block RPCs); notes/activity log.
- Storybook (→ R3), E2E + visual regression (→ R3), mobile read-only **enforcement** (→ R3), permission-gated sidebar hide (needs permission resolver), DB-persisted shell prefs + `DASHBOARD_*` audit events.

---

## Seeded test data (live, via MCP) — fixed UUIDs
- Org `0e000000-0000-4000-8000-000000000001`; **Business `…0b1` "Demo Trading Ltd"** (admin = OWNER via `business_user_roles`).
- Bank account `…0a1`, statement_upload `…0c1`.
- **6 transactions** (May 2026), **3 documents** (d1 AWS / d2 Costa / d3 rent), **3 match_records** (one confirmed this session), **3 draft_ledger_entries** (+ chart_of_accounts 7503/7100/7400 + mapping version `…0e1`), **review_issues** across all 5 buckets (one MEDIUM snoozed this session).

---

## Where to resume: R2.6
**R2.6 — OUT + IN workflow run UI + Invoice generator (B12/B13).** The largest remaining ticket: OUT_MONTHLY/IN_MONTHLY run views (phases, holds, gates, approvals) + invoice generator (drafts, numbering, PDF, recurring, credit notes, clients). This is also where the statement upload→parse→results viewer belongs.

Then **R2.7** (finalization & archive, B15), **R2.8** (dashboard cards + exports, B16·P06–P11), **R3** (a11y/i18n/E2E), **R4** (productionization).

## How to work (unchanged)
Take an R-ticket → **In Progress** → seed data via MCP if the screen needs it → build against existing RPCs/tables → **verify in the browser** (Playwright: navigate, screenshot, check console, exercise one write-path) → **Done**. One ticket at a time, top-down. Run `pnpm lint`/`tsc --noEmit` (scope to new files). Be economical with reads (the spec tables are self-describing; avoid the 900KB advisor dump). Servers: web :3000, api :8000.
