# unknown_blocker_review_issue_ui_spec

**Category:** UI specs · **Owning block:** 12 — OUT Workflow · **Co-owner:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 1 cross-block UI spec)

The review-card UX for `classification.unknown_type` issues — transactions classified as `UNKNOWN` per `transaction_type_enum`. Per Block 14 Phase 02: UNKNOWN is canonically BLOCKING — the workflow run cannot advance until reclassified.

This is a critical surface — BLOCKING issues are the most visible blockers in the queue. The card prioritizes clarity and a fast resolution path.

---

## Card layout

```
┌────────────────────────────────────────────────────────────┐
│ ⬢ BLOCKING — Classification needed                         │
│                                                            │
│ We couldn't determine the type for this transaction.       │
│ Pick a type to continue.                                   │
│                                                            │
│ ┌──────────────────────────────────────────────────────┐   │
│ │ Transaction details                                  │   │
│ │                                                      │   │
│ │ 15 Jan 2026  −€1,250.00  EUR                         │   │
│ │ Ref: WIRE TFR ANDREAS CONSTRUCTIONS LTD              │   │
│ │ Account: Revolut Main                                │   │
│ └──────────────────────────────────────────────────────┘   │
│                                                            │
│ Choose a transaction type:                                 │
│                                                            │
│ ◐ Outgoing expense                  [Select]               │
│ ◐ Internal transfer between accounts [Select]              │
│ ◐ Loan or shareholder movement       [Select]              │
│ ◐ Payroll or team payment            [Select]              │
│ ◐ Tax payment                        [Select]              │
│                                                            │
│ Don't see the right one?  [Show all types]                 │
│                                                            │
│ [Add note]                                                 │
└────────────────────────────────────────────────────────────┘
```

The `⬢` icon (Lucide `Octagon` filled) marks the BLOCKING severity. Per `severity_color_tokens`: severity-blocking-bg / -border / -text / -icon.

Card width: 600px on desktop. Padding: `--space-6`. Border-left: 4px solid `--severity-blocking-border` for high visual priority.

## Suggested types — top 5

The card lists 5 candidate types — the most likely OUT_EXPENSE variants ranked by classifier confidence. The full 12-type list per `transaction_type_enum` is available via "Show all types".

The top-5 ordering uses Block 08's classifier output: the type the Layer 3 classifier scored highest (even though confidence didn't pass the threshold for auto-classification, the type ordering is preserved).

For OUT-side transactions (negative amount): the top 5 default to OUT_EXPENSE-family types. For IN-side transactions (positive amount): IN_INCOME-family types. For zero-amount transactions (rare, possibly FX): FX_EXCHANGE prominently shown.

## "Show all types" — full picker

Click expands the card to show the full 12-type list per `transaction_type_enum`. Per Stage 1: 12 closed values + UNKNOWN itself (which the user can't pick — they're resolving away from UNKNOWN).

The full picker uses a small inline tooltip per type to explain when to pick it:

```
◐ FX_EXCHANGE
  Currency conversion or multi-leg payment
◐ BANK_FEE
  Bank charges, account fees, wire fees
◐ REFUND_OUT
  Refund issued to a customer
... etc
```

The `◐` icon (Lucide `Circle`) is a placeholder for the unselected state. On select (click): the icon becomes `●` (Lucide `CheckCircle2` filled in `--color-action-primary`); the row becomes the active choice.

## Reclassification commit

Selecting a type doesn't immediately commit — the user reviews the choice and clicks "Apply reclassification":

```
┌────────────────────────────────────────────────────────────┐
│ Selected: Outgoing expense                                 │
│                                                            │
│ This will reclassify the transaction and re-run the        │
│ workflow's matching + ledger preparation steps.            │
│                                                            │
│ [Apply reclassification]   [Cancel]                        │
└────────────────────────────────────────────────────────────┘
```

Per `resolution_action_enum`: this triggers `reclassify_transaction` action. The cascade per Block 14 Phase 08's re-scan invalidates downstream review issues for the same transaction.

Per `mobile_write_rejection_endpoints`: this action is desktop-only.

## "Add note" path

A user can add a note before reclassifying — useful for explaining why the type was ambiguous (e.g., "Vendor is a sole proprietor; I treated as expense rather than payroll").

The note attaches to the resolved `review_issues.resolution_note` per Stage 1 single-note policy.

## In-flight workflow run consequences

When the user reclassifies an UNKNOWN transaction:

1. The transaction's `transaction_type` updates
2. The transaction's `classification_status = CONFIRMED`, `classification_method = MANUAL`
3. The run's REVIEW_HOLD lifts IF no other BLOCKING issues remain
4. Block 11's ledger preparation re-runs per `ledger_recompute_side_effects_policy`
5. Block 12's gate re-evaluates per `tool_gate_function_signature` semantics
6. The audit emits `CLASSIFICATION_USER_RECLASSIFIED` per `audit_event_taxonomy`

The card itself transitions to a brief success state ("Reclassified to Outgoing expense") for 2 seconds, then dismisses.

## Multiple UNKNOWN in one run

If a workflow run has multiple UNKNOWN transactions, the queue shows one card per — they don't aggregate. The user resolves them one at a time.

Per Block 14 Phase 05 bulk actions: bulk-reclassify is NOT supported for UNKNOWN (the types could differ per transaction; bulk-applying the same type would be wrong). Each is resolved individually.

## Permission gating

| Role | Can resolve UNKNOWN? |
| --- | --- |
| Owner | Yes |
| Admin | Yes |
| Bookkeeper | Yes |
| Accountant | Yes |
| Reviewer | No (view-only) |
| Read-only | No |

Per `permission_matrix`: `REVIEW_QUEUE_RESOLVE` surface required. Per `severity_enum`'s BLOCKING-cannot-be-DISMISSED rule: there's no dismiss option. The only resolutions are reclassify or escalate-to-engineering (per `cross_tenant_alerting_runbook` if the type is fundamentally ambiguous).

## Token bindings

| Element | Tokens |
| --- | --- |
| Severity ribbon | `--severity-blocking-bg` + `--severity-blocking-text` + `--severity-blocking-icon` |
| Card border-left | 4px `--severity-blocking-border` |
| Transaction details section | `--color-bg-canvas` + `--radius-md` + `--space-4` padding |
| Type row | Hover: `--color-bg-canvas`; selected: `--color-action-primary` 8% tint |
| Select button | `Button` ghost variant |
| Apply button | `Button` primary variant |

## Accessibility

- BLOCKING severity announced via `aria-label`: "Blocking issue: classification needed for transaction"
- Each type row is a button: `role="button"` + Tab navigable + Enter to select
- Live region announces selection: "Selected: Outgoing expense"
- High-contrast severity colors per `severity_color_tokens` color-blind safety

## Cross-references

- `transaction_type_enum` — closed 12-value enum
- `severity_enum` — BLOCKING semantics
- `severity_color_tokens` — color quartet
- `issue_group_enum` — `Needs Confirmation` bucket
- `resolution_action_enum` — `reclassify_transaction` action
- `mobile_write_rejection_endpoints` — resolution is desktop-only
- `permission_matrix` — REVIEW_QUEUE_RESOLVE surface
- `ledger_recompute_side_effects_policy` — Block 11 cascade
- `audit_log_policies` — event family
- `component_library_ui_spec` — base components
- `design_system_tokens` — tokens
- Block 08 Phase 02 — classification Layer 1
- Block 12 Phase 02 — UNKNOWN routing as BLOCKING
- Block 14 Phase 02 — issue routing
- Block 14 Phase 03 — issue card rendering
- Block 14 Phase 04 — resolution actions
