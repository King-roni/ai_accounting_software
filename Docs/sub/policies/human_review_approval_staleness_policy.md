# human_review_approval_staleness_policy

**Category:** Policies · **Owning block:** 12 — OUT Workflow · **Co-owner:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 1 cross-block policy)

The rule for recording approval staleness on OUT/IN HUMAN_REVIEW_HOLD and the re-approval UX. Per Block 12 Phase 07 + Block 13 Phase 09 — when a recorded approval becomes stale (the underlying data changed since approval was given), the run is HELD again until a fresh approval is recorded.

This policy pins WHEN an approval becomes stale, the recorded-vs-current data comparison, and the re-approval flow.

---

## What triggers staleness

An approval recorded for a workflow run becomes stale when any of the following changes occur after the approval was given:

| Change | Affects |
| --- | --- |
| New `review_issues` raised at HIGH or BLOCKING severity | OUT + IN |
| Existing `review_issues` re-opened (status from RESOLVED → OPEN via Owner override per `resolution_action_enum`) | OUT + IN |
| Severity escalation on a snoozed issue (per `rescan_policies`) | OUT + IN |
| `transactions.classification_status` changes from CONFIRMED back to NEEDS_CONFIRMATION (rare; manual re-classify-as-uncertain) | OUT |
| `match_records.match_status` changes from CONFIRMED to REJECTED | OUT + IN |
| New transactions added to the period (late statement upload) | OUT + IN |
| `effective_match_status` changes for any transaction in scope | OUT + IN |
| Block 11 ledger entries recomputed (per `ledger_recompute_side_effects_policy`) | OUT |
| Block 13 invoice lifecycle changes | IN |

The approval contract: "I approve this run with the data as it currently stands." Any data change breaks that contract.

## Detection mechanism

The `workflow_run_approvals` table is defined in `workflow_approval_schema` (Block 03 / Block 12 co-owned). This policy governs the staleness window for approval records; it does not redefine the schema.

The `data_state_hash` is the hash of the canonical-JSON-serialised state of the run's data. When the workflow engine evaluates the gate to advance from HUMAN_REVIEW_HOLD → FINALIZATION:

1. Re-compute the current `data_state_hash`
2. Compare to the stored `data_state_hash` on the most recent non-revoked approval
3. If equal → approval still valid; advance
4. If different → approval is stale; HOLD the run; emit `WORKFLOW_RUN_APPROVAL_STALE`

## Re-approval UX

When the user returns to a stale-approval state:

1. UI surfaces a "Re-approval required" banner per `human_review_approval_staleness_ui` (Layer 2, Block 14)
2. The banner shows a structured diff: what changed since the prior approval
3. User reviews the diff
4. User clicks "Re-approve" — issues a fresh step-up token per `step_up_validity_window_policy`
5. New `workflow_run_approvals` row inserted with fresh `data_state_hash`
6. Engine re-evaluates the gate; advances to FINALIZATION

The diff is computed from `data_state_summary_json` — the human-readable form of what was approved. Per Block 14 Phase 04: the diff renders in plain language ("3 new issues raised, 1 transaction reclassified").

## Step-up requirement on re-approval

Per `step_up_validity_window_policy`: the re-approval is itself a step-up-requiring action (it's a fresh approval). The user must MFA-challenge again. The token's `consumed_for_action_id` is the workflow_run_id; the consumption invalidates any prior step-up window for that run.

## Per-workflow-type overrides

| Workflow type | Staleness sensitivity |
| --- | --- |
| `OUT_MONTHLY` | Strict — any data change invalidates |
| `IN_MONTHLY` | Strict |
| `OUT_ADJUSTMENT` | Strict — adjustment scope is narrow; new issues are notable |
| `IN_ADJUSTMENT` | Strict |
| Other (INGESTION, CLASSIFICATION, etc. — no HUMAN_REVIEW_HOLD typically) | N/A |

No relaxation in MVP. Per `multi_approver_workflow_policy` (now part of OUT/IN policies): post-MVP dual-approval workflows may apply a "minor change tolerance" — out of scope for MVP.

## Revocation by another user

Per `permission_matrix`: Owner / Admin can revoke an approval before it's consumed. The flow:

1. Owner clicks "Revoke approval" on the review queue
2. `workflow_run_approvals.revoked_at` set; reason recorded
3. Audit event `FINALIZATION_APPROVAL_REVOKED`
4. The run reverts to HUMAN_REVIEW_HOLD

Revocation is rare — used when an Owner spots an issue the approver missed.

## Audit events

| Event | When |
| --- | --- |
| `FINALIZATION_APPROVAL_RECORDED` | New approval row inserted |
| `WORKFLOW_RUN_APPROVAL_STALE` | Engine detected staleness on gate evaluation |
| `FINALIZATION_APPROVAL_REVOKED` | Explicit revocation by Owner/Admin |
| `WORKFLOW_RUN_RE_APPROVAL_RECORDED` | Fresh approval after staleness |

## Cross-block contract

Block 12 Phase 07 (OUT) and Block 13 Phase 09 (IN) both consume this policy. The behavior is symmetric — the only differences are which specific data fields trigger staleness on each side.

Block 14 Phase 02 routes the staleness state into the review queue rendering (the `Ready to Finalize` queue-state projection per `issue_group_enum` becomes "Re-approval required" instead).

## Performance

The data_state_hash recomputation is on the hot path of every gate evaluation for a HUMAN_REVIEW_HOLD run. Performance budget per `fixture_performance_budget`:

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| data_state_hash recomputation (typical 50-transaction run) | 50 ms | 200 ms | 800 ms |

Beyond P99: the hash is computed asynchronously and the gate result is cached; the user sees the prior result with a "checking" indicator.

## Cross-references

- `workflow_run_approvals` table (Block 12 Phase 01 sub-doc) — host table
- `permission_matrix` — `WORKFLOW_APPROVE` surface
- `resolution_action_enum` — re-open action
- `rescan_policies` (consolidated) — severity escalation triggers
- `step_up_validity_window_policy` — re-approval step-up
- `ledger_recompute_side_effects_policy` — Block 11-side staleness trigger
- `audit_log_policies` — event family
- Block 12 Phase 07 — HUMAN_REVIEW_HOLD phase
- Block 13 Phase 09 — IN gate library + HUMAN_REVIEW_HOLD
- Block 14 Phase 02 — issue routing

---

## Staleness detection scenario

**Scenario:** Approver assigned, 24 hours pass, no action taken.

This is the most common staleness scenario and involves the passage of time rather than a data change. Here is the exact sequence:

1. The bookkeeper (or Owner) opens the review queue for an `OUT_MONTHLY` run at 09:00 on Monday
2. All HIGH/BLOCKING issues are resolved; the run is in `HUMAN_REVIEW_HOLD` state, `Ready to Finalize` section shows the run
3. The bookkeeper clicks "Approve" and completes step-up MFA at 09:05
4. `workflow_run_approvals` row is inserted; `data_state_hash = h1`; `approved_at = 09:05`
5. No one acts on the run for 24 hours (business closes for the day; the bookkeeper expected someone else to finalize)
6. At 14:30 Tuesday, a junior accountant uploads a late invoice for one of the period's transactions. This triggers a match re-score; the new match at `STRONG_PROBABLE` level raises a `Needs Confirmation` issue at `MEDIUM` severity
7. The issue is a new `review_issues` row — it is not HIGH/BLOCKING but it IS a data change
8. The engine re-computes `data_state_hash = h2`; `h2 ≠ h1`
9. The engine emits `WORKFLOW_RUN_APPROVAL_STALE` and moves the run back to `HUMAN_REVIEW_HOLD`
10. The review queue displays "Re-approval required" banner; the bookkeeper is notified
11. The bookkeeper reviews the diff ("1 new MEDIUM issue: Strong Probable match needs confirmation"), resolves the issue, and re-approves with a fresh step-up token

The key insight: even a MEDIUM issue — one that doesn't halt the gate — invalidates a prior approval because the approval was given on a different data state.

---

## Concurrent approvers edge case

When two approvers (e.g., Owner and Admin) act on the same approval window concurrently:

**Scenario:** Owner approves at T=0; Admin approves at T=0.2s (before the first approval has been fully committed and visible):

- Owner's approval POST arrives; `workflow_run_approvals` row inserted with `approved_by = owner_id`, `data_state_hash = h1`
- Admin's approval POST arrives; the engine reads the current approval state and finds the Owner's approval is already present and non-stale
- The Admin's request returns `APPROVAL_ALREADY_RECORDED` — informational, not an error
- The Admin's step-up token is marked `not_consumed` (token can theoretically be used for another action in its validity window, though same-run re-use is the only practical case)

**Scenario:** Owner approves at T=0; a data change occurs at T=0.5s; Admin approves at T=1s:

- Owner's approval is now stale (`h1 ≠ h2`); run is back in `HUMAN_REVIEW_HOLD`
- Admin's approval at T=1s is against the new `data_state_hash = h2`
- Admin's approval is recorded as the new valid approval; `WORKFLOW_RUN_RE_APPROVAL_RECORDED` emitted
- Owner's stale approval record remains in the table with `stale_at` timestamp set; it is not deleted (audit trail)

**Anti-pattern to avoid:** do not build a UI that presents both approvers with the same "Approve" button at the same time without coordinating which one is the authoritative approver. The system handles the collision gracefully, but user confusion about who needs to act is a UX problem separate from the technical safety guarantees.

---

## Audit event on staleness detection

The `WORKFLOW_RUN_APPROVAL_STALE` event payload:

```ts
emitAudit("WORKFLOW_RUN_APPROVAL_STALE", {
  workflow_run_id,
  stale_approval_id,                   // the approval record that is now stale
  prior_data_state_hash: string,       // h1 — the hash when the approval was given
  current_data_state_hash: string,     // h2 — the hash at detection time
  staleness_triggers: string[],        // which data changes caused the hash to change
  detected_at: timestamptz,
  approver_user_id: uuid               // who gave the stale approval
});
```

`staleness_triggers` is a human-readable list of the specific changes detected, e.g. `["new_review_issue:STRONG_PROBABLE_MATCH_PENDING", "ledger_entry_recomputed:txn_abc123"]`. This enables the re-approval diff UI in Block 14 Phase 04 to show exactly what changed.

---

## Additional cross-references

- `workflow_approval_schema` — `workflow_run_approvals` table columns including `stale_at`, `data_state_hash`, `data_state_summary_json`
