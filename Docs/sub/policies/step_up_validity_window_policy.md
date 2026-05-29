# step_up_validity_window_policy

**Category:** Policies · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 1 cross-block policy)

The window during which a fresh MFA challenge ("step-up") is considered valid. Per `permission_matrix`: a subset of surfaces require step-up (FINALIZATION is the canonical example). The challenge must be fresh — a step-up taken yesterday doesn't authorise an action today.

This policy pins the default window, per-surface overrides, re-challenge triggers, and the token lifecycle.

---

## Default window

**5 minutes** from successful step-up challenge.

Rationale: long enough for the user to complete their workflow action without re-challenging; short enough that a stolen session can't be reused for a high-sensitivity action hours later.

## Per-surface overrides

| Surface | Window | Rationale |
| --- | --- | --- |
| `FINALIZATION` | 5 min (default) | The user has just decided to finalize — they should be present |
| `BUSINESS_SETTINGS_EDIT` (per-business opt-in) | 5 min | Sensitive config; same as finalization |
| `USER_INVITE` (per-business opt-in) | 5 min | Granting access to new principal |
| `EXTERNAL_INTEGRATION` (per-business opt-in) | 10 min | OAuth flows take longer (provider redirect, consent screen) |
| Pre-step-up reauth flows (changing password, MFA re-enroll) | 30 min | These ARE the step-up; longer window to complete |

Overrides are per `step_up_surface_registry` (Block 02 Phase 04, sub-doc Layer 2). Per-business overrides extending these windows beyond defaults are not supported in MVP.

## Token lifecycle

The `step_up_tokens` table DDL is defined in `step_up_token_schema.md`. This policy governs the validity window for step-up MFA tokens (15 minutes from issuance).

## Issuance

A successful MFA challenge issues a step-up token. The token is bound to:

- The user's session (one user per token)
- The business_id (business-scoped — Owner-of-A token cannot finalize business B)
- The factor used (audit trail records which factor)

Per Block 02 Phase 03's MFA flow: the challenge endpoint returns the token to the client; the client includes it in the subsequent action call.

## Consumption

Single-use. When an action accepts the token:

```sql
UPDATE step_up_tokens
   SET consumed_at = now(),
       consumed_for_surface = $surface,
       consumed_for_action_id = $action_id
 WHERE id = $token_id
   AND user_id = $user_id
   AND business_id = $business_id
   AND consumed_at IS NULL
   AND revoked_at IS NULL
   AND expires_at > now();
-- Validate exactly one row updated
```

A token can only be consumed once. A second action call with the same token fails with `STEP_UP_TOKEN_ALREADY_CONSUMED`.

## Re-challenge triggers

A new step-up challenge is required when:

1. **Token expired** — `expires_at < now()`
2. **Token consumed** — single-use semantics
3. **Token revoked** — explicit revocation (e.g., logout)
4. **Surface change** — a token consumed for `FINALIZATION` cannot be re-used for a different `FINALIZATION` action (action_id binding)
5. **MFA factor change** — if the user's MFA factor was rotated since the token was issued, the token is invalidated

## Re-challenge UX

Per `step_up_ui_spec`: when the gated action receives an expired/missing token, the UI surfaces an inline MFA challenge:

```
"Verify your identity to continue
 Enter the 6-digit code from your authenticator"

 [_ _ _ _ _ _]

 [Verify]   [Cancel]
```

The cancel returns to the prior state without committing the gated action. Successful verification issues a fresh token and resumes the action.

## Revocation

Tokens are revoked on:

- User logout (`LOGOUT_INITIATED` triggers UPDATE setting revoked_at)
- Session timeout (idle / absolute timeout per `session_lifetime_policy`)
- Operator-initiated session revoke (per `cross_tenant_alerting_runbook`)
- MFA factor re-enrollment (the old factor's tokens are revoked en masse)

## Audit events

| Event | When |
| --- | --- |
| `STEP_UP_REQUIRED` | An action requested but no valid token presented |
| `STEP_UP_PASSED` | Successful challenge + token issued |
| `STEP_UP_FAILED` | Failed challenge (wrong code, MFA disabled, etc.) |
| `STEP_UP_TOKEN_CONSUMED` | Token used for action |
| `STEP_UP_TOKEN_EXPIRED` | Token expired without being consumed |
| `STEP_UP_TOKEN_REVOKED` | Explicit revocation |

Per `audit_log_policies` aggregation: events are emitted per individual occurrence (not aggregated — security events benefit from per-event detail).

## Cross-business safety

Per `permission_matrix`: a step-up token issued for business A cannot authorize an action on business B. The business_id binding on the token is enforced at validation time.

An Owner of two businesses needs two separate step-up challenges to perform sensitive actions on both.

## Indexes

```sql
CREATE INDEX idx_step_up_tokens_user
  ON step_up_tokens(user_id, business_id, expires_at);

CREATE INDEX idx_step_up_tokens_consumed
  ON step_up_tokens(business_id, consumed_at)
  WHERE consumed_at IS NOT NULL;
```

## Retention

Per `retention_policies_schema` (Block 04): step_up_tokens are retained for 1 year after consumption / expiration for audit traceback. Beyond 1 year, eligible for deletion subject to legal hold.

## Cross-references

- `permission_matrix` — surfaces requiring step-up
- `step_up_surface_registry` (Block 02 Phase 04) — per-surface configuration
- `step_up_ui_spec` — challenge UX
- `audit_log_policies` — `STEP_UP_*` event family
- `mfa_totp_secrets` table (via `totp_secret_storage_integration`) — factor source
- `session_lifetime_policy` — session timeout interaction
- `cross_tenant_alerting_runbook` — operator-initiated revocation
- Block 02 Phase 03 — multi-factor authentication
- Block 02 Phase 06 — step-up authentication (architecture)
- Block 15 Phase 03 — approval modality & step-up auth (FINALIZATION consumer)
