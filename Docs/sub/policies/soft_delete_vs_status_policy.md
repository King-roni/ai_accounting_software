# Soft Delete vs Status Policy

**Category:** Policies · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

This policy establishes the single decision rule for how a record's lifecycle end is represented in the database: either through a `status` ENUM (carrying an `INACTIVE` or `ARCHIVED` value) or through a hard `deleted_at` timestamp column. The rule is not a preference — it is structurally derived from GDPR erasure requirements and the data-retention engine's operating assumptions. Every Schema sub-doc that introduces a new table must cite this policy and declare which pattern it uses.

---

## The decision rule

| Record category | Pattern | Rationale |
| --- | --- | --- |
| **Business-data records** — transactions, documents, invoices, matches, ledger entries, evidence PDFs, archive packages, review issues | `status` ENUM with `INACTIVE` / `ARCHIVED` value | Business data participates in the retention engine (Block 04 Phase 10). Retention rules evaluate `status` to decide when automated deletion is eligible. A `deleted_at` timestamp on business data would create a separate deletion pathway outside retention control, bypassing legal-hold checks and the 6-year Cyprus retention floor. |
| **Identity records** — `users`, `organizations`, `organization_users`, `user_invitations` | `deleted_at` timestamp | Identity records are subject to GDPR right-to-erasure (Article 17). The `deleted_at` column marks the erasure execution point. The GDPR pipeline pseudonymizes PII immediately and schedules full anonymization after the retention period. A status ENUM alone cannot express "erased and data scrubbed" without introducing a parallel PII-scrubbing pipeline that would still need a timestamp anchor. |
| **Operational state records** — workflow runs, phase states, tool invocations | `status` ENUM only | These records are immutable once terminal (`FINALIZED`, `FAILED`, `CANCELLED`). Lifecycle transitions go through the workflow state machine; no external deletion is permitted. Retention deletion of these records (post-retention-window) is handled by the retention engine via the `status` column filter. |

---

## ENUM values

Tables using the `status` pattern must use values drawn from the relevant closed ENUM defined in `tenancy_schema_definition` or the relevant domain schema. The three lifecycle values that trigger the rule:

| Value | Meaning |
| --- | --- |
| `INACTIVE` | Operationally suspended. Not included in workflow triggers, dashboard aggregations, or new matches. Still readable by authorized roles. Retention timer continues. |
| `ARCHIVED` | Permanently closed, human-verified. Used for business entities that have ceased trading or bank accounts formally closed. Stricter than INACTIVE: write operations are rejected at the API layer. |
| `DELETED` | Reserved for the retention engine's internal soft-delete state (before physical row deletion). Not to be set by application code directly. |

---

## Interaction with the retention engine (Block 04 Phase 10)

The retention engine evaluates records for deletion by querying `status NOT IN ('ACTIVE', 'INACTIVE')` on business-data tables, subject to:

1. Retention window expiry (default 6 years for Cyprus VAT and accounting records).
2. Legal-hold flag on the business (`legal_hold_active = true` suspends all automated deletion for the entire business).
3. Finalization lock — finalized-period records are Object-Locked in Supabase Storage; the retention engine skips the underlying file deletion for these records until Object Lock expiry.

For identity records using `deleted_at`, the retention engine's cleanup pass reads `deleted_at IS NOT NULL AND deleted_at < (now() - retention_interval)` to schedule full anonymization. This is distinct from the status-based pipeline; the two passes run independently.

Audit event on retention deletion: `RETENTION_DELETION_EXECUTED` — emitted by the retention engine, not by this policy's enforcement layer.

---

## Interaction with RLS

### Status-filtered views

The RLS policies on business-data tables filter `status != 'ARCHIVED'` in the `USING` clause for standard read operations. Archived records are excluded from normal dashboard queries and workflow processing. They remain readable via privileged read (Owner/Admin role + explicit `include_archived=true` query parameter) for audit and reconstruction purposes.

The `rls_policy_template` defines two policy variants per table type:
- `_live_read` policy — filters `status IN ('ACTIVE', 'INACTIVE')`
- `_archive_read` policy — permits `status = 'ARCHIVED'` for Owner/Admin only

### Hard-deleted identity records

Once `deleted_at` is set on a `users` or `organizations` row, the RLS `USING` clause includes `deleted_at IS NULL` to exclude the row from all reads. The row is physically retained (for the audit trail and to satisfy the `GDPR_ERASURE_REQUESTED` event's chain reference) but is invisible to all application queries.

Supabase Auth handles the `auth.users` deletion separately; the `public.users` row's `deleted_at` timestamp is set first, then the auth record is scheduled for deletion after pseudonymization is confirmed.

---

## Deactivation vs deletion: audit event mapping

| Action | Table category | Mechanism | Audit event | Severity |
| --- | --- | --- | --- | --- |
| Suspend a bank account | Business data | `status → INACTIVE` | `TENANCY_BANK_ACCOUNT_DEACTIVATED` | MEDIUM |
| Archive a business entity | Business data | `status → ARCHIVED` | `TENANCY_BUSINESS_ARCHIVED` | HIGH |
| Remove a user from org | Identity record | `deleted_at = now()` + `status → INACTIVE` on `organization_users` | `TENANCY_MEMBER_REMOVED` | MEDIUM |
| GDPR erasure of a user | Identity record | `deleted_at = now()` (pseudonymize immediately) | `GDPR_ERASURE_REQUESTED` then `GDPR_PSEUDONYMIZED` | HIGH |
| Retention-engine deletion | Any | Physical row delete (business data) or full anonymize (identity) | `RETENTION_DELETION_EXECUTED` | LOW |

All events listed above must appear in `audit_event_taxonomy`.

---

## Edge case: `organization_users` membership

`organization_users` is an identity-adjacent join table (it connects a user to an organization). It follows the identity-record pattern: it carries both `status` (for suspension) and `deleted_at` (for hard removal). When a user is removed from an organization:
1. `deleted_at` is set to mark the removal timestamp.
2. All associated `business_user_roles` rows for that user within that organization are set to `status = 'INACTIVE'`.
3. The GDPR erasure pipeline, if triggered, anonymizes the `organization_users` row independently of the `users` row.

---

## Application-layer enforcement

Even with RLS in place, the application layer must enforce the write-rejection rules for ARCHIVED records independently. RLS prevents unauthorized reads but does not always prevent writes that would technically pass the RLS WITH CHECK clause (e.g., an Owner updating a non-status column on an ARCHIVED business entity).

Rules:
1. Any API endpoint that mutates a business-data record must check `status != 'ARCHIVED'` before executing the write and return HTTP 409 with `error_code: RECORD_ARCHIVED` if the check fails.
2. The workflow engine must refuse to create a new `workflow_run` for a business where `business_entities.status = 'ARCHIVED'`.
3. The invitation flow must refuse to create invitations for a business where `status = 'ARCHIVED'`.

These checks are implemented in the API gateway (Block 02 Phase 04's application query helper). They are not duplicated in each endpoint handler; the helper wraps all tenant-scoped writes and applies the check centrally.

For identity records: once `deleted_at` is set, the application must treat the record as non-existent. The `current_user_id()` helper function already returns NULL for users with `deleted_at IS NOT NULL`, which propagates a denial through all RLS policies automatically.

---

## Operational status vs data status

A note on naming precision: the word "status" appears in two distinct contexts:

- **Operational status** (`org_status`, `account_status`, `business_status` ENUMs on tenancy tables) — governs whether a record is active in the system's operational flows. This is what this policy governs.
- **Workflow status** (`workflow_run_status`, `tool_invocation_status`, etc.) — governs the lifecycle state of a workflow execution artefact. These ENUMs are defined in `workflow_state_enum` and `tool_invocation_schema`. They use different terminal states (`FINALIZED`, `FAILED`, `CANCELLED`) and are not subject to the INACTIVE/ARCHIVED/deleted_at rule because workflow artefacts are never subject to GDPR erasure or the retention engine's status sweep.

Do not conflate the two. A `workflow_run` reaching `FINALIZED` does not set any `status = 'ARCHIVED'` column; it stays `FINALIZED` forever until the retention engine physically deletes the row post-retention-window via the service role.

---

## Adding a new table: checklist

When adding a new table, the Schema sub-doc author must answer:
1. Is this table identity data or business data?
2. Does this table contain PII subject to GDPR erasure?
3. Does this table need to participate in the retention engine's deletion sweep?
4. Are records on this table ever ARCHIVED (permanently closed, write-rejected) as distinct from INACTIVE (suspended)?

If (2) yes → include `deleted_at`. If (3) yes and (2) no → use `status` ENUM with `INACTIVE`/`ARCHIVED` values. If both apply → use both (see `organization_users` pattern above). If (4) no → ENUM needs only `ACTIVE` and `INACTIVE`; do not add an `ARCHIVED` value that the lifecycle never reaches.

Example classification for new tables introduced in downstream blocks:

| Table | Category | Pattern |
| --- | --- | --- |
| `transactions` | Business data | `status` ENUM — participates in retention engine |
| `documents` | Business data | `status` ENUM — same |
| `match_records` | Business data | `status` ENUM — same |
| `review_issues` | Business data | `status` ENUM — lifecycle managed by Block 14 |
| `workflow_runs` | Operational state | `status` ENUM only — state machine owned by Block 03 |
| `tool_invocations` | Operational state | `status` ENUM only — immutable once terminal |
| `user_invitations` | Identity-adjacent | `status` ENUM for lifecycle + no `deleted_at` (invitations are not PII-bearing records requiring erasure in their own right; the invitee's `users` row handles GDPR) |

For any table not listed here, apply the four-question checklist above. Document the decision in the table's Schema sub-doc under a "Lifecycle pattern" heading with a one-sentence rationale citing this policy.

---

## Cross-references

- `audit_log_policies` — event naming convention
- `audit_event_taxonomy` — canonical events: `GDPR_ERASURE_REQUESTED`, `GDPR_PSEUDONYMIZED`, `RETENTION_DELETION_EXECUTED`, `TENANCY_MEMBER_REMOVED`, `TENANCY_BUSINESS_ARCHIVED`, `TENANCY_BANK_ACCOUNT_DEACTIVATED`
- `tenancy_schema_definition` — column definitions for `organizations`, `users`, `business_entities`, `bank_accounts`, `organization_users`, `business_user_roles`
- `rls_policy_template` — how `status` filtering integrates with RLS USING clauses
- `Docs/phases/02_tenancy_and_access/01_schema_scaffolding.md` — schema phase (establishes the columns this policy governs)
- Block 04 Phase 10 — retention engine (consumes `status` and `deleted_at` for scheduled deletion)
