# Block 11 — Phase 03: Per-Business Chart Customization & Versioning

## References

- Block doc: `Docs/blocks/11_ledger_and_cyprus_vat_engine.md` (Chart of Accounts — "Mapping rules are versioned per business so historical periods continue to render correctly even after the chart is changed")
- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (lock semantics — finalized periods must remain renderable)

## Phase Goal

Let users extend or override the seeded chart per business — add accounts, rename them, disable them, change mapping rules — while making sure finalized periods continue to render exactly as they did at finalization. The mechanism is version-pinning: every draft ledger entry carries the `chart_mapping_version_id` it was computed against; a finalized period freezes that version's mapping rules permanently.

## Dependencies

- Phase 01 (`chart_of_accounts`, `chart_of_accounts_mappings`, `chart_of_accounts_mapping_versions`)
- Phase 02 (default seed must already be loaded — customization layers on top)
- Block 02 Phase 04 (permission matrix — only Owner or Admin can edit the chart)
- Block 15 (finalization — freezes a mapping version on period close)

## Deliverables

- **Customization API** (called from Block 02's settings surface; Stage 1 settings UI is desktop-only):
  - `chart.addAccount({ business_id, code, name, account_class, parent_code?, category?, deductibility? }) → account` — creates a non-seeded account.
  - `chart.renameAccount({ business_id, code, new_name }) → account` — name only; `code`, `account_class`, and `deductibility` are immutable post-creation.
  - `chart.disableAccount({ business_id, code }) → account` — sets `disabled_at`; existing references remain renderable; new mapping rules cannot select a disabled account.
  - `chart.addMappingRule({ business_id, transaction_type?, tag?, vat_treatment?, entry_kind?, direction, account_code, priority }) → mapping_rule`.
  - `chart.disableMappingRule({ business_id, mapping_rule_id }) → mapping_rule` — sets `disabled_at`; existing draft entries that referenced the rule still resolve via the version-pin.
  - **Permission gate:** Owner and Admin only; Bookkeeper, Accountant, Reviewer, Read-only are denied.
  - **Audit per call:** the corresponding event from Phase 01's audit list is emitted with the user, before/after payload, and the active mapping-version id.
- **Mapping-version increment rule:**
  - Any of the customization calls above creates a new `chart_of_accounts_mapping_versions` row by default — the current version is closed, a new version with `version_number = previous + 1` and `effective_from = now()` is created. New chart/mapping rows reference the new version.
  - **Batch customization:** an explicit `chart.beginBatch()` / `chart.commitBatch()` pair lets the user make multiple edits under a single new version (e.g., adding three new sub-accounts at once produces one version increment, not three). Default `effective_from` is the batch-commit time.
  - **Effective-from in the past is forbidden** in Stage 1 — `effective_from` is always `now()` (the system clock at increment time). Backdated chart changes are deferred to Stage 2+ via a sub-doc.
- **Period → mapping-version resolution:**
  - When Phase 07 prepares a draft ledger entry for transaction `t`, it resolves the active mapping version for `t.entry_period` by selecting the version with the largest `effective_from <= t.entry_period_start`. The resolved version's `id` is pinned on the draft entry's `chart_mapping_version_id`.
  - Re-deriving a draft (Phase 07's recompute path) re-pins to the same resolved version unless the period is currently `DRAFT` and the user has changed the chart in the interim — in which case the recompute uses the now-current resolved version. Once a period is finalized, its entries' `chart_mapping_version_id` is immutable.
- **Freeze on finalization:**
  - **Pre-finalization invariant (Phase 09 enforces; restated here for clarity):** before a period can transition from `DRAFT` to `READY_FOR_FINALIZATION`, every `draft_ledger_entries` row in that period must share a single `chart_mapping_version_id`. If a user customized the chart mid-period while entries were already drafted against an older version, Phase 09's pre-exit recompute pass re-derives every entry against the now-current version so the period is uniform. Block 15 never sees a multi-version period.
  - When Block 15 finalizes a period, it calls `chart.freezeVersionForPeriod({ business_id, mapping_version_id })` with the single version id all of that period's entries pin. The version row's `frozen_at` is set; subsequent edits to that version's accounts or mapping rules are blocked at the database layer (a CHECK constraint or an UPDATE trigger; sub-doc decides).
  - **If the same version is shared by a still-`DRAFT` later period**, freezing it on the earlier period's finalization also locks the later period to that version. This is intentional — a frozen version is permanent across every period that pinned it. Customizations after the freeze always create a successor version (`version_number + 1`); they never mutate the frozen one.
  - A frozen version cannot be re-opened by any non-privileged path. The Block 15 reopen-period flow re-creates a fresh successor version rather than mutating the frozen one.
- **Disabled-account semantics:**
  - A disabled account remains FK-valid for existing draft and locked entries.
  - Phase 07's mapping resolver skips disabled accounts when selecting a target. If every applicable rule resolves to a disabled account, the entry is flagged `requires_accountant_review` (Phase 08) with reason `"Mapped account is disabled — please pick a successor."`.
- **Audit events** (declared in Phase 01; emitted by this phase):
  - `CHART_ACCOUNT_CREATED`, `CHART_ACCOUNT_DISABLED`, `CHART_ACCOUNT_UPDATED`
  - `CHART_MAPPING_RULE_CREATED`, `CHART_MAPPING_RULE_DISABLED`
  - `CHART_MAPPING_VERSION_CREATED`, `CHART_MAPPING_VERSION_FROZEN`

## Definition of Done

- A customization edit creates a new mapping-version row; default `effective_from` is `now()`.
- A batch edit produces exactly one version increment.
- A draft ledger entry pins `chart_mapping_version_id` to the version active at the entry's period.
- After finalization, that version's `frozen_at` is set and edits to its accounts or mapping rules are blocked.
- Re-rendering a finalized period uses the frozen version and produces identical output regardless of subsequent chart customizations.
- Disabling an account and then running the resolver against a transaction whose default rule points at the disabled account raises an accountant-review flag.
- Permission gate blocks non-Owner/Admin roles; tests cover the deny path.

## Sub-doc Hooks (Stage 4)

- **Customization API contract sub-doc** — exact JSON shapes, error cases, idempotency.
- **Version-pin resolution sub-doc** — the SQL query plan, edge cases at period boundaries.
- **Freeze-mechanism sub-doc** — DB-level enforcement (CHECK constraint vs trigger), error messages on attempted edits.
- **Backdated-edit deferred-feature sub-doc** — what Stage 2+ would need to support `effective_from < now()`.
- **Settings-UI sub-doc** — desktop-only Stage 1 layout, permission visibility.
