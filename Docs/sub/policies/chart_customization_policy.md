# chart_customization_policy

**Category:** Policies · **Owning block:** 11 — Ledger & Cyprus VAT · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the binding rules for customising the chart of accounts per business. The chart is the structured list of ledger account codes used to record every debit and credit entry. Customisation rules are strict because chart changes have system-wide consequences: they affect ledger entry generation, VAT treatment mapping, the accountant pack, and VIES reporting.

---

## Section 1 — Chart derivation model

Every business's chart of accounts is derived from the **system default chart** — the canonical Cypriot SME chart maintained by the platform (Block 11 Phase 02). At business creation, a copy of the current default chart is provisioned for the business via `ledger.initialize_chart`. This provisioned chart becomes the business's chart from which customisations are made.

The system default chart is not shared at runtime — each business holds its own copy. Changes to the system default chart by the platform team do not propagate to existing businesses' charts automatically; migrations are explicit.

The account numbering scheme follows the Cyprus standard account number structure. System accounts use the standard number ranges. Custom accounts use **reserved ranges** defined in `ledger_account_mapping_schema` (Block 11 Phase 01). Writing a custom account with a number outside the reserved ranges is rejected by `ledger.update_chart`.

---

## Section 2 — Additive-only constraint

Customisations to a business's chart are **additive only**:

- System accounts (accounts present at chart initialisation time) **cannot be deleted**.
- System accounts **cannot be renumbered** (the account code is immutable once provisioned).
- System accounts **cannot be restructured** — the parent/child hierarchy of system accounts is fixed.
- System accounts **can be renamed** — see Section 4.
- **Custom accounts** (added by the business) can be added, renamed, and marked inactive (Section 5). Custom accounts cannot be deleted; they are soft-deleted (inactivated).

The additive constraint ensures that historical ledger entries always have a valid account code reference. Removing or renumbering an account that historical entries reference would break ledger reconstruction for auditing or re-finalization.

---

## Section 3 — Account hierarchy

System account hierarchy is fixed. The parent/child tree is seeded from the Cyprus standard chart structure at initialisation and is not modifiable per business.

Custom accounts may be added as **children** of system accounts. A custom account inherits the account class (asset, liability, equity, income, expense) from its parent system account. A custom account may also be a child of another custom account, but the root ancestor must always be a system account.

The maximum hierarchy depth for custom accounts is **3 levels below a system account** (to keep the chart manageable in reporting). Attempting to add a custom account at depth 4 or greater below a system account is rejected by `ledger.update_chart`.

---

## Section 4 — Account renaming

Account names may be renamed by users with the **Owner or Admin** role. Renaming applies to:
- System account display names (the underlying code is unchanged).
- Custom account names.

Rules:
- The display name must be non-empty, maximum 200 characters.
- The display name must be unique within the business's chart at the same hierarchy level (siblings cannot share a name).
- Renaming does not affect historical ledger entries — the historical entries carry the account code, not the display name. Reporting always resolves the display name from the chart at the time of report generation.

---

## Section 5 — Custom account inactivation

A custom account may be marked **inactive** (soft delete). An inactive account:
- Does not appear in the account picker for new ledger entries or mapping rules.
- Does not accept new debit or credit entries (`ledger.prepare_entries` rejects an inactive account code).
- Retains all historical entries — existing entries on an inactive account are preserved and remain in reports.
- May be reactivated by an Owner or Admin at any time.

System accounts **cannot be inactivated** in MVP. If a system account is no longer applicable for a business, the business may zero its mapping rules, but the account remains in the chart and visible in reports.

---

## Section 6 — Access control

Chart mutations require the **Owner or Admin** role on the business, enforced by `canPerform('CHART_WRITE', business_id)` in Block 02 Phase 04.

The `ledger.update_chart` tool is the sole tool that performs chart mutations. No other tool may write to `chart_of_accounts` rows directly. `ledger.update_chart` is declared with side-effect classes `WRITES_RUN_STATE | WRITES_AUDIT` and AI tier `NONE`.

---

## Section 7 — Non-retroactivity

Chart changes do **not** retroactively affect historical ledger entries. A renamed account is displayed with its new name in all reports (since reports resolve names at generation time), but the underlying entries are unchanged. An inactivated account still appears in historical reports because it had active entries at the time those entries were made.

Finalized periods are immutable: the `chart_of_accounts_mapping_versions` row frozen at finalization time (per `ledger_account_mapping_schema` version-freeze semantics) is the source of truth for that period's entry accounts, regardless of subsequent chart changes.

---

## Section 8 — Audit

Every chart mutation emits:

| Event | When | Severity |
|---|---|---|
| `CHART_OF_ACCOUNTS_UPDATED` | Any chart mutation: account added, renamed, or inactivated | MEDIUM |

`MEDIUM` severity reflects that chart changes affect accounting classification and may affect VAT reporting. The audit record includes the action type (`ACCOUNT_ADDED`, `ACCOUNT_RENAMED`, `ACCOUNT_INACTIVATED`), the account code, the before/after values (for renames), and the actor's user ID and role.

The event is emitted via `emitAudit()` per `audit_log_policies` and exists in `audit_event_taxonomy` under the LEDGER domain.

---

## Section 9 — Mobile write rejection

Chart mutations are write-surface operations. Mobile clients cannot invoke `ledger.update_chart`. Any chart write attempt from a mobile client is rejected per `mobile_write_rejection_endpoints.md`. Read access to the chart of accounts is permitted on mobile.

---

## Section 10 — Reserved number ranges for custom accounts

Custom accounts must use number ranges reserved for business-level additions. The reserved ranges are defined in `ledger_account_mapping_schema` (Block 11 Phase 01). The general principle is that the system default chart occupies the standard Cyprus account code ranges; custom ranges are a defined set of codes set aside so that custom accounts sort consistently in reports and do not collide with future system account additions.

`ledger.update_chart` validates the proposed account code against the reserved ranges at write time. A code outside the reserved ranges is rejected with a structured error. The validation is not RLS-level; it is application-layer logic in the tool.

---

## Section 11 — Conflict resolution: system account update vs. business customization

When the platform team publishes an update to the system default chart (e.g., adding a new required account for a Cyprus regulatory change), the update is applied to the system default chart only. Existing business charts are not automatically updated. The business Owner or Admin is notified of the change via the dashboard notification system and may apply the update manually via `ledger.update_chart`. The update is advisory in MVP; mandatory system account propagation is a Stage 2 feature.

If a business has a custom account whose code would conflict with a newly added system account in a future update, the conflict is detected at system-chart update time and the business is notified. Resolution is manual.

---

## Workflow run states applicable to chart operations

Chart mutations are not executed within a workflow run. They are direct operational writes triggered by Owner/Admin UI actions. The chart is not versioned within a workflow run; version freezing occurs at finalization time (Block 15 Phase 03), which is a workflow-run operation. The chart itself is always in a mutable state between finalizations.

---

## Cross-references

- `audit_log_policies` — `LEDGER_*` domain; `<DOMAIN>_<PAST_VERB>` naming convention
- `audit_event_taxonomy` — `CHART_OF_ACCOUNTS_UPDATED`, `CHART_ACCOUNT_ADDED`, `CHART_ACCOUNT_RETIRED`, `CHART_MAPPING_VERSION_CREATED`
- `ledger_account_mapping_schema` — reserved number ranges for custom accounts; mapping rules that reference account codes; version-freeze semantics
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
- `tool_naming_convention_policy` — `ledger.*` namespace; `ledger.update_chart` as the sole chart mutation tool
- `data_layer_conventions_policy` — UUID v7 for account IDs; canonical JSON for chart version snapshots
- `vat_rate_table_reference` — VAT rate-to-account mapping; accounts in the chart are referenced in rate-to-treatment tables
- Block 02 Phase 04 — `canPerform('CHART_WRITE', business_id)` access control; Owner/Admin role requirement
- Block 11 Phase 01 — ledger schema foundation; `chart_of_accounts` and `chart_of_accounts_mapping_versions` table definitions
- Block 11 Phase 02 — default Cyprus chart of accounts (system default source)
- Block 11 Phase 03 — per-business chart customization and versioning (implementation home)
- Block 11 Phase 07 — ledger entry preparation; reads account codes from the chart at draft time
- Block 15 Phase 03 — period finalization; triggers chart version freeze via `ledger.freeze_chart_version`
