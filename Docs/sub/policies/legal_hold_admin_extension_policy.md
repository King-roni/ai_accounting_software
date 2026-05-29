# Legal Hold Admin Extension Policy

**Category:** Policies · **Owning block:** 04 — Data Architecture · **Co-owner:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

The MVP rule that **legal hold management is Owner-only** and the Stage-2 deferred consideration of granting the Admin role per-business legal-hold permission. Per the Phase 11 phase doc: "whether and how the Admin role could be granted legal-hold management permission as a per-business override; post-MVP consideration. Owner-only is the canonical MVP rule."

This policy pins the MVP rule unambiguously, captures the Stage-2 design space, and defines the change-management process for any future relaxation.

---

## 1. MVP canonical rule: Owner-only

**The `LEGAL_HOLD/SET` and `LEGAL_HOLD/LIFT` permission_matrix surfaces are granted ONLY to the Owner role.** This is the canonical MVP rule.

Per `permission_matrix.md` (amended this cycle):

| Surface | Owner | Admin | Bookkeeper | Accountant | Reviewer | Read-only |
|---|---|---|---|---|---|---|
| `LEGAL_HOLD/SET` | ✓ + step-up | ✗ | ✗ | ✗ | ✗ | ✗ |
| `LEGAL_HOLD/LIFT` | ✓ + step-up | ✗ | ✗ | ✗ | ✗ | ✗ |

No per-business grant + no per-user grant + no per-hold grant. The rule is binary at the role level.

`auth.canPerform(actor, 'LEGAL_HOLD/SET', business_id)` returns `ALLOW` if and only if `auth.role_on_business(actor, business_id) = 'Owner'` AND a valid step-up token is presented.

---

## 2. Rationale for Owner-only in MVP

Three concurrent reasons:

1. **Legal accountability is concentrated.** A legal hold is a regulator-, court-, or compliance-driven action. The accountable principal in Cyprus business law is the business owner / sole shareholder / managing director — modeled in this platform as the Owner role. Distributing the authority below the accountable principal creates an audit-trail gap (who actually owned the decision?).
2. **Mistake recovery is expensive.** A wrongly-filed hold extends Object Lock retention by up to `max_legal_hold_window` years (per `legal_hold_maximum_window_policy.md`). COMPLIANCE-mode Object Lock cannot be shortened. Restricting the surface to the most-accountable role reduces the population of users who can trigger an irreversible-at-platform-layer cost increase.
3. **Step-up frequency aligns.** Owners file/lift holds rarely; the step-up MFA recency tax is low for them. Admins perform high-frequency operational actions where step-up would be disruptive if extended to hold management.

---

## 3. Stage-2 design space — Admin per-business override

For Stage-2 a per-business grant model is considered: businesses with multiple equal-power principals (e.g., partnership-structured Cyprus companies with multiple shareholders) could elect to extend `LEGAL_HOLD/SET` to a designated Admin user.

Proposed mechanism (NOT in MVP; sketched for Stage-6 reconciliation):

```sql
CREATE TABLE archive.legal_hold_admin_grant (
  business_id            uuid NOT NULL,
  admin_user_id          uuid NOT NULL REFERENCES users(id),
  granted_by_owner_id    uuid NOT NULL REFERENCES users(id),
  granted_at             timestamptz NOT NULL DEFAULT now(),
  revoked_at             timestamptz NULL,
  revoked_by_owner_id    uuid NULL REFERENCES users(id),

  PRIMARY KEY (business_id, admin_user_id)
);
```

Per-business + per-admin grant. Granted by an Owner, revocable by any Owner. The grant is consulted by `auth.canPerform` only for `LEGAL_HOLD/*` surfaces:

```sql
-- Stage-2 canPerform logic (sketch):
auth.canPerform(actor, 'LEGAL_HOLD/SET', business_id) → ALLOW IF:
  (role = 'Owner')
  OR
  (role = 'Admin'
   AND EXISTS (SELECT 1 FROM archive.legal_hold_admin_grant
               WHERE business_id = $1 AND admin_user_id = actor
                 AND revoked_at IS NULL))
  AND step_up_valid;
```

Constraints baked into the Stage-2 design:

- **Step-up still required** for granted Admins. Non-negotiable.
- **No transitive grants** — a granted Admin cannot grant to another user.
- **Owner-revocable** — any Owner on the business can revoke at any time without notice.
- **Audit-visible** — `LEGAL_HOLD_ADMIN_GRANT_SET` + `LEGAL_HOLD_ADMIN_GRANT_REVOKED` at HIGH severity (Stage-2 future events; NOT added to taxonomy this cycle).
- **Grant scope is per-business** — does not extend to other businesses where the same user holds Admin.

---

## 4. Change-management process for any future relaxation

Moving from MVP Owner-only to the Stage-2 grantable model requires:

1. A decisions-log amendment per the convention established by 2026-05-08 (`ISSUE_RESOLVE`) and 2026-05-09 (`REPORT_EXPORT`) amendments.
2. A `permission_matrix.md` update (per its "Adding a surface or changing a default grant requires a Docs/decisions_log.md amendment" rule).
3. A migration shipping `legal_hold_admin_grant` + the `auth.canPerform` logic update.
4. Audit-event-taxonomy additions for the two grant events.
5. Pilot rollout to opt-in businesses before general availability.

The MVP commits to none of these — they are explicit Stage-2 work.

---

## 5. Owner removal interaction

Per `legal_hold_lifecycle_policy.md` §5.1: if the filing Owner is removed from the business while a hold is active, the hold remains active and is liftable by any other current Owner. If NO Owner exists, the recovery path is platform-admin co-approval via `admin_legal_hold_lift_runbook.md` (Stage-6 doc-write candidate).

In the Stage-2 grantable model, a granted Admin would NOT be able to lift a hold on a business with no Owner — the grant requires Owner presence to be auditable. The recovery path remains platform-admin co-approval.

---

## 6. Cyprus business-law alignment

Cyprus Companies Law (Cap. 113) treats the business owner / sole shareholder / managing director as the accountable principal for tax-record preservation duties under Income Tax Law (Cap. 297) and VAT Law (N.95(I)/2000). The MVP role model reflects this directly: Owner is the principal of record. Stage-2's grantable model preserves the audit trail (every grant is recorded with its granting Owner) without abrogating the principal-of-record relationship.

---

## 7. Audit events

MVP emits no events specific to admin extension — the surface is not granted at all. Stage-2 proposed events (NOT in MVP):

| Event | Severity | When |
|---|---|---|
| `LEGAL_HOLD_ADMIN_GRANT_SET` | HIGH | Owner grants the surface to an Admin user |
| `LEGAL_HOLD_ADMIN_GRANT_REVOKED` | HIGH | Owner revokes the grant |

---

## 8. Cross-references

- `legal_hold_lifecycle_policy.md` — Owner-removal interaction §5.1
- `permission_matrix.md` — `LEGAL_HOLD/SET` + `LEGAL_HOLD/LIFT` surfaces (Owner-only in MVP)
- `legal_hold_ui_spec.md` — UI consumers; Admin sees panel as read-only history
- `legal_hold_maximum_window_policy.md` — platform-admin-only window override (different surface, same admin-only gating principle)
- `admin_retention_override_runbook.md` — platform-admin escalation pattern (distinct from in-business Admin grant)
- `admin_legal_hold_lift_runbook.md` (Stage-6 doc-write candidate) — last-resort Owner-removed lift path
- `audit_event_taxonomy.md` — `LEGAL_HOLD_*` event family
- `data_layer_conventions_policy.md` — permission_matrix update process
- Block 02 Phase 04 — Owner role definition + `permission_matrix` host
- Block 04 Phase 11 — owning phase
- Cyprus Companies Law Cap. 113 — accountable-principal alignment
