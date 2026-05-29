# step_up_auth_for_workflow_approval_policy

**Category:** Policies · **Owning block:** 12 — OUT Workflow · **Co-owner:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 1 cross-block policy)

The threshold rules for when OUT/IN HUMAN_REVIEW_HOLD approval requires fresh MFA (step-up) vs accepting a normal authenticated session. Separate from the FINALIZATION step-up (which is always required per `permission_matrix`) — this policy governs the lighter-weight mid-workflow approvals.

---

## When step-up is required

Step-up is required for HUMAN_REVIEW_HOLD approval when ANY of the following applies:

| Condition | Rationale |
| --- | --- |
| Any unresolved issue with `severity = BLOCKING` exists | BLOCKING issues should not exist at approval time; their presence means something is wrong with the gating |
| The run is `OUT_ADJUSTMENT` or `IN_ADJUSTMENT` | Adjustments operate on finalized data; step-up parity with the original FINALIZATION |
| The run covers `> 100` transactions | Large-scope runs benefit from extra friction (typo'd approval would affect many records) |
| Cumulative `amount_eur_cents` in scope exceeds €100,000 | Scale-driven threshold; high-value runs deserve fresh confirmation |
| The approver previously approved this run and it became stale > 3 times | Repeated re-approvals suggest distracted approver; step-up forces focus |
| The session is older than 30 minutes since last step-up | Recency requirement |

## When step-up is NOT required

For non-adjustment runs with no BLOCKING issues, ≤ 100 transactions, ≤ €100,000 total scope:

- Approval uses the user's existing authenticated session
- The session's `last_mfa_at` must still be within 30 minutes
- Audit event: `WORKFLOW_APPROVAL_RECORDED` with `step_up_present = false`

This light-weight path covers the typical monthly-close scenario: a Bookkeeper has been working on the run for an hour, has 30 invoices in scope, no BLOCKING issues, and just needs to advance the workflow. Forcing MFA on every approval here is friction without benefit.

## Per-business override (Stage 2+)

Per `per_business_approver_role_override_policy` (now part of OUT/IN policies): a business may opt INTO requiring step-up on all approvals regardless of scope. Per the override sub-doc — deferred to Stage 2+.

A business may NOT opt OUT of step-up for FINALIZATION — that's per `permission_matrix` (FINALIZATION requires step-up unconditionally).

## Token lifecycle

When step-up IS required: the approval call must present a fresh step-up token per `step_up_validity_window_policy`. The token is consumed by the approval action; `consumed_for_action_id = workflow_run_id`.

A consumed token can be re-used for the SAME run's same approval (re-approval after staleness) IF the token hasn't expired AND the data_state_hash matches the value at issuance. Otherwise: new token required.

## Threshold rationale

The transaction-count threshold (100) and the amount threshold (€100,000) are starting calibrations. Per Stage 4 sub-doc-level refinement, thresholds may be tuned based on user feedback.

The current values reflect typical Cyprus SME monthly volumes:

| Business size | Typical OUT_MONTHLY scope |
| --- | --- |
| Micro (1-5 employees) | 20-50 transactions, €5k-30k |
| Small (5-25 employees) | 50-200 transactions, €30k-200k |
| Medium (25+ employees) | 200-500 transactions, €200k-1M |

The 100-transaction / €100k threshold catches roughly the upper-half of small businesses — they get step-up friction; the lower half doesn't.

## Audit shape

```ts
emitAudit("WORKFLOW_APPROVAL_RECORDED", {
  workflow_run_id,
  approved_by_user_id,
  step_up_present: boolean,
  step_up_token_id: uuid | null,
  step_up_was_required: boolean,                   // whether THIS approval required step-up
  threshold_triggers: string[],                    // which conditions triggered, if step_up_was_required
  data_state_hash: string,                          // per human_review_approval_staleness_policy
  transactions_in_scope_count: integer,
  total_amount_eur_cents: bigint
});
```

The `threshold_triggers` array captures which specific conditions fired. Used in operator investigation when an approval was rejected.

## Failure paths

| Scenario | Behavior |
| --- | --- |
| Step-up required but no token presented | Approval rejected with `STEP_UP_REQUIRED` (HTTP 401-equivalent) |
| Step-up token presented but expired | Rejected with `STEP_UP_TOKEN_EXPIRED`; UI prompts re-challenge |
| Step-up token presented but wrong action_id | Rejected with `STEP_UP_TOKEN_ACTION_MISMATCH` |
| Conditions evaluated to require step-up but the user is Owner | Step-up still required — role doesn't override the threshold |

## Cross-block contract

Block 12 Phase 07 (OUT) and Block 13 Phase 09 (IN) both consume this policy. The thresholds are identical; the difference is the workflow-specific data shape evaluated against them.

Block 14's review queue surfaces the "step-up required" hint to the user before they click Approve, so they can pre-fetch a fresh MFA code from their authenticator.

## Cross-references

- `step_up_validity_window_policy` — token lifecycle
- `permission_matrix` — WORKFLOW_APPROVE + FINALIZATION surfaces
- `human_review_approval_staleness_policy` — data_state_hash mechanism
- `severity_enum` — BLOCKING trigger
- `audit_log_policies` — WORKFLOW_APPROVAL_RECORDED + STEP_UP_REQUIRED events
- `per_business_approver_role_override_policy` (now in OUT/IN policy cluster) — Stage 2+ override
- Block 12 Phase 07 — HUMAN_REVIEW_HOLD (OUT)
- Block 13 Phase 09 — HUMAN_REVIEW_HOLD (IN)
- Block 15 Phase 03 — approval modality (FINALIZATION baseline)
- `archive_step_up_policy` — step-up rules for archive-access operations

---

## Threshold matrix

Full enumeration of which operations require step-up MFA and at what level.

| Operation | Workflow types | Step-up required? | MFA level | Condition |
| --- | --- | --- | --- | --- |
| HUMAN_REVIEW_HOLD approval (standard path) | OUT_MONTHLY, IN_MONTHLY | Conditional | TOTP or passkey | Any of the 6 threshold conditions in the first section |
| HUMAN_REVIEW_HOLD approval (adjustment path) | OUT_ADJUSTMENT, IN_ADJUSTMENT | Always | TOTP or passkey | Unconditional — adjustments always require step-up |
| FINALIZATION approval | All | Always | TOTP or passkey | Per `permission_matrix`; unconditional |
| Approval revocation (Owner/Admin) | All | Yes | TOTP or passkey | Per `human_review_approval_staleness_policy` |
| Re-approval after staleness | All | Yes | TOTP or passkey | Fresh step-up token required per `step_up_validity_window_policy` |
| Archive-access step-up | Archive reads | Conditional | Per `archive_step_up_policy` | Separate policy; not governed here |

Step-up MFA level is always "second factor" — TOTP, hardware key, or platform passkey. SMS OTP is not accepted as a valid step-up factor.

---

## Edge cases

### Step-up expires mid-approval

The step-up token has a validity window (per `step_up_validity_window_policy`). If the user initiates approval, passes the step-up challenge, then waits longer than the window before submitting the approval form, the token may expire before the approval POST is processed.

Behavior: the server rejects with `STEP_UP_TOKEN_EXPIRED`. The UI must handle this gracefully — present a "Your MFA session expired; please re-authenticate" prompt and re-trigger the step-up challenge. The approval is not recorded until a fresh valid token is presented.

The user does not lose their review progress — only the step-up token expires. The underlying review issues and run state are unchanged.

### Multiple approvers attempting concurrent approval

When two approvers (e.g., Owner and Admin) both see the `HUMAN_REVIEW_HOLD` state and attempt to approve concurrently:

- Both pass their respective step-up challenges
- The first approval POST to arrive wins; a `workflow_run_approvals` row is inserted
- The second approval POST: the engine detects an existing non-revoked, non-stale approval; returns `APPROVAL_ALREADY_RECORDED` (idempotent — not an error, but the second record is discarded)
- The second approver's step-up token is NOT consumed (the server consumed the first approver's token on the first successful write)
- Audit: `WORKFLOW_APPROVAL_RECORDED` fires once; the second attempt is logged but does not produce a second approval record

If the run's `data_state_hash` changed between the two approval attempts (i.e., the first approval triggered a data change — unusual but possible in concurrent multi-approver setups), the second attempt sees a stale hash on re-evaluation and is also rejected with `APPROVAL_DATA_STATE_STALE`.

### Step-up token scoped to wrong run

A user holds a valid step-up token scoped to run A but submits it for run B. The engine rejects with `STEP_UP_TOKEN_ACTION_MISMATCH`. The token's `consumed_for_action_id` must match the target `workflow_run_id`. Token cannot be reused for a different run even if both runs belong to the same business.

---

## Additional cross-references

- `step_up_validity_window_policy` — token issuance, window duration, consumption semantics
- `archive_step_up_policy` — step-up rules specific to archive access (separate policy, related contract)
