# oauth_scope_assertion_policy

**Category:** Policies · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 09 — Document Intake & Extraction · **Stage:** 4 sub-doc (Layer 2)

The platform's **runtime scope assertion** rules — what to do when Google returns a scope set that does not exactly match the requested scope set, in either direction. Companion to `gmail_oauth_integration.md` §"Scope Enforcement" (which already handles the *degraded* direction) and `oauth_token_encryption_schema.md` (which stores the `scopes_granted` array).

This doc is the canonical reference for the **inflated-grant** case the OAuth integration sub-doc does not cover: Google's incremental-authorization behaviour can return *more* scopes than the request asked for. We treat that as a least-privilege concern, not as additional capability.

---

## 1. The two assertion directions

| Direction | Definition | Owning doc |
|---|---|---|
| **Degraded grant** | `scopes_granted ⊊ scopes_requested` — Google returned fewer than asked, typically because the user un-ticked a scope on the consent screen, or the user re-authorised an existing client with a reduced subset. | `gmail_oauth_integration.md` §"Scope Enforcement" — operates in degraded mode (attachment-only / Drive-only / fully-disabled). |
| **Inflated grant** | `scopes_granted ⊋ scopes_requested` — Google returned scopes the current request did not ask for. Almost always due to **incremental authorisation carryover**: scopes granted on a previous authorisation for the same `client_id` remain attached to subsequent grants. | This document. |
| Exact match | `scopes_granted = scopes_requested` — the happy path; no assertion required. | — |

Both directions must be checked at every token issuance event (initial authorisation, refresh-with-scope-rotation, re-authorisation). Drift between requested and granted is a tenancy-state signal that audit and review-queue surfaces consume.

---

## 2. Why inflated grants happen

Google's OAuth implementation merges scope grants across requests by `client_id` per the [Google Identity Platform documentation on incremental authorisation](https://developers.google.com/identity/protocols/oauth2/web-server#incrementalAuth). The behaviour is:

- User authorises scope set `A = {gmail.readonly}` at time T₁.
- User authorises scope set `B = {drive.readonly}` at time T₂.
- The next token issuance from the same `client_id` returns `scopes_granted = A ∪ B = {gmail.readonly, drive.readonly}` regardless of which scope set the current request asked for.

This is by design on Google's side and **cannot be disabled at the client end**. It can only be observed and handled at the application layer.

A second mechanism that can produce inflated grants: scope reuse across business contexts. If a user previously connected their Google account to the platform under a *different* business, the grant carries through. The platform's `oauth_tokens` row is per-`(business_id, provider, account_email)`, so this manifests as a fresh row with already-broad scopes.

---

## 3. Assertion at token issuance

The check runs in the **OAuth callback handler** before the new `oauth_tokens` row is written. It runs again on every **refresh** event because Google may return updated scope sets at refresh time.

```
1. Parse `scopes_granted` from the token response.
2. Compute drift_set = scopes_granted \ scopes_requested.   -- inflated scopes
3. Compute missing_set = scopes_requested \ scopes_granted. -- degraded scopes
4. If missing_set ≠ ∅: enter degraded path per gmail_oauth_integration.md.
5. If drift_set ≠ ∅: enter inflated path per §4 below.
6. If both are empty: normal path; persist scopes_granted = scopes_requested.
```

The `scopes_requested` value is **always the platform's canonical scope set** for the integration (currently `{gmail.readonly, drive.readonly}`) — never user-supplied or client-supplied. Comparing against a non-canonical baseline is a security anti-pattern (an adversary on a compromised client could shift the baseline to "match" an inflated grant).

---

## 4. Inflated-grant handling

The platform **accepts the grant but does not extend application capabilities**. Concretely:

| Field | Behaviour |
|---|---|
| `oauth_tokens.scopes_granted` | Stored as **what Google returned**, including the extras. This preserves forensic ground truth — we must be able to reconstruct what Google actually granted. |
| Application capability check | Performed against a **separate effective-scope set** that is the intersection of `scopes_granted ∩ platform_canonical_scopes`. Code MUST NOT trust `scopes_granted` directly as the capability-grant signal. |
| Effective-scope helper | `auth.effective_oauth_scopes(token_id uuid) → text[]` — returns the intersection. All intake tools MUST consult this helper, not raw `scopes_granted`. |
| Audit | `AUTH_OAUTH_GRANT_INFLATED` (MEDIUM) emitted exactly once per (business_id, token issuance event) when drift_set is non-empty. Payload carries `requested_scopes`, `granted_scopes`, `drift_scopes`. |
| Review queue | No automatic review-issue. Inflated grants are forensically interesting but not user-actionable from the platform side (the user would have to revoke at Google's account settings). |

The platform does **not** call Google's revocation endpoint to strip the extras. Google's API treats partial revocation by scope as poorly defined; the canonical recovery path is full revocation + re-authorisation, which is heavyweight and disruptive. Audit-and-retain is the chosen response.

---

## 5. Runtime per-call assertion

Every intake tool (Gmail finder, Drive finder, attachment fetcher, etc.) calls `auth.effective_oauth_scopes(token_id)` immediately before any provider API call. If the required scope for the call is **not** in the effective-scope set:

```
1. Tool emits AUTH_OAUTH_SCOPE_INSUFFICIENT (MEDIUM)
   with payload: {required_scope, effective_scopes, token_id, tool_name, business_id}.
2. Tool returns a typed error TOOL_ERROR_OAUTH_SCOPE_INSUFFICIENT.
3. The owning workflow run transitions to REVIEW_HOLD per
   gmail_oauth_integration.md §"Refresh Strategy" / Refresh failure path
   (same escalation pattern, different trigger).
4. A review-issue of type OAUTH_SCOPE_INSUFFICIENT is created
   so the business owner can re-authorise with the full canonical scope set.
```

The runtime check is **defence in depth** — it catches cases where the issuance-time check passed but the underlying grant has since been narrowed by the user at Google's account settings (which does not necessarily revoke the token; it only updates the scope set the next refresh will return).

---

## 6. Refresh-time re-assertion

On every refresh per `gmail_oauth_integration.md` §"Refresh Strategy" / Reactive path or Proactive 50-min job, the response's `scopes_granted` is re-checked against `scopes_requested`. The same §3 algorithm runs.

A scope **reduction** detected at refresh (compared to the previously-stored `scopes_granted`) emits `AUTH_OAUTH_PERMISSION_DOWNGRADED` per `gmail_oauth_integration.md` and degrades the integration mode accordingly.

A scope **inflation** newly detected at refresh emits `AUTH_OAUTH_GRANT_INFLATED` exactly once per inflation event — defined as a refresh response where `drift_set` was previously empty for this token and is now non-empty. Subsequent refreshes that return the same already-known drift_set do **not** re-emit; the audit is for state transitions, not steady-state.

---

## 7. Audit events introduced by this policy

| Event | Severity | Trigger | Payload |
|---|---|---|---|
| `AUTH_OAUTH_GRANT_INFLATED` | MEDIUM | Token issuance or refresh returns `scopes_granted ⊋ scopes_requested` for the first time. | `{business_id, user_id, provider, requested_scopes, granted_scopes, drift_scopes, issued_or_refreshed_at}` |
| `AUTH_OAUTH_SCOPE_INSUFFICIENT` | MEDIUM | Runtime per-call check finds required scope missing from effective-scope set. | `{business_id, token_id, tool_name, required_scope, effective_scopes, business_id}` |

These events are **NEW** and must be added to `audit_event_taxonomy.md` Appendix A (cross-block coordination flagged for B05·P02 implementation).

Existing events relevant to this policy (already in taxonomy):

- `AUTH_OAUTH_CONNECTED` — initial grant
- `AUTH_OAUTH_TOKEN_REFRESHED` — successful refresh
- `AUTH_OAUTH_PERMISSION_DOWNGRADED` — degraded grant detected
- `AUTH_OAUTH_TOKEN_REVOKED` — token revoked

---

## 8. Effective-scope helper

```sql
CREATE OR REPLACE FUNCTION auth.effective_oauth_scopes(p_token_id uuid)
RETURNS text[]
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT array(
    SELECT s
    FROM unnest(t.scopes_granted) s
    WHERE s = ANY(platform_canonical_scopes())
  )
  FROM oauth_tokens t
  WHERE t.id = p_token_id
    AND t.business_id = ANY (auth.business_ids_for_session())
    AND auth.has_surface(t.business_id, 'EXTERNAL_INTEGRATION')
$$;

CREATE OR REPLACE FUNCTION platform_canonical_scopes()
RETURNS text[]
LANGUAGE sql IMMUTABLE
AS $$
  SELECT ARRAY[
    'https://www.googleapis.com/auth/gmail.readonly',
    'https://www.googleapis.com/auth/drive.readonly'
  ]
$$;
```

The `platform_canonical_scopes()` function is the single source of truth for which scopes the platform considers operationally meaningful. Adding a new scope (e.g., `gmail.metadata` for a future low-PII intake mode) is a **schema migration** that updates this function — the canonical set is not configurable at runtime per business.

**Cross-block coordination flagged for B02·P08 migration:** add `auth.effective_oauth_scopes` and `platform_canonical_scopes` to the OAuth integration foundation migrations.

---

## 9. Edge cases

| Case | Behaviour |
|---|---|
| Google returns scope outside the integration's vocabulary (e.g., `calendar.readonly` that the platform never requested anywhere) | Stored in `scopes_granted` for forensic record. Excluded from effective-scope set. `AUTH_OAUTH_GRANT_INFLATED` emitted with `drift_set` containing the unknown scope. |
| User reduces grant at Google's account settings between platform sessions | Refresh returns reduced `scopes_granted`. `AUTH_OAUTH_PERMISSION_DOWNGRADED` emitted (existing taxonomy). Integration degrades per `gmail_oauth_integration.md`. |
| First-ever authorisation from a brand-new user, scopes exactly match request | Normal path. No drift events emitted. |
| Token issuance race: user opens two browser tabs and authorises with different scope sets in each | The second callback's `scopes_granted` becomes authoritative (most-recent-wins per `oauth_tokens (business_id, provider, account_email)` unique constraint). The first issuance's audit row remains for forensic record. |
| `platform_canonical_scopes()` changes (schema migration adds a new scope) | The next refresh after the migration assesses against the new canonical set. Previously-issued tokens may show as degraded against the new canonical (e.g., missing the newly-required scope). `AUTH_OAUTH_PERMISSION_DOWNGRADED` may be emitted at refresh for tokens that don't carry the new scope. This is correct: existing tokens need re-authorisation to acquire the new scope. |
| Token issuance returns `scopes_granted = []` (empty array) | Treated as degraded grant (everything is missing). Integration is fully disabled. `AUTH_OAUTH_PERMISSION_DOWNGRADED` emitted with `removed_scopes = scopes_requested`. |

---

## 10. Cross-references

- `gmail_oauth_integration.md` — degraded-grant handling and OAuth lifecycle (parent doc)
- `oauth_token_encryption_schema.md` — `scopes_granted` column source of truth
- `audit_event_taxonomy.md` — `AUTH_OAUTH_*` events (two NEW events introduced here for B05·P02)
- `audit_event_payload_schemas.md` — payload schemas for the two new events
- `permission_matrix.md` — `EXTERNAL_INTEGRATION` surface gating the helper
- `rls_helper_functions.md` — `auth.has_surface`, `auth.business_ids_for_session` (consumed)
- `principal_context_schema.md` — server-resolved business + role used by RLS
- Block 02 Phase 08 — OAuth integration foundation (consumer of `auth.effective_oauth_scopes` migration)
- Block 05 Phase 02 — audit taxonomy (consumer of two new events)
- Block 09 Phase 05 — Gmail finder (runtime per-call assertion consumer)
- Block 09 Phase 06 — Drive finder (runtime per-call assertion consumer)
- Stage 1 decision — least-privilege at application layer
- [Google Identity Platform — Incremental authorisation](https://developers.google.com/identity/protocols/oauth2/web-server#incrementalAuth) — provider-side rationale for inflated grants
