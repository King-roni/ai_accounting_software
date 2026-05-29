# Block 04 — Phase 11: Legal Hold

## References

- Block doc: `Docs/blocks/04_data_architecture.md` (Legal hold section)
- Decisions log: `Docs/decisions_log.md` (legal hold is a per-business flag)

## Phase Goal

Implement the per-business legal-hold flag and wire it into the retention engine and Storage Object Lock lifecycle. After this phase, an Owner can set a legal hold on a business; while active, the retention engine refuses to delete that business's archived data and the corresponding Storage bundle locks have their retention extended.

## Dependencies

- Phase 07 (archive schema; Object Lock retention can be extended)
- Phase 10 (retention engine; this phase replaces its placeholder hook with the real implementation)
- Block 02 Phase 04 (Owner role + permission)
- Block 02 Phase 06 (step-up auth required for setting/lifting holds)

## Deliverables

- **`legal_holds` table:**
  - `id` (UUID v7), `business_id`, `status` (`ACTIVE`, `LIFTED`)
  - `hold_reason` (non-empty free text — required at set time)
  - `set_by`, `set_at`
  - `lift_reason` (non-empty free text — required at lift time)
  - `lifted_by`, `lifted_at`
  - `created_at`, `updated_at`
  - Index on `(business_id, status)` for the retention-engine hook query.
- **Set-hold API** — `POST /businesses/:id/legal-holds`:
  - Owner role only.
  - Step-up MFA required (Block 02 Phase 06).
  - Body: `{ hold_reason }` — must be non-empty.
  - Creates an `ACTIVE` row, emits `LEGAL_HOLD_SET`.
- **Lift-hold API** — `POST /legal-holds/:id/lift`:
  - Same auth + step-up requirements.
  - Body: `{ lift_reason }` — required.
  - Transitions the row to `LIFTED`, emits `LEGAL_HOLD_LIFTED`.
- **Hook implementation** — replaces the placeholder from Phase 10:
  - Signature exactly: `legalHoldHook(business_id) → { on_hold: boolean, hold_reasons: string[] }` — same shape as the Phase 10 placeholder.
  - Reads `legal_holds WHERE business_id = ? AND status = 'ACTIVE'`.
  - **Replacement mechanism:** the hook is registered in a runtime registry at boot. Phase 11 registers its implementation over the placeholder via that registry — no code change in Phase 10 is required.
  - The retention engine calls this for every business in its pass; on `on_hold = true`, deletion is skipped and the hold reasons are recorded in `RETENTION_DELETION_SKIPPED_LEGAL_HOLD` (canonical event owned by Phase 10).
- **Storage Object Lock interaction:**
  - When a hold is set, all archive bundles for the business have their Object Lock retention extended to `max(current_lock_retention, hold_set_at + max_legal_hold_window)`. The default `max_legal_hold_window` is configurable (sub-doc) and at minimum covers the longest plausible legal proceeding.
  - When a hold is lifted, the lock retention reverts to the standard policy.
  - Object Lock cannot be shortened in `compliance` mode; the retention engine respects this and treats it as a hard floor (sub-doc).
- **UI affordance** — a "Legal hold" panel under business settings, visible to Owner. Displays current status, history of past holds with their reasons, and the set/lift form.
- **Audit events:** `LEGAL_HOLD_SET`, `LEGAL_HOLD_LIFTED`. The retention-skip-on-hold event is `RETENTION_DELETION_SKIPPED_LEGAL_HOLD`, owned by Phase 10 (canonical name); Phase 11 does not emit a duplicate.

## Definition of Done

- The `legal_holds` table exists; the (business_id, status) index supports the retention hook's query.
- An Owner can set a hold via the UI; the API enforces non-empty reason, step-up, and Owner-only role.
- The retention engine's hook now returns the real result; a business with an active hold has its retention pass skip deletion and emit the right audit event.
- Storage Object Lock retention is extended on set and reverts on lift.
- An Admin attempting to set a hold without Owner role is rejected.
- Lifting a hold without step-up is rejected.
- A test of the full retention cycle: set hold → retention pass skips → lift hold → next retention pass deletes (if record is past threshold).
- All legal-hold actions appear in the audit log with their reasons.

## Sub-doc Hooks (Stage 4)

- **Legal hold UI sub-doc** — exact panel layout, set/lift forms, history display, copy.
- **Object Lock retention extension sub-doc** — exact extension calculation, interaction with Object Lock compliance vs governance modes, what happens at lift if the lock retention has already been pushed beyond the policy.
- **Hold lifecycle sub-doc** — set/lift state machine, audit completeness, edge cases (Owner removed mid-hold, business dissolution mid-hold).
- **Hold reason guidance sub-doc** — example reasons, retention notes, redaction considerations for any sensitive content in the reason text.
- **Maximum hold window sub-doc** — default value, override mechanism, jurisdictional considerations.
- **Admin-extension policy sub-doc** — whether and how the Admin role could be granted legal-hold management permission as a per-business override; post-MVP consideration. Owner-only is the canonical MVP rule.
