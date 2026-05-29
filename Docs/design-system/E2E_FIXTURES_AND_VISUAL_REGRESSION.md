# End-to-End Dashboard Tests & Visual Regression

The regression-test layer for Block 16's full surface. 110 fixtures across 12 categories. The catalog lives in `dashboard_fixture_registry`; the actual harness (Storybook + Playwright + axe-core + Percy/Chromatic) runs in the app/CI layer.

**Phase**: B16·P13 (BOOK-160) · **Source spec**: `Docs/phases/16_dashboard_and_reporting/13_end_to_end_dashboard_tests_and_visual_regression.md` · **Schema**: `dashboard_fixture_registry` + 3 RPCs + `v_dashboard_fixture_coverage` from `20260526000038_b16p13_e2e_fixtures_and_visual_regression.sql`

This is the **final phase of Block 16** and the **final phase of Stage 2**.

---

## Coverage summary

| Category | Count | Producing phase |
|---|---|---|
| CARD_RENDERING | 16 | B16·P06 |
| DRILL_DOWN | 18 | B16·P02 + B16·P08 |
| MULTI_BUSINESS | 7 | B16·P07 |
| REFRESH_STATE | 6 | B16·P07 |
| EXPORT | 8 | B16·P09 |
| PDF_DETERMINISM | 9 | B16·P10 |
| ACCOUNTANT_PACK_AND_VIES | 10 | B16·P11 |
| ACCESSIBILITY | 9 | B16·P12 |
| I18N | 5 | B16·P12 |
| MOBILE_READ_ONLY | 6 | B16·P12 |
| PERFORMANCE | 6 | B16·P12 |
| VISUAL_REGRESSION | 10 (baseline-only) | B16·P13 |
| **Total** | **110** | |

Query at runtime via `SELECT * FROM v_dashboard_fixture_coverage` or `SELECT * FROM list_dashboard_fixtures(<category>)`.

---

## Fixture file structure (canonical 9-file shape)

Every functional fixture has the same nine files in `Docs/phases/16_dashboard_and_reporting/fixtures/<fixture_name>/`. Files that are not applicable for a given fixture are present but empty (or contain `{}` for JSON).

| File | Purpose |
|---|---|
| `business_state.json` | Tenant + roles + permissions snapshot at test start |
| `pre_dashboard_state.json` | Operational + analytics + archive DB state at the start of the test |
| `expected_dashboard_render.json` | Per-card data + severity + click-through targets |
| `expected_drill_down_results.json` | Per-route row sets the drill-down query must return |
| `expected_export_artifacts.json` | Per-export hash + byte size |
| `expected_pdf_hashes.json` | Deterministic PDF byte-hash (SHA-256) per generator |
| `recorded_axe_results.json` | axe-core baseline (zero violations expected for green fixtures) |
| `expected_audit_events.json` | Audit events the flow must emit, in order |
| `recorded_step_up_auth_responses.json` | Pre-recorded TOTP / passkey responses for fixtures that need step-up |

Visual regression baselines are an exception — their files live in the Percy/Chromatic baseline store, not in the fixture directory. The registry row records the canonical fixture name; the matrix expansion (`light/dark x 375/1024/1440` = 6 snapshots) is owned by the visual-regression-library-choice sub-doc.

---

## 3 RPCs

- `register_dashboard_fixture(fixture_name, category, description, sub_doc_ref, producing_phase, is_baseline_only, ctx)` — idempotent UPSERT. Used by the seed migration + app-layer bootstrap. Returns `{decision: 'OK', fixture_name}`.
- `list_dashboard_fixtures(category)` — returns rows in the registry. `category = NULL` returns everything. SECURITY DEFINER, STABLE, GRANT EXECUTE TO authenticated.
- `run_dashboard_fixture(fixture_name, ctx)` — **stub** returning `{status: 'NOT_IMPLEMENTED', fixture_name, message}`. Raises `FIXTURE_NOT_FOUND` for unknown names. The actual orchestration (Storybook story load → axe-core → DOM capture → diff vs `expected_*.json` → screenshot diff vs Percy baseline) lives in the app layer at `tests/dashboard/runDashboardFixture.ts`.

---

## Test runner contract — `runDashboardFixture(fixture_name)`

The app-layer harness loops over fixture rows and for each:

1. Looks up the registry row to confirm category + producing_phase.
2. Loads the fixture directory's 9 JSON files.
3. Sets up the test business + tenancy + analytics state from `business_state.json` + `pre_dashboard_state.json`.
4. Loads recorded auth / step-up responses (if applicable).
5. Executes the relevant flow:
   - **CARD_RENDERING / VISUAL_REGRESSION**: load the Storybook story, snapshot the DOM, optionally Percy/Chromatic diff.
   - **DRILL_DOWN**: navigate to the drill-down route, capture row set, diff vs `expected_drill_down_results.json`.
   - **EXPORT**: call `request_export` via the app-layer wrapper, poll for COMPLETED, hash the bundle, diff vs `expected_export_artifacts.json`.
   - **PDF_DETERMINISM**: invoke the generator with the snapshot input, hash the bytes, diff vs `expected_pdf_hashes.json`.
   - **ACCOUNTANT_PACK_AND_VIES**: full pipeline through `validate_accountant_pack_request` → composition → `mark_accountant_pack_completed`.
   - **ACCESSIBILITY**: run axe-core, diff results vs `recorded_axe_results.json`.
   - **I18N / MOBILE_READ_ONLY / PERFORMANCE / REFRESH_STATE / MULTI_BUSINESS**: per-category bespoke harness logic.
6. Captures audit events emitted during the flow; diff vs `expected_audit_events.json`.
7. Reports per-step pass/fail with diff payloads on failure.

Returns `FixtureResult { fixture_name, status, diffs, axe_violations, screenshot_paths }`.

---

## Visual regression matrix

For each VISUAL_REGRESSION baseline fixture:

| Theme | Breakpoint | Snapshot count |
|---|---|---|
| Light | 375 px | 1 |
| Light | 1024 px | 1 |
| Light | 1440 px | 1 |
| Dark | 375 px | 1 |
| Dark | 1024 px | 1 |
| Dark | 1440 px | 1 |

**6 snapshots per baseline x 10 baselines = 60 visual-regression snapshots** in the Percy/Chromatic store.

### Baseline acceptance policy

- CI does NOT auto-approve drift.
- An intentional design change requires explicit baseline acceptance in the PR review.
- Per-component breakpoint-specific overrides require a sub-doc amendment.

---

## CI integration

- Runs on every PR touching Block 16 phase code, fixtures, or any Block 16 dependency.
- Failure blocks merge.

### Performance budget for the runner itself

| Suite | Budget |
|---|---|
| axe-core | < 60 s |
| Visual regression | < 120 s |
| Full Block 16 fixture run | < 300 s |

---

## Three tricky rules (engineering must honor)

- **Visual regression baselines require explicit human acceptance** — CI does NOT auto-approve. An intentional design change must be reviewed and the baseline explicitly updated; otherwise the diff fails the build. **Drift-by-stealth is the enemy** — silent baseline-shift is how a design system rots.
- **PDF determinism is verified by byte-hash, NOT visual diff** — font / library version drift causes byte-level changes that visual diff would miss. The `expected_pdf_hashes.json` SHA-256 match is the contract. B16·P10's font-pinning + library-version-pinning + the `pdf_generate_font_pinning_drift_detected` fixture backstop this. **Do NOT replace byte-hash with visual diff "because it's slow"** — they verify different invariants.
- **Fixture file structure is canonical — do NOT add ad-hoc files per fixture** — every functional fixture has the same 9-file shape (some files may be empty / `{}` when not applicable). Adding a 10th file type for one fixture forces every other fixture's harness loop to special-case it. New file types require a sub-doc amendment, not per-fixture creativity. **Consistency lets the harness loop generically.**

---

## No audit events

Fixture pass / fail are CI artifacts, NOT Block 05 audit-log emissions. This mirrors the pattern established by every prior block's Phase 10 (`finalization_fixture_registry`, `intake_fixture_registry`, etc.) — registry rows describe the fixture; harness output flows to CI logs + Percy/Chromatic, not the audit chain.

---

## Definition of Done

- All 110 fixtures exist in the registry with category + producing_phase + description.
- Running the test runner against any fixture produces the expected output exactly (app-layer responsibility).
- A deliberate change that breaks any Block 16 phase makes the right fixtures fail with clear diffs.
- Deterministic-PDF invariant verified — same input -> byte-identical PDF.
- Deterministic-accountant-pack invariant verified.
- VIES XML XSD validation passes.
- All accessibility fixtures pass axe-core.
- Cyprus locale formatting verified.
- Mobile read-only constraint verified at client + server layers.
- CWV budgets met in Lighthouse CI.
- Visual regression baseline captured for every page × theme × breakpoint.
- Performance budget met for the test runner itself.

---

## Sub-doc hooks (Stage 4)

- Fixture format — directory structure, file naming, JSON shapes
- Visual regression library choice — Percy vs Chromatic vs custom
- axe-core CI integration — per-story coverage; regression-blocking config
- Lighthouse CI configuration — budget thresholds; per-route variants
- Step-up auth simulation — how to mock TOTP / passkey responses
- PDF determinism CI — font / library version pinning verification
- Cross-block fixture-stitching — how B16's fixtures inherit state from Blocks 12 / 13 / 15
- Performance budget — measurement methodology; per-fixture timing
- Visual-regression baseline-acceptance UX — PR review pattern for design changes
