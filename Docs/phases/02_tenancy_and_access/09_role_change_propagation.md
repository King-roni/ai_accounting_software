# Block 02 — Phase 09: Role Change Propagation

## References

- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Role Change Propagation section)
- Block doc: `Docs/blocks/03_workflow_engine.md` (run lifecycle, principal context)
- Decisions log: `Docs/decisions_log.md` (role changes apply to new actions only; active runs preserve their original principal context)

## Phase Goal

When a user's role on a business changes mid-flight, **active workflow runs continue under the principal context they started with** while **new actions and new runs use the updated role**. This phase wires up the snapshotting, the divergence, and the audit visibility into both states.

Phase 09 **does not mutate** `business_user_roles` — it reads them. Role mutation is owned by Phase 07's `MEMBER_ROLE_CHANGED` event. This phase implements the snapshot-vs-live read behaviour around the role table, plus the workflow-run snapshot itself.

## Dependencies

- Phase 04 (principal context defined and signed)
- Phase 07 (role change action exists)
- **Cross-block dependency on Block 03 (Workflow Engine) is deferred.** Phase 09 specifies the principal-context snapshot shape; Block 03's run-record schema must accept that shape when it's decomposed. No Block 02 work blocks on Block 03.

## Deliverables

- **Principal context snapshot** stored on the `Workflow Run` record at run creation time. The snapshot contains everything `canPerform` reads: `user_id`, `organization_id`, `business_id`, `role`, `permissions`, `mfa_recent_at`. The snapshot is signed and immutable for the run's lifetime.
- **`canPerform` integration** — when called inside a workflow run context, reads from the run's snapshot rather than the live principal context. Outside a run, reads live.
- **Mid-flight role change semantics:**
  - The user's session role updates immediately — anything they do *outside* the run reflects the new role.
  - Their active runs continue under the snapshotted role until completion (or abort).
  - Starting a new run uses the live role.
- **UI indicator** — a discreet banner inside an active run when the user's live role differs from the run's snapshot ("Your live role on this business is now X; this run continues under Y until finalized").
- **Run completion flow** — when an active run finalizes, the next run on the same business by this user automatically uses the live role.
- **Audit events:** `WORKFLOW_RUN_PRINCIPAL_SNAPSHOTTED`, `ROLE_CHANGED_DURING_ACTIVE_RUN`, `WORKFLOW_RUN_COMPLETED_WITH_LIVE_ROLE_DIFFERENT`.

## Definition of Done

- A Bookkeeper demoted to Reviewer in the middle of an active OUT_MONTHLY run can still resolve issues and finalize that run.
- The same user starting a new run after the demotion is correctly limited to Reviewer permissions.
- The UI banner is shown inside the active run.
- Audit events correctly distinguish snapshotted from live decisions.
- Tests cover at least: demotion mid-run, promotion mid-run, and the cross-business case (role on Business A unaffected when role on Business B changes).

## Sub-doc Hooks (Stage 4)

- **Snapshot shape sub-doc** — exact fields, signing, immutability guarantees.
- **Snapshot vs live decision dispatch sub-doc** — how `canPerform` decides which to read.
- **Mid-flight banner sub-doc** — copy and visual treatment.
- **Edge cases sub-doc** — what happens if the user is removed from the business entirely while a run is active (the run completes; the user has no future access).
