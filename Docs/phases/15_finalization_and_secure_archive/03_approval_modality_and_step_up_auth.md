# Block 15 — Phase 03: Approval Modality & Step-Up Auth at Finalization

## References

- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (Approval Modality)
- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Phase 03 — MFA factors; Phase 06 — step-up auth)
- Block doc: `Docs/blocks/12_out_workflow.md` (Phase 07 — `out_workflow.user_approval`; `workflow_run_approvals` table; the `approval_method` enum carries `STANDARD` and `STEP_UP`)
- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (Phase 09 — `in_workflow.user_approval`; same approval mechanism on IN side)
- Decisions log: `Docs/decisions_log.md` (Owner / Admin can finalize; same TOTP / passkey factor as login; accountant signoff not required)

## Phase Goal

Pin the approval contract for finalization: **explicit step-up authentication** using the same TOTP / passkey factor configured at login (Block 02 Phase 03), Owner / Admin role only (Stage 1), recorded as an audit event in Block 05's hash chain. Resolve the apparent conflict with Block 12 Phase 07 / Block 13 Phase 09: HUMAN_REVIEW_HOLD approvals can be `STANDARD`; reaching FINALIZATION requires the approval to have used `STEP_UP`. The same approval row may serve both gates if the user step-up'd at HUMAN_REVIEW_HOLD time, OR a fresh step-up'd approval is recorded at finalization.

## Dependencies

- Phase 01 (`archive_packages.step_up_auth_used`)
- Phase 02 (`gate.finalization.approval_recorded`)
- Block 02 Phase 03 (MFA factors — TOTP + WebAuthn / passkeys)
- Block 02 Phase 06 (step-up authentication framework)
- Block 02 Phase 04 (permission matrix — finalization permission surface)
- Block 12 Phase 01 (`workflow_run_approvals` table; `approval_method` enum)
- Block 12 Phase 07 (`out_workflow.user_approval` — the existing tool)
- Block 13 Phase 09 (`in_workflow.user_approval`)

## Deliverables

- **Approval requirement at finalization (canonical):**
  - **Role gate:** the approving user must hold a role in `{Owner, Admin}` for the business. Stage 1 explicitly excludes other roles from finalization approval; Accountant signoff is advisory only and not a blocking requirement.
  - **Step-up auth gate:** the `workflow_run_approvals` row used to satisfy `gate.finalization.approval_recorded` MUST have `approval_method = STEP_UP`. A `STANDARD` approval (sufficient for Block 12 Phase 07's HUMAN_REVIEW_HOLD clearing) does NOT satisfy finalization.
  - **Reconciliation with Block 12 Phase 07:**
    - HUMAN_REVIEW_HOLD's `gate.out.human_review_hold_clear` accepts any non-revoked approval row (`STANDARD` or `STEP_UP`).
    - Block 15's `gate.finalization.approval_recorded` requires `STEP_UP`.
    - **Two valid user flows:**
      - **Flow A (single approval):** the user step-up's at HUMAN_REVIEW_HOLD time → `approval_method = STEP_UP` → both gates clear with the same row.
      - **Flow B (two approvals):** the user clears HUMAN_REVIEW_HOLD with a `STANDARD` approval → reaches `FINALIZING` state → `gate.finalization.approval_recorded` returns `HOLD` with `failure_reason = 'STEP_UP_REQUIRED'` → the UI prompts for a fresh step-up'd approval → user records `out_workflow.user_approval` (or `in_workflow.user_approval`) again with step-up → second approval row exists; gate clears. **Both rows remain in audit**; the gate counts only the qualifying STEP_UP row.
    - Sub-doc tracks the UX trade-off (single-step-up vs split flows); Stage 1 supports both.
- **Step-up auth invocation:**
  - When the user invokes `out_workflow.user_approval` (or IN equivalent) and the run is at `AWAITING_APPROVAL`, the approval flow:
    1. Asks the user to confirm via the **same TOTP / passkey factor** used at login (Block 02 Phase 03's MFA factors). No dedicated finalization-only credential in MVP per Stage 1.
    2. The challenge is fired through Block 02 Phase 06's step-up framework. On success, the resulting approval row carries `approval_method = STEP_UP`.
    3. On failure (wrong TOTP, denied passkey), no approval row is written; the user can retry. After 5 consecutive failures, Block 02 Phase 06's lockout policy applies (sub-doc tracks).
  - **The user can opt into `STANDARD` approval** at the HUMAN_REVIEW_HOLD step (e.g., they're clearing the gate without intending to immediately finalize). The UI surfaces the choice at approval time. Stage 1 default — surface both options if the run is at `AWAITING_APPROVAL`.
- **`approval_method` enum on `workflow_run_approvals`** (Block 12 Phase 01 owns the column):
  - `STANDARD` — no step-up auth used. Sufficient for clearing HUMAN_REVIEW_HOLD.
  - `STEP_UP` — step-up auth (TOTP / passkey) successfully completed. Required for finalization.
- **Approval staleness vs finalization** (interaction with Block 12 Phase 07's approval-staleness rule):
  - Block 12 Phase 07's staleness rule fires when a re-run of `AI_END_SCAN` produces a new blocking issue post-approval. The prior approval row stays in audit but doesn't satisfy the gate; a fresh approval is required.
  - **Block 15's approval check inherits this:** if the run progressed past HUMAN_REVIEW_HOLD with approval row A, then re-entered HOLD due to a new blocker, then cleared again with approval row B, Block 15 reads the **most recent non-revoked** row that meets STEP_UP. The canonical SQL lives with the table owner (Block 12 Phase 01); this phase consumes the helper and does not duplicate the query definition.
- **Permission gate:**
  - `FINALIZATION` surface (Block 02 Phase 04) — already used by Block 12 Phase 07 / Block 13 Phase 09. Stage 1 grants Owner, Admin, Bookkeeper. **Block 15 narrows the role grant for `STEP_UP` approvals to Owner / Admin only** — Bookkeeper-recorded approvals can be `STANDARD` (HUMAN_REVIEW_HOLD-clearing) but cannot be `STEP_UP` (finalizing). Sub-doc tracks the matrix entry.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `FINALIZATION`):
  - `FINALIZATION_STEP_UP_CHALLENGED` (when the user is prompted)
  - `FINALIZATION_STEP_UP_PASSED` / `_FAILED` (per Block 02 Phase 06's audit chain; restated here for Block 15 traceability)
  - `FINALIZATION_APPROVAL_QUALIFIED` (when an approval row is recorded with `approval_method = STEP_UP`; restated cross-check from Block 12 Phase 07's `OUT_HUMAN_REVIEW_APPROVAL_RECORDED`)
  - `FINALIZATION_APPROVAL_NOT_QUALIFIED` (when `gate.finalization.approval_recorded` rejects a `STANDARD` approval; the workflow stays in `AWAITING_APPROVAL` and the UI prompts for step-up)

## Definition of Done

- A user with role `Owner` invokes `out_workflow.user_approval` with step-up: TOTP challenge fires, the user enters the code, the approval row is written with `approval_method = STEP_UP`. `gate.finalization.approval_recorded` returns `ADVANCE`.
- A user clears HUMAN_REVIEW_HOLD with `STANDARD` approval; the run reaches `FINALIZING`; `gate.finalization.approval_recorded` returns `HOLD` with `failure_reason = 'STEP_UP_REQUIRED'`; the UI prompts for step-up; the user re-approves with step-up; gate clears.
- A user with role `Bookkeeper` attempts a `STEP_UP` approval; denied per the matrix narrowing — they can record `STANDARD` only. (Owner / Admin can record either.)
- A user with role `Accountant` attempts any approval; denied per the existing `FINALIZATION` matrix gate.
- 5 consecutive step-up failures trigger Block 02 Phase 06's lockout.
- A staleness scenario where a fresh `STEP_UP` approval is required works correctly (most-recent-non-revoked-qualifying lookup).
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Step-up UX flow sub-doc** — TOTP entry surface; passkey prompt; retry / lockout messaging.
- **HUMAN_REVIEW_HOLD-vs-FINALIZATION approval-flow sub-doc** — the canonical UI for offering both `STANDARD` and `STEP_UP` at HUMAN_REVIEW_HOLD time.
- **Approval-method matrix narrowing sub-doc** — exact role × `approval_method` matrix entry.
- **Most-recent-non-revoked-qualifying SQL sub-doc** — the lookup query; staleness interaction.
- **Dedicated finalization credential sub-doc (deferred Stage 2+)** — Stage 1 reuses login factor; Stage 2+ may add a separate credential.
