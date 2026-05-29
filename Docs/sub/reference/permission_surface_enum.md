# Permission Surface Enum

**Block:** 02 — Tenancy & Access
**Category:** Reference data
**Stage:** 4 sub-doc (Layer 2)

---

## Purpose

Defines the closed enum of all 13 canonical permission surfaces used by
`auth.can_perform`. Every authorization check in the application names one surface
from this list. Adding a surface requires a PR that updates this file, the CRUD matrix
in `permission_matrix.md`, and the surface validation map inside `auth.can_perform`.
No surface may be introduced into production code before it appears here.

---

## Enum Definition

```
workflow_run
transaction
invoice
document
ledger_entry
bank_upload
vendor_memory
counterparty
review_issue
archive
report
admin_settings
audit_log
```

These 13 values are the only accepted inputs for the `surface` parameter of
`auth.can_perform`. The enum is checked at application boot via a fixture assertion;
any value in production code that does not appear in this list causes the build to
fail.

---

## Surface Descriptions

| Surface | Description | Owning block |
| --- | --- | --- |
| `workflow_run` | A workflow run record and its status lifecycle | 03 — Workflow Engine |
| `transaction` | A normalised bank transaction row and its classification | 07/08 — Bank Statement Pipeline / Classification |
| `invoice` | An outgoing or incoming invoice, including line items and PDF | 13 — IN Workflow + Invoice Generator |
| `document` | An intake document (PDF, image, email attachment) and its extracted fields | 09 — Document Intake |
| `ledger_entry` | A prepared double-entry ledger row and its VAT treatment | 11 — Ledger & Cyprus VAT |
| `bank_upload` | A raw bank statement file upload | 07 — Bank Statement Pipeline |
| `vendor_memory` | The per-business vendor classification memory store | 08 — Transaction Classification |
| `counterparty` | A resolved counterparty record | 11 — Ledger & Cyprus VAT |
| `review_issue` | A review queue issue card | 14 — Review Queue |
| `archive` | A finalized period archive bundle and its manifest | 15 — Finalization & Secure Archive |
| `report` | A generated dashboard report or accountant pack | 16 — Dashboard & Reporting |
| `admin_settings` | Business configuration, integration settings, user management | 02 — Tenancy & Access |
| `audit_log` | The append-only audit event log | 05 — Security & Audit |

---

## CRUD Matrix

Operations: **C** = CREATE, **R** = READ, **U** = UPDATE, **D** = DELETE.
Mark meanings: `Y` = permitted, `N` = denied, `-` = operation is not applicable
to this surface (the surface has no concept of that operation; `auth.can_perform`
will return false for these).

Roles: **OWNER**, **ACCOUNTANT**, **VIEWER**, **ADMIN** (platform admin, cross-business).

| Surface | Operation | OWNER | ACCOUNTANT | VIEWER | ADMIN |
| --- | --- | --- | --- | --- | --- |
| `workflow_run` | C | Y | Y | N | Y |
| `workflow_run` | R | Y | Y | Y | Y |
| `workflow_run` | U | Y | Y | N | Y |
| `workflow_run` | D | N | N | N | N |
| `transaction` | C | N | N | N | N |
| `transaction` | R | Y | Y | Y | Y |
| `transaction` | U | Y | Y | N | Y |
| `transaction` | D | N | N | N | N |
| `invoice` | C | Y | Y | N | Y |
| `invoice` | R | Y | Y | Y | Y |
| `invoice` | U | Y | Y | N | Y |
| `invoice` | D | N | N | N | N |
| `document` | C | Y | Y | N | Y |
| `document` | R | Y | Y | Y | Y |
| `document` | U | Y | Y | N | Y |
| `document` | D | N | N | N | N |
| `ledger_entry` | C | N | N | N | N |
| `ledger_entry` | R | Y | Y | Y | Y |
| `ledger_entry` | U | N | Y | N | Y |
| `ledger_entry` | D | N | N | N | N |
| `bank_upload` | C | Y | Y | N | Y |
| `bank_upload` | R | Y | Y | Y | Y |
| `bank_upload` | U | N | N | N | N |
| `bank_upload` | D | N | N | N | N |
| `vendor_memory` | C | N | N | N | N |
| `vendor_memory` | R | Y | Y | N | Y |
| `vendor_memory` | U | Y | Y | N | Y |
| `vendor_memory` | D | N | N | N | N |
| `counterparty` | C | N | N | N | N |
| `counterparty` | R | Y | Y | Y | Y |
| `counterparty` | U | Y | Y | N | Y |
| `counterparty` | D | N | N | N | N |
| `review_issue` | C | N | N | N | N |
| `review_issue` | R | Y | Y | Y | Y |
| `review_issue` | U | Y | Y | N | Y |
| `review_issue` | D | N | N | N | N |
| `archive` | C | N | N | N | N |
| `archive` | R | Y | Y | Y | Y |
| `archive` | U | N | N | N | N |
| `archive` | D | N | N | N | N |
| `report` | C | Y | Y | N | Y |
| `report` | R | Y | Y | Y | Y |
| `report` | U | N | N | N | N |
| `report` | D | N | N | N | N |
| `admin_settings` | C | Y | N | N | Y |
| `admin_settings` | R | Y | N | N | Y |
| `admin_settings` | U | Y | N | N | Y |
| `admin_settings` | D | Y | N | N | Y |
| `audit_log` | C | N | N | N | N |
| `audit_log` | R | Y | Y | N | Y |
| `audit_log` | U | N | N | N | N |
| `audit_log` | D | N | N | N | N |

Notes on the matrix:
- `transaction CREATE` is `N` for all roles because transactions are created only by
  the workflow engine (Block 07), never by a user-initiated API call.
- `ledger_entry CREATE` is `N` for all roles because ledger entries are created only
  by `ledger.prepare_entries` during a workflow run.
- `archive UPDATE` and `archive DELETE` are `N` for all roles. Archives are
  Object-Locked; no API path writes to or deletes an archive bundle.
- `audit_log CREATE`, `UPDATE`, `DELETE` are `N` for all roles. The audit log is
  append-only and writable only via the internal `emitAudit()` function, not through
  any user-facing surface.
- `vendor_memory CREATE` is `N` because vendor memory rows are created exclusively by
  `classification.write_vendor_memory` during the classification phase.

---

## `SURFACE_UNKNOWN` Error

If `auth.can_perform` receives a `surface` value that is not in this enum, it throws
`SURFACE_UNKNOWN` — it does not return `false`. This is intentional: a `false` return
would allow callers to silently proceed with a mistyped surface name, potentially
bypassing authorization checks. `SURFACE_UNKNOWN` propagates as an unhandled exception
that surfaces to the caller as HTTP 500 and triggers a `SECURITY_ALERT_RAISED` event.

The lint rule that validates surface names in source files (checked at CI time) means
`SURFACE_UNKNOWN` at runtime indicates a code path that bypassed the lint or was
introduced via a dynamic string. Both cases are security-relevant.

---

## Adding a New Surface

Adding a surface requires all four of the following steps in the same PR:

1. Add the surface name to the enum definition in this file.
2. Add the surface row(s) to `permission_matrix.md` with a complete CRUD grant for
   every role.
3. Add the surface to the validation map in `auth.can_perform` (the map is the
   runtime enforcement counterpart to this file).
4. Add or update the surface description table in this file.

A PR that updates only this file without updating `permission_matrix.md` fails review.
The lint fixture that loads both files checks that their surface lists are identical.

---

## Cross-references

- `tool_can_perform_helper.md` — `auth.can_perform` implementation and SURFACE_UNKNOWN
  throw path
- `permission_matrix.md` — full grant table used by `auth.can_perform` at runtime
- `rls_deny_audit_pattern_policy.md` — RLS deny detection and `SECURITY_RLS_DENY_DETECTED`
  event, which fires when the DB layer rejects access that the application layer should
  have prevented
- Block 02 Phase 04 — Role model and permission matrix (phase doc)
- `audit_event_taxonomy.md` — `AUTH_PERMISSION_DENIED` event definition
