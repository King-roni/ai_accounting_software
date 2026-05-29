# Block 02 — Phase 04: Role Model & Permission Matrix

## References

- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Role Model + Permission Surfaces sections)
- Decisions log: `Docs/decisions_log.md` (six base roles only in MVP; accountant approval not required for finalization; role changes apply to new actions only)

## Phase Goal

The six roles (Owner, Admin, Bookkeeper, Accountant, Reviewer, Read-only) exist in code. Every protected action in the system has a single, deterministic permission check it routes through. The permission matrix is data, not scattered if-statements, and is fully test-covered.

## Dependencies

- Phase 01 (`business_user_roles` table)
- Phase 02 (a logged-in user has a session and a principal context)

## Deliverables

- **Role enum** in code with canonical names: `OWNER`, `ADMIN`, `BOOKKEEPER`, `ACCOUNTANT`, `REVIEWER`, `READ_ONLY`.
- **Permission surfaces** as constants: `BUSINESS_ACCESS`, `BANK_ACCOUNT_ACCESS`, `DOCUMENT_VIEW`, `WORKFLOW_EXECUTE`, `ISSUE_RESOLVE`, `FINALIZATION`, `REPORT_EXPORT`, `USER_MANAGEMENT`, `EXTERNAL_INTEGRATION`.
- **Permission matrix** as a typed table mapping `(role, surface) → action set` (read, create, update, delete, finalize, etc., with `STEP_UP_REQUIRED` flag). The matrix is the **single source of truth for `STEP_UP_REQUIRED`** — Phase 06's step-up runtime consumes this flag rather than re-declaring its own list of step-up surfaces.
- **Decision function** — a single `canPerform(principalContext, surface, action) → Decision` that returns `ALLOW`, `DENY`, or `REQUIRE_STEP_UP`. Implementations elsewhere call this, never the matrix directly.
- **Principal context type** — the signed bundle attached to a request: `user_id`, `organization_id`, `business_id`, `role`, `permissions`, `mfa_recent_at`. Required on every protected operation.
- **Helper for "principal of a workflow run"** — captures the principal context at run start so role changes apply only to new runs (Phase 09 wires the propagation).
- **Audit hook** — every `DENY` emits an `ACCESS_DENIED` event; every `ALLOW` for a sensitive action (finalization, user management, export) emits an `ACCESS_GRANTED` event with the surface name.
- **Tests** covering every cell of the matrix, plus negative tests for cross-tenant queries.

## Definition of Done

- A user with role `BOOKKEEPER` on Business A can run workflows on Business A but not on Business B (where they have no role).
- A user with role `READ_ONLY` is denied any write surface and gets an audit event.
- A `DENY` decision returned via `canPerform` is the only path through which the rest of the codebase blocks an action — no inline role checks in handlers.
- The permission matrix can be printed as a clean table for documentation and audit.
- Cross-tenant access attempts produce an audit event flagged for security review.
- Test coverage includes every (role × surface × action) combination plus the cross-tenant scenarios.

## Sub-doc Hooks (Stage 4)

- **Permission matrix sub-doc** — the canonical table, written once and referenced as the source of truth for the role × surface design.
- **Principal context sub-doc** — exact shape, signing, lifetime, refresh on role change.
- **canPerform helper sub-doc** — function signature, error shapes, integration with audit logging.
- **Cross-tenant alerting sub-doc** — what counts as a cross-tenant attempt, alert routing, severity escalation.
