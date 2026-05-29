# Block 05 — Phase 06: Access Control Runtime

## References

- Block doc: `Docs/blocks/05_security_and_audit.md` (Access Control Runtime section)
- Block doc: `Docs/blocks/02_tenancy_and_access.md` (`canPerform` is owned here)
- Decisions log: `Docs/decisions_log.md` (step-up auth uses the same TOTP/passkey factor as login; cross-tenant attempts surface internally only in MVP)

## Phase Goal

Build the runtime that wraps every protected operation in the codebase. Block 02 owns the *decision* (`canPerform`); Block 05 owns the *enforcement* — the runtime that calls `canPerform`, processes the decision, applies step-up checks, and emits an audit event for every outcome. After this phase, no code path that performs a sensitive action bypasses access control.

## Dependencies

- Phase 02 (audit log emission)
- Block 02 Phase 04 (`canPerform` decision function)
- Block 02 Phase 06 (step-up auth + `mfa_recent_at` window)

## Deliverables

- **Access-control wrapper:**
  - `withAccessControl(principal, surface, action, resource, fn)` — the chokepoint.
  - Calls `canPerform(principal, surface, action, resource)` from Block 02.
  - Processes the returned decision (`ALLOW` / `DENY` / `REQUIRE_STEP_UP`).
  - On `ALLOW`: emits `ACCESS_ALLOWED` (for sensitive surfaces) and runs the wrapped `fn`.
  - On `DENY`: emits `ACCESS_DENIED` with the reason code; throws `AccessDeniedError`.
  - On `REQUIRE_STEP_UP`: checks the principal's `mfa_recent_at` against the validity window. If within window, treats as ALLOW. Otherwise, emits `ACCESS_STEP_UP_TRIGGERED` and returns a structured "step-up required" response that the client converts into an MFA challenge.
- **Sensitive surfaces** (always emit `ACCESS_ALLOWED`, not just `ACCESS_DENIED`):
  - Finalization, user management, integration disconnect, finalized-archive export, role escalation, secrets rotation, KEK rotation, DEK rotation, key destruction, decrypt-at-use API.
- **Cross-tenant detection:**
  - When a `DENY` is returned because the resource's tenancy doesn't match the principal's, the audit event carries `cross_tenant: true`. Repeated `cross_tenant: true` denials trigger the Phase 10 alert pipeline.
- **Integration points:**
  - Every workflow phase tool invocation (Block 03 Phase 03's `engine.invokeTool`) routes through this runtime before execution.
  - Every export endpoint in Block 16 routes through this runtime.
  - Every mutation API across the codebase wraps its handler in `withAccessControl`.
  - The decrypt-at-use API in Phase 05 uses this runtime for its permission check.
  - Block 02 Phase 05's application query helper integrates with this runtime — queries against tenant-scoped tables go through both RLS and access control.
- **Decision-throws failure path:**
  - If `canPerform` itself throws (a bug in the decision function), the runtime treats it as `DENY` with reason `decision_threw` and surfaces a `CRITICAL` alert through Phase 10. The wrapped operation does not proceed.
- **Audit events:** `ACCESS_ALLOWED` (sensitive surfaces only), `ACCESS_DENIED`, `ACCESS_STEP_UP_TRIGGERED`, `ACCESS_DECISION_THREW`.

## Definition of Done

- Every code path performing a protected action is wrapped in `withAccessControl`.
- An ALLOW decision lets the wrapped function execute and audits accordingly.
- A DENY decision throws and emits the right audit event with the reason code.
- A REQUIRE_STEP_UP decision either passes (recent MFA) or returns the step-up signal that triggers a challenge.
- A cross-tenant access attempt produces an audit event with `cross_tenant: true`.
- A decision-throws scenario is treated as DENY and produces a CRITICAL alert.
- Tests cover ALLOW, DENY, REQUIRE_STEP_UP (recent), REQUIRE_STEP_UP (stale), cross-tenant, and decision-threws.

## Sub-doc Hooks (Stage 4)

- **`withAccessControl` signature sub-doc** — exact function signature, error shapes, async semantics.
- **Sensitive-surfaces sub-doc** — the canonical list of surfaces that emit `ACCESS_ALLOWED`, ownership per surface.
- **Cross-tenant alert routing sub-doc** — threshold for promotion from individual `cross_tenant: true` event to a security alert; how Phase 10 consumes these events.
- **Decision-throws handling sub-doc** — exact alert payload, on-call rotation, recovery procedure if `canPerform` is broken in production.
- **Step-up validity window override sub-doc** — per-surface override mechanism (e.g., key destruction may want a tighter window than other sensitive actions).
