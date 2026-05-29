# Block 02 — Tenancy & Access Control

## Role in the System

This block defines who exists in the system, what they belong to, what they are allowed to do, and how the system enforces those rules at the data layer. It is the foundation that makes multi-business operation safe.

Every record in the operational database carries `organization_id` and `business_id`. Every query is scoped by both. Every action is performed by a known principal whose role determines the operations they can invoke. This block specifies the model; Block 05 (Security & Audit Layer) implements its enforcement and logs the access events.

---

## Scope

### In scope
- Identity hierarchy and the relationships between User, Organization, Business Entity, and Bank Account
- The role model and the permission matrix
- Row-level isolation rules and the query-scoping contract
- Authentication strategy (login, MFA, session management)
- External authorization grants (Gmail, Google Drive) — scoped per business

### Out of scope (covered elsewhere)
- Encryption, key management, audit log internals → Block 05 (Security & Audit Layer)
- Storage zones and where role-checked data lives → Block 04 (Data Architecture)
- The set of operations a workflow phase is permitted to invoke → Block 03 (Workflow Engine)

---

## Identity Hierarchy

```text
User
  └─ Organization (owned or member)
       └─ Business Entity
            └─ Bank Account
                 └─ Accounting Period
                      └─ Workflow Run
                           └─ Transaction → Evidence → Ledger Entry
```

A `User` may belong to multiple `Organization`s. An `Organization` contains one or more `Business Entity` records. A `Business Entity` owns one or more `Bank Account`s. Everything below the Business Entity is scoped to it.

The two scoping IDs that travel through every record are:

- `organization_id` — the tenant boundary
- `business_id` — the entity boundary inside a tenant

A query that omits either is a critical bug.

---

## Role Model

Six base roles, ordered from broadest to narrowest privilege:

| Role | Manages users? | Runs workflows? | Resolves issues? | Finalizes periods? | Exports reports? | Read-only? |
| --- | --- | --- | --- | --- | --- | --- |
| Owner | yes | yes | yes | yes | yes | — |
| Admin | yes (within org) | yes | yes | yes | yes | — |
| Bookkeeper | no | yes | yes | no | yes | — |
| Accountant | no | no | yes | yes (with policy) | yes | — |
| Reviewer | no | no | yes | no | partial | — |
| Read-only | no | no | no | no | partial | yes |

Per the Stage 1 decision, Accountant approval is **not required** for finalization in MVP — Owner/Admin approval suffices. The Accountant role retains technical finalization capability where a business explicitly enables it via policy.

Roles are assigned at the (User × Business) level, not globally. A user can be `Bookkeeper` on Business A and `Read-only` on Business B inside the same organization.

---

## Permission Surfaces

Every protected action belongs to one of these surfaces:

- **Business access** — can the user see this business at all?
- **Bank account access** — can the user see transactions for this account?
- **Document viewing** — can the user open evidence files?
- **Workflow execution** — can the user start, pause, or resume a workflow run?
- **Issue resolution** — can the user resolve review queue items?
- **Finalization** — can the user lock a period?
- **Report export** — can the user download exports, and which ones?
- **User management** — can the user invite, remove, or change roles?
- **External integration** — can the user connect or disconnect Gmail / Drive?

The role × surface matrix is the canonical permission table. Phase docs will translate this into concrete RBAC checks and database policies.

---

## Isolation Enforcement

Three layers, all required:

1. **Application layer.** Every query helper accepts `organization_id` and `business_id` and refuses to execute without them. There is no "no-tenant" code path.
2. **Database layer.** Row-level security policies (or equivalent) reject reads and writes without matching tenant claims.
3. **Audit layer.** Block 05 logs every access; cross-tenant access attempts produce alerts.

Tenant isolation is tested as a first-class invariant — every query helper must have a test that proves it cannot return rows from a different tenant.

---

## Authentication

- Email + password baseline.
- Multi-factor authentication uses **TOTP + WebAuthn/passkeys**. TOTP for broad compatibility (Google Authenticator, 1Password, etc.); passkeys for phishing-resistant strong auth on supported devices.
- MFA required for `Owner`, `Admin`, and `Accountant` roles. Strong recommendation for everyone else; mandatory in policy mode.
- Session lifetimes scoped tightly; re-authentication required for sensitive actions (user management, finalization, integration disconnect).
- SSO/OAuth supported for organizational logins where applicable.

---

## External Authorization (Gmail, Drive)

Gmail and Google Drive access is granted per business, not per user. The grant lives on the business, the OAuth token is stored encrypted (Block 05 owns the encryption), and the scope is recorded.

- Gmail scope is read-only and search-driven — Block 09 queries only what is relevant to a workflow run.
- Drive scope is read-only and folder-restricted — only explicitly connected folders are searchable.
- Disconnecting an integration revokes the token and writes an audit event. Existing matched documents remain attached; future searches stop.
- Token refresh and re-authorization may be performed by **any Owner or Admin** of the business, not only the original connecting user. The audit log records who performed the refresh.

---

## Role Change Propagation

When a user's role on a business changes mid-flight, the change applies to **new actions only**. Active workflow runs continue under the principal context they started with. The new role takes effect on the user's next workflow action or new run start. This avoids breaking in-progress runs and keeps audit trails coherent.

---

## Interfaces

### Inputs
- User credentials and MFA challenges (from the auth UI)
- OAuth callbacks from Gmail and Drive (per-business)

### Outputs
- A signed principal context (`user_id`, `organization_id`, `business_id`, `role`, `permissions`) attached to every workflow run, query, and audit event
- Encrypted external authorization tokens persisted via Block 05

---

## Operating Rules

- **Principle 4 (Security by Design):** isolation is enforced at three layers; never just one.
- **Principle 1 (Workflow-First):** workflow runs always carry the principal context — no anonymous workflow execution.
- **Principle 5 (Simple Interface):** role assignment UI hides surface-level permission toggles unless the user has user-management rights and explicitly asks for granular control.

---

## Stage 1 Resolutions

All initially-open questions have been resolved (see `Docs/decisions_log.md`):

- **Accountant approval before finalization:** not required in MVP; Owner/Admin approval suffices.
- **Role set in MVP:** the six base roles only — no External Auditor or custom-role builder yet.
- **Role change propagation:** applies to new actions only; active runs continue under their original principal context (covered in the Role Change Propagation section above).
- **Gmail/Drive token refresh authority:** any Owner or Admin (covered in External Authorization above).
- **MFA factors:** TOTP + WebAuthn/passkeys (covered in Authentication above).

No open questions remain at the architecture level for this block. Phase docs will address concrete implementation: RLS policy SQL, RBAC table shape, OAuth flow specifics, and MFA enrolment UX.
