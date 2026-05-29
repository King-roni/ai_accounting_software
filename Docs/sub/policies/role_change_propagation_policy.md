# role_change_propagation_policy

**Category:** Policies · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2)

The behavioural contract for how role / business-membership changes propagate through the system — what reads the **immutable workflow-run snapshot** vs what reads the **live per-request principal context**, the dispatch rules that route calls to the right authority bundle, and the edge-case handling when a user's membership is mutated or revoked entirely while a workflow run is in flight.

Companion to `principal_context_schema.md` (which defines the snapshot's shape + signing model + lifetime). This policy is the operational contract that consumes those constructs.

---

## 1. The Stage 1 binding rule

> *"Role-change propagation: apply to new actions only; active workflow runs continue with the principal context they started under."*
> — Stage 1 decision, quoted in `workflow_run_schema.md` line 127 and `principal_context_schema.md` §9.

This is the load-bearing invariant. The rest of this document is the operationalisation:

- "**New actions**" means anything that begins **after** the role mutation has been committed: any new workflow run, any standalone RPC, any RLS-policied query made from a freshly-authenticated session.
- "**Active workflow runs**" means runs whose `workflow_runs.status` is not in `(FINALIZED, COMPENSATING, CANCELLED)` at the moment the role mutation commits.

Mid-run actions ARE NOT new actions — they execute under the run's snapshotted authority, regardless of the live role state.

---

## 2. The dispatch model

`auth.canPerform(...)` (audit-C1, signature `(actor_user_id, surface, action, resource jsonb, business_id, organization_id) → ALLOW / DENY / REQUIRE_STEP_UP`) is **dispatch-agnostic**. It does not look at workflow context. It reads its inputs and the `permission_matrix` and returns a decision.

The dispatch — choosing **which authority bundle** to pass into `canPerform` — happens **at the caller**, not inside `canPerform`. Two distinct callers, two distinct sources:

| Caller | Authority source | GUC at evaluation time |
|---|---|---|
| **Tool/RPC invoked inside a workflow run** | `workflow_runs.principal_context_snapshot_json` for the owning run | `app.principal_context_json` SET LOCAL to the snapshot value |
| **Tool/RPC invoked outside a workflow run** (standalone request, RLS-policied SELECT, etc.) | The live per-request principal context built from the verified JWT + server-resolved tenancy (per `principal_context_schema.md` §1, §5, §6) | `app.principal_context_json` SET LOCAL to the live value |

Both callers SET the same GUC; the difference is what they SET it to. Helpers in `rls_helper_functions.md` (`current_user_id`, `current_business_id`, `current_role`, `auth.business_ids_for_session`) read from the GUC and are unaware of which source populated it.

This is what "canPerform decides which to read" actually means in practice: it doesn't. The workflow runner decides, and `canPerform` operates on whatever the GUC holds.

---

## 3. Who is the workflow runner

`workflow.execute_step(run_id, step_id, …)` (Block 03) is the canonical entry point for in-flight tool invocations. Its contract:

1. SELECT the run's `principal_context_snapshot_json` (FOR SHARE — concurrent-safe; the column is immutable so no lock contention).
2. `SET LOCAL app.principal_context_json = <snapshot value>`.
3. Invoke the step's bound tool/RPC.
4. The invoked code reads context via the standard helpers; helpers return snapshot values transparently.
5. End-of-transaction releases the GUC (per `principal_context_schema.md` §15).

Background jobs (post-write triggers, scheduled workers) operate under the **SYSTEM actor variant** per `principal_context_schema.md` §11 — they construct an operator principal context with `role = 'SYSTEM'` and `actor_system = '<job-name>'`. The dispatch model is the same; the source is the SYSTEM construction routine, not a workflow snapshot.

---

## 4. What the snapshot freezes (recap)

Per `principal_context_schema.md` §9, the 5-field subset stored in `workflow_runs.principal_context_snapshot_json`:

- `app_user_id` — who initiated the run
- `business_id` — which business the run is bound to
- `role` — the role in effect at run start
- `org_id` — the organisation context
- `session_id_at_start` — the session that initiated (informational; not used for authorisation, only for audit join)

What is **NOT** in the snapshot (and therefore evaluated against live state at each action):

| Live-evaluated field | Source | Implication |
|---|---|---|
| `step_up_qualified_until` | `user_sessions.step_up_qualified_until` | Step-up freshness is per-action. A run started with a fresh step-up still requires a re-step-up for actions hit after the step-up window expires. |
| `mfa_recent_at` | `users.mfa_recent_at` (placeholder pending B02·P06) | MFA recency is per-action by the same logic. |
| `client_form_factor` | Live per-request | Mobile-write rejection per `mobile_write_rejection_endpoints.md` is per-action; a desktop-initiated run can have its mobile-rejected steps blocked individually if the live caller is mobile. |

The snapshot is the **role/business authority** for the run. Step-up and MFA recency are separately and continuously verified.

---

## 5. Mid-run role mutations — concrete sequence

A user-A has role `ACCOUNTANT` on business-B at time T₀. Workflow run R is created at T₁ with `principal_context_snapshot_json.role = 'ACCOUNTANT'`. At T₂, Owner downgrades user-A's role to `READ_ONLY`. R is still in flight.

Behaviour:

| Action by user-A | Time | Authority used | Outcome |
|---|---|---|---|
| RPC bound to run R (mid-step continuation) | T₂ + ε | Snapshot — `role = 'ACCOUNTANT'` | Authorised per ACCOUNTANT's matrix entries; the run continues normally. |
| Standalone RPC outside R | T₂ + ε | Live — `role = 'READ_ONLY'` | Authorised only for READ_ONLY surfaces. |
| New workflow run R' created after T₂ | T₂ + ε | Live — `role = 'READ_ONLY'` is snapshotted into R' | R' executes under READ_ONLY for its entire lifetime. |
| Step-up-gated action inside R | T₂ + ε | Snapshot for role, **live for step-up freshness** | If R was started with step-up but step-up has since expired, the action prompts re-step-up; the role remains ACCOUNTANT for the matrix lookup. |
| Run R finalises at T₃ | T₃ | Snapshot for the FINALIZE action | Allowed; FINALIZE is gated on `gate_finalization_zero_blocking_issues` per `gate_finalization_zero_blocking_issues.md` + the snapshot role permits FINALIZE on this surface. |

This table is the canonical decision matrix consumers should test against.

---

## 6. User-removal edge case (BOOK-224 hook)

The hook explicitly asks: *"what happens if the user is removed from the business entirely while a run is active (the run completes; the user has no future access)."* The hook restates the answer; this section makes it operational.

A "user removal" can mean any of three distinct mutations:

| Mutation | Effect on `business_user_roles` | Effect on the run |
|---|---|---|
| **Role change** (ACCOUNTANT → READ_ONLY) | UPDATE `role` column | Run continues under snapshot role (ACCOUNTANT). New actions outside the run use READ_ONLY per §5. |
| **Membership removal** (DELETE `business_user_roles` row) | Row deleted | Run continues under snapshot role. **The user has no future access**: any new request resolves `business_id := NULL`, `role := NULL` per `principal_context_schema.md` §5, so any standalone business-scoped action is denied. |
| **Account deactivation / GDPR erasure** (anonymise `users` row tombstone per `principal_context_schema.md` §14) | `users` row anonymised; `business_user_roles` rows cascade | Run continues. Any join from a downstream audit query to `users.full_name` returns the tombstone marker, not the real name. The audit row itself is immutable and retains the anonymised display. |

The common thread: **the snapshot is the source of authority for the run; revoking the user's external access does not interrupt the run.** This is by design — accounting workflows often span days, and a mid-run authority revocation that aborted in-flight work would corrupt the bookkeeping state.

### What about run abort?

The platform does **not** auto-abort a run when the initiating user is removed from the business. Two reasons:

1. The run's state is the business's, not the user's. Aborting it because user-A was demoted to READ_ONLY would discard ledger entries, document classifications, and any human-reviewed match decisions accumulated mid-run.
2. The mid-run snapshot already isolates the run from user-A's current role. There is no security hole to close by aborting.

An Owner who genuinely needs to halt an in-flight run uses the run-cancellation surface (Block 14 review queue + `workflow_run_status_enum.CANCELLED`), which is a separate explicit operation. Membership removal is not a backdoor for run cancellation.

### Other edge cases

| Case | Behaviour |
|---|---|
| User-A is the **only** member of business-B and removes themselves | Disallowed by `org_member_capacity_policy.md` — businesses require at least one Owner. The removal RPC fails before commit. |
| Run was initiated by user-A; user-A is removed at T₂; user-B (Admin, still active) needs to advance the run | User-B invokes the run-advancement RPC under user-B's live principal context. The dispatch rule applies: actions bound to run R use the snapshot (still bearing user-A's ACCOUNTANT role) for matrix lookup, but the **acting actor** for audit purposes is user-B (per `audit_event_payload_schemas.md` actor fields). Both are recorded. |
| User-A's session is revoked while run R is in flight | The session revocation invalidates user-A's wire credentials. Run R continues — it's a server-side execution context that doesn't depend on user-A's session. User-A simply cannot initiate new actions against R; user-B (with valid session) can. |
| Cross-org move: user-A is moved from org-1 to org-2 mid-run | Per `principal_context_schema.md` §14, the JWT's `org_id` claim remains stale until refresh. Mid-run actions executed by user-A inside the stale-org context still hit the snapshot (which is bound to business-B in org-1). Standalone actions resolve against org-1 (the JWT claim) and fail authorisation against business-B in org-2. Re-login refreshes the JWT to `org_id = org_2`; subsequent standalone actions resolve correctly. |

---

## 7. Audit footprint for role-change events

Role mutations on `business_user_roles` are themselves audited (Block 05 taxonomy: `TENANCY_ROLE_CHANGED`, `TENANCY_MEMBER_REMOVED`). These events are emitted under the **mutating actor's** principal context (typically Owner / Admin), not under the affected user's context.

In-flight runs do not emit a separate "snapshot-active" or "live-divergence" event — the snapshot is the run's authority and the audit-event payload (per `audit_event_payload_schemas.md`) records `actor_role_at_event` from the snapshot for every action emitted from inside the run. This is the forensic trace that lets reconstruction tell which role authorised which action.

**Cross-block coordination flagged for B05·P02 implementation:** the `TENANCY_ROLE_CHANGED` payload should carry both `previous_role` and `new_role`. The `TENANCY_MEMBER_REMOVED` payload should carry `removed_user_id`, `previous_role`, `removed_by`, `removed_at`. Confirm Stage-2 taxonomy already covers these field shapes; if not, a Stage-6 taxonomy refresh is required.

---

## 8. Interaction with MFA re-challenge

Per `mfa_required_role_rechallenge_policy.md` (BOOK-177), certain role transitions force an MFA re-challenge by nulling `step_up_qualified_until`. This policy interacts with this one as follows:

| Scenario | Effect |
|---|---|
| User-A is promoted to a step-up-required role mid-run | The promotion triggers `mfa_required_role_rechallenge_policy.md`, nulling `step_up_qualified_until` on user-A's sessions. **In-flight run R is unaffected** — its snapshot already records the old role. User-A's NEXT step-up-gated standalone action requires re-challenge per the live state. |
| User-A is demoted mid-run | No MFA re-challenge implication. The run's snapshot role authorises future in-run actions. Standalone actions use the demoted role. |
| Run R's snapshot role is one that requires step-up for the FINALIZE surface | At FINALIZE time, the live `step_up_qualified_until` is checked. If expired, the action prompts re-step-up regardless of run-state. The step-up token consumption uses the **live actor's** user_id, not the snapshot's (per `_consume_step_up_token_for_actor`). |

The two policies are orthogonal: this one governs role authority continuity; the MFA policy governs step-up freshness, which is always live.

---

## 9. Helpers reading the dispatched GUC

All helpers in `rls_helper_functions.md` read from `app.principal_context_json`. This means RLS policies on schemas owned by Block 04 (storage zones, ledger entries, audit chain, archive) automatically respect the workflow-run snapshot when the caller is inside a workflow run, with no policy changes required.

The implication for migrations: when Block 03's `workflow.execute_step` lands at B03·P02, no RLS policy in Block 04, 05, 10, 11, 12, 13, 14, or 15 needs to be aware of the snapshot mechanism. The GUC is the abstraction barrier.

**Cross-block coordination flagged for B03·P02 implementation:** the workflow runner must call `SET LOCAL app.principal_context_json` BEFORE any tool-bound code runs, and the SET must happen inside the same transaction as the tool invocation. Setting it outside the transaction has no effect (GUC LOCAL is transaction-scoped).

---

## 10. Cross-references

- `principal_context_schema.md` — snapshot shape, lifetime, GUC mechanism, SYSTEM actor variant
- `workflow_run_schema.md` — `principal_context_snapshot_json` column DDL + Stage-1-decision quote
- `permission_matrix.md` — `permission_decision` enum + role-surface matrix
- `rls_helper_functions.md` — helpers that read the dispatched GUC
- `mfa_required_role_rechallenge_policy.md` — orthogonal MFA-recency interaction (§8)
- `org_member_capacity_policy.md` — last-Owner removal prohibition (§6)
- `audit_event_payload_schemas.md` — `actor_role_at_event` recorded from snapshot
- `audit_event_taxonomy.md` — `TENANCY_ROLE_CHANGED`, `TENANCY_MEMBER_REMOVED` (consumers in §7)
- `mobile_write_rejection_endpoints.md` — `client_form_factor` is live-evaluated, not snapshotted (§4)
- `step_up_validity_window_policy.md` — step-up freshness is live (§4, §8)
- `gdpr_data_subject_rights_policy.md` — anonymisation tombstone behaviour (§6)
- Block 02 Phase 04 — role model architecture (consumer of canPerform contract)
- Block 02 Phase 06 — `mfa_recent_at` populator (placeholder pending)
- Block 02 Phase 09 — role-change propagation (architecture; this policy operationalises it)
- Block 03 Phase 02 — workflow runner (GUC dispatch site; coordination flagged in §9)
- Block 05 Phase 02 — audit taxonomy (TENANCY_ROLE_CHANGED + TENANCY_MEMBER_REMOVED payload shapes; coordination flagged in §7)
- Stage 1 decision — role-change propagation (the binding rule §1 quotes)
