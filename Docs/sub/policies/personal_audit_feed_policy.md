# personal_audit_feed_policy

**Category:** Policies · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

The data contract for the user-facing "Personal audit feed" surfaced in `settings_page_ui_spec.md` §Security and described in B02·P11 phase doc Deliverables → Personal audit feed. Defines: which audit-event types are visible to the acting user, how the feed scopes to a single user, how shared-event payloads are redacted to prevent leakage of other users' identities or cross-business detail, and the query against Block 05's read API.

Companion to `audit_event_taxonomy.md` (canonical event catalogue), `audit_event_payload_schemas.md` (payload shapes), and `audit_log_viewer_ui_spec.md` (admin-side cross-user audit viewer; out-of-scope for this surface).

---

## 1. Scope

The personal audit feed is **strictly the acting user's own activity record**. It is NOT an admin tool. The phase doc explicitly: "Last 30 days of audit events scoped to this user (their logins, MFA actions, settings changes, integrations they connected). Read-only."

The feed reads from Block 05's audit log via the `audit.read_personal_feed` read API. Block 02 does NOT store or mutate audit events — every event in this feed was emitted by some other path (auth, settings, integrations) and lives in the canonical `audit_events` table.

---

## 2. Event-type whitelist

The feed surfaces a **closed, hand-curated** allowlist of event types. Adding a new type requires updating this section AND the `audit.read_personal_feed` function's filter.

### 2.1 Authentication & session events

| Event | Severity | Surfaced under |
|---|---|---|
| `AUTH_LOGIN_SUCCEEDED` | LOW | Sign-ins |
| `AUTH_LOGIN_FAILED` | MEDIUM | Sign-ins |
| `AUTH_LOGOUT` | LOW | Sign-ins |
| `AUTH_SESSION_CREATED` | LOW | Sign-ins |
| `AUTH_SESSION_REVOKED` | LOW | Sign-ins |
| `AUTH_SESSION_DEVICE_MISMATCH` | MEDIUM | Security signals |
| `AUTH_SESSION_REFRESH_RATE_LIMITED` | LOW | Security signals |
| `AUTH_PASSWORD_CHANGED` | MEDIUM | Account changes |
| `AUTH_PASSWORD_RESET_REQUESTED` | LOW | Account changes |
| `AUTH_PASSWORD_RESET_COMPLETED` | MEDIUM | Account changes |

### 2.2 MFA events

| Event | Severity | Surfaced under |
|---|---|---|
| `MFA_ENROLLED` | MEDIUM | MFA |
| `MFA_DEVICE_REMOVED` | MEDIUM | MFA |
| `MFA_CHALLENGE_PASSED` | LOW | MFA |
| `MFA_CHALLENGE_FAILED` | MEDIUM | MFA |
| `MFA_BACKUP_CODES_REGENERATED` | MEDIUM | MFA |
| `MFA_BACKUP_CODE_USED` | LOW | MFA |
| `STEP_UP_CHALLENGE_PASSED` | LOW | MFA |
| `STEP_UP_CHALLENGE_FAILED` | MEDIUM | MFA |

### 2.3 Settings events

| Event | Severity | Surfaced under |
|---|---|---|
| `PROFILE_UPDATED` | LOW | Account changes |
| `EMAIL_CHANGE_REQUESTED` | MEDIUM | Account changes |
| `EMAIL_CHANGED` | HIGH | Account changes |
| `EMAIL_CHANGE_CANCELLED` | LOW | Account changes |

### 2.4 Integration events (this-user-as-actor only)

| Event | Severity | Surfaced under |
|---|---|---|
| `AUTH_OAUTH_CONNECTED` | LOW | Integrations |
| `AUTH_OAUTH_TOKEN_REFRESHED` | LOW | Integrations |
| `AUTH_OAUTH_TOKEN_REVOKED` | MEDIUM | Integrations |
| `AUTH_OAUTH_PERMISSION_DOWNGRADED` | MEDIUM | Integrations |
| `INTEGRATION_FOLDER_MAPPED` | LOW | Integrations |
| `INTEGRATION_DISCONNECTED` | LOW | Integrations |

### 2.5 Events NOT surfaced

The following deliberately do NOT appear in the personal audit feed even if the user was involved:

- All `LEDGER_*`, `INVOICE_*`, `MATCH_*`, `ARCHIVE_*`, `WORKFLOW_*` events — these belong to the business's audit-log viewer (admin-side), not the user's personal feed. The personal feed is about the user's account, not their business operations.
- All `TENANCY_*` events about OTHER users (e.g., `TENANCY_MEMBER_INVITED` where target is another user) — visible to Owners on the team page, not on the inviting user's personal feed.
- All `SYSTEM_*` and `JOB_*` events — operational; not user-relevant.
- All `SECURITY_ALERT_*` events — these go to the security alerting surface per `security_alert_routing_policy.md`, not the personal feed.
- `FIELD_DECRYPTED` aggregated audit events — high-volume operational signal; aggregated dashboard exists for admins; would flood the personal feed.

Rationale: the personal feed answers the question "what happened on MY account?" — not "what happened in my business" (which is the admin audit viewer's job).

---

## 3. Scope: actor-only vs target-also

A single audit event can involve multiple users via its payload. Three patterns:

| Pattern | Example event | Personal feed visibility |
|---|---|---|
| **Self-only** | `AUTH_LOGIN_SUCCEEDED` (actor = self) | Always visible to self. |
| **Actor + target where target IS self** | `TENANCY_MEMBER_INVITED` (actor = Owner; target_user = invited user) | Visible to the **target** user (they were invited). NOT visible on the actor's personal feed (it was business administration, not personal). The actor sees it on the team-management page instead. |
| **Multi-user** | `WORKFLOW_RUN_FINALIZED` (initiator + approver + reviewers) | NOT visible on any personal feed — runs are business-scoped events, not personal-account events. |

The personal feed query selects only:

```
WHERE actor_user_id = <self>   -- actions self performed
   OR target_user_id = <self>  -- actions performed on self
```

These two sets cover everything in §2.

---

## 4. Redaction rules for shared events

When an event involves the user as the **target** (Pattern 2 above), the event was emitted under the **actor's** principal context (e.g., an Owner-X invited Member-Y; the event's `actor_user_id = X`). The acting user (X) saw their version of the payload at emission. The target user (Y) sees the SAME row in their personal feed but the payload is **redacted at read time** to limit cross-user leakage.

Redaction rules:

| Field in raw payload | What the target user sees |
|---|---|
| `actor_user_id`, `actor_email`, `actor_role` | **Shown** — the target deserves to know who acted on them. Common-team-member identity is not a secret. |
| `target_user_id` | Shown as `<self>` (the target user IS the viewer). |
| Other PII fields not directly identifying the actor or target | Redacted to `[hidden]`. Examples: any `business_settings_diff` showing other businesses' state; any internal IP address; any session_id belonging to the actor. |
| `before_state` / `after_state` JSONB payloads | Only the keys whose VALUES reference the target user are surfaced; other keys redacted to `[hidden]`. |
| Cross-business detail | Hard-redacted (`[different-business]`) if the actor's business_id differs from the target's. Prevents cross-tenant leakage via the personal feed channel. |

The redaction happens server-side inside `audit.read_personal_feed`. The client never receives the unredacted version; redaction is not a CSS hide.

### 4.1 The cross-tenant safeguard

If the actor and target are in DIFFERENT businesses (which happens during platform-admin overrides or cross-org GDPR erasure), the personal-feed row carries:

- `actor_display = "Platform support"` (literal string, never an admin's real name)
- `business_context = "<target's business name>"` (always the target's; the actor's business is not exposed)
- Payload reduced to `{action_summary: "<one-line description>"}` only

This protects against a sophisticated user being able to enumerate platform-admin identities or other businesses' Owners via their own audit feed.

---

## 5. The query

```sql
CREATE OR REPLACE FUNCTION audit.read_personal_feed(
  p_from        timestamptz DEFAULT (now() - INTERVAL '30 days'),
  p_to          timestamptz DEFAULT now(),
  p_event_kinds text[]      DEFAULT NULL,           -- NULL = all whitelisted kinds
  p_limit       int         DEFAULT 50,
  p_offset      int         DEFAULT 0
)
RETURNS TABLE (
  event_id         uuid,
  event_kind       text,
  severity         audit_severity_enum,
  occurred_at      timestamptz,
  actor_display    text,
  business_context text,
  payload_redacted jsonb,
  source_surface   text                              -- 'sign_in' | 'mfa' | 'account_changes' | 'integrations' | 'security_signal'
)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = audit, public, extensions
AS $$
DECLARE
  v_user_id uuid := auth.current_user_id();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'PRINCIPAL_CONTEXT_MISSING' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    SELECT
      e.id                                                                                  AS event_id,
      e.event_kind                                                                          AS event_kind,
      e.severity                                                                            AS severity,
      e.occurred_at                                                                         AS occurred_at,
      audit.compute_actor_display(e, v_user_id)                                             AS actor_display,
      audit.compute_business_context(e, v_user_id)                                          AS business_context,
      audit.compute_payload_redacted(e, v_user_id)                                          AS payload_redacted,
      audit.event_kind_to_surface(e.event_kind)                                             AS source_surface
    FROM audit.audit_events e
    WHERE e.occurred_at BETWEEN p_from AND p_to
      AND e.event_kind = ANY (audit.personal_feed_whitelist())
      AND (p_event_kinds IS NULL OR e.event_kind = ANY (p_event_kinds))
      AND (e.actor_user_id = v_user_id OR e.target_user_id = v_user_id)
    ORDER BY e.occurred_at DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$;
```

`audit.personal_feed_whitelist()` is the IMMUTABLE function returning the event-kind array enumerated in §2. Adding a new event kind to the personal feed = single-function migration.

`audit.compute_payload_redacted` is the per-event redactor implementing §4. It's a CASE statement over event_kind that knows the per-kind redaction rules.

---

## 6. Window + pagination

- **Default window:** 30 days back from now. Phase-doc binding.
- **Maximum window:** 90 days (hard cap). Older events live in the canonical `audit_events` table forever but are not exposed via personal feed — the user can request historical access via `gdpr_data_subject_rights_policy.md` data-export flow.
- **Page size:** 50 rows per page. Configurable via `p_limit` (1-100; values outside this range are clamped). Per-page pagination via `p_offset`.
- **Sort:** descending by `occurred_at`. The most recent action is always first.

The 30-day default + 90-day cap matches the data-retention regime: short enough to keep the UI responsive on the index query, long enough to cover the audit-investigation horizon most users care about.

---

## 7. Per-event card structure

Each row renders as a card in `settings_page_ui_spec.md` §Security → "Review your account activity" surface. The UI consumes the function's output columns directly:

```
┌──────────────────────────────────────────────────────────────────────────┐
│  [Icon based on source_surface]                                          │
│                                                                          │
│  <event_kind translated to user-friendly string>                         │
│  <occurred_at relative + absolute>                                       │
│                                                                          │
│  <actor_display> in <business_context>                                   │
│  <one-line payload summary from payload_redacted>                        │
│                                                                          │
│  [View details]                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

The "user-friendly string" mapping is owned by `audit_event_kind_display_strings.md` (a small reference doc enumerating each event-kind → display label + i18n key). **Stage-6 candidate: confirm this reference doc exists or write it as part of the personal-feed deliverable.**

"View details" opens a side panel showing the redacted payload as formatted JSON. Helpful for users reviewing security signals (e.g., "what IP country did this AUTH_SESSION_DEVICE_MISMATCH come from?").

---

## 8. Per-business filter

Users with roles on multiple businesses see all their personal-feed events globally — the feed is not business-filtered. Rationale: a login event has no business_id (it's an authentication action, not a business action). Filtering would inappropriately hide login records when the user is switched to a different business context.

Optional per-business filtering CAN be applied at the UI layer for integration-events only (which DO have a business_id), but it's a UI quality-of-life feature, not a security boundary.

---

## 9. Audit footprint

Reading the personal feed does NOT itself emit an audit event. Personal-feed reads are extremely high-volume (every settings-page render) and auditing each would multiply audit-table write volume by a wasteful factor. The principle "the audit log shouldn't be auditing itself reading its own data" applies.

If a future requirement emerges to log "Owner X read their personal feed," that would land as a separate `PERSONAL_FEED_VIEWED` event at LOW severity. Not in MVP.

---

## 10. Cross-references

- `settings_page_ui_spec.md` §Security — UI consumer of `audit.read_personal_feed`
- `audit_event_taxonomy.md` — canonical event catalogue (whitelist source)
- `audit_event_payload_schemas.md` — payload shapes (input to redactor §4)
- `audit_log_viewer_ui_spec.md` — admin-side viewer; different surface, different scope
- `audit_log_policies.md` — PII-minimisation principles
- `principal_context_schema.md` §12 — `current_user_id` helper
- `gdpr_data_subject_rights_policy.md` — full-history access path (alternative to 90-day cap §6)
- `gdpr_right_to_erasure_policy.md` — anonymisation behaviour for past events
- `security_alert_routing_policy.md` — SECURITY_ALERT events deliberately out of scope (§2.5)
- `account_email_change_flow_policy.md` — source of EMAIL_CHANGE_* events surfaced (§2.3)
- `tool_session_refresh.md` — source of AUTH_SESSION_* events surfaced (§2.1)
- `mfa_enrollment_policy.md` — source of MFA_* events surfaced (§2.2)
- `gmail_oauth_integration.md` + `oauth_token_encryption_schema.md` — source of AUTH_OAUTH_* events (§2.4)
- Block 02 Phase 11 — account settings (owning phase)
- Block 05 Phase 02 — audit taxonomy (whitelist source)
- Block 05 Phase 03 — audit emission + read API (`audit.read_personal_feed` location)
- Stage 1 decision — personal-feed scope is account-only, not business-ops
