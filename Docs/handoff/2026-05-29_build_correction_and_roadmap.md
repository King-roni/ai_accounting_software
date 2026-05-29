# Handoff — Build Correction & Roadmap (2026-05-29)

**Supersedes** the prior "Stage-3 sub-doc walk" handoffs. Those used a framing that turned out to be wrong (see below). For the plan going forward, read `Docs/BUILD_ROADMAP.md`. To start the next session, use `Docs/BUILD_START_PROMPT.md`.

---

## What happened this session

The session began continuing a "Stage-3 sub-doc backlog walk" — writing canonical sub-docs for Plane tickets. **That framing was wrong.** Investigation (triggered by the project lead asking "why are we only making .md files when the codebase is full of code?") revealed:

1. **The product is already built at the backend layer.** 240 migrations are applied and live on Supabase `noxvmnxrqlzsdfngfiww`; reference data is seeded; backend logic lives in Postgres RPCs across all 16 blocks. Verified 2026-05-29 via `list_migrations` + `list_tables`.
2. **Plane's per-block "backlog" is a SPEC walk, not a build to-do list.** Every phase-level build ticket was already Done; the ~543 open tickets were all `·SD` sub-doc spec stubs. Following that backlog = re-documenting already-built code.
3. **50 redundant sub-doc `.md` files written earlier in the session were deleted**, and the 41 Plane tickets closed during that work were reverted to Backlog.

## What was corrected / done

- **Repo committed** (it was entirely untracked — a major risk). Commit `92664f2` on branch `build/full-snapshot-2026-05-29`: 220 migrations + api + web + 704 sub-docs + scripts/prompts. `.playwright-mcp/` ignored. No secrets committed.
- **Plane cycles reordered** to canonical dependency build order and renamed `#02 B02 … #16 B16` (was `Stage-3 · BNN`), with sequential dates + truthful descriptions. (One cosmetic residual: `#02 B02` is locked with a literal `&amp;` — Plane locks past-dated cycles.)
- **Foundation verified:** DB live + seeded; **139 API unit tests pass**; frontend confirmed unbuilt (only B02 auth in `web/`).
- **Security finding:** Supabase advisor flags **17 RLS-disabled tables** (tracked as R0.2).
- **Reproducibility gap:** repo migration files (138, some stubs) don't fully rebuild the live DB (240 applied) — tracked as R0.1.
- **Roadmap created:** `Docs/BUILD_ROADMAP.md` (R0–R4, dependency-ordered).
- **Plane encoded for build:** new module **`#17 · Remaining Build`** + cycle **★ Remaining Build (R0–R4)** with 17 actionable tickets; **416 spec-debt tickets parked** in the **⏸ Spec-debt (deferred)** cycle (B16's 87 couldn't transfer — active cycle — left labeled).

## Final Plane state
- Work the **★ Remaining Build (R0–R4)** cycle / **#17** module (17 tickets).
- Backend block cycles `#02–#15` are clean (Done only). `#16 B16` keeps 87 spec-debt (labeled).
- `⏸ Spec-debt (deferred · post-MVP)` = 416 parked spec tickets. Ignore for build.

## Key facts for whoever picks this up
- **Don't write sub-docs. Don't treat Plane block backlogs as unbuilt. Verify against the DB/code before assuming anything is missing.**
- Real remaining work = **frontend** (Next.js, ~80% of effort) + R0 hardening + R4 productionization.
- Memory: `project-build-vs-plane-state`, `project-canonical-build-order` (file memory). KG resume pointer updated.
