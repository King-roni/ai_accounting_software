# Block 12 — Phase 07: `HUMAN_REVIEW_HOLD` Phase

## References

- Block doc: `Docs/blocks/12_out_workflow.md` (Phase Sequence — `HUMAN_REVIEW_HOLD`; Gate Conditions — "zero blocking issues open AND user approval recorded")
- Block doc: `Docs/blocks/14_review_queue.md` (six review-issue buckets; severity levels)
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 04 — state machine; `AWAITING_APPROVAL` run-level state)

## Phase Goal

Define the `HUMAN_REVIEW_HOLD` side phase: entered after `AI_END_SCAN` produces blocking review issues, exited only when zero blocking issues remain open AND the user has explicitly recorded approval. Per Block 03 Phase 04's state machine, the run-level state during this phase is `AWAITING_APPROVAL`. After this phase clears, `FINALIZATION` runs.

## Dependencies

- Phase 02 (`HUMAN_REVIEW_HOLD` registered as a side phase between `AI_END_SCAN` and `FINALIZATION`)
- Phase 05 (`gate.out.ai_end_scan_complete` routes here on `ROUTE_TO_SIDE_PHASE`; `gate.out.human_review_hold_clear` evaluates exit)
- Block 02 Phase 04 (permission matrix — only Owner / Admin / Bookkeeper can record approval; sub-doc tunes which role per business)
- Block 03 Phase 04 (state machine — run-level `AWAITING_APPROVAL` state during this phase)
- Block 04 Phase 04 (`review_issues` — the data the gate counts)
- Block 06 Phase 11 (`AI_END_SCAN` — produces the issues this phase waits on)
- Block 14 (review queue UI — surface where the user resolves issues and approves)

## Deliverables

- **Phase entry condition** (driven by `gate.out.ai_end_scan_complete` returning `ROUTE_TO_SIDE_PHASE`):
  - At least one `review_issues` row in any of Block 14's six buckets has `severity ∈ {HIGH, BLOCKING}` AND `status = OPEN`. "Blocking" is defined by severity, not bucket — even a `MEDIUM` issue does not block, even when it's in a sensitive bucket like `Possible Tax/VAT Issue`.
  - On entry, run-level state transitions to `AWAITING_APPROVAL` (Block 03 Phase 04); `phase_state.status = HOLDING`.
  - Issues that are `MEDIUM` / `LOW` do not block — they remain visible in the review queue but the run can finalize with them open.
  - **Carry-forward boundary at finalization:** unresolved `MEDIUM` / `LOW` issues (and any `HIGH` / `BLOCKING` issues the user explicitly snoozed via Block 14's snooze action) are captured in the finalized archive's `review_issues` snapshot exactly as they stood at finalization moment (Block 15 owns the snapshot). Snoozed issues additionally **carry forward** into the next `OUT_MONTHLY` run for the same business — they reappear at the start of that next run per Block 14's snooze contract (decisions log, Block 14). Open-but-non-snoozed informational issues stay in the finalized archive only — they don't reappear in the next run unless explicitly snoozed first.
- **Tool registrations** with `engine.registerTool`:
  - **`out_workflow.user_approval`** — the explicit user-approval action that the gate requires. Side-effect: `WRITES_RUN_STATE` (writes a `workflow_run_approvals` row with `run_id`, `approved_by`, `approved_at`, `approval_method`, `approval_note`). AI tier: `NONE`.
  - **`out_workflow.user_revoke_approval`** — the user can revoke a recorded approval before the run finalizes (e.g., they approved, then noticed an issue). Side-effect: `WRITES_RUN_STATE` (marks the prior approval row as `revoked_by`, `revoked_at`); the gate re-evaluates and the phase remains in `AWAITING_APPROVAL`. AI tier: `NONE`.
- **`workflow_run_approvals` table** — declared in Phase 01; this phase is the consumer. Multiple approval rows per `run_id` are allowed (after a revoke, a fresh approval is recorded; the gate counts only non-revoked rows).
- **Permission gate for `out_workflow.user_approval`:**
  - **Permission surface name:** `WORKFLOW_APPROVE` — owned by Block 02 Phase 04's permission matrix. The role-to-surface mapping (Owner / Admin / Bookkeeper grant; Accountant / Reviewer / Read-only deny per Stage 1) lives in the matrix, not enumerated here. This phase reads from the matrix at runtime; per-business overrides go through Block 02's surface configuration.
  - Step-up auth is NOT required by default in MVP (per Stage 1 — "Block 15 finalization does not require accountant signoff"); sub-doc tracks the option to enable step-up for high-value periods via the matrix's surface-level `requires_step_up` flag.
- **Phase exit condition** (driven by `gate.out.human_review_hold_clear`):
  - **Both** must hold:
    1. **Zero blocking issues open** — `count(review_issues WHERE run_id = $run AND severity IN ('HIGH', 'BLOCKING') AND status = 'OPEN') = 0`.
    2. **A non-revoked approval row exists** — `EXISTS(SELECT 1 FROM workflow_run_approvals WHERE run_id = $run AND revoked_at IS NULL)`.
  - On exit, run-level state transitions to `FINALIZING` (Block 03 Phase 04 owns the transition; the `FINALIZATION` phase starts).
- **Approval-then-issue-reopens semantics:**
  - If the user records an approval AND a downstream re-evaluation (e.g., a re-run of `AI_END_SCAN` after a re-classification) produces a NEW blocking issue, the gate flips back to `HOLD` even though the approval row exists. The approval row is NOT auto-revoked — it remains valid for any prior issue set. To clear and proceed, the new issue must be resolved AND a fresh approval recorded (the prior approval is treated as stale).
  - Sub-doc tracks the "approval staleness" rule (Stage 1 default: any new blocking issue post-approval requires a fresh approval; the existing approval stays in audit but is no longer counted by the gate).
- **Issue-resolution mechanics (cross-block contract with Block 14):**
  - The user resolves issues from the Block 14 review queue. Each resolution action (per Block 14's resolution-action library) updates the issue's `status` to `RESOLVED` or `DISMISSED`. The gate re-evaluates on issue-status changes.
  - This phase doesn't own issue-resolution UI — Block 14 does. This phase only owns the run-level approval and the gate logic.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `OUT_WORKFLOW`):
  - `OUT_HUMAN_REVIEW_HOLD_ENTERED`
  - `OUT_HUMAN_REVIEW_APPROVAL_RECORDED` (with `approved_by`, `approval_method`)
  - `OUT_HUMAN_REVIEW_APPROVAL_REVOKED`
  - `OUT_HUMAN_REVIEW_HOLD_CLEARED`
  - `OUT_HUMAN_REVIEW_APPROVAL_STALENESS_DETECTED` (when a new blocking issue arrives after approval — the approval is now stale)

## Definition of Done

- A run reaching `AI_END_SCAN` with one open HIGH issue routes to `HUMAN_REVIEW_HOLD`; run-level state is `AWAITING_APPROVAL`.
- The user resolves the issue (Block 14 path); the user records approval via `out_workflow.user_approval`; the gate evaluates `ADVANCE`; `FINALIZATION` starts.
- A run with zero blocking issues but no approval row is HELD by the gate (approval is required even when no issues are blocking).
- A user without permission (Accountant) calling `out_workflow.user_approval` is denied with the right error.
- A user revokes their approval; the gate re-evaluates `HOLD`; the phase remains in `AWAITING_APPROVAL`.
- A new blocking issue post-approval flips the gate back to `HOLD` and emits `OUT_HUMAN_REVIEW_APPROVAL_STALENESS_DETECTED`.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Approval-staleness sub-doc** — exact rule for when a recorded approval becomes stale; UX for "your approval is stale, please re-approve".
- **Step-up auth for approval sub-doc** — when a business should require step-up; threshold rules (e.g., total period amount over X).
- **Per-business approver-role override sub-doc** — extension of the permission gate.
- **Approval audit retention sub-doc** — `workflow_run_approvals` row retention in the finalized archive.
- **Multi-approver workflow (deferred Stage 2+)** — what dual-approval would look like; not in MVP.
