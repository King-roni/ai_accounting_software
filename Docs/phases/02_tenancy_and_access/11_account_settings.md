# Block 02 — Phase 11: Account Settings

## References

- Block doc: `Docs/blocks/02_tenancy_and_access.md` (entire block — this phase is the user-facing surface for it)
- Decisions log: `Docs/decisions_log.md` (TOTP + WebAuthn/passkeys; six base roles)

## Phase Goal

A single Account Settings area where the user manages their profile, password, MFA factors, sessions, and (where their role allows) business integrations. This phase wires up the UI surfaces that earlier phases produced engines for. Sensitive actions go through step-up (Phase 06).

## Dependencies

- Phase 02 (auth + email)
- Phase 03 (MFA factors)
- Phase 06 (step-up)
- Phase 07 (member list — for cross-link to org/business management)
- Phase 08 (integrations — for connect/disconnect)

## Deliverables

- **Profile section:**
  - Display name, optional avatar.
  - Email change flow (request → verification of new email → swap on confirmation; old email notified).
- **Password section:**
  - Change password (re-auth required).
  - "Last changed" timestamp.
- **MFA section:**
  - List of enrolled factors (TOTP, passkey/s).
  - Add new factor flows (TOTP, passkey).
  - Remove factor (step-up; refuse if doing so would drop below the user's required factor count).
  - Regenerate backup codes (step-up).
- **Sessions section:**
  - Active sessions list (device, IP region, last active).
  - Revoke a specific session.
  - "Sign out all other sessions" button (step-up).
- **Integrations section** (only for users with Owner/Admin on at least one business):
  - Per-business list of Gmail and Drive integration status.
  - Connect / refresh / disconnect actions, with step-up where required.
- **Personal audit feed:**
  - Last 30 days of audit events scoped to this user (their logins, MFA actions, settings changes, integrations they connected).
  - Read-only.
  - **Reads from Block 05's audit log via its read API; this phase does not store or mutate audit events.**
- **Audit events:** `PROFILE_UPDATED`, `EMAIL_CHANGE_REQUESTED`, `EMAIL_CHANGED`, `PASSWORD_CHANGED`, `SESSION_REVOKED`, `ALL_SESSIONS_REVOKED`.

## Definition of Done

- Profile fields editable; changes audit-logged.
- Email change round-trip works (request → verify → swap → notification).
- Password change requires re-auth and produces the audit event.
- MFA factor management covers add, remove, and backup-code regeneration with step-up where appropriate.
- Active sessions list is accurate; revoke works for individual sessions and "all others".
- Integration management actions reflect the right Owner/Admin gating.
- Personal audit feed shows the right events for the current user.
- The Settings page is **desktop-only in MVP**. The Stage 1 mobile-UX decision scopes mobile read-only to dashboards, drill-down, and queue browsing — settings is intentionally not in that mobile scope.

## Sub-doc Hooks (Stage 4)

- **Settings page UX sub-doc** — section layout, navigation, mobile read-only treatment.
- **Email change flow sub-doc** — exact verification timeline, rollback if user loses access mid-flow.
- **Sessions data sub-doc** — what the session list reads, how device fingerprinting is captured for display.
- **Personal audit feed sub-doc** — which event types are surfaced, redaction for shared events.
