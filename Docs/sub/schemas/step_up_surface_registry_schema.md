# step_up_surface_registry_schema

**Category:** Schemas · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

The canonical registry of surfaces that require step-up MFA. One row per registered surface; tools consult the registry at request-validation time to decide whether to require a fresh-MFA step-up token.

Resolves cross-references from `step_up_validity_window_policy.md` (BOOK-195) §"Per-surface overrides" and `step_up_ui_spec.md` which both reference `step_up_surface_registry` as the source-of-truth for per-surface configuration.

---

## 1. What it is

A runtime-read-only registry table. Application code consults the registry on every step-up-decision path; migrations are the only INSERT path; all changes require a `Docs/decisions_log.md` amendment.

The registry decouples the surface-level step-up configuration from the application code: adding a new step-up-requiring surface no longer requires code changes — only a registry INSERT via migration.

---

## 2. Table DDL

```sql
CREATE TYPE step_up_surface_kind_enum AS ENUM (
  'FINALIZATION_GATE',
  'BUSINESS_CONFIG_MUTATION',
  'ACCESS_CONTROL_MUTATION',
  'EXTERNAL_INTEGRATION_AUTH',
  'PRE_STEP_UP_REAUTH'
);

CREATE TABLE step_up_surface_registry (
  surface                       text PRIMARY KEY,
  surface_kind                  step_up_surface_kind_enum NOT NULL,
  validity_window_seconds       integer NOT NULL,
  mandatory                     boolean NOT NULL,
  per_business_opt_in_default   boolean NOT NULL DEFAULT false,
  factor_allowlist              mfa_factor_kind_enum[] NOT NULL
                                    DEFAULT ARRAY['TOTP','PASSKEY','BACKUP_CODE']::mfa_factor_kind_enum[],
  audit_event_on_required       text NOT NULL DEFAULT 'STEP_UP_REQUIRED',
  description_md                text NOT NULL,
  decisions_log_ref             text NOT NULL,
  registered_at                 timestamptz NOT NULL DEFAULT now(),
  last_modified_at              timestamptz NOT NULL DEFAULT now(),
  retired_at                    timestamptz,                       -- added on retire; rows never physically deleted

  CHECK (validity_window_seconds BETWEEN 60 AND 3600),
  CHECK (cardinality(factor_allowlist) >= 1),
  CHECK (mandatory = true OR per_business_opt_in_default IS NOT NULL)
);

ALTER TABLE step_up_surface_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE step_up_surface_registry FORCE ROW LEVEL SECURITY;

-- Read-permitted for authenticated (every step-up-decision path consults it):
CREATE POLICY "step_up_surface_registry_select"
  ON step_up_surface_registry AS PERMISSIVE FOR SELECT TO authenticated
  USING (retired_at IS NULL);

-- Write-restricted: no authenticated INSERT/UPDATE/DELETE; migrations only.
CREATE POLICY "step_up_surface_registry_no_authenticated_write"
  ON step_up_surface_registry AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (false);
-- Same restrictive policies for UPDATE and DELETE.
```

The CHECK on `validity_window_seconds BETWEEN 60 AND 3600` means windows outside [1 min, 60 min] require relaxing the constraint via a migration + decisions-log amendment.

---

## 3. The `step_up_surface_kind_enum`

Five values; the kind drives UI grouping in the security dashboard and feeds operator triage:

| Kind | What surfaces fall here | Example |
|---|---|---|
| `FINALIZATION_GATE` | Period-finalization actions that produce immutable archive state | `FINALIZATION` |
| `BUSINESS_CONFIG_MUTATION` | Sensitive business-level configuration changes | `BUSINESS_SETTINGS_EDIT`, AI-config edits |
| `ACCESS_CONTROL_MUTATION` | Changes to who can do what on the business | `USER_INVITE`, role grants, forced session revocations |
| `EXTERNAL_INTEGRATION_AUTH` | OAuth-flow surfaces where the user is connecting an external account | `EXTERNAL_INTEGRATION` |
| `PRE_STEP_UP_REAUTH` | System-internal "meta-step-up" needed BEFORE the user can change their MFA factor or password — distinct because the step-up that authorises the change can't use the about-to-be-changed factor | `_PRE_STEP_UP_REAUTH` (underscore prefix marks system-internal pseudo-surfaces) |

The kind is fixed per-row at registration and changes only via a major-review decisions-log amendment (a kind change implies the security model for that surface fundamentally changed).

---

## 4. Initial MVP seed

5 rows reproducing the per-surface table from BOOK-195 `step_up_validity_window_policy.md`:

| surface | surface_kind | validity_window_seconds | mandatory | per_business_opt_in_default | factor_allowlist | description |
|---|---|---|---|---|---|---|
| `FINALIZATION` | `FINALIZATION_GATE` | `300` | `true` | n/a (always mandatory) | TOTP, PASSKEY, BACKUP_CODE | The user has just decided to finalize a period — must be present and authenticated with fresh MFA. |
| `BUSINESS_SETTINGS_EDIT` | `BUSINESS_CONFIG_MUTATION` | `300` | `false` | `false` | TOTP, PASSKEY, BACKUP_CODE | Sensitive configuration; same window as finalization. Per-business opt-in. |
| `USER_INVITE` | `ACCESS_CONTROL_MUTATION` | `300` | `false` | `false` | TOTP, PASSKEY, BACKUP_CODE | Granting access to a new principal. Per-business opt-in. |
| `EXTERNAL_INTEGRATION` | `EXTERNAL_INTEGRATION_AUTH` | `600` | `false` | `false` | TOTP, PASSKEY | OAuth flows have provider redirects + consent screens; 10-min window. Backup codes excluded — some OAuth providers don't accept them on the redirect side. |
| `_PRE_STEP_UP_REAUTH` | `PRE_STEP_UP_REAUTH` | `1800` | `true` | n/a | TOTP, PASSKEY, BACKUP_CODE | The meta-step-up gating password change and MFA re-enrolment. 30-min window because the multi-step flow takes longer. |

The underscore-prefix on `_PRE_STEP_UP_REAUTH` marks it as a system-internal pseudo-surface (not in `permission_matrix` BOOK-179 user-facing enum).

---

## 5. Format conventions for rows

| Field | Convention |
|---|---|
| `surface` | Matches the canonical `permission_surface_enum` value from `permission_matrix.md` (BOOK-179) when the surface is user-facing. Underscore-prefix for system-internal pseudo-surfaces. Snake_case is permitted in legacy entries but new entries should use UPPER_SNAKE_CASE matching the permission-surface convention. |
| `validity_window_seconds` | Integer seconds, [60, 3600]. Surfaces wanting tighter than 60s require explicit relaxation + decisions-log amendment. |
| `mandatory` | `true` = the surface always requires step-up regardless of business opt-in. `false` = per-business opt-in via `business_settings.step_up_opt_in_surfaces`. |
| `per_business_opt_in_default` | The default for `business_settings.step_up_opt_in_surfaces` entries when a new business onboards. Ignored when `mandatory = true`. |
| `factor_allowlist` | Default = all 3 factors. OAuth-flow surfaces may exclude backup codes per the §4 rationale; other exclusions require explicit per-row justification in the decisions-log entry. |
| `audit_event_on_required` | The audit event name emitted when this surface's step-up is requested. Default `STEP_UP_REQUIRED` per BOOK-195 §"Audit events". Per-surface override permitted but discouraged. |
| `description_md` | Markdown shown in the operator admin dashboard + audit explorer. Explains why this surface requires step-up. Must be present and ≥ 20 chars. |
| `decisions_log_ref` | Date or ID of the `Docs/decisions_log.md` entry that introduced or last-modified this row. Required field. |

---

## 6. How new surfaces are added

5-step procedure. Skipping any step is a security-policy violation.

1. **Identify the surface** — confirm it's in `permission_matrix.md` (BOOK-179) `permission_surface_enum` if user-facing, OR pick an underscore-prefix name if system-internal. Confirm it's not already in the registry.
2. **Decisions-log amendment** — open a `Docs/decisions_log.md` amendment with the proposed row's full field set + rationale + intended consumer block + cross-references to the consuming RPC / endpoint.
3. **Owner sign-off** — the Owner role is the sole accountable principal for security-policy changes per `permission_matrix.md` (BOOK-179) period:unlock asymmetry rule. Same authority binds here. Sign-off recorded in the decisions-log entry.
4. **Forward-only migration** — write a migration that `INSERT ... ON CONFLICT (surface) DO NOTHING`s the row. Migration is forward-only per the project's migration convention (per project-meta drawer); fix-ups are NEW migrations.
5. **Update this sub-doc** — add the row to §4 + append an entry to §10 change-log.

---

## 7. How surfaces are modified

Change-semantics by field:

| Field changed | Required review level | Audit event |
|---|---|---|
| `validity_window_seconds` (lowering) | Standard PR review + decisions-log entry | `STEP_UP_SURFACE_MODIFIED` (MEDIUM) |
| `validity_window_seconds` (raising) | Explicit security review + decisions-log amendment | `STEP_UP_SURFACE_MODIFIED` (MEDIUM) — payload notes "raise" |
| `mandatory: true → false` | Major security review + Owner sign-off | `STEP_UP_SURFACE_MODIFIED` (HIGH) — removes a security guard |
| `mandatory: false → true` | Decisions-log amendment + coordinated deploy (existing in-flight requests will start requiring step-up) | `STEP_UP_SURFACE_MODIFIED` (HIGH) |
| `factor_allowlist` (removing a factor) | Verification that recovery path still works + decisions-log amendment | `STEP_UP_SURFACE_MODIFIED` (MEDIUM) |
| `factor_allowlist` (adding a factor) | Decisions-log entry | `STEP_UP_SURFACE_MODIFIED` (LOW) |
| `description_md` | Standard PR review; no decisions-log entry needed for prose-only changes | (no audit emit for prose-only changes) |
| `surface_kind` | Major review + decisions-log amendment (kind change implies fundamental security-model change) | `STEP_UP_SURFACE_MODIFIED` (HIGH) |

The `last_modified_at` column is automatically updated by a trigger on UPDATE.

---

## 8. How surfaces are removed

Extremely rare in MVP. The removal is treated as a security-policy change:

1. Decisions-log amendment explaining why the surface no longer needs step-up (e.g., the underlying surface was removed from `permission_matrix`).
2. Owner sign-off recorded in the amendment.
3. Forward-only migration that does NOT physically delete the row but sets `retired_at = now()`. The row stays in the table for audit traceability.
4. Application code stops consulting retired rows via the existing `retired_at IS NULL` predicate in the SELECT policy (§2).
5. Append an entry to §10 change-log marking the row retired.

There is no "undelete" — re-introducing a previously-retired surface requires inserting a fresh row under §6.

---

## 9. Runtime consultation pattern

The `auth.can_perform` helper (BOOK-183, subject to pre-audit-C1 reconciliation drift) and the step-up enforcement points consult the registry:

```sql
SELECT validity_window_seconds, mandatory, factor_allowlist, audit_event_on_required
FROM step_up_surface_registry
WHERE surface = :requested_surface
  AND retired_at IS NULL;
```

Decision flow:

```
IF no row → step-up NOT required (surface not registered)
ELSE IF row.mandatory = true → step-up REQUIRED
ELSE → consult business_settings.step_up_opt_in_surfaces[:surface]
       IF true → step-up REQUIRED
       ELSE → step-up NOT required
END
```

The SELECT is per-step-up-decision path; with the PK on `surface`, it's an O(1) index lookup (sub-millisecond at typical cardinality).

---

## 10. Per-business opt-in mechanism

For non-mandatory surfaces, businesses can opt in via the Settings UI (post-MVP). The `business_settings.step_up_opt_in_surfaces` JSONB column carries per-surface booleans:

```jsonc
{
  "BUSINESS_SETTINGS_EDIT": true,
  "USER_INVITE": false,
  "EXTERNAL_INTEGRATION": true
}
```

Default values come from the registry's `per_business_opt_in_default` column at business-creation time. Changing per-business opt-in:

- Requires Owner role via `BUSINESS_SETTINGS_EDIT` surface (which itself may require step-up — recursive but legitimate).
- Emits `BUSINESS_STEP_UP_OPT_IN_CHANGED` (MEDIUM) with payload `{ business_id, surface, previous_value, new_value, changed_by_user_id }`.
- Changes take effect on the next request (no caching).

---

## 11. Migration safety rules

Migrations that INSERT into this registry MUST:

1. Be forward-only (per project-meta drawer migration convention).
2. Be idempotent via `ON CONFLICT (surface) DO NOTHING` or explicit existence check.
3. Coordinate with deploy when adding a `mandatory=true` row — pre-existing in-flight requests at deploy time will start failing with `STEP_UP_REQUIRED` if they don't carry a step-up token.

The coordinated-deploy requirement for mandatory-true migrations is the highest-risk path. Mitigation:

- Stage the deploy by first inserting the row with `mandatory=false` for a soft-launch window (24-48 hours), letting clients adopt the step-up flow.
- Then update to `mandatory=true` via a second migration once telemetry confirms zero clients are calling without a step-up token.

---

## 12. RLS

Read-permitted for `authenticated` role (every step-up-decision path consults it). Write-restricted to migration role + service-role key only. No user-facing UI mutates the registry.

The restrictive INSERT/UPDATE/DELETE policies for `authenticated` are defined alongside the SELECT policy in §2. The migration role uses the service-role key to bypass these restrictions during migration execution.

---

## 13. Audit events

Registry-change events emitted by the migration tooling (not by application code — application code only reads the registry):

| Event | Severity | Trigger |
|---|---|---|
| `STEP_UP_SURFACE_REGISTERED` | HIGH (for mandatory) / MEDIUM (for opt-in) | New row INSERTed via migration |
| `STEP_UP_SURFACE_MODIFIED` | Per the §7 matrix | Existing row UPDATEd |
| `STEP_UP_SURFACE_RETIRED` | HIGH | Existing row's `retired_at` set |

Application-side step-up events (`STEP_UP_REQUIRED`, `STEP_UP_PASSED`, `STEP_UP_FAILED`, `STEP_UP_TOKEN_CONSUMED`, `STEP_UP_TOKEN_EXPIRED`, `STEP_UP_TOKEN_REVOKED`) are owned by `step_up_validity_window_policy.md` (BOOK-195) §"Audit events" and are NOT this registry's concern.

---

## 14. Change-log

Append-only log of registry changes. Each entry includes the change date, actor (Owner email), affected surface, change kind, and the migration file. Human-readable audit trail; the audit-events table is the systemic counterpart.

| Date | Actor | Surface | Change kind | Migration file | Decisions-log ref |
|---|---|---|---|---|---|
| (MVP seed) | (initial deploy) | `FINALIZATION` | REGISTERED | `YYYYMMDD_b02_p06_step_up_surface_registry_seed.sql` | initial MVP |
| (MVP seed) | (initial deploy) | `BUSINESS_SETTINGS_EDIT` | REGISTERED | (same) | initial MVP |
| (MVP seed) | (initial deploy) | `USER_INVITE` | REGISTERED | (same) | initial MVP |
| (MVP seed) | (initial deploy) | `EXTERNAL_INTEGRATION` | REGISTERED | (same) | initial MVP |
| (MVP seed) | (initial deploy) | `_PRE_STEP_UP_REAUTH` | REGISTERED | (same) | initial MVP |

New entries append at the bottom. Format: `YYYY-MM-DD | <owner_email> | <surface> | REGISTERED/MODIFIED/RETIRED | <migration_filename> | <decisions_log_anchor>`.

---

## 15. Stage-2+ extensions (deferred)

- **Per-business custom validity windows** — currently rejected by BOOK-195's "per-business overrides extending these windows beyond defaults are not supported in MVP" rule. Stage 2+ may add a `business_step_up_window_overrides` table keyed `(business_id, surface)` if customer demand justifies it.
- **Surface-grouping** — Stage 2+ may allow one step-up token to authorise multiple related surfaces within a single user-session-action. Currently each surface requires its own per BOOK-195 §"Single-use semantics."
- **Conditional mandatory** — e.g., FINALIZATION mandatory unless the previous step-up was within the last 5 min on the same business by the same user. Currently always-required without conditional bypass.
- **Webhook-driven registry sync** — for multi-region deployments where a registry change at one region must propagate to all others. MVP runs single-region per project-meta drawer's EU eu-west-1 commitment, so this is post-multi-region work.

---

## 16. Cross-references

- `step_up_validity_window_policy.md` (BOOK-195) — duration policy that this registry implements per-surface; primary consumer
- `step_up_ui_spec.md` — UX consumer; reads `factor_allowlist` to decide which challenge options to display
- `tool_step_up_request.md` — RPC entry point for step-up challenge issuance
- `permission_matrix.md` (BOOK-179) — `permission_surface_enum` source for user-facing surface names
- `tool_can_perform_helper.md` (BOOK-183, pre-audit-C1 shape drift) — runtime consultation site; the SELECT in §9 lives inside this helper's evaluation path
- `principal_context_schema.md` (BOOK-181) — `business_id` source for per-business opt-in lookup
- `mfa_required_role_rechallenge_policy.md` (BOOK-177, STANDARD/HIGH tier-name drift) — role-change-triggered re-challenge consumer of this registry
- `mfa_backup_codes_policy.md` (BOOK-175) — backup codes as a `factor_allowlist` member
- `passkey_relying_party_integration.md` (BOOK-173) — passkeys as a `factor_allowlist` member
- `totp_secret_storage_integration.md` (BOOK-171) — TOTP as a `factor_allowlist` member
- `dedup_pattern_ownership_map.md` (BOOK-198) — interaction with `audit_event_idempotency` pattern on registry-change emits
- `audit_event_taxonomy.md` — `STEP_UP_SURFACE_*` events (registry-side) and `STEP_UP_*` events (application-side per BOOK-195)
- `decisions_log.md` — source of truth for every registry row's `decisions_log_ref`
- Block 02 Phase 04 — creates the underlying table at migration time
- Block 02 Phase 06 — owning phase for step-up authentication
- Block 05 Phase 04 — Vault setup (factor storage context referenced by `factor_allowlist`)
