# Permission Matrix

**Category:** Reference data · **Owning block:** 02 — Tenancy & Access · **Co-owners:** 13, 14, 16 · **Stage:** 4 sub-doc (Layer 1 taxonomy)

The canonical permission matrix — role × surface authorization for every action in the system. This is the single source of truth that the runtime authorization helper `auth.canPerform(actor, surface, business_id)` (per Block 02 Phase 04) consults. Adding a surface or changing a default grant requires a `Docs/decisions_log.md` amendment.

The matrix is the post-amendments state after the 2026-05-08 (`ISSUE_RESOLVE` decomposition) and 2026-05-09 (`REPORT_EXPORT` decomposition + dashboard surfaces) amendments. The base set declared in Block 02 Phase 04 architecture is the starting point; the amendments evolved it.

---

## The 6 roles (closed)

| Role | Default new-user role | Intent |
| --- | --- | --- |
| Owner | (set at business creation) | Highest authority; sole user of `USER_INVITE`, `BUSINESS_SETTINGS_EDIT`, etc. by default |
| Admin | Owner-grantable | Operational top-of-business; cannot transfer ownership |
| Bookkeeper | Owner/Admin-grantable | Day-to-day operator; resolves issues, triggers runs, no settings edits |
| Accountant | Owner/Admin-grantable | Reviews and reports; export-heavy access |
| Reviewer | Owner/Admin-grantable | Read-only on operational data + queue view |
| Read-only | Owner/Admin-grantable | Dashboard + audit-light only |

Per Stage 1: no External Auditor role in MVP; no custom-role builder. The 6 roles are closed.

---

## Workflow and run actions

| Action | org:owner | org:admin | org:accountant | org:viewer | Notes |
|---|---|---|---|---|---|
| `run:create` | ✓ | ✓ | ✗ | ✗ | Requires `WORKFLOW_TRIGGER` surface. Bookkeeper also holds this; see full matrix below. |
| `run:cancel` | ✓ | ✓ | ✗ | ✗ | Only on CREATED, RUNNING, PAUSED, REVIEW_HOLD states. FINALIZING and beyond: blocked. |
| `run:finalize` | ✓ | ✓ | ✗ | ✗ | Requires `FINALIZATION` surface + step-up MFA. See step-up section. |

## Invoice actions

| Action | org:owner | org:admin | org:accountant | org:viewer | Notes |
|---|---|---|---|---|---|
| `invoice:void` | ✓ | ✓ | ✗ | ✗ | Status must be DRAFT, SENT, PARTIALLY_PAID, or OVERDUE. PAID invoices require adjustment run. |
| `invoice:send` | ✓ | ✓ | ✓ | ✗ | Status must be DRAFT. Moves to SENT on dispatch. |

## Period management

| Action | org:owner | org:admin | org:accountant | org:viewer | Notes |
|---|---|---|---|---|---|
| `period:lock` | ✓ | ✓ | ✗ | ✗ | Requires `FINALIZATION` surface + step-up MFA. Irreversible without period:unlock. |
| `period:unlock` | ✓ | ✗ | ✗ | ✗ | Owner-only. Requires step-up MFA. Emits `FINALIZATION_PERIOD_UNLOCKED` audit event. |

## Review queue

| Action | org:owner | org:admin | org:accountant | org:viewer | Notes |
|---|---|---|---|---|---|
| `review_queue:resolve` | ✓ | ✓ | ✓ | ✗ | Requires `REVIEW_QUEUE_RESOLVE` surface. Viewer role holds `REVIEW_QUEUE_VIEW` only. |

## Team management

| Action | org:owner | org:admin | org:accountant | org:viewer | Notes |
|---|---|---|---|---|---|
| `team:invite` | ✓ | ✓ | ✗ | ✗ | Requires `USER_INVITE` surface. Token generated with `gen_random_uuid()`. |
| `team:remove` | ✓ | ✓ | ✗ | ✗ | Cannot remove org:owner. Owner removal requires ownership transfer first. |

## API keys and settings

| Action | org:owner | org:admin | org:accountant | org:viewer | Notes |
|---|---|---|---|---|---|
| `api_key:create` | ✓ | ✓ | ✗ | ✗ | Requires `EXTERNAL_INTEGRATION` surface. Key scoped to business_entity_id. |
| `settings:update` | ✓ | ✓ | ✗ | ✗ | Requires `BUSINESS_SETTINGS_EDIT` surface. Step-up optional per-business (Stage 2). |

## Audit logs and reports

| Action | org:owner | org:admin | org:accountant | org:viewer | Notes |
|---|---|---|---|---|---|
| `audit_log:read` | ✓ | ✓ | ✓ | ✓ | All roles can read audit logs for their business_entity_id only. Cross-tenant: never. |
| `report:generate` | ✓ | ✓ | ✓ | ✗ | Basic reports: Owner, Admin, Accountant. Full/regulator-grade: Owner, Admin, Accountant only. |

---

## Consolidated matrix (all surfaces)

| Surface | Owner | Admin | Bookkeeper | Accountant | Reviewer | Read-only |
| --- | --- | --- | --- | --- | --- | --- |
| SESSION_MANAGE | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| USER_INVITE | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ |
| BUSINESS_SETTINGS_EDIT | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ |
| EXTERNAL_INTEGRATION | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ |
| WORKFLOW_TRIGGER | ✓ | ✓ | ✓ | ✗ | ✗ | ✗ |
| WORKFLOW_APPROVE | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ |
| FINALIZATION | ✓ + step-up | ✓ + step-up | ✗ | ✗ | ✗ | ✗ |
| REVIEW_QUEUE_VIEW | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| REVIEW_QUEUE_RESOLVE | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| REVIEW_ASSIGN | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ |
| REVIEW_REGENERATE | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ |
| REPORT_EXPORT_BASIC | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| REPORT_EXPORT_FULL | ✓ | ✓ | ✗ | ✓ | ✗ | ✗ |
| DASHBOARD_VIEW | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| DASHBOARD_REFRESH_MANUAL | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| RETENTION_POLICY/UPDATE | ✓ + step-up | ✓ + step-up | ✗ | ✗ | ✗ | ✗ |
| LEGAL_HOLD/SET | ✓ + step-up | ✗ | ✗ | ✗ | ✗ | ✗ |
| LEGAL_HOLD/LIFT | ✓ + step-up | ✗ | ✗ | ✗ | ✗ | ✗ |

---

## Role name mapping

The action tables above use the `org:` prefixed names used in API payloads and JWT claims.
The consolidated surface matrix uses the shorthand names used internally. The mapping is:

| API / JWT claim name | Internal shorthand |
|---|---|
| `org:owner` | Owner |
| `org:admin` | Admin |
| `org:bookkeeper` | Bookkeeper |
| `org:accountant` | Accountant |
| `org:viewer` | Reviewer |
| `org:readonly` | Read-only |

`org:accountant` in the action tables above maps to Accountant in the surface matrix.
`org:viewer` in the action tables above maps to Reviewer in the surface matrix.

---

## Step-up authentication requirement

A subset of surfaces require fresh MFA (TOTP or passkey, within `step_up_validity_window_policy`'s window). Marked with `+ step-up` in the consolidated matrix.

| Surface | Step-up required? | Why |
| --- | --- | --- |
| FINALIZATION | Yes | Immutable lock; mistakes are unrecoverable without an adjustment run |
| BUSINESS_SETTINGS_EDIT | Per-business optional (deferred Stage 2 toggle) | Sensitive configuration |
| USER_INVITE | Per-business optional (deferred Stage 2 toggle) | New principal entering the business |
| EXTERNAL_INTEGRATION | Per-business optional (deferred Stage 2 toggle) | Connecting OAuth tokens |
| RETENTION_POLICY/UPDATE | Yes | Retention policy is a Cyprus-compliance control point; recency of authentication required for any extension |
| LEGAL_HOLD/SET | Yes | Filing a hold is an irreversible-at-platform-layer action (COMPLIANCE Object Lock extension cannot be shortened); Owner accountability + step-up recency required |
| LEGAL_HOLD/LIFT | Yes | Lifting a hold resumes deletion eligibility; Owner accountability + step-up recency required |
| All other surfaces | No (single-factor auth sufficient) | Operational actions |

---

## Conditional permission notes

**run:cancel** — cancel is only permitted while the run is in a cancellable state per
`run_status_enum`: CREATED, RUNNING, PAUSED, REVIEW_HOLD, AWAITING_APPROVAL. Once a run enters
FINALIZING, FINALIZED, or FAILED, cancel is blocked. COMPENSATING runs cannot be cancelled.

**invoice:void** — voiding is blocked on PAID invoices. A PAID invoice must be reversed via a
credit note (see `invoice_credit_note_link_policy`). VOID is a terminal status; voided invoices
cannot be reinstated.

**period:unlock** — reserved for `org:owner` only. Admin cannot unlock periods. This asymmetry
is intentional: period lock is a financial control point; unlock authority is concentrated in the
single accountable principal.

**audit_log:read** — all roles can read audit logs, but only for their active `business_entity_id`.
Cross-tenant audit log access is prohibited for all roles without exception. See
`multi_tenancy_isolation_policy` Section 8.

**report:generate** — `REPORT_EXPORT_BASIC` covers operational reports. `REPORT_EXPORT_FULL`
covers regulator-grade exports (VAT preparation, VIES XML, finalized archive packages).
Accountant holds both. Bookkeeper holds BASIC only.

---

## Cross-block contracts

Surfaces are referenced by these blocks:

| Block | Surfaces consumed |
| --- | --- |
| 12 — OUT Workflow | `WORKFLOW_TRIGGER` (Phases 07, 08), `WORKFLOW_APPROVE` (Phase 07) |
| 13 — IN Workflow | `WORKFLOW_TRIGGER` (Phases 07, 09), `WORKFLOW_APPROVE` (Phase 09) |
| 14 — Review Queue | `REVIEW_QUEUE_VIEW`, `REVIEW_QUEUE_RESOLVE`, `REVIEW_ASSIGN`, `REVIEW_REGENERATE` |
| 15 — Finalization | `FINALIZATION` + step-up |
| 16 — Dashboard | `DASHBOARD_VIEW`, `DASHBOARD_REFRESH_MANUAL`, `REPORT_EXPORT_BASIC`, `REPORT_EXPORT_FULL` |
| 4 — Data Architecture | `RETENTION_POLICY/UPDATE` + step-up (Phase 10 — per `retention_policies_schema.md` §4 update RPC); `LEGAL_HOLD/SET` + `LEGAL_HOLD/LIFT` + step-up (Phase 11 — per `legal_hold_lifecycle_policy.md` §3-4 set/lift RPCs; Owner-only per `legal_hold_admin_extension_policy.md`) |

## Cross-references

- `severity_enum` — dismissal eligibility per role × severity
- `resolution_action_enum` — action-level eligibility consuming `REVIEW_*` surfaces
- `step_up_validity_window_policy` — fresh-MFA window
- `rls_policy_template` — Postgres RLS policy template that implements the matrix at the row level
- `audit_log_policies` — `TENANCY_*`, `ACCESS_DENIED`, `STEP_UP_*` event naming
- `multi_tenancy_isolation_policy` — cross-tenant access prohibition
- `org_invitation_policy` — `USER_INVITE` surface and invitation flow
- Block 02 Phase 04 — role model & permission matrix (architecture, original 9 surfaces)
- 2026-05-08 decisions-log amendment — `ISSUE_RESOLVE` decomposition
- 2026-05-09 decisions-log amendment — `REPORT_EXPORT` decomposition + dashboard surfaces
