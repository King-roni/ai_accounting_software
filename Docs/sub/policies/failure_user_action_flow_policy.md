# failure_user_action_flow_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Co-owners:** 14 — Review Queue & Human Review, 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

The user-side companion to `failure_review_issue_shape_policy`. Defines what happens when a Bookkeeper, Accountant, Owner, or Admin clicks Retry / Skip / Abort (or one of the secondary actions) on a failure review-issue card — the server-side RPC, the state transitions, permission gating, race-condition handling, and audit emission per action.

This policy does NOT cover gate-failure or lock-contention issues — those are owned by `gate_throws_semantics_policy` and `phase_execution_locking_policy` respectively. The actions defined here apply to the three tool-failure issue types (`TOOL_TRANSIENT_FAILURE_EXHAUSTED`, `TOOL_FATAL_ERROR`, `TOOL_SCHEMA_ERROR`) per `failure_review_issue_shape_policy` §1.

---

## The six actions

| Action | Primary use | Per `failure_review_issue_shape_policy` allowed for |
| --- | --- | --- |
| `RETRY` | Try the same tool again with the same input | TRANSIENT_NETWORK / RATE_LIMITED / TIMEOUT / SERVICE_UNAVAILABLE / UNKNOWN |
| `SKIP_IF_OPTIONAL` | Mark the failed tool as skipped and advance past it | Any class IF the tool is declared optional in the phase config |
| `ABORT_RUN` | Cancel the run; do not finalize | Every class |
| `RE_AUTHENTICATE` | Reset vendor credentials and prepare for retry | PERMISSION_DENIED |
| `RESOLVE_MANUALLY` | Mark resolved without engine action (user fixed externally) | TRANSIENT / FATAL / UNKNOWN |
| `REPORT_BUG` | Flag for engineering triage; issue stays OPEN | VALIDATION_ERROR + UNKNOWN |

Three primary (RETRY / SKIP / ABORT) + three secondary. The UI surfaces the subset enabled per the issue's `error_class`; disabled actions render as tooltips explaining why.

## RETRY semantics

```
1. UI: User clicks Retry on the review-issue card.
2. Permission check: can_perform(actor, 'WORKFLOW_RUN', 'RETRY', { run_id }) — typically ALLOW for Bookkeeper+.
3. Server-side RPC engine.retry_failed_tool(review_issue_id):
     a. Lock the run via pg_advisory_xact_lock(engine.run_lock_key(run_id))   [phase_execution_locking_policy]
     b. Read review_issue + linked tool_invocations row
     c. If run_status is terminal (CANCELLED/FAILED/FINALIZED): raise RUN_TERMINAL; abort RPC
     d. Reset workflow_phase_states.retry_count to 0 (per phase doc B03·P08)
     e. INSERT new tool_invocations row with status=PENDING + same dedup_key + attempt_number=1
     f. Emit WORKFLOW_TOOL_USER_RETRY_REQUESTED audit (LOW)
     g. Mark review_issue.status = OPEN (unchanged; same row stays open)
     h. Commit transaction
4. Background: engine.advanceRun(run_id) is enqueued for the trigger engine [phase_execution_loop_policy].
5. UI: Toast "Retry initiated. Status will update shortly." Realtime subscription per engine_run_progress_api_policy delivers progression.
```

Retry respects the `dedup_key` invariant from `dedup_key_generator_policy` — if the prior failed attempt actually succeeded on the vendor side (e.g., write happened, response lost), the retry's dedup check sees the prior SUCCESS row and short-circuits. The user does not need to know about this; it is handled transparently.

User can click Retry repeatedly. Each click resets retry_count to 0 and starts a fresh retry budget. The engine does NOT enforce a "max user retries per issue" — that's a UX consideration not a safety one.

## SKIP_IF_OPTIONAL semantics

```
1. UI: Skip button enabled only when tool's phase declares optional=true (per workflow_phase_definitions).
2. Permission check: can_perform(actor, 'WORKFLOW_RUN', 'SKIP_TOOL', { run_id }).
3. Server-side RPC engine.skip_failed_tool(review_issue_id, skip_reason text):
     a. Acquire advisory lock
     b. Verify the tool's phase has the tool in optional_tools list (CHECK constraint)
     c. UPDATE tool_invocations SET status='SKIPPED', skipped_reason=$skip_reason
     d. UPDATE review_issue SET status='RESOLVED', resolution_action='SKIP_IF_OPTIONAL', resolution_user_id=auth.uid()
     e. Emit WORKFLOW_TOOL_USER_SKIPPED (LOW)
     f. Commit
4. Background: engine.advanceRun resumes; phase advances past the skipped tool to the next one.
```

`skip_reason` is a user-typed free-text string (≤ 500 chars). Required for audit-trail purposes — a skip with no rationale is a future maintenance hazard.

If the tool is NOT in the phase's `optional_tools` list, the RPC raises `TOOL_NOT_OPTIONAL`. The UI's Skip button is disabled in this case; this server-side check is a defense-in-depth guard against client-side bypass.

## ABORT_RUN semantics

```
1. UI: User clicks Abort on the review-issue card (or via the run-detail page directly).
2. Confirmation dialog: "Abort this run? All progress will be lost. This cannot be undone." User types the run sequence ID to confirm (per UI safety pattern).
3. Permission check: can_perform(actor, 'WORKFLOW_RUN', 'ABORT', { run_id }) — typically Owner / Admin only.
4. Server-side RPC engine.abort_run(run_id, abort_reason text):
     a. Acquire advisory lock
     b. Verify run is in a non-terminal state (CREATED/RUNNING/PAUSED/REVIEW_HOLD/AWAITING_APPROVAL)
     c. transitionRun(run_id, target='CANCELLED', reason=$abort_reason) [B03·P04]
     d. UPDATE all OPEN review_issues for run SET status='DISMISSED', resolution_action='RUN_ABORTED'
     e. UPDATE current phase_state SET status='ABORTED'
     f. Emit ENGINE_RUN_ABORTED (HIGH) with payload {run_id, abort_reason, abort_actor_user_id}
     g. Commit
5. Background: any in-flight tool invocations are NOT externally cancelled — they may complete; their results are recorded but ignored (run is already CANCELLED).
```

CANCELLED is terminal per `workflow_state_enum`. The aborted run cannot be resumed; if work needs redoing, a fresh run is created. Ledger entries written by the aborted run remain in `DRAFT` status (per `ledger_entry_status_enum`) and are NOT included in any finalization.

Abort permission is Owner-only by default (`permission_matrix` row). The Admin role can be granted ABORT via `business_role_permission_overrides` per `role_change_propagation_policy`.

## RE_AUTHENTICATE semantics

```
1. UI: Re-authenticate button visible only on PERMISSION_DENIED issues.
2. Permission check: can_perform(actor, 'OAUTH_TOKEN', 'REFRESH', { provider }).
3. Client-side: redirect to vendor OAuth consent URL.
4. On callback: token is stored; client invokes engine.retry_failed_tool (the standard Retry RPC).
5. Server: same flow as RETRY.
```

The RPC itself is just the standard Retry path; the action label and the OAuth redirect are UI affordances. The issue stays OPEN until the retry actually succeeds.

## RESOLVE_MANUALLY semantics

```
1. UI: User clicks "Mark resolved" → modal asks for a rationale (required, ≤ 500 chars).
2. Permission check: can_perform(actor, 'REVIEW_ISSUE', 'RESOLVE', { issue_id }).
3. Server-side RPC engine.resolve_issue_manually(review_issue_id, rationale text):
     a. Acquire advisory lock (because this transitions a held run)
     b. UPDATE review_issue SET status='RESOLVED', resolution_action='RESOLVE_MANUALLY',
        resolution_rationale=$rationale, resolution_user_id=auth.uid()
     c. IF no other OPEN issues for the run: transitionRun(run_id, target='RUNNING') [resume from HOLD]
     d. Emit WORKFLOW_ISSUE_RESOLVED_MANUALLY (MEDIUM)
     e. Commit
4. Background: if the run resumed (step 3c), engine.advanceRun fires.
```

This action is the user saying "I fixed it externally; engine doesn't need to retry; just continue from where you were." If the issue was the only thing blocking the run, the run resumes. If other issues remain OPEN, the run stays in REVIEW_HOLD.

The rationale is mandatory and is captured on `review_issue_history` for forensic audit.

## REPORT_BUG semantics

```
1. UI: "Report bug" button on VALIDATION_ERROR or UNKNOWN issues; text area for repro steps.
2. Permission check: can_perform(actor, 'BUG_REPORT', 'CREATE', { issue_id }).
3. Server-side RPC engine.report_bug_on_issue(review_issue_id, repro_steps text):
     a. INSERT engineering_bug_reports row with FK to review_issue + repro_steps + actor info
     b. Emit ENGINEERING_BUG_REPORTED (MEDIUM) — sent to ops backplane via outbound webhook
     c. Issue.status REMAINS OPEN (the bug report does not resolve the issue; only engineering action can)
     d. Commit
4. Out-of-band: engineering triages bug; fixes engine; deploys; the underlying issue may then unblock on next Retry click.
```

Bug reports do NOT auto-resolve the issue — the user can still Retry or Abort while engineering acts. The bug-report record links the issue to the eventual fix for traceability.

## Permission gating summary

| Action | Default role required | Per `permission_matrix` |
| --- | --- | --- |
| RETRY | Bookkeeper+ | `WORKFLOW_RUN / RETRY` = ALLOW |
| SKIP_IF_OPTIONAL | Bookkeeper+ | `WORKFLOW_RUN / SKIP_TOOL` = ALLOW |
| ABORT_RUN | Owner / Admin | `WORKFLOW_RUN / ABORT` = ALLOW (REQUIRE_STEP_UP for Owner-tier abort if business settings demand) |
| RE_AUTHENTICATE | Same role as original OAuth grant + Bookkeeper+ | `OAUTH_TOKEN / REFRESH` = ALLOW |
| RESOLVE_MANUALLY | Bookkeeper+ | `REVIEW_ISSUE / RESOLVE` = ALLOW |
| REPORT_BUG | Any authenticated user | `BUG_REPORT / CREATE` = ALLOW |

The READ_ONLY role sees the issue card but cannot click any action button.

Step-up authentication is required for ABORT_RUN on FINALIZATION-path runs (per `step_up_token_policy`). For other paths, ABORT is single-factor.

## Race-condition handling

Multiple users may be looking at the same issue. The action RPCs use OCC (optimistic concurrency control) via `review_issues.version` (bigint, incremented on every UPDATE):

```sql
UPDATE review_issues
SET    status = 'RESOLVED', version = version + 1, ...
WHERE  id = $issue_id
  AND  status = 'OPEN'                            -- guard: still actionable
  AND  version = $version_at_load;                -- guard: not modified by peer
-- Affected rows = 0 → another user beat us; UI shows "Already resolved by <peer>"
```

The advisory lock per §RETRY-semantics serialises engine-side mutation but does NOT block the UI's optimistic-read pattern. OCC handles the user-side race.

## Audit events per action

| Action | Event | Severity |
| --- | --- | --- |
| RETRY | `WORKFLOW_TOOL_USER_RETRY_REQUESTED` | LOW |
| SKIP_IF_OPTIONAL | `WORKFLOW_TOOL_USER_SKIPPED` | LOW |
| ABORT_RUN | `ENGINE_RUN_ABORTED` | HIGH |
| RE_AUTHENTICATE | (no event from this RPC; RETRY's event fires post-callback) | — |
| RESOLVE_MANUALLY | `WORKFLOW_ISSUE_RESOLVED_MANUALLY` | MEDIUM |
| REPORT_BUG | `ENGINEERING_BUG_REPORTED` | MEDIUM |

All carry `actor_user_id`, `review_issue_id`, `workflow_run_id`, `business_id`, and the user-typed rationale where applicable.

## UI surface (review-issue card)

The card layout (rendered in B14's review queue UI and B16's run-detail panel):

```
┌─────────────────────────────────────────────────────────────┐
│ ⚠️ <title>                                          BLOCKING│
├─────────────────────────────────────────────────────────────┤
│ <description rendered from template>                        │
│                                                             │
│ Failed at: <tool_friendly_name> in <phase_name>             │
│ Attempt: 3 of 3 (last attempted 2 min ago)                  │
│ Error: <error_class_signal>                                 │
├─────────────────────────────────────────────────────────────┤
│ [ Retry ]  [ Skip ]  [ Abort run ]    [ Resolve manually ▾ ]│
└─────────────────────────────────────────────────────────────┘
```

Action buttons are arranged left (primary actions) → right (secondary, in a dropdown). Disabled buttons render with reduced opacity + tooltip explaining the constraint.

For mobile (per `mobile_write_rejection_endpoints` policy): RETRY and ABORT are available; SKIP requires desktop confirmation (typed run-sequence-ID, hard to enter on mobile keyboards).

## Cross-block contract

- **Block 03 Phase 04** `transitionRun` is called by ABORT_RUN.
- **Block 03 Phase 06** `engine.advanceRun` is enqueued by RETRY / SKIP / RESOLVE_MANUALLY.
- **Block 14** review queue UI hosts the cards; `review_issue_history` records actions.
- **Block 16** run-detail page also shows the cards for context.
- **Block 02 RBAC** `can_perform` gates every RPC.

## Cross-references

- `failure_review_issue_shape_policy` — issue types + `allowed_resolution_actions` enum that this policy consumes
- `retry_policy` — RETRY resets `workflow_phase_states.retry_count` to 0 per phase doc B03·P08
- `dedup_key_generator_policy` — RETRY respects the dedup_key invariant transparently
- `phase_execution_locking_policy` — all RPCs acquire advisory lock
- `phase_execution_loop_policy` — `engine.advanceRun` is the post-action re-entry point
- `engine_run_progress_api_policy` — Realtime channel delivers post-action state to UI
- `role_change_propagation_policy` — permission-matrix overrides (e.g., grant ABORT to Admin)
- `step_up_token_policy` — required for ABORT on FINALIZATION-path runs
- `mobile_write_rejection_endpoints` — desktop-only SKIP confirmation
- `error_classification_policy` — error_class determines which action buttons are enabled
- `dashboard_card_policies` — B16 rendering rules
- `audit_event_payload_schemas` (Stage-6 catalog) — per-action event payloads
- Block 02 — RBAC + permission_matrix
- Block 03 Phase 04 — `transitionRun`
- Block 03 Phase 06 — `engine.advanceRun`
- Block 03 Phase 08 — owning phase
- Block 14 — review queue UI host
- Block 16 — dashboard run-detail page
