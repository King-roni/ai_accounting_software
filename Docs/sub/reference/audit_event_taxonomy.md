# Audit Event Taxonomy

**Category:** Reference data · **Owning block:** 05 — Security & Audit · **Co-owners:** all 15 phase-decomposed blocks · **Stage:** 4 sub-doc (Layer 1 taxonomy)

The single catalogue of every approved audit event in the system, organised by domain. Every audit-emitting tool, policy, runbook, and gate validates against this catalogue at lint time. Adding an event requires the canonical event-naming convention from `audit_log_policies` AND an addition to this catalogue (one PR can do both; the lint runs after merge).

Per-event payload schemas live in `Docs/sub/schemas/audit_event_payload_schemas.md` (Layer 2, Block 05). This taxonomy commits to the event names and one-line semantics; the payload shape is Layer 2.

---

## Naming + lint reference

Convention: `<DOMAIN>_<PAST_VERB>` per `audit_log_policies`.

Lint: regex `^[A-Z][A-Z0-9_]*_[A-Z][A-Z0-9_]*$` plus this catalogue membership check. Build fails if either check fails.

Hash chain: every event's `chain_hash` is computed from `prev_chain_hash || event_payload_canonical_json` per `data_layer_conventions_policy`. Three-level chain partitioning (global / org / business) per `audit_log_policies`.

---

## Domain catalogue

Events grouped by DOMAIN. The list below is canonical for MVP. Adding an event requires an amendment.

### TENANCY / LOGIN / MFA / PASSWORD / INVITATION / OAUTH / INTEGRATION (Block 02)

```
LOGIN_SUCCEEDED                       LOGIN_FAILED
SESSION_REFRESHED                     SESSION_REVOKED
MFA_CHALLENGE_PASSED                  MFA_CHALLENGE_FAILED
MFA_ENROLLED                          MFA_BACKUP_CODE_USED
PASSWORD_CHANGED                      PASSWORD_RESET_REQUESTED  PASSWORD_RESET_COMPLETED
INVITATION_CREATED                    INVITATION_ACCEPTED  INVITATION_REVOKED
INVITATION_EXPIRED
OAUTH_AUTHORIZED                      OAUTH_TOKEN_REFRESHED
OAUTH_STATE_CREATED                   OAUTH_STATE_CONSUMED  OAUTH_STATE_EXPIRED_UNUSED
INTEGRATION_REFRESH_FAILED            INTEGRATION_DISCONNECTED
TENANCY_ROLE_GRANTED                  TENANCY_ROLE_REVOKED  TENANCY_ROLE_CHANGED
TENANCY_OWNERSHIP_TRANSFERRED
TENANCY_USER_CREATED
TENANCY_ORG_CREATED                   TENANCY_ORG_DEACTIVATED
TENANCY_BUSINESS_CREATED              TENANCY_BUSINESS_DEACTIVATED  TENANCY_BUSINESS_ARCHIVED
TENANCY_BANK_ACCOUNT_ADDED            TENANCY_BANK_ACCOUNT_DEACTIVATED
TENANCY_MEMBER_REMOVED
TENANCY_MEMBER_SOFT_LIMIT_WARNED
ACCESS_DENIED                         STEP_UP_REQUIRED  STEP_UP_PASSED  STEP_UP_FAILED
STEP_UP_TOKEN_CONSUMED                STEP_UP_TOKEN_EXPIRED  STEP_UP_TOKEN_REVOKED
STEP_UP_TOKEN_ALREADY_CONSUMED        STEP_UP_TOKEN_ACTION_MISMATCH
STEP_UP_SIMULATION_REJECTED_IN_PRODUCTION_MODE
STEP_UP_SIMULATION_ROW_PURGED
MOBILE_WRITE_REJECTED
BUSINESS_WORKFLOW_CONFIG_TOGGLED
INTEGRATION_FOLDER_MAPPED
EMAIL_DISPATCHED                      EMAIL_DISPATCH_FAILED
EMAIL_BOUNCED                         EMAIL_COMPLAINED  EMAIL_ADDRESS_SUPPRESSED
```

### USER (Block 02 — `users` table lifecycle)

```
USER_CREATED                          USER_UPDATED
USER_DEACTIVATED
```

`USER_CREATED` (LOW) — emitted when a new `users` row is inserted at signup. Payload: `user_id`, `email`.
`USER_UPDATED` (LOW) — emitted when `display_name`, `avatar_url`, or `email_verified` changes. Payload: `user_id`, changed fields with old and new values.
`USER_DEACTIVATED` (MEDIUM) — emitted when `is_active` is set to `false`. Payload: `user_id`, `deactivated_by_user_id`. MEDIUM because deactivation prevents authentication.

### BUSINESS (Block 02 — `business_entities` table lifecycle)

```
BUSINESS_CREATED                      BUSINESS_UPDATED
BUSINESS_DEACTIVATED                  BUSINESS_VAT_VALIDATED
BUSINESS_SETTINGS_UPDATED
```

`BUSINESS_CREATED` (LOW) — emitted when a new `business_entities` row is inserted. Payload: `business_id`, `organization_id`, `created_by_user_id`.
`BUSINESS_UPDATED` (LOW) — emitted when any business configuration field changes. Payload: `business_id`, changed fields with old and new values.
`BUSINESS_DEACTIVATED` (HIGH) — emitted when `is_active` is set to `false` by the platform admin. HIGH because deactivation starts the 7-year retention clock and halts new workflow runs. Only platform admin may emit this event.
`BUSINESS_VAT_VALIDATED` (LOW) — emitted on each business VAT-number validation attempt (e.g., via the settings VAT UI). LOW because validation attempts are routine. Payload: `business_id`, `vat_number`, `validation_result`, `validated_by_user_id`. See `settings_vat_ui_spec.md`.
`BUSINESS_SETTINGS_UPDATED` (LOW) — emitted when any business-level settings field changes via the settings surfaces. LOW because routine configuration changes are expected. Payload: `business_id`, `changed_fields` (array), `updated_by_user_id`. See `settings_vat_ui_spec.md`.

### SESSION (Block 02 — `user_sessions` table lifecycle)

```
SESSION_CREATED                       SESSION_REVOKED
SESSION_TERMINATED                    SESSION_EVICTED_MAX_CONCURRENCY
```

`SESSION_CREATED` (LOW) — emitted when a new `user_sessions` row is created on login. Payload: `session_id`, `user_id`, `business_id`, `ip_address`, `expires_at`.
`SESSION_REVOKED` (MEDIUM) — emitted when `is_revoked` is set to `true`. MEDIUM regardless of whether the revocation was self-initiated (logout) or admin-initiated (forced logout). Payload: `session_id`, `user_id`, `revoked_reason`, `revoked_by_user_id`.
`SESSION_TERMINATED` (LOW/MEDIUM) — emitted on explicit logout, idle timeout expiry, absolute timeout expiry, concurrency eviction, or admin-forced revocation. LOW for `USER_LOGOUT`, `IDLE_TIMEOUT`, `ABSOLUTE_TIMEOUT`; MEDIUM for `MAX_CONCURRENCY_EVICTION` and `ADMIN_FORCED_REVOCATION`. Payload: `session_id`, `user_id`, `business_id`, `reason`, `terminated_by_user_id` (nullable), `session_age_seconds`. See `session_lifetime_policy`.
`SESSION_EVICTED_MAX_CONCURRENCY` (MEDIUM) — emitted when an existing session is evicted to make room for a 6th concurrent session. MEDIUM because unexpected eviction on another device is a security-relevant signal. Payload: `evicted_session_id`, `user_id`, `new_session_id`, `eviction_reason`, `session_count_before`, `last_active_at_evicted`. See `session_lifetime_policy`.

### MFA_DEVICE (Block 02 — `mfa_devices` table lifecycle)

```
MFA_DEVICE_REGISTERED                 MFA_DEVICE_REMOVED
MFA_DEVICE_ENROLLED                   MFA_ENROLLMENT_FORCED
MFA_BACKUP_CODE_USED                  MFA_RECOVERY_CODE_USED
```

`MFA_DEVICE_REGISTERED` (MEDIUM) — emitted when `is_verified` transitions to `true` on first successful TOTP code confirmation. Payload: `device_id`, `user_id`, `device_name`.
`MFA_DEVICE_REMOVED` (HIGH) — emitted when `is_active` is set to `false` on a TOTP device. HIGH because device removal reduces authentication strength. Payload: `device_id`, `user_id`, `removed_by_user_id`.
`MFA_DEVICE_ENROLLED` (MEDIUM) — emitted when a new `mfa_devices` row becomes `is_active = true` after a first successful TOTP code confirmation or FIDO2 assertion. This is the enrollment-completion signal used by `mfa_enrollment_policy.md`. Payload: `device_id`, `user_id`, `device_type` (`TOTP` or `FIDO2`), `device_name`, `enrolled_at`. MEDIUM because MFA enrollment changes the user's authentication posture and is security-relevant.
`MFA_ENROLLMENT_FORCED` (HIGH) — emitted when all `mfa_devices` rows for a user are invalidated and the user is required to re-enroll on next login. HIGH because forced re-enrollment is always triggered by a security event (password reset, compromise detection, or admin action) and leaves the user without active MFA until re-enrollment completes. Payload: `user_id`, `business_id`, `forced_by_user_id` (null for system-initiated), `reason` (`PASSWORD_RESET` | `COMPROMISE_DETECTED` | `ADMIN_INITIATED`), `device_count_invalidated`. See `mfa_enrollment_policy.md`.
`MFA_BACKUP_CODE_USED` (HIGH) — emitted when a one-time backup code passes challenge verification. HIGH because backup-code consumption may indicate a recovery scenario or account-takeover attempt. Payload: `device_id`, `user_id`, `codes_remaining`.
`MFA_RECOVERY_CODE_USED` (HIGH) — emitted when a single-use recovery code from the `mfa_recovery_codes` table passes challenge verification and is consumed. HIGH because recovery code consumption reduces the user's remaining recovery options and is a signal for account-takeover review. Payload: `user_id`, `codes_remaining`, `consumed_at`. Distinct from `MFA_BACKUP_CODE_USED` (which covers the TENANCY/MFA challenge domain) in that this event is scoped to the `mfa_recovery_codes` table lifecycle. See `mfa_enrollment_policy.md`.

Note: `MFA_BACKUP_CODE_USED` and `MFA_RECOVERY_CODE_USED` are separate events. `MFA_BACKUP_CODE_USED` is the existing event in the TENANCY/MFA challenge domain. `MFA_RECOVERY_CODE_USED` is the new device-lifecycle event scoped to the `mfa_recovery_codes` table. The `MFA_DEVICE_*` domain covers device-level and recovery-code lifecycle; the TENANCY/MFA block covers challenge-level events.

### WORKFLOW / WORKFLOW_GATE / WORKFLOW_TOOL (Block 03)

```
WORKFLOW_RUN_CREATED                  WORKFLOW_RUN_STATE_CHANGED
WORKFLOW_RUN_PAUSED                   WORKFLOW_RUN_RESUMED
WORKFLOW_RUN_CANCELLED                WORKFLOW_RUN_FAILED
WORKFLOW_GATE_PASSED                  WORKFLOW_GATE_HOLD
WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE    WORKFLOW_GATE_EVALUATED
WORKFLOW_GATE_DECISION
WORKFLOW_TOOL_INVOKED                 WORKFLOW_TOOL_DEDUP_HIT
WORKFLOW_TOOL_REPLAY_VIA_EXTERNAL_REQUEST_ID
WORKFLOW_TOOL_INVOCATION_STARTED      WORKFLOW_TOOL_INVOCATION_COMPLETED
WORKFLOW_TOOL_INVOCATION_FAILED
WORKFLOW_TOOL_VERSION_BUMPED          WORKFLOW_TOOL_REGISTRATION_DEPRECATED
TOOL_REGISTRY_STARTUP_COMPLETED       TOOL_REGISTRY_STARTUP_FAILED
WORKFLOW_APPROVAL_RECORDED            WORKFLOW_RUN_RE_APPROVAL_RECORDED
WORKFLOW_RUN_APPROVAL_STALE
WORKFLOW_APPROVAL_REQUESTED           WORKFLOW_APPROVAL_GRANTED
WORKFLOW_APPROVAL_REJECTED            WORKFLOW_APPROVAL_EXPIRED
WORKFLOW_TRIGGER_SHORT_CIRCUITED
WORKFLOW_TYPE_REGISTRY_UPDATED
WORKFLOW_PHASE_SEQUENCE_MIGRATED      WORKFLOW_PHASE_SEQUENCE_MIGRATION_REVERTED
WORKFLOW_GATE_TIMEOUT
EVENT_SUBSCRIPTION_REGISTERED         EVENT_SUBSCRIPTION_DISABLED
TRIGGER_EVENTS_PROCESSED_RECORDED
WORKFLOW_RUN_FORCE_RESUMED
WORKFLOW_RUN_COMPENSATING_STARTED     WORKFLOW_RUN_COMPENSATING_COMPLETED
WORKFLOW_RUN_STALLED
WORKFLOW_TOOL_INVOCATION_RETRY_EXHAUSTED
EVENT_AUDIT_RECOVERED
ENGINE_WORKFLOW_TYPE_REGISTERED
```

`EVENT_AUDIT_RECOVERED` (LOW) — Emitted when a non-finalization audit-append failure is recovered via the fallback path. Payload: `workflow_run_id`, `original_event_name`, `recovery_attempt_at`. See `tool_hash_chain_append` for the two-transaction emission pattern and Block 03 Phase 07 for resumability.

`ENGINE_WORKFLOW_TYPE_REGISTERED` (LOW) — emitted by the workflow type registry at application boot when a new `workflow_type_registry` row is inserted (the `ON CONFLICT DO NOTHING` path on subsequent boots does not emit this event). LOW because first-time type registration is expected behaviour during initial deployment or when a new workflow type is introduced. Payload: `workflow_type`, `registered_by_block`, `phase_count`, `gate_count`, `registered_at`. See `workflow_type_registry_schema.md`.

`WORKFLOW_APPROVAL_REQUESTED` (LOW) — emitted when a new `workflow_run_approvals` row is inserted with `status = PENDING`. LOW because creating an approval request is the expected, routine action at the `REVIEW_HOLD` release and finalization gates. Payload: `approval_id`, `workflow_run_id`, `approval_type`, `requested_by_user_id`, `expires_at`. See `workflow_run_approvals_schema.md`.

`WORKFLOW_APPROVAL_GRANTED` (LOW) — emitted when a `workflow_run_approvals` row transitions to `status = APPROVED`. LOW because a granted approval is the expected outcome when all preconditions are met. Payload: `approval_id`, `workflow_run_id`, `approval_type`, `approved_by_user_id`, `resolved_at`, `step_up_token_id` (included for `FINALIZATION` type only; null otherwise). See `workflow_run_approvals_schema.md`.

`WORKFLOW_APPROVAL_REJECTED` (MEDIUM) — emitted when a `workflow_run_approvals` row transitions to `status = REJECTED`. MEDIUM because a rejected approval indicates either a data readiness problem (accountant found outstanding issues) or a step-up token failure (`STEP_UP_EXPIRED`, `STEP_UP_ALREADY_CONSUMED`); both require follow-up action before the run can advance. Payload: `approval_id`, `workflow_run_id`, `approval_type`, `approved_by_user_id`, `rejection_reason`, `resolved_at`. See `workflow_run_approvals_schema.md`.

`WORKFLOW_APPROVAL_EXPIRED` (MEDIUM) — emitted by the background expiry job when a `workflow_run_approvals` row is transitioned to `status = EXPIRED` because `expires_at <= now()` was reached before resolution. MEDIUM because an expired approval leaves the run stalled in `REVIEW_HOLD` or `AWAITING_APPROVAL`; a new approval request must be created explicitly. Payload: `approval_id`, `workflow_run_id`, `approval_type`, `requested_by_user_id`, `expired_at`. See `workflow_run_approvals_schema.md`, `human_review_approval_staleness_policy.md`.

`WORKFLOW_GATE_DECISION` (LOW) — emitted by the gate evaluation framework when a gate decision of `HOLD` or `ROUTE_TO_SIDE_PHASE` is persisted to `workflow_phase_states.gate_decision`. Distinct from `WORKFLOW_GATE_EVALUATED` (per-evaluation signal) in that this event records the persisted decision and reason. Payload: `workflow_run_id`, `phase_name`, `gate_decision`, `decision_reason`, `business_id`. See `gate_evaluation_framework.md`.

### WORKFLOW_PHASE (Block 03 — phase-level execution state)

```
WORKFLOW_PHASE_STATE_TRANSITIONED
```

`WORKFLOW_PHASE_STATE_TRANSITIONED` (LOW) — emitted by the phase execution engine on every `workflow_phase_states.status` column transition. Payload: `phase_state_id`, `workflow_run_id`, `phase_name`, `phase_index`, `from_status`, `to_status`, `gate_decision` (nullable), `retry_count`. LOW severity for all phase transitions; run-level severity is tracked separately via `WORKFLOW_RUN_STATE_CHANGED`. See `workflow_phase_states_schema` for the phase-state status enum and its relationship to the run-level enum.

`WORKFLOW_RUN_STALLED` (HIGH) — emitted by the Block 03 Phase 07 watchdog when a run has been in `RUNNING` status for more than 30 minutes with no `workflow_phase_states.status` transition. HIGH because a stalled run requires operator or automated intervention. Payload: `workflow_run_id`, `business_id`, `stalled_duration_minutes`, `last_known_phase_name`. See `resumability_policy` for the stall detection and auto-resume logic.

`WORKFLOW_TOOL_INVOCATION_RETRY_EXHAUSTED` (HIGH) — emitted by `engine.invoke_tool` when the maximum retry count for a tool invocation is reached and the error persists. Uses `WORKFLOW_TOOL` domain per `audit_log_policies`. HIGH because retry exhaustion always requires operator action to proceed or abort the run. Payload: `workflow_run_id`, `phase_name`, `tool_name`, `error_class`, `attempt_count`, `last_error_message`, `business_id`. See `retry_policy` for retry parameters by error class and AI tier.

### RETENTION / LEGAL_HOLD / OBJECT_LOCK / ANALYTICS (Block 04)

```
RETENTION_RULE_EVALUATED              RETENTION_DELETION_EXECUTED
RETENTION_DELETION_SKIPPED_LEGAL_HOLD RETENTION_INCONSISTENCY_DETECTED
RETENTION_POLICY_INITIAL_SEED         RETENTION_POLICY_UPDATED        RETENTION_POLICY_SHORTEN_REJECTED
RETENTION_PASS_STARTED                RETENTION_PASS_COMPLETED        RETENTION_PASS_SKIPPED_CONCURRENT
RETENTION_PASS_TIMEOUT                RETENTION_PASS_TRIGGERED_MANUAL RETENTION_PASS_AUTH_ERROR
RETENTION_PASS_DELETION_STATE_RESET   RETENTION_DELETION_PLANNED      RETENTION_DELETION_RECONCILED_ORPHAN
RETENTION_DELETION_PLANNED_DRY_RUN    RETENTION_HOOK_REGISTERED
LEGAL_HOLD_SET                        LEGAL_HOLD_LIFTED               LEGAL_HOLD_EXPIRED
LEGAL_HOLD_REASON_UPDATED             LEGAL_HOLD_WINDOW_OVERRIDE_SET
LEGAL_HOLD_OBJECT_LOCK_EXTENSION_STARTED                              LEGAL_HOLD_OBJECT_LOCK_EXTENSION_COMPLETED
LEGAL_HOLD_EXTENSION_TIMEOUT          LEGAL_HOLD_EXTENSION_AUTH_ERROR
BUSINESS_DEACTIVATION_BLOCKED_LEGAL_HOLD
OBJECT_LOCK_VIOLATION_DETECTED        OBJECT_LOCK_RETENTION_EXTENDED  OBJECT_LOCK_RETENTION_SET
OBJECT_LOCK_EXTENSION_DUE_FOR_RENEWAL OBJECT_LOCK_EXTENSION_REJECTED_SHORTEN
ANALYTICS_REFRESH_TRIGGERED           ANALYTICS_REFRESH_COMPLETED     ANALYTICS_REFRESH_FAILED
```


### KEY / BACKUP / GDPR / SECURITY / AUDIT / FILE (Block 05)

```
KEY_ROTATION_REQUESTED                KEY_ROTATED
KEY_ACCESSED                          BACKUP_KEY_ROTATED
KEY_ENCRYPTION_ROTATED
KEY_ACCESS_DENIED                     KEY_ROTATION_INCOMPLETE
VAULT_INITIALIZED
KEK_CREATED                           KEK_ROTATED
DEK_CREATED                           DEK_ROTATED                  DEK_RETIRED
DEK_DESTRUCTION_REQUESTED             DEK_DESTRUCTION_ABORTED      DEK_DESTRUCTION_INCOMPLETE
DEK_DESTROYED
SECURITY_KEY_HIERARCHY_INVARIANT_VIOLATION
FIELD_DECRYPTED                       FIELD_ENCRYPTED                FIELD_DECRYPTION_FAILED
MASKED_FORM_RULE_CHANGED
ENCRYPTION_MIGRATION_COMPLETED        ENCRYPTION_MIGRATION_VERIFICATION_FAILED
ENCRYPTION_MIGRATION_ROLLED_BACK
SECURITY_DECRYPT_RATE_LIMIT_EXCEEDED
ACCESS_ALLOWED                        ACCESS_DENIED
ACCESS_STEP_UP_TRIGGERED              ACCESS_DECISION_THREW
INTEGRATION_CREDENTIAL_STALE_SUSPECTED INTEGRATION_CREDENTIAL_STALE_VERIFIED
INTEGRATION_CREDENTIAL_STALE_FALSE_POSITIVE
BACKUP_KEY_RETIRED                    BACKUP_KEY_RESTORE_VERSION_MISSING
BACKUP_KEY_COMPROMISE_ROTATED
BACKUP_REPLICATION_BACKLOG_EXCEEDED   BACKUP_RESIDENCY_VIOLATION_DETECTED
GDPR_PSEUDONYM_CREATED                GDPR_PSEUDONYM_REVERSED       GDPR_PSEUDONYM_ANONYMIZED
GDPR_ANONYMIZATION_STARTED            GDPR_ANONYMIZATION_TIMEOUT    GDPR_ANONYMIZATION_DEFERRED_LEGAL_HOLD
GDPR_REQUEST_FULFILLED
GDPR_EXPORT_GENERATED                 GDPR_EXPORT_DOWNLOADED        GDPR_EXPORT_SIZE_CAP_EXCEEDED
GDPR_EXPORT_EXPIRED_UNDOWNLOADED
GDPR_REQUEST_DEFERRED_LEGAL_HOLD      GDPR_HOLD_LIFTED_REQUEST_RESUMED
GDPR_DEFERRAL_NOTIFICATION_SENT
BACKUP_CREATED                        BACKUP_VERIFIED  BACKUP_RESTORED
GDPR_ACCESS_REQUESTED                 GDPR_ACCESS_EXPORTED
GDPR_ERASURE_REQUESTED                GDPR_PSEUDONYMIZED  GDPR_ANONYMIZED
SECURITY_ALERT_RAISED                 SECURITY_ALERT_DEDUPLICATED
SECURITY_ALERT_CREATED                SECURITY_ALERT_ACKNOWLEDGED           SECURITY_ALERT_RESOLVED
SECURITY_AUDIT_QUERY_TIMEOUT          SECURITY_INVESTIGATION_RECORDED
SECURITY_RLS_DENY_DETECTED            SECURITY_RATE_LIMIT_EXCEEDED
SECURITY_PLAINTEXT_FALLBACK_DETECTED
SECURITY_DR_DRILL_COMPLETED           SECURITY_ACCOUNT_COMPROMISE_SUSPECTED
ALERT_RULE_ADDED                      ALERT_RULE_UPDATED  ALERT_RULE_DISABLED
AUDIT_CHAIN_HEAD_ANCHORED             AUDIT_CHAIN_DIVERGENCE_DETECTED
AUDIT_CHAIN_DIVERGENCE_RESOLVED       AUDIT_CHAIN_TIMESTAMP_VERIFICATION_FAILED
AUDIT_HASH_CHAIN_VERIFICATION_FAILED
AUDIT_HASH_CHAIN_VERIFICATION_PASSED
ARCHIVE_TAMPER_DETECTED
FILE_INDEXED                          FILE_DECRYPTED
```

`SECURITY_DR_DRILL_COMPLETED` (LOW) — emitted against the global audit chain when a quarterly DR drill completes (or when a real restore completes). LOW because a successful drill is the expected outcome. Payload: `drill_environment`, `drill_start_at`, `drill_end_at`, `rto_achieved_minutes`, `rpo_achieved_minutes`, `conducted_by_user_id`. Written to the global chain (no `business_id`). See `dr_restore_runbook.md`.

`SECURITY_ACCOUNT_COMPROMISE_SUSPECTED` (HIGH) — emitted when the security alerting subsystem detects a signal pattern consistent with account takeover (e.g., successful login from an anomalous IP following a credential-stuffing spike, or an admin action immediately after password reset from an unrecognised device). HIGH because the event triggers forced MFA re-enrollment and session invalidation for the affected user. Payload: `user_id`, `business_id` (nullable), `signal_type`, `detected_at`, `triggering_alert_id`. See `security_alert_routing_policy.md`, `mfa_enrollment_policy.md`.

`SECURITY_RLS_DENY_DETECTED` (HIGH) — emitted by the `fn_emit_rls_deny_audit` trigger function when a Postgres RLS policy denies row-level access on a multi-tenant table. HIGH because an RLS denial at the database layer indicates either a programming error or an access boundary violation. Suppressed for system-role and migration-transaction contexts. Payload: `table_name`, `operation`, `user_id`, `business_id`, `row_id`. See `rls_deny_audit_pattern_policy`.
`SECURITY_RATE_LIMIT_EXCEEDED` (MEDIUM) — emitted (deduplicated per `(business_id, endpoint_group)` over a 5-minute window) when a tenant's request rate exceeds the configured limit for an endpoint group. MEDIUM because consistent rate-limit breaches indicate either a misconfigured integration or abuse. Payload: `business_id`, `endpoint_group`, `limit`, `request_count`, `window_start_at`, `window_end_at`, `first_rejected_path`. See `rate_limit_configuration_policy`.

`AUDIT_HASH_CHAIN_VERIFICATION_FAILED` (BLOCKING) — emitted by the weekly hash-chain verification scan (Block 05 Phase 07) when the recomputed `entry_hash` for any `audit_log_hash_chain` row diverges from the stored value. BLOCKING because a chain break indicates data corruption or tampering and must halt dependent finalization operations until investigated. Payload: `business_id`, `first_broken_sequence_number`, `audit_log_id`, `stored_hash_hex`, `recomputed_hash_hex`. See `hash_chain_schema` for the chain structure and `audit_log_policies` Section 4 for chain partitioning.
`AUDIT_HASH_CHAIN_VERIFICATION_PASSED` (LOW) — emitted by the caller of `archive.verify_hash_chain` (typically `engine.finalize` or the weekly automated scan) after a successful verification pass in which all checked rows' recomputed hashes match their stored values. LOW because a successful verification is the expected outcome of every finalization. Payload: `business_id`, `run_id` (nullable — null for full-chain scans), `rows_checked`, `verification_duration_ms`, `verified_at`. See `tool_archive_verify.md`, `hash_chain_verification_policy.md`.

`KEY_ENCRYPTION_ROTATED` (HIGH) — emitted when a DEK (per-business Data Encryption Key) or KEK (platform Key Encryption Key) rotation completes. Uses the `KEY` domain per `audit_log_policies` naming convention. HIGH because key rotation affects the confidentiality of every encrypted field for the affected scope. Payload: `rotation_type` (`DEK` or `KEK`), `business_id` (for DEK rotations; null for KEK), `rotated_by_user_id`, `rotated_at`. Decryption at use is not individually logged; only rotation events are tracked. See `encryption_at_rest_policy`.

`SECURITY_ALERT_CREATED` (HIGH) — emitted by `security.raise_alert` when a new `security_alerts` row is inserted (not deduplicated). HIGH because every new alert is a security-relevant signal. Payload: `alert_id`, `alert_type`, `severity`, `business_id`, `source_event_id`, `workflow_run_id`, `description`. See `alert_schema` and `security_alert_routing_policy`.

`SECURITY_ALERT_RESOLVED` (MEDIUM) — emitted when a `security_alerts` row transitions to `status = RESOLVED`. MEDIUM because resolution closes a known issue and should be visible in the audit trail. Payload: `alert_id`, `alert_type`, `business_id`, `resolved_by_user_id`, `resolution_note`, `resolved_at`. See `alert_schema`.

`SECURITY_PLAINTEXT_FALLBACK_DETECTED` (BLOCKING) — emitted by the gateway bypass detection layer when a request body, response body, log line, or storage write is found to contain an unencrypted sensitive field value. BLOCKING because a confirmed plaintext exposure is a data breach scenario requiring immediate incident response and pipeline halt. Written to the global audit chain (not the business chain) so it cannot be silenced by per-business RLS. Payload: `detection_point` (`REQUEST_BODY` | `RESPONSE_BODY` | `LOG_LINE` | `STORAGE_WRITE`), `field_name`, `business_id` (nullable), `request_id`, `detected_at`. See `no_plaintext_fallback_policy.md`, `gateway_bypass_detection_policy.md`.

`PASSWORD_RESET_REQUESTED` (LOW) — emitted when a new `password_reset_tokens` row is successfully inserted (a reset email has been dispatched). LOW because requesting a reset is an anticipated user action. Payload: `user_id`, `token_id`, `requested_from_ip`. The raw token and hash are never included. See `password_reset_token_schema`.

`OAUTH_STATE_CREATED` (LOW) — emitted when a new `oauth_states` row is inserted (OAuth authorisation redirect initiated). Payload: `state_id`, `user_id` (nullable), `provider`, `expires_at`. See `oauth_state_schema`.
`OAUTH_STATE_CONSUMED` (LOW) — emitted when `consumed_at` is set on a valid `oauth_states` row (callback received and validated). Payload: `state_id`, `user_id` (nullable), `provider`, `consumed_at`. See `oauth_state_schema`.
`OAUTH_STATE_EXPIRED_UNUSED` (LOW) — emitted by the purge job when an unconsumed `oauth_states` row is removed after its 24-hour post-expiry window. Payload: `state_id`, `user_id` (nullable), `provider`, `expires_at`. See `oauth_state_schema`.

### AUTH (Block 02 — application-layer permission check, OAuth lifecycle, invitations, password management, and session refresh)

```
AUTH_PERMISSION_DENIED
AUTH_OAUTH_CONNECTED
AUTH_OAUTH_TOKEN_REFRESHED
AUTH_OAUTH_TOKEN_REVOKED
AUTH_OAUTH_PERMISSION_DOWNGRADED
AUTH_INVITATION_SENT              AUTH_INVITATION_CONSUMED
AUTH_INVITATION_REVOKED           AUTH_INVITATION_EXPIRED
AUTH_MFA_ENROLLED                 AUTH_MFA_FAILED
AUTH_MFA_UNENROLLED
AUTH_PASSWORD_CHANGED             AUTH_PASSWORD_RESET_REQUESTED
AUTH_PASSWORD_RESET_COMPLETED     AUTH_PASSWORD_BREACHED_DETECTED
AUTH_SESSION_CREATED              AUTH_SESSION_EXPIRED
AUTH_SESSION_REFRESHED
AUTH_SESSION_DEVICE_MISMATCH      AUTH_SESSION_REFRESH_FAILED
AUTH_SESSION_REFRESH_RATE_LIMITED
AUTH_STEP_UP_CONSUMED             AUTH_STEP_UP_ISSUED
AUTH_STEP_UP_REVOKED
```

`AUTH_PERMISSION_DENIED` (MEDIUM) — emitted by `auth.can_perform` when the resolved role for a `(user_id, business_id)` pair does not grant the requested surface and operation. MEDIUM because a permission denial at the application layer may indicate access configuration errors or an attempt to reach surfaces outside the role's grant. Payload: `user_id`, `business_id`, `surface`, `operation`, `role_at_check`, `reason`. Not emitted for `SURFACE_UNKNOWN` or `USER_SUSPENDED` error paths. See `tool_can_perform_helper`.

`AUTH_OAUTH_CONNECTED` (LOW) — emitted when the Google OAuth flow completes successfully and an `oauth_tokens` row is inserted for a business. LOW because a successful connection is the expected outcome of the authorization flow. Payload: `business_id`, `user_id`, `provider`, `scopes_granted`, `connected_at`. See `gmail_oauth_integration.md`.

`AUTH_OAUTH_TOKEN_REFRESHED` (LOW) — emitted when an access token is refreshed via the stored refresh token, either proactively (the 50-minute refresh job) or reactively (inline on a 401 response). LOW because token refresh is routine and expected. Payload: `business_id`, `user_id`, `provider`, `refreshed_at`, `new_expires_at`. See `gmail_oauth_integration.md`.

`AUTH_OAUTH_TOKEN_REVOKED` (MEDIUM) — emitted when an OAuth token is revoked: on user-initiated disconnect, business deactivation, or refresh failure. MEDIUM because revocation halts intake for the business and requires re-authorization. Payload: `business_id`, `user_id`, `provider`, `revocation_reason` (`USER_DISCONNECT` | `BUSINESS_DEACTIVATED` | `REFRESH_FAILED`), `revoked_at`. See `gmail_oauth_integration.md`.

`AUTH_OAUTH_PERMISSION_DOWNGRADED` (MEDIUM) — emitted when a re-authorization grants fewer scopes than the previous grant. MEDIUM because a scope reduction degrades intake capability and may surprise the business owner. Payload: `business_id`, `user_id`, `provider`, `previous_scopes`, `new_scopes`, `removed_scopes`. See `gmail_oauth_integration.md`.

`AUTH_INVITATION_SENT` (LOW) — emitted when a new `invitation_tokens` row is inserted and the invitation email is dispatched. LOW because sending an invitation is an expected, routine administrative action. Payload: `token_id`, `business_id`, `invited_by_user_id`, `invitee_email`, `assigned_role`, `expires_at`. See `invitation_token_schema.md`.

`AUTH_INVITATION_CONSUMED` (LOW) — emitted when `consumed_at` is set on successful redemption of an invitation token. LOW because successful redemption is the expected outcome. Payload: `token_id`, `business_id`, `consumed_by_user_id`, `assigned_role`, `consumed_at`. See `invitation_token_schema.md`.

`AUTH_INVITATION_REVOKED` (MEDIUM) — emitted when `revoked_at` is set by an OWNER or ADMIN. MEDIUM because revocation may be a security action (wrong address, suspected interception). Payload: `token_id`, `business_id`, `revoked_by_user_id`, `revocation_reason` (optional, max 200 chars). See `invitation_token_schema.md`.

`AUTH_INVITATION_EXPIRED` (LOW) — emitted on the first failed redemption attempt on an expired token, or by the expiry sweep job. LOW because expiry is expected for unclaimed invitations. Payload: `token_id`, `business_id`, `expires_at`, `attempted_at`. See `invitation_token_schema.md`.

`AUTH_PASSWORD_CHANGED` (MEDIUM) — emitted on any successful password change (self-service via settings, or post-reset). MEDIUM because a password change is a security-relevant event visible to the Owner. Payload: `user_id`, `change_context` (`SELF_SERVICE` | `POST_RESET` | `FORCED_ROTATION`). No password or hash in payload. See `password_policy.md`.

`AUTH_PASSWORD_RESET_REQUESTED` (LOW) — emitted when a new `password_reset_tokens` row is successfully inserted and the reset email is dispatched. LOW because requesting a reset is a routine, expected user action. Payload: `user_id`, `token_id`, `requested_from_ip`. No raw token or hash in payload. See `password_policy.md`, `password_reset_token_schema.md`.

`AUTH_PASSWORD_RESET_COMPLETED` (MEDIUM) — emitted when a reset token is consumed and the new password hash is stored. MEDIUM because completion confirms the password has changed and existing sessions have been invalidated. Payload: `user_id`, `token_id`, `completed_at`. See `password_policy.md`.

`AUTH_PASSWORD_BREACHED_DETECTED` (MEDIUM) — emitted when the HaveIBeenPwned k-anonymity check returns a match for the submitted password at set-time. MEDIUM because the user is attempting to set a known-breached password. The password, SHA-1 hash, and k-anonymity prefix are never included in the payload. Payload: `user_id`, `detected_at`, `check_context` (`SIGNUP` | `PASSWORD_CHANGE` | `PASSWORD_RESET`). See `password_policy.md`.

`AUTH_SESSION_REFRESHED` (LOW) — emitted when `auth.session_refresh` succeeds and the session token is renewed. LOW because a successful refresh is the expected routine outcome for an active session. Payload: `session_id`, `business_id`, `user_id`, `refreshed_at`, `refresh_count`. See `session_lifetime_policy`.

`AUTH_SESSION_DEVICE_MISMATCH` (MEDIUM) — emitted when `auth.session_refresh` detects a device fingerprint change between the stored session fingerprint and the fingerprint presented in the refresh request. MEDIUM because a fingerprint change may indicate session token theft or use from an unexpected device. Payload: `session_id`, `business_id`, `user_id`, `expected_fingerprint_hash`, `detected_fingerprint_hash`. See `session_lifetime_policy`.

`AUTH_SESSION_REFRESH_FAILED` (LOW) — emitted when `auth.session_refresh` fails due to an expired token or a revoked session. LOW because token expiry and revocation are expected lifecycle outcomes; the failure is informational for the audit trail. Payload: `session_id` (if known; null when the token is unrecognisable), `business_id`, `user_id`, `failure_reason` (`TOKEN_EXPIRED` | `SESSION_REVOKED` | `SESSION_NOT_FOUND`). See `session_lifetime_policy`.

`AUTH_SESSION_REFRESH_RATE_LIMITED` (LOW) — emitted when `auth.session_refresh` is rate-limited because more than 10 refresh calls have been made for the same session within a rolling one-hour window. LOW because transient burst refresh is unlikely to be malicious; repeated triggering over multiple hours should be investigated. Payload: `session_id`, `business_id`, `user_id`, `refresh_count_last_hour`. See `session_lifetime_policy`.

`AUTH_SESSION_CREATED` (LOW) — emitted when a new authenticated session is established (complement to `AUTH_SESSION_REFRESHED` and `SESSION_CREATED`). Payload: `user_id`, `session_id`, `device_info`, `business_id`.

`AUTH_SESSION_EXPIRED` (LOW) — emitted when a session token expires and is not renewed. Payload: `user_id`, `session_id`, `expired_at`, `business_id`.

`AUTH_MFA_ENROLLED` (MEDIUM) — emitted when a user completes MFA enrollment (TOTP or SMS factor). Payload: `user_id`, `factor_type`, `session_id`, `business_id`.

`AUTH_MFA_FAILED` (MEDIUM) — emitted when an MFA challenge fails at the application auth layer. Payload: `user_id`, `factor_type`, `session_id`, `business_id`.

`AUTH_MFA_UNENROLLED` (MEDIUM) — emitted when a user removes their MFA factor (TOTP or SMS), whether self-initiated, admin-initiated, or platform-support override. Payload: `user_id`, `factor_type`, `session_id`, `business_id`.

`AUTH_STEP_UP_CONSUMED` (LOW) — emitted when a step-up MFA token is successfully consumed for a write operation. Payload: `user_id`, `session_id`, `token_id`, `operation`, `business_id`. See `step_up_token_schema.md`.

`AUTH_STEP_UP_ISSUED` (LOW) — emitted when a step-up MFA token is issued for a high-risk operation. Payload: `user_id`, `session_id`, `token_id`, `operation`, `business_id`. See `step_up_token_schema.md`.

`AUTH_STEP_UP_REVOKED` (MEDIUM) — emitted when a step-up MFA token is revoked before consumption. Payload: `user_id`, `session_id`, `token_id`, `reason`, `business_id`. See `step_up_token_schema.md`.

`AUTH_STEP_UP_FAILED_MAX_ATTEMPTS` (HIGH) — emitted when a step-up MFA attempt is rejected due to exceeding maximum attempt count. HIGH because exceeding the attempt ceiling indicates either a brute-force attack or a locked-out user requiring administrator intervention. Payload: `user_id`, `session_id`, `attempt_count`, `business_id`.

### AI / AI_GATEWAY / AI_PROMPT / AI_CACHE (Block 06)

```
AI_GATEWAY_INVOKED                    AI_GATEWAY_REJECTED
AI_GATEWAY_VALIDATION_FAILED          AI_GATEWAY_RESPONSE_INVALID
AI_CACHE_HIT                          AI_CACHE_STORED  AI_CACHE_EVICTED
AI_CACHE_PRUNED
AI_REDACTION_ALLOWLIST_DROP           AI_REDACTION_VALIDATION_FAILED
AI_REDACTION_POLICY_ROLLED_BACK
AI_REDACTION_APPLIED                  AI_REDACTION_REJECTED
AI_PII_DETECTED_IN_NON_DECLARED_FIELD
AI_REDACTION_POLICY_ACTIVATED         AI_REDACTION_POLICY_ACTIVATE_REJECTED
AI_PROMPT_INVOKED                     AI_PROMPT_DEPRECATED
AI_PROMPT_REGISTERED                  AI_PROMPT_REGISTER_REJECTED
AI_PROMPT_DEPLOYED                    AI_PROMPT_DEPLOY_REJECTED
AI_PROMPT_ROLLED_BACK
AI_PROMPT_PROMOTION_OVERRIDE_USED
AI_PROMPT_REGRESSION_FAILED
TIER_3_INVOKED                        TIER_3_RESPONSE_RECEIVED
TIER_3_FAILED                         TIER_3_BYPASS_ATTEMPT_BLOCKED
TIER_2_INVOKED                        TIER_2_RESPONSE_RECEIVED
TIER_2_FAILED                         TIER_2_HEALTH_CHECK_FAILED
TIER_2_CIRCUIT_BREAKER_OPENED         TIER_2_BYPASS_ATTEMPT_BLOCKED
AI_COST_CEILING_HIT                   AI_COST_CEILING_OVERRIDE_APPROVED
AI_COST_CEILING_REACHED
AI_COST_CONFIG_UPDATED                AI_COST_CONFIG_UPDATE_REJECTED
AI_COST_WARNING
AI_COST_OVERRIDE_REQUESTED            AI_COST_OVERRIDE_GRANTED
AI_COST_OVERRIDE_DENIED
AI_TIER_ESCALATED                     AI_TIER_DOWNGRADED_COST_CEILING
AI_ESCALATION_HOLD_TRIGGERED
AI_CLASSIFICATION_LAYER_3_INVOKED     AI_CLASSIFICATION_LAYER_3_DECIDED
AI_PRIVACY_GATEWAY_BYPASS_DETECTED    AI_PRIVACY_GATEWAY_BYPASS_LINT_FAILURE
AI_TIER_UNAVAILABLE
AI_TIER_ROUTED                        AI_TIER_BLOCKED
AI_TIER_CONFIG_UPDATED                AI_TIER_CONFIG_UPDATE_REJECTED
AI_PAYLOAD_REDACTED
AI_USAGE_RECORDED                     AI_USAGE_AGGREGATION_REFRESHED
AI_INVOCATION_RETRY_ATTEMPTED
END_SCAN_TRIGGERED                    END_SCAN_FINDING_RAISED  END_SCAN_COMPLETED
END_SCAN_FAILED
END_SCAN_AFFECTED_ONLY_RESCAN_TRIGGERED
END_SCAN_STARTED                      END_SCAN_CHECK_RAN
END_SCAN_ISSUE_RAISED                 END_SCAN_RESCAN_AFFECTED
PLAIN_LANGUAGE_GENERATED              PLAIN_LANGUAGE_GENERATION_FAILED
PLAIN_LANGUAGE_FALLBACK_USED
AI_INVOCATION_COMPLETED               AI_INVOCATION_FAILED
AI_ANOMALY_DETECTION_COMPLETED        AI_CLASSIFICATION_BATCH_COMPLETED
ANOMALY_DETECTED
AI_CONFIG_MODEL_REVERTED
AI_ROLLOUT_STAGE_ADVANCED
AI_CLASSIFICATION_CONFIG_CREATED      AI_CLASSIFICATION_CONFIG_UPDATED
```

`AI_ANOMALY_DETECTION_COMPLETED` (LOW) — emitted when an AI anomaly detection scan completes for a run. Payload: `run_id`, `anomaly_count`, `sensitivity`, `business_id`.

`AI_CLASSIFICATION_BATCH_COMPLETED` (LOW) — emitted when an AI classification batch completes for a set of transactions. Payload: `run_id`, `transaction_count`, `avg_confidence`, `model_used`, `business_id`.

`ANOMALY_DETECTED` (MEDIUM) — emitted when a specific anomaly is detected during an AI scan. Payload: `run_id`, `transaction_id`, `anomaly_type`, `score`, `business_id`.

`AI_INVOCATION_COMPLETED` (LOW) — emitted when an `ai_invocation_records` row is inserted with `status = SUCCESS`. Payload: `invocation_id`, `tool_name`, `ai_tier`, `model_identifier`, `input_token_count`, `output_token_count`, `latency_ms`, `response_cached`. See `ai_gateway_schema`.
`AI_INVOCATION_FAILED` (MEDIUM) — emitted when an `ai_invocation_records` row is inserted with `status` in `{FAILED, TIMEOUT, RATE_LIMITED}`. Payload: `invocation_id`, `tool_name`, `ai_tier`, `model_identifier`, `error_class`, `latency_ms`. See `ai_gateway_schema`.
`AI_INVOCATION_RETRY_ATTEMPTED` (LOW) — emitted by `ai.invoke` before each retry attempt on a transient failure, prior to reaching the 3-attempt exhaustion limit. Payload: `invocation_id`, `attempt_number`, `prompt_key`, `tier_attempted`, `error_class`, `business_id`, `run_id`. See `tool_gateway_invoke_ai`.
`AI_CACHE_HIT` (LOW) — emitted when `ai.invoke` returns a response from the AI cache without dispatching to the LLM provider. No spend is recorded on cache hits. Payload: `cache_key`, `prompt_key`, `prompt_version`, `business_id`, `run_id`, `cached_tier`. See `tool_gateway_invoke_ai`, `ai_cache_schema`.
`AI_COST_CEILING_REACHED` (HIGH) — **LEGACY / RESERVED.** This name was originally allocated for a monthly-ceiling model (cumulative business spend across all runs in a calendar month, with silent downgrade to Tier 1 once crossed). B06·P08 instead ships a **per-run soft ceiling** with explicit override semantics — see `AI_COST_CEILING_HIT`. The monthly-ceiling model is not implemented; if it lands later (e.g., for fraud-guard / budget-spike alerts), this event would be repurposed at that time. **Not currently emitted.**

`AI_COST_CEILING_OVERRIDE_APPROVED` (LEGACY) — original name for what B06·P08 emits as `AI_COST_OVERRIDE_GRANTED`. The newer name follows the canonical `<DOMAIN>_<PAST_VERB>` convention more cleanly (no `_CEILING_` redundancy in the action name; the subject_id makes the ceiling-vs-tier distinction). **Not emitted by B06·P08.**

`AI_COST_CONFIG_UPDATED` (LOW) — emitted by `public.update_business_cost_ceiling` on a successful Owner-driven write of the per-business cost-ceiling config. Subject is the `business_ai_config` row (`subject_type=BUSINESS_AI_CONFIG`). Carries both `before_state` and `after_state` so reviewers can diff. Payload (`after_state`): `business_id`, `default_ceiling_per_run`, `warning_threshold_pct`, `ceiling_currency`, `tier_2_gating_enabled`.

`AI_COST_CONFIG_UPDATE_REJECTED` (MEDIUM) — emitted by `update_business_cost_ceiling` on policy failure (DENY), invalid threshold pct (outside (0, 100]), non-positive ceiling, or business-not-found. MEDIUM because attempted policy mutations against the cost-control surface warrant investigation. Payload (`after_state`): `rejection_code` (`PERMISSION_DENIED` / `CEILING_MUST_BE_POSITIVE` / `WARNING_PCT_OUT_OF_RANGE` / `BUSINESS_NOT_FOUND`), `business_id`, `requested.*`.

`AI_COST_WARNING` (MEDIUM) — emitted **exactly once per run** by `check_run_cost_ceiling` the first time the projected cumulative cost crosses the warning threshold (`effective_ceiling × warning_threshold_pct / 100`). Subsequent crossings within the same run do not re-emit (deduplicated via `ai_cost_ceiling_runs.warning_emitted_at`). MEDIUM because operator attention is warranted but the run is still proceeding. SYSTEM actor (`actor_system='ai_cost_ceiling'`). Payload (`after_state`): `workflow_run_id`, `current_spend`, `projected_total`, `warning_floor`, `effective_ceiling`, `currency`, `triggering_tier`.

`AI_COST_CEILING_HIT` (HIGH) — emitted by `check_run_cost_ceiling` every time a projected cost would exceed `effective_ceiling`. Carries `is_first_hit` boolean: the first hit creates a B14 review issue (downstream consumer) and the run is transitioned to `REVIEW_HOLD`; subsequent hits within the same run after an override only require step-up (no review issue). Decision returned to the gate caller is `BLOCKED` (before any override) or `REQUIRES_STEP_UP` (after override). HIGH because dispatch is refused and the run is held. SYSTEM actor. Payload (`after_state`): `workflow_run_id`, `is_first_hit`, `decision`, `current_spend`, `projected_total`, `effective_ceiling`, `override_count`, `currency`, `triggering_tier`.

`AI_COST_OVERRIDE_REQUESTED` (LOW) — emitted by `public.request_cost_ceiling_override` when the user clicks "Continue past AI cost ceiling" in the review queue (before step-up). Audit-only signal; no state mutation. LOW because the user merely clicked the button — the actual grant requires step-up. Payload (`after_state`): `workflow_run_id`, `requested_reason`.

`AI_COST_OVERRIDE_GRANTED` (HIGH) — emitted by `public.grant_cost_ceiling_override` after a step-up token is successfully consumed (surface=`ai_cost_override`) and the `effective_ceiling` is bumped (default: previous + `original_ceiling`). HIGH because the override is a deliberate cost expansion that should be reviewable. Subject is the run; carries `before_state.effective_ceiling` / `after_state.effective_ceiling` so the reviewer can see the jump. Payload (`after_state`): `workflow_run_id`, `effective_ceiling` (new), `override_count` (post-increment), `step_up_token_id`, `reason`.

`AI_COST_OVERRIDE_DENIED` (HIGH) — emitted by `public.grant_cost_ceiling_override` (on policy / step-up / ceiling-not-increased failure — Mitigation A) or by `public.deny_cost_ceiling_override` (admin denial). HIGH because a denied override either indicates a real authorization issue (worth investigating) or an admin actively blocking an override request. Payload (`after_state`): `rejection_code` (`PERMISSION_DENIED` / `STEP_UP_FAILED` / `CEILING_NOT_INCREASED` / `MANUAL_DENIAL` / `BUSINESS_NOT_FOUND` / `NO_CEILING_FOR_RUN`), `workflow_run_id`, optional `requested_extended_ceiling`, `requested_reason` or `denial_reason`.

`AI_CACHE_STORED` (LOW) — emitted by `public.ai_cache_store` when a new `(workflow_run_id, cache_key)` row is inserted into `ai_cache`. LOW because cache stores are the routine outcome of successful first-time dispatches. Race-safe duplicate stores (via `ON CONFLICT DO NOTHING` returning `stored=false`) do not re-emit — only first-write per `(run, key)`. SYSTEM actor (`actor_system='ai_cache'`) when no user is in the call chain. Payload (`after_state`): `cache_id`, `workflow_run_id`, `cache_key`, `tool_name`, `prompt_id`, `prompt_version`, `policy_version`. See `ai_cache`, `ai_cache_store`, `make_ai_cache_key`.

`AI_CACHE_PRUNED` (LOW) — emitted by `public.ai_cache_prune_for_run` when a run's cache rows are deleted (typically by the B04·P06 TTL job 24h after FINALIZED / 30d after failure, or by manual operator cleanup). LOW because pruning is the expected lifecycle endpoint. Carries a `reason` string so the audit log distinguishes scheduled TTL prunes from operator-driven ones. SYSTEM actor (`actor_system='ai_cache_pruner'`) when invoked by the TTL job; USER otherwise. Payload (`after_state`): `workflow_run_id`, `pruned_count`, `reason`.

Note on `AI_CACHE_EVICTED`: this name is in the AI section header but is **not emitted** by B06·P09. It was an earlier name for the prune concept; the canonical name per spec is `AI_CACHE_PRUNED` (eviction implies an LRU-style policy, which we don't run — cache rows live for the duration of the run and are pruned together via TTL). `_EVICTED` is RESERVED/LEGACY.

`PLAIN_LANGUAGE_GENERATED` (LOW) — emitted by `public.record_plain_language_event` after a successful plain-language render (Tier 2 by default, Tier 3 when caller passes `options.preferred_tier=EXTERNAL_LLM` or the prompt's `meta.yaml` declares Tier 3). Subject is the workflow run (`subject_type=WORKFLOW_RUN`); a single render can serve multiple downstream consumers (review queue, matching engine, exports), so binding the audit to the run gives reviewers the right reconstruction unit. SYSTEM actor (`actor_system='plain_language'`) when no user is in the call chain. Payload (`after_state`): `prompt_id` (one of `ai_layer.plain_language.review_issue` / `match_reason` / `other`), `prompt_version`, `tier`, `kind` (`REVIEW_ISSUE` / `MATCH_REASON` / `OTHER`), `language`, `title_len`, `description_len`. Cache hits (from B06·P09) emit `AI_CACHE_HIT` instead — not `PLAIN_LANGUAGE_GENERATED`.

`PLAIN_LANGUAGE_GENERATION_FAILED` (MEDIUM) — emitted by `record_plain_language_event` on Tier 2 failure (transient or not) or on output-schema violation (title > 80 chars, description > 300 chars, missing required fields). MEDIUM because the underlying issue or match still gets created with a fallback rendering (see `PLAIN_LANGUAGE_FALLBACK_USED`), but quality is degraded for that record until manual re-render. Carries the `transient` flag B03·P08's retry policy reads. Payload (`after_state`): `kind`, `prompt_id`, `prompt_version`, `tier`, `reason` (`SCHEMA_VIOLATION_OUTPUT` / `TIMEOUT` / `MODEL_ERROR` / `REDACTION_REJECTED`), `transient` (boolean).

`PLAIN_LANGUAGE_FALLBACK_USED` (MEDIUM) — emitted by `record_plain_language_event` when the caller rendered the consumer record with a fallback string (e.g., the raw `issue_type` code) because the AI render failed and the record could not wait. MEDIUM because the user sees a less-friendly label until a re-render succeeds; rate of fallback events is a quality KPI. Payload (`after_state`): `kind`, `fallback_text` (the raw value used in lieu of the AI render — e.g. `'OUT_EXPENSE_NO_INVOICE'`), `original_failure_reason` (the same `reason` code as the paired `PLAIN_LANGUAGE_GENERATION_FAILED` event, threaded so reviewers can correlate).
`AI_TIER_ESCALATED` (LOW) — emitted by `ai.invoke` each time a tier escalation occurs due to insufficient confidence in the lower-tier response. One event per escalation step. Payload: `invocation_sequence_id`, `from_tier`, `to_tier`, `from_confidence`, `threshold`, `prompt_key`, `business_id`, `run_id`. See `ai_tier_escalation_policy`.
`AI_TIER_DOWNGRADED_COST_CEILING` (HIGH) — emitted by `ai.invoke` on each invocation where the requested tier (tier 2 or tier 3) is downgraded to tier 1 because the business has reached its monthly cost ceiling. HIGH because the caller receives lower-capability results than requested. Payload: `business_id`, `requested_tier`, `effective_tier`, `spend_usd`, `ceiling_usd`, `prompt_key`, `run_id`. See `ai_tier_escalation_policy`.
`AI_ESCALATION_HOLD_TRIGGERED` (HIGH) — emitted when a workflow run accumulates 3 consecutive tier-3 escalations, triggering a `REVIEW_HOLD`. HIGH because the run requires human intervention to proceed. Payload: `run_id`, `business_id`, `consecutive_tier3_count`, `last_prompt_key`, `hold_run_status_before`. See `ai_tier_escalation_policy`.
`END_SCAN_COMPLETED` (LOW) — emitted by `public.complete_end_scan` when an `end_scan_runs` row transitions to `COMPLETED`. LOW because successful completion is the steady-state event for every workflow run that reaches the `AI_END_SCAN` phase. Subject is the workflow run. Payload (`after_state`): `scan_id`, `workflow_run_id`, `status` (`COMPLETED`), `finding_count`, `severity_counts` (object `{LOW, MEDIUM, HIGH, BLOCKING}` → counts), `checks_ran_count`, `failure_reason` (NULL on COMPLETED).
`END_SCAN_FAILED` (MEDIUM) — emitted by `public.complete_end_scan` on `FAILED` transition. MEDIUM because a failed scan leaves the run without anomaly-detection coverage and must be investigated. Same payload shape as `END_SCAN_COMPLETED` with `status='FAILED'` and the operator's `failure_reason` populated.

`END_SCAN_STARTED` (LOW) — emitted by `public.start_end_scan` when a new `end_scan_runs` row is inserted with `status='STARTED'`. Pairs with the eventual terminal `END_SCAN_COMPLETED` / `END_SCAN_FAILED`. Subject is the workflow run. SYSTEM actor (`actor_system='end_scan'`) when the engine runs unattended (e.g., as part of the workflow phase advancement); USER otherwise. Payload (`after_state`): `scan_id`, `workflow_run_id`, `is_rescan` (boolean), `affected_entity_kind` (NULL on full scans; one of `transaction` / `document` / `match_record` / `draft_ledger_entry` on rescans), `affected_entity_ids` (NULL on full scans; UUID array on rescans).

`END_SCAN_CHECK_RAN` (LOW) — emitted by `public.record_end_scan_check` once per individual check the engine executes (e.g. `out_evidence.missing_invoice`, `vat.unclear_treatment`). Gives reviewers per-check observability: which checks ran, how many findings each produced, how long each took. SYSTEM actor when engine-driven. Payload (`after_state`): `scan_id`, `workflow_run_id`, `check_name` (namespaced — lowercase dot-separated, validated by RPC), `finding_count`, `deterministic` (boolean — true if the check is pure SQL, false if it involved an AI call), `duration_ms`.

`END_SCAN_ISSUE_RAISED` (MEDIUM) — emitted by `public.raise_end_scan_issue` once per finding. Subject is the new `review_issues` row (`subject_type=REVIEW_ISSUE`, `subject_id=issue_id`). MEDIUM because every flagged anomaly is something the operator must respond to, even if individually most are LOW severity issues; the audit-stream consumer needs per-issue events to thread the run-quality story. Payload (`after_state`): `issue_id`, `scan_id`, `workflow_run_id`, `issue_type` (namespaced — e.g. `out_evidence.missing_invoice`), `issue_group` (one of `MISSING_DOCUMENTS` / `NEEDS_CONFIRMATION` / `POSSIBLE_WRONG_MATCH` / `POSSIBLE_TAX_VAT_ISSUE` / `UNUSUAL_TRANSACTION`), `severity` (`LOW` / `MEDIUM` / `HIGH` / `BLOCKING`), `fallback_applied` (boolean — whether the plain-language fields used the B06·P10 fallback path).

`END_SCAN_RESCAN_AFFECTED` (LOW) — emitted by `public.start_end_scan_rescan_affected` when the engine is invoked for an affected-only re-evaluation (typically by B14's resolution-side hook when a resolved issue means previously-flagged entities should be re-checked). Before starting the new scan, existing OPEN `review_issues` for the affected entities are flipped to `status='DISMISSED'` with `resolution_action='SUPERSEDED_BY_RESCAN'` and a `resolution_note` documenting the supersede — this preserves issue history while honouring the spec's "re-scan replaces existing OPEN issues; it does not duplicate them." Payload (`after_state`): `workflow_run_id`, `affected_entity_kind`, `affected_entity_ids`, `superseded_count`, `supersede_status` (always `DISMISSED`), `supersede_action` (always `SUPERSEDED_BY_RESCAN`).

Note on legacy AI section header names — `END_SCAN_TRIGGERED`, `END_SCAN_FINDING_RAISED`, `END_SCAN_AFFECTED_ONLY_RESCAN_TRIGGERED`: these were earlier names for what B06·P11 emits as `END_SCAN_STARTED`, `END_SCAN_ISSUE_RAISED`, `END_SCAN_RESCAN_AFFECTED` respectively. The shorter spec-canonical forms are what the engine actually emits; the legacy names are RESERVED / not emitted.

Note on legacy `end_scan_results` table reference: earlier taxonomy bodies referenced an `end_scan_results` table that was never created. B06·P11 ships `end_scan_runs` instead; the data model is the spec's lifecycle row (STARTED → COMPLETED/FAILED/CANCELLED), not a separate results table.

`STATEMENT_UPLOAD_REQUESTED` (LOW) — emitted by `public.request_statement_upload` when an authenticated user requests a signed upload URL for a bank statement. Subject is the `bank_accounts` row the upload targets (`subject_type=BANK_ACCOUNT`); the API layer then uses the returned `raw_path` to call Supabase Storage's `createSignedUploadUrl`. LOW because requesting an upload is a routine workflow action. Payload (`after_state`): `bank_account_id`, `file_id` (the UUID v7 the upload will land under in Storage), `raw_path` (the canonical `raw-uploads/<business>/<bank_account>/<file_id>.<ext>` path), `declared_period_start`, `declared_period_end`, `file_format` (`CSV` / `PDF`), `original_filename`. See `request_statement_upload`.

`STATEMENT_UPLOAD_COMPLETED` (LOW) — emitted by `public.complete_statement_upload` after a successful Storage upload, when the `statement_uploads` row is inserted at `upload_status='UPLOADED'`. Subject is the new `statement_uploads` row. Phase 01 is the **emission point**; Block 03·P09 (trigger engine) is the downstream consumer that turns this into a `STATEMENT_UPLOAD_COMPLETED` trigger event. LOW because this is the steady-state success event for every upload. Payload (`after_state`): `upload_id`, `bank_account_id`, `file_id`, `file_hash` (SHA-256 hex), `file_format`, `provider` (`REVOLUT` for MVP), `declared_period_start`, `declared_period_end`, `original_filename`, `upload_status` (always `UPLOADED` at this event — subsequent transitions own their own events). See `complete_statement_upload`.

`STATEMENT_UPLOAD_REJECTED_DUPLICATE_HASH` (MEDIUM) — emitted by `complete_statement_upload` when the `UNIQUE(bank_account_id, file_hash)` constraint fires. Spec invariant: re-uploading the exact same file under the same bank account is rejected, not silently ignored. MEDIUM because a duplicate upload is either (a) a UI / app-layer retry that should have been deduplicated upstream, or (b) an operator confusion worth investigating. Cross-account duplicate uploads are allowed (per-account scope is the MVP rule; sub-doc tracks the post-MVP cross-account rule). Subject is the **existing** statement_uploads row. Payload (`after_state`): `rejection_code` (always `DUPLICATE_HASH`), `bank_account_id`, `file_hash`, `existing_upload_id`, `existing_uploaded_at`, `attempted_filename`.

`STATEMENT_UPLOAD_REJECTED_PERMISSION` (HIGH) — emitted by `request_statement_upload` or `complete_statement_upload` when `can_perform(surface='workflow_run', action='execute')` returns DENY (or an unexpected non-ALLOW / non-STEP_UP decision). HIGH because a denied statement-upload attempt is a security signal — uploads are the entry point for every transaction the system processes, and a denied attempt either indicates an authorization-drift issue or an unauthorized access attempt. Subject is the targeted `bank_accounts` row (or `WORKFLOW_RUN` for pre-sign attempts where no specific row exists yet). Payload (`after_state`): `rejection_code` (always `PERMISSION_DENIED`), `bank_account_id`, plus the request shape that was attempted.

`STATEMENT_UPLOAD_FAILED` (MEDIUM) — body slot reserved for the API-layer Storage-failure path (e.g., Storage returns 5xx after a signed-URL upload attempt, or the completion webhook can't reach the DB). MEDIUM because failed uploads block the run from progressing. **Not emitted by B07·P01 itself** — the DB RPCs surface failures via the return envelope; the API layer (when shipped) emits this when it has to record a Storage-side failure that isn't covered by the per-RPC reject paths. Payload shape: `upload_id?`, `bank_account_id`, `failure_stage` (e.g., `signed_url_expired`, `storage_5xx`, `webhook_timeout`), `failure_detail`.

Note on legacy header entries `STATEMENT_UPLOADED` / `STATEMENT_UPLOAD_RECEIVED` / `STATEMENT_UPLOAD_PARSING_STARTED`: these are RESERVED. `STATEMENT_UPLOADED` is a `statement_uploads.upload_status` value (the lifecycle state), not an audit action — the audit equivalent is `STATEMENT_UPLOAD_COMPLETED`. `STATEMENT_UPLOAD_RECEIVED` overlapped with `_COMPLETED` and was deprecated. `STATEMENT_UPLOAD_PARSING_STARTED` is superseded by `STATEMENT_PARSE_STARTED` (B07·P02's spec-canonical name for the UPLOADED → PARSING transition). The legacy name stays in the header for historical compatibility; B07·P02 emits `STATEMENT_PARSE_STARTED`.

`STATEMENT_PARSER_REGISTERED` (LOW) — emitted by `public.register_statement_parser` after a successful UPSERT into `statement_parser_registry`. The parser registry is the single source of truth for which Python parser module the workflow engine dispatches for a given `(provider, file_format, version)`; registration is an Owner-level administrative action gated by `can_perform(surface='statement_parser_registry', action='REGISTER')` (Mitigation A — denials emit `STATEMENT_PARSER_REGISTRATION_DENIED`). LOW because parser registration is the expected administrative path; the operational risk is in *what code* the `parser_module_ref` points at (governed by code review + the static lint at `scripts/lint_no_direct_ai_imports.py` style), not in the act of registering. Subject is `STATEMENT_PARSER` (no `subject_id` — the natural-key triple lives in `after_state`). Payload (`after_state`): `provider` (e.g. `REVOLUT`), `file_format` (`CSV` / `PDF`), `version` (semver), `parser_module_ref` (dotted `package.module:callable`), `is_active`. See `register_statement_parser`.

`STATEMENT_PARSER_REGISTRATION_DENIED` (HIGH) — emitted by `public.register_statement_parser` when `can_perform` returns a non-`ALLOW` decision. HIGH because the parser registry is a privileged dispatch table — a denied attempt to mutate it is either an authorization-drift signal or an unauthorized administrative attempt and warrants investigation. Subject is `STATEMENT_PARSER`. Payload (`after_state`): `decision` (the raw can_perform decision), `provider`, `file_format`, `version`. The returned envelope shape is `{ok: false, reason: 'POLICY_DENIED', decision, audit_event_id}`. See `register_statement_parser`.

`STATEMENT_PARSE_STARTED` (LOW) — emitted by `public.start_statement_parse` when a `statement_uploads` row in status `UPLOADED` is transitioned to `PARSING` and a `statement_parse_runs` row is created at status `STARTED`. The active `(provider, file_format)` parser is looked up at start time and its version is frozen on the parse_run row so the parse_run records *which* parser actually ran (registry is allowed to evolve after start). Subject is `STATEMENT_UPLOAD` (the user-facing object being parsed); `parse_run_id` rides in `after_state`. Actor is SYSTEM (`actor_system='statement_parser'`) when called engine-side without a user, USER otherwise. The orchestrator-deferral pattern: B07·P02 ships only the SQL contract; the Python parser body (CSV decoding, Revolut column recognition, FX-pair detection) calls this RPC, then iterates rows via `record_parsed_row`, then closes via `complete_statement_parse` or `fail_statement_parse`. Payload (`before_state`): `upload_status: UPLOADED`. Payload (`after_state`): `upload_status: PARSING`, `parse_run_id`, `parser_provider`, `parser_file_format`, `parser_version`. Reject paths return `{ok:false, reason}` without emitting: `UPLOAD_NOT_IN_UPLOADED_STATE` (caller bug) and `NO_ACTIVE_PARSER` (registry hole — caller should surface the missing-parser case via Phase 08's review-issue path). See `start_statement_parse`.

`STATEMENT_PARSE_COMPLETED` (LOW) — emitted by `public.complete_statement_parse` when a parse_run in status `STARTED` transitions to `COMPLETED` and the linked upload transitions `PARSING → PARSED`. LOW because successful parse is the steady-state happy path. Subject is `STATEMENT_UPLOAD`. Payload (`before_state`): `upload_status: PARSING`. Payload (`after_state`): `upload_status: PARSED`, `parse_run_id`, `row_count` (the cumulative count of `statement_parsed_rows` for this run — emitted once per parse_run, not per row, to avoid flooding the audit log), `parser_provider`, `parser_file_format`, `parser_version`. See `complete_statement_parse`.

`STATEMENT_PARSE_FAILED` (MEDIUM) — emitted by `public.fail_statement_parse` when a parse_run transitions `STARTED → FAILED` and the linked upload transitions `PARSING → FAILED`. MEDIUM because a failed parse blocks the upload's downstream ingestion and typically requires the operator to re-upload (the partial-upload / review-issue surfacing is owned by B07·P08, not this phase). Subject is `STATEMENT_UPLOAD`. Payload (`before_state`): `upload_status: PARSING`. Payload (`after_state`): `upload_status: FAILED`, `parse_run_id`, `error_category` (enum: `MALFORMED_CSV` | `EMPTY_FILE` | `MISSING_HEADERS` | `WRONG_COLUMN_COUNT` | `UNREADABLE_ENCODING` | `UNKNOWN_PROVIDER_FORMAT` | `INTERNAL_ERROR`), `error_message` (1..2000 chars; truncated to 240 in the audit `reason` text), `rows_recorded_before_failure` (the row_count snapshot at failure — Phase 08 may use this to decide partial-recovery semantics), `parser_provider`, `parser_file_format`, `parser_version`. See `fail_statement_parse`.

Note on legacy BANK_STATEMENT_PARSED / BANK_STATEMENT_PARSE_FAILED entries (BANK_UPLOAD section): these were earlier-stage names for the parse-lifecycle events. B07·P02's spec-canonical names are `STATEMENT_PARSE_COMPLETED` / `STATEMENT_PARSE_FAILED`. The legacy `BANK_STATEMENT_*` bodies remain documented as the older shape (with `file_id`/`run_id` payload) and stay RESERVED for the historical `bank_statement_raw_schema` lifecycle; the active emitters in B07·P02 use the `STATEMENT_PARSE_*` names. `STATEMENT_PARSER_FAILED` in the `STATEMENT / INTAKE` header is also a legacy alias for `STATEMENT_PARSE_FAILED` and is RESERVED, not emitted.

`STATEMENT_PDF_OCR_STARTED` (LOW) — emitted by `public.record_pdf_ocr_started` when the Python PDF parser is about to dispatch the upload to Google Document AI (through the Privacy Gateway, B06·P02, with redaction policy applied per B06·P03 — statements carry IBANs and personal addresses). LOW because OCR start is the steady-state happy path for PDF uploads. Subject is `STATEMENT_UPLOAD`; `parse_run_id` rides in `after_state`. Actor is SYSTEM (`actor_system='statement_pdf_parser'`) when called engine-side. Storage side-effects: writes `ocr_processor_id`, `ocr_processor_version`, `ocr_started_at` onto the `statement_parse_runs` row so the audit row records *which* processor version ran. The RPC is idempotency-gated — a second call returns `{ok:false, reason:'OCR_ALREADY_STARTED'}` and no second audit. CSV runs never emit this event (the RPC rejects `parser_file_format != PDF`). Payload (`after_state`): `parse_run_id`, `ocr_processor_id` (Document AI processor resource path, e.g. `projects/.../locations/eu/processors/<id>`), `ocr_processor_version`. See `record_pdf_ocr_started`.

`STATEMENT_PDF_OCR_COMPLETED` (LOW) — emitted by `public.record_pdf_ocr_completed` when Document AI returns a successful response and the orchestrator records page-count + cost on the `statement_parse_runs` row. LOW because OCR completion is the steady-state happy path. Subject is `STATEMENT_UPLOAD`. The orchestrator is expected to **also** call `public.record_ai_usage` (B06·P07) immediately after this RPC so the (page_count, cost_cents) pair lands in the cross-tier `ai_usage_records` ledger — that side of the contract is separate so the OCR run and the gateway-invocation cost row each own their own lifecycle. Payload (`after_state`): `parse_run_id`, `ocr_processor_id`, `ocr_processor_version`, `page_count` (Document AI page count; bills per page), `cost_cents` (estimated cost in cents based on processor pricing tier — see Stage-4 cost-tracking sub-doc for the formula), `ocr_artifact_path` (Processing-zone path where the raw Document AI response was persisted as an `AI_PAYLOAD` artifact per B04·P06). Idempotency-gated against `OCR_NOT_STARTED` / `OCR_ALREADY_COMPLETED`. See `record_pdf_ocr_completed`.

`STATEMENT_PDF_OCR_FAILED` (MEDIUM) — emitted by `public.record_pdf_ocr_failed` for any Document AI failure mode. MEDIUM (not HIGH on every event) because OCR failures span a wide blast radius from transient 5xx blips to persistent unsupported-PDF rejects; the `transient` flag in the payload distinguishes. The RPC deliberately **does not** change parse_run status — the caller (orchestrator) reads `transient` and decides retry (B03·P08 retry policy applies for `transient: true`) or follows up with `public.fail_statement_parse` to terminate the parse (for `transient: false`). Subject is `STATEMENT_UPLOAD`. Payload (`after_state`): `parse_run_id`, `ocr_processor_id`, `ocr_processor_version`, `error_category` (enum: `DOC_AI_5XX` | `DOC_AI_4XX` | `EMPTY_EXTRACTION` | `UNSUPPORTED_PDF` | `CORRUPTED_FILE` | `CREDENTIALS_MISSING` | `TIMEOUT`), `transient` (boolean), `error_message` (1..2000 chars; truncated to 200 in the audit `reason` text). Empty extraction (`EMPTY_EXTRACTION`) is the spec's "Document AI returned no tables" path — the review-issue suggesting the user re-export as CSV is owned by B07·P08, not this RPC. See `record_pdf_ocr_failed`.

`STATEMENT_PDF_PARSE_LOW_CONFIDENCE_ROW` (LOW) — emitted by `public.flag_low_confidence_parsed_row` once per LOW-confidence parsed row. Per spec, the orchestrator decides which rows are LOW by comparing each `extraction_confidence_per_field` value against the per-business threshold (`business_ai_config.pdf_low_confidence_threshold`, default `0.85`, CHECK in `[0.50, 1.00]`); rows where *any* required field falls below the threshold are written with `parser_confidence='LOW'` via `record_pdf_parsed_row`, then this RPC is called once per such row to record the audit signal. LOW because per-row low-confidence flagging is bounded by the LOW subset (not every parsed row, which would flood the audit log); the RPC rejects HIGH rows with `{ok:false, reason:'ROW_NOT_LOW_CONFIDENCE'}`. Subject is `STATEMENT_UPLOAD`. Payload (`after_state`): `parsed_row_id`, `parse_run_id`, `statement_upload_id`, `source_row_index`, `fields_below_threshold` (jsonb array of field names — must be non-empty), `threshold` (numeric, what was used at flagging time so historical audits remain interpretable when the per-business threshold changes). Downstream phases (especially B07·P04 normalization and B07·P08 partial-upload handling) consult this audit signal + the `parser_confidence` column to route LOW rows through additional review. See `flag_low_confidence_parsed_row`.

Note on the orchestrator-deferral pattern (B07·P03): the Python PDF parser at `cyprus_bookkeeping_api.parsers.revolut_pdf:parse` calls `record_pdf_ocr_started` → external Document AI HTTP via Privacy Gateway → `record_pdf_ocr_completed` → `record_ai_usage` → N × `record_pdf_parsed_row` → M × `flag_low_confidence_parsed_row` → `complete_statement_parse`. On persistent OCR failure: `record_pdf_ocr_failed(transient=false)` → `fail_statement_parse`. On transient OCR failure: `record_pdf_ocr_failed(transient=true)` + caller backs off (B03·P08 retry).

`TRANSACTION_NORMALIZED` (LOW) — emitted by `public.record_normalized_transaction` once per row written to the `statement_normalized_rows` staging table. Subject is `STATEMENT_UPLOAD`; per-row volume is bounded by upload size (typically tens to a few hundred rows per upload, not flooding-scale, so per-row audit is acceptable here — the spec calls out batch-aggregation as an optional future optimization). Actor is SYSTEM (`actor_system='statement_normalizer'`) when called engine-side. Per spec §Phase-04: this phase does NOT insert into `transactions`; it returns NormalizedTransaction[] (here materialised as `statement_normalized_rows`) for Phase 05's dedup tool. Payload (`after_state`): `normalized_row_id`, `normalization_run_id`, `parsed_row_ids` (jsonb array — length 1 for normal rows, 2 for FX-pair merged rows), `transaction_date`, `amount`, `currency`, `direction` (IN / OUT — BOTH not valid here per CHECK), `transaction_type_candidate` (transaction_type_enum text — e.g. `FX_EXCHANGE`, `OUT_EXPENSE`, etc.), `source_row_hash` (sha256 hex, deterministic per spec Block 04 Phase 01 helpers), `transaction_fingerprint` (sha256 hex over date+amount+currency+cleaned description — used as Phase 05's dedup key), `normalization_confidence` (`HIGH` / `LOW`; PDF rows with `parser_confidence='LOW'` from B07·P03 propagate LOW here), `extraction_method` (`DETERMINISTIC` / `AI_FALLBACK`; AI_FALLBACK fires when deterministic counterparty patterns don't match and the Tier-2 LLM via B06·P02 was consulted). See `record_normalized_transaction`.

`STATEMENT_NORMALIZATION_FAILED` (MEDIUM) — emitted by `public.record_normalization_failed` per parsed row that the normalizer rejected. MEDIUM because per-row normalization failures indicate the row couldn't be coerced into the canonical NormalizedTransaction shape — most failures (ZERO_AMOUNT, INVALID_DATE, INVALID_CURRENCY) point at the source file having a row the parser was lenient about but normalization can't accept, and the row will not flow downstream. The RPC deliberately does **not** transition the normalization_run to FAILED — that's a per-run decision the caller makes via `fail_statement_normalization` (used when the whole run is unrecoverable, distinct from per-row tolerable failures). Subject is `STATEMENT_UPLOAD`. Payload (`after_state`): `normalization_run_id`, `parsed_row_id`, `source_row_index` (the row number in the original parsed file — survives even when the parsed row was filtered), `reason` (enum: `ZERO_AMOUNT` | `INVALID_DATE` | `INVALID_CURRENCY` | `INVALID_AMOUNT_FORMAT` | `MISSING_REQUIRED_FIELD` | `UNPAIRED_FX_LEG` | `INTERNAL_ERROR`), `error_message` (1..2000 chars; truncated to 200 in `reason`). See `record_normalization_failed`.

`STATEMENT_NORMALIZATION_FX_PAIR_RESOLVED` (LOW) — emitted by `public.record_fx_pair_resolved` once per FX exchange line that was successfully collapsed from two parsed rows (one OUT in source currency, one IN in target currency) into a single normalized row with `transaction_type_candidate='FX_EXCHANGE'` and `fx_paired_legs` JSONB carrying both legs + rate + fee. LOW because successful FX-pair resolution is the expected outcome for Revolut FX export lines (the unhappy path is an unpaired leg, which lands as `STATEMENT_NORMALIZATION_FAILED` with `reason='UNPAIRED_FX_LEG'`). The RPC validates the normalized row's `transaction_type_candidate` is `FX_EXCHANGE` and that both leg parsed_row_ids are present in the row's `parsed_row_ids` array (defensive sanity check). Subject is `STATEMENT_UPLOAD`. Payload (`after_state`): `normalization_run_id`, `normalized_row_id`, `parsed_row_id_out`, `parsed_row_id_in`, `fx_paired_legs` (verbatim — the spec-canonical shape with `leg_out: {currency, amount}`, `leg_in: {currency, amount}`, `rate`, optional `fee_currency`/`fee_amount`). See `record_fx_pair_resolved`.

`STATEMENT_NORMALIZATION_AI_FALLBACK_USED` (LOW) — emitted by `public.record_ai_fallback_used` once per parsed row where the deterministic extraction pattern didn't match and the normalizer fell back to a Tier-2 LLM call (via B06·P02's Privacy Gateway). LOW because AI fallback for counterparty extraction is the expected behaviour when bank descriptions don't match the deterministic regex catalogue; the operational signal is the *rate* of fallback (tracked via `ai_fallback_count` on the run), not individual events. The Tier-2 LLM call itself produces its own gateway audit (`AI_GATEWAY_INVOKED` from B06·P02); this event is the *normalizer's* signal that fallback was needed, distinct from the gateway-side invocation row. `fallback_kind` is currently `COUNTERPARTY_EXTRACTION` only — the enum is text-based so additional kinds can be added without an ALTER TYPE migration. Subject is `STATEMENT_UPLOAD`. Payload (`after_state`): `normalization_run_id`, `parsed_row_id`, `fallback_kind` (`COUNTERPARTY_EXTRACTION`), `model_ref` (optional — the LLM model identifier used, e.g. `local-llm-mistral-7b@1.0`). See `record_ai_fallback_used`.

Note on the orchestrator-deferral pattern (B07·P04): the Python normalizer at (likely) `cyprus_bookkeeping_api.normalizers.bank_row:normalize` reads parsed rows from `statement_parsed_rows`, applies description cleanup / date parsing / counterparty extraction / ISO-4217 validation / sha256 hashing (`sourceRowHash` + `transactionFingerprint` from B04·P01), detects FX pairs, calls `start_statement_normalization` → N × `record_normalized_transaction` (one per row, where FX pairs result in one normalized row from two parsed rows) → M × `record_fx_pair_resolved` → K × `record_ai_fallback_used` → P × `record_normalization_failed` → `complete_statement_normalization`. Encryption of `counterparty_identifier_*` happens orchestrator-side using B05·P05 helpers (the RPC accepts already-encrypted bytea + pre-masked text). The actual insert into `transactions` is Phase 05's job — this phase only stages.

`TRANSACTION_DEDUP_NEW` (LOW) — emitted by `public.classify_and_record_dedup_row` when a normalized row is classified as `NEW` (no existing match by source_row_hash or fingerprint) and a fresh `transactions` row is inserted with `dedup_status='NEW'`. LOW because NEW is the steady-state path for clean uploads. Subject is `STATEMENT_UPLOAD`. The dedup engine applies the direction sign at insert time: `statement_normalized_rows.amount` is the absolute value (CHECK > 0), while `transactions.amount` is signed per `transactions_amount_direction_chk` (OUT < 0, IN > 0). Payload (`after_state`): `dedup_run_id`, `normalized_row_id`, `transaction_id` (the new row), `dedup_status='NEW'`, `source_row_index`, `transaction_fingerprint`, `signed_amount`. See `classify_and_record_dedup_row`.

`TRANSACTION_DEDUP_EXACT_DUPLICATE` (LOW) — emitted when a normalized row matches an existing `transactions` row on `(business_id, bank_account_id, source_row_hash)`. The candidate row is silently rejected (no new `transactions` row, no `review_issue`). LOW because exact duplicates are an expected outcome of statement re-uploads / overlapping period uploads — the test of correctness is that an identical re-upload produces zero new transactions. Two detection paths exist: (a) the strict pass against `transactions` (the normal cross-statement duplicate path), and (b) the within-batch fallback against `statement_dedup_row_classifications` (rare; catches the duplicate-of-a-duplicate within the same dedup batch where the prior in-batch row was itself a duplicate so no `transactions` row was inserted). The `matched_within_batch` flag distinguishes within-this-upload duplicates from cross-statement duplicates by comparing `matched_transaction.statement_upload_id` against the dedup run's `statement_upload_id`. Subject is `STATEMENT_UPLOAD`. Payload: `dedup_run_id`, `normalized_row_id`, `matched_transaction_id`, `matched_within_batch` (boolean), `dedup_status='DUPLICATE_EXACT'`, `source_row_index`, `transaction_fingerprint`. See `classify_and_record_dedup_row`.

`TRANSACTION_DEDUP_PROBABLE_DUPLICATE` (MEDIUM) — emitted when a normalized row matches an existing `transactions` row on `(business_id, bank_account_id, transaction_fingerprint)` AND the date and amount fall within the soft-dedup tolerance window (default `soft_window_days=30`, `amount_tolerance_cents=1` — the 1-cent rule absorbs typical bank rounding). Creates a `review_issues` row with `issue_type='bank_pipeline.duplicate_probable'`, `issue_group='POSSIBLE_WRONG_MATCH'`, `severity='MEDIUM'`, `status='OPEN'`. MEDIUM because the user must resolve (confirm-as-new / mark-as-duplicate / edit-and-confirm — B14 actions) before the row becomes a transaction. The review issue's `transaction_id` points at the **matched** existing transaction (satisfies `review_issue_at_least_one_entity_chk`); the candidate row sits in `card_payload_json`. Subject is `STATEMENT_UPLOAD`. Payload: `dedup_run_id`, `normalized_row_id`, `review_issue_id`, `matched_transaction_id`, `dedup_status='DUPLICATE_PROBABLE'`, `source_row_index`, `transaction_fingerprint`. **Naming reconciliation**: the spec uses `TRANSACTION_DEDUP_POSSIBLE_DUPLICATE`; the `transaction_dedup_status_enum` standardised on `DUPLICATE_PROBABLE` (more analytical weight than "possible"). The audit event aligns with the enum. `TRANSACTION_DEDUP_POSSIBLE_DUPLICATE` is RESERVED as the spec's older name. See `classify_and_record_dedup_row`.

`TRANSACTION_DEDUP_NEEDS_REVIEW` (MEDIUM) — emitted when a normalized row's `transaction_fingerprint` matches an existing transaction BUT the date is outside `soft_window_days` OR the amount differs by more than `amount_tolerance_cents`. Same review-issue routing as PROBABLE but with `issue_type='bank_pipeline.duplicate_needs_review'`. Distinguished from PROBABLE so the review queue can prioritise NEEDS_REVIEW (the analytically harder case) ahead of PROBABLE (almost-certainly-the-same row). Subject is `STATEMENT_UPLOAD`. Payload shape mirrors `TRANSACTION_DEDUP_PROBABLE_DUPLICATE`. See `classify_and_record_dedup_row`.

`STATEMENT_DEDUP_BATCH_COMPLETED` (LOW) — the only batch-level event in the dedup family. Emitted by `public.complete_statement_dedup` when the dedup run transitions STARTED → COMPLETED. LOW because batch completion is the steady-state outcome. Subject is `STATEMENT_UPLOAD`. Payload (`after_state`): `dedup_run_id`, `new_count`, `exact_duplicate_count`, `probable_duplicate_count`, `needs_review_count`. The four counts let downstream phases (especially the statement_uploads → ACCEPTED transition gated by Phase 06 evidence generation, and Phase 09 event-driven workflow triggers) read the dedup batch outcome without scanning the per-row events. See `complete_statement_dedup`.

Note on the orchestrator-deferral pattern (B07·P05): the Python dedup tool wraps `start_statement_dedup` → for each `statement_normalized_rows` row in the upload, calls `classify_and_record_dedup_row` (the RPC handles transactions/review_issues writes, sign correction, and idempotency via the `(dedup_run_id, normalized_row_id)` UNIQUE on `statement_dedup_row_classifications`) → `complete_statement_dedup`. Block 03 Phase 03 tool registration with dedup-key over `statement_upload_id` lives in B07·P07; the partial UNIQUE index on `(statement_upload_id) WHERE status='STARTED'` enforces server-side idempotency for `start_statement_dedup`. `statement_uploads.upload_status` advance to `ACCEPTED` is Phase 06's responsibility (gated by evidence generation), not this phase.

`EVIDENCE_PDF_GENERATED` (LOW) — emitted by `public.record_evidence_pdf_generated` when an `evidence_pdfs` row is inserted with `generated_from_transaction_version=1` (first generation). LOW because per-NEW-transaction PDF generation is the steady-state path. Subject is `EVIDENCE_PDF` (the evidence_pdfs row id). Per spec §Principle 2: the PDF is rendered FROM the structured `transactions` row, never the reverse — the structured row stays canonical. Idempotent via UNIQUE `(transaction_id, file_hash)` from B04·P02: replay with the same content hash returns `{idempotent_replay: true, evidence_pdf_id}` without a second audit event. Caller computes the sha256 via B04·P01's `hashFile` and writes the PDF bytes to Raw Upload at `{org_id}/{business_id}/evidence_pdf/{file_id}` orchestrator-side; this RPC just records the row + emits the audit. Payload (`after_state`): `evidence_pdf_id`, `transaction_id`, `file_id`, `file_hash` (sha256 hex), `version` (always 1 for this event). See `record_evidence_pdf_generated`.

`EVIDENCE_PDF_REGENERATED` (LOW) — emitted by `public.record_evidence_pdf_generated` when `version > 1` (explicit re-generation path). Spec §Snapshot semantics: editing a transaction does NOT auto-regenerate the PDF — the structured row is canonical (Principle 2); re-generation is an explicit user action that creates a new versioned row leaving older versions intact for audit traceability. The UNIQUE `(transaction_id, file_hash)` still prevents content-identical duplicates (re-generating without any field changes produces the same file_hash and is treated as idempotent replay). Payload identical shape to `EVIDENCE_PDF_GENERATED` with `version >= 2`. See `record_evidence_pdf_generated`.

`EVIDENCE_PDF_GENERATION_FAILED` (HIGH) — emitted by `public.record_evidence_pdf_generation_failed` when the Python renderer (Puppeteer / WeasyPrint / ReactPDF) fails on a specific transaction. HIGH because every transaction must have a human-readable evidence artefact for audit/accountant access without DB queries — a missing PDF is a compliance gap. Creates a `review_issues` row with `issue_type='bank_pipeline.evidence_pdf_generation_failed'`, `issue_group='MISSING_DOCUMENTS'` (the PDF *is* the missing document), `severity='HIGH'`, `status='OPEN'`, `card_content_tier_used='NONE'` (static template). Per spec: failure on one PDF does NOT block the rest of the bulk batch — the orchestrator continues generating the remaining NEW transactions' PDFs and the failed one surfaces as a HIGH review issue for operator retry. Subject is `TRANSACTION` (the user's mental model is "this transaction is missing its PDF"). Payload (`after_state`): `transaction_id`, `review_issue_id`, `error_category` (text — Python-side category like `RENDERER_CRASH`, `STORAGE_WRITE_FAILED`, `TEMPLATE_PARSE_ERROR`), `error_message` (1..2000 chars; truncated to 200 in `reason`). See `record_evidence_pdf_generation_failed`.

`STATEMENT_UPLOAD_ACCEPTED` (LOW) — emitted by `public.accept_statement_upload` when the upload transitions PARSED → ACCEPTED. LOW because acceptance is the steady-state terminator of the bank-statement-pipeline. The transition is gated by **complete evidence coverage**: all transactions on the upload with `dedup_status='NEW'` must have at least one `evidence_pdfs` row. EXACT / PROBABLE / NEEDS_REVIEW transactions are excluded — EXACT has no transactions row at all (silent reject from B07·P05), and PROBABLE / NEEDS_REVIEW are pending user resolution (no transactions row yet either). Idempotent: re-calling on an already-ACCEPTED upload returns `{ok:true, idempotent_replay:true}` without a second audit. Subject is `STATEMENT_UPLOAD`. Payload (`before_state`): `upload_status='PARSED'`. Payload (`after_state`): `upload_status='ACCEPTED'`, `new_tx_count` (NEW transactions expected to have PDFs), `evidence_pdf_count` (DISTINCT transactions with at least one evidence_pdfs row — equal to new_tx_count on success). See `accept_statement_upload`.

Note on the orchestrator-deferral pattern (B07·P06): the Python evidence PDF generator at (likely) `cyprus_bookkeeping_api.evidence.generate_pdf:generate` reads a `transactions` row, renders the PDF (per Stage-4 template sub-doc), computes sha256 via `hashFile` (B04·P01), writes bytes to Raw Upload, then calls `record_evidence_pdf_generated`. The bulk operation iterates over all `NEW` transactions for a statement upload in parallel (bounded concurrency per Stage-4 perf sub-doc). After all NEW transactions complete (success or failure), the orchestrator calls `accept_statement_upload` to attempt the PARSED → ACCEPTED transition — which gates on evidence coverage. The follow-up re-entry path for resolved duplicates (a NEEDS_REVIEW row that an operator later confirms via B14's confirm-as-new action) invokes the same RPC for that specific transaction with its own dedup key — the UNIQUE `(transaction_id, file_hash)` handles the idempotency.

`INGESTION_PHASE_STARTED` (LOW) — emitted by `public.record_ingestion_phase_started` when the workflow engine enters the INGESTION phase for a specific `statement_uploads` row. LOW because phase entry is the steady-state path. The RPC validates the entry gate (`bank_pipeline.ingestion_entry`) before emitting — refuses with `{ok:false, reason:'ENTRY_GATE_NOT_PASSED', gate_envelope}` if `upload_status <> 'UPLOADED'`. Subject is `STATEMENT_UPLOAD`; `workflow_run_id` rides in `after_state`. Per spec: the INGESTION phase is shared between OUT_MONTHLY and IN_MONTHLY runs (B03·P10's shared-phase coordination ensures it runs once per upload even when both workflows target the same upload). Payload (`after_state`): `workflow_run_id`, `statement_upload_id`, `entry_gate` (the full evaluator envelope). See `record_ingestion_phase_started`.

`INGESTION_PHASE_COMPLETED` (LOW) — emitted by `public.record_ingestion_phase_completed` when the workflow engine attempts the INGESTION phase exit transition. Validates the exit gate (`bank_pipeline.ingestion_exit`) which requires (a) `upload_status='ACCEPTED'` (set by `accept_statement_upload` from B07·P06 only after every NEW transaction has its evidence_pdfs row), and (b) belt-and-suspenders re-verification of the same coverage. Refuses with `{ok:false, reason:'EXIT_GATE_NOT_PASSED', gate_envelope}` when the gate fails. Subject is `STATEMENT_UPLOAD`. Payload (`after_state`): `workflow_run_id`, `statement_upload_id`, `exit_gate` (the full evaluator envelope with `new_tx_count`, `evidence_pdf_count`). See `record_ingestion_phase_completed`.

`INGESTION_PHASE_HOLDING` (MEDIUM) — emitted by `public.record_ingestion_phase_holding` when one of the five INGESTION tools (`bank_pipeline.parse_csv` / `parse_pdf` / `normalize` / `dedupe` / `generate_evidence_pdfs`) holds the phase due to a non-recoverable per-tool failure that requires user action via B14 (e.g., a CSV header mismatch the parser can't auto-recover from). MEDIUM because the phase stalls until operator intervention. The RPC validates `holding_at_tool` against the closed set of five INGESTION tools (rejects unknown tool names with `invalid_parameter_value`). Per spec §B03·P05 HOLD semantics: the phase doesn't fail outright — it pauses at the failing tool, raises a review_issue via the tool's own failure handler, and waits for B14 user action to resume. Subject is `STATEMENT_UPLOAD`. Payload (`after_state`): `workflow_run_id`, `statement_upload_id`, `holding_at_tool` (one of the five tool names), `hold_reason` (1..2000 chars; truncated to 200 in audit `reason`). See `record_ingestion_phase_holding`.

Note on the INGESTION tool/gate registrations (B07·P07): the 5 tools register with `register_tool` and the 2 gates with `register_gate` (both from B03·P03). Gate evaluators back the registry by naming convention: `evaluate_ingestion_entry(statement_upload_id)` and `evaluate_ingestion_exit(statement_upload_id)` — both return `{passed, reason?, ...}` envelopes. The phase-event RPCs (`record_ingestion_phase_started` / `_completed`) gate-check before emitting, so audit events accurately reflect gate-allowed transitions. The 5 tools share `dedup_key_generator_ref='statement_upload_id'` — per-upload idempotency means an engine retry on the same upload lands on the existing in-progress run state from the B07·P02–P06 partial unique indexes. `bank_pipeline.parse_pdf` is the only tool with `ai_tier=EXTERNAL_LLM` (Document AI is Tier 3 through B06·P02's Privacy Gateway); `bank_pipeline.normalize` declares `ai_tier=NONE` even though it may dispatch Tier-2 LLM counterparty fallback — the LLM call shows up as its own AI gateway invocation, not as the normalize tool's primary tier.

`STATEMENT_PARTIAL_UPLOAD_DETECTED` (HIGH) — emitted by `public.record_partial_upload_detected` when the parser detects a partial / truncated upload (CSV truncation signals, PDF Document AI low-confidence cells, missing pages relative to declared period). HIGH because a partial upload means downstream periods are missing rows the user thinks are there; blocks finalization until resolved (B14 resolution actions: re-upload complete file, accept-as-is, contact support). The RPC appends to `statement_uploads.parse_warnings` (jsonb array of warning objects describing what the parser skipped or couldn't read) AND creates a HIGH `review_issues` row with `issue_type='bank_pipeline.partial_upload'`, `issue_group='MISSING_DOCUMENTS'`, `status='OPEN'`, `card_content_tier_used='NONE'`. **Anchor constraint**: review_issues' `transaction_id` NOT NULL via `review_issue_at_least_one_entity_chk` means the orchestrator must call this RPC *after* at least one transaction has been inserted (typically post-dedupe); the RPC returns `{ok:false, reason:'NO_TRANSACTIONS_TO_ANCHOR'}` if zero transactions exist for the upload. Anchor defaults to the lowest-`source_row_index` transaction. Idempotent on `(statement_upload_id, issue_type='bank_pipeline.partial_upload')`. Subject is `STATEMENT_UPLOAD`. Payload (`after_state`): `statement_upload_id`, `review_issue_id`, `anchor_transaction_id`, `parse_warning_summary` (verbatim jsonb the caller supplied). See `record_partial_upload_detected`.

`STATEMENT_ROW_OUTSIDE_DECLARED_PERIOD` (MEDIUM) — emitted by `public.record_row_outside_declared_period` once per transaction whose `transaction_date` falls outside the upload's `declared_period_start`..`declared_period_end` range. MEDIUM because the row IS still inserted into `transactions` (per spec — flagging is advisory; the user resolves via confirm-and-include or exclude-from-period actions, not via deletion). Creates `review_issues` with `issue_type='bank_pipeline.row_outside_declared_period'`, `issue_group='POSSIBLE_WRONG_MATCH'`, `severity='MEDIUM'`, `transaction_id` set to the offending row (natural anchor — no anchor lookup needed). Defensive: if the row's date is actually within the period, the RPC returns `{ok:false, reason:'ROW_WITHIN_DECLARED_PERIOD'}` without creating an issue (caller bug guard). Idempotent on `(transaction_id, issue_type)`. Subject is `TRANSACTION`. Payload: `transaction_id`, `statement_upload_id`, `review_issue_id`, `transaction_date`, `declared_period_start`, `declared_period_end`. See `record_row_outside_declared_period`.

`STATEMENT_DECLARED_PERIOD_MISMATCH` (HIGH) — emitted by `public.record_declared_period_mismatch` when *every* parsed row falls outside the declared period (typically the user declared the wrong month). HIGH because the upload's data doesn't match what the user said it was. Creates HIGH `review_issues` with `issue_type='bank_pipeline.declared_period_mismatch'`, `issue_group='NEEDS_CONFIRMATION'` (the user must re-declare the period and re-trigger ingestion, or accept the data for a different period). The RPC sanity-checks the counts (`outside_period_count` must equal `total_row_count` and `total_row_count > 0` — otherwise returns `NOT_ALL_OUTSIDE_PERIOD`) so callers can't fire this audit when the all-outside condition doesn't actually hold. Anchor constraint same as partial-upload: defaults to lowest-`source_row_index` transaction. Idempotent on `(statement_upload_id, issue_type)`. Subject is `STATEMENT_UPLOAD`. Payload (`after_state`): `statement_upload_id`, `review_issue_id`, `total_row_count`, `outside_period_count`, `declared_period_start`, `declared_period_end`. See `record_declared_period_mismatch`.

`TRANSACTION_EXCLUDED_FROM_PERIOD` (LOW) — emitted by `public.exclude_transaction_from_period` when an operator (via B14's "exclude-from-this-period" resolution action) opts to mark a transaction as excluded from the declared period. LOW because exclusion is the steady-state resolution path for legitimate out-of-period rows (e.g., an early-cut March transaction that landed on the April statement). The row is **not destroyed** per spec — sets `transactions.period_excluded_at = clock_timestamp()` and otherwise leaves the row intact, so the audit trail of which transactions an operator chose to exclude is preserved. Idempotent: re-calling on an already-excluded transaction returns `{ok:true, idempotent_replay:true, period_excluded_at}` without a second audit. Subject is `TRANSACTION`. Payload (`after_state`): `transaction_id`, `statement_upload_id`, `period_excluded_at`, `exclusion_reason` (operator-supplied; 1..2000 chars, truncated to 200 in audit `reason`). See `exclude_transaction_from_period`.

Note on the orchestrator-deferral pattern (B07·P08): the Python parsers and normalizer detect partial / period signals as part of their primary work (per spec — "Partial-upload detection is co-located inside the registered tools. There is no separate `bank_pipeline.detect_partial_upload` tool"). After detection, they call into B07·P08 RPCs: parser detects truncation → set parse_warnings via `record_partial_upload_detected` (deferred until ≥1 transaction exists); normalizer computes each row's date vs declared period → calls `record_row_outside_declared_period` per outlier; orchestrator aggregates counts and calls `record_declared_period_mismatch` once if all outside. The helper `get_statement_upload_preview(statement_upload_id) → jsonb` returns the upload's `{first/last_transaction_date, total_transaction_count, outside_period_count, partial_upload_warning_count}` for Block 14/16's UX preview hook. Resolution actions: B14's confirm-and-include is "just resolve the review_issue" (no SQL side-effect); `exclude_transaction_from_period` is the explicit exclude action.

`STATEMENT_UPLOAD_EVENT_EMITTED` (LOW) — emitted by `public.emit_statement_upload_completed_event` once per outbox row inserted into `statement_upload_events_outbox`. LOW because event emission is the steady-state path triggered by every successful statement upload completion. Per spec § Emission point: "Emission and the row commit are in the same transaction so partial states are impossible" — the RPC INSERTs the outbox row + emits this audit in a single transaction. Per-upload idempotency via UNIQUE `(statement_upload_id)` on the outbox table: re-emitting on the same upload returns `{ok:true, idempotent_replay:true, event_id}` with the existing event_id, no second audit. Subject is `TRIGGER_EVENT` (with `subject_id = event_id`). Payload (`after_state`) carries the full event schema per spec: `event_id`, `event_kind='STATEMENT_UPLOAD_COMPLETED'`, `statement_upload_id`, `bank_account_id`, `declared_period_start`, `declared_period_end`, `file_format`, `provider`, `actor_user_id`. See `emit_statement_upload_completed_event`.

`STATEMENT_UPLOAD_EVENT_CONSUMED` (LOW) — emitted by `public.consume_statement_upload_completed_event` once per outbox row marked CONSUMED (the consumer side wraps this RPC in B03·P09's Python loop). LOW because consumption is the steady-state path. The RPC creates `workflow_runs` for each enabled workflow type (OUT_MONTHLY + IN_MONTHLY by default; disabled types are skipped per the `business_workflow_config.enabled_phases='[]'` convention), then records the event in `trigger_events_processed` (PK on `event_id text` provides cross-call replay protection). Each created run has `trigger_kind='EVENT'`, `trigger_event_id=event_id::text` (satisfies `wr_trigger_kind_event_id_coupling` CHECK), `status='CREATED'`, `principal_snapshot=(actor_user_id, event_id, statement_upload_id)`. Subject is `TRIGGER_EVENT`. Payload (`after_state`): `event_id`, `statement_upload_id`, `created_run_ids` (array — may be empty when both workflow types are disabled), `workflow_types_enabled`, `out_disabled`, `in_disabled`. When both types are disabled the event still marks CONSUMED and writes to `trigger_events_processed` so the consumer doesn't infinitely retry — the empty `created_run_ids` is the correct semantics for "user has opted out of both workflows on this business". See `consume_statement_upload_completed_event`.

`STATEMENT_UPLOAD_EVENT_REPLAY_NOOP` (LOW) — emitted by `public.consume_statement_upload_completed_event` when the event is already in `trigger_events_processed` (a prior consume already created the runs). Per spec § Replay protection: "re-emitting the same event_id is a no-op (the runs are already created)". LOW because replay is the expected behavior under at-least-once delivery semantics (Block 03 Phase 09's redelivery, handler crashes, message-broker retries). Subject is `TRIGGER_EVENT`. Payload (`after_state`): `event_id`, `created_run_ids` (the runs from the prior consume, returned again for caller's convenience). See `consume_statement_upload_completed_event`.

`STATEMENT_UPLOAD_EVENT_HANDLER_FAILED` (MEDIUM) — emitted by `public.record_statement_upload_event_handler_failed` when the consumer's Python handler crashes or fails mid-processing. MEDIUM because a failed event handler stalls the workflow trigger for that upload until requeued; manual-trigger fallback remains available to the user via Block 03 Phase 09. Marks the outbox row `status='FAILED'` with `last_error_category` + `last_error_message`. Does NOT delete the outbox row or affect `trigger_events_processed` (no run creation means no replay-protection row), so the orchestrator can flip status back to PENDING for redelivery. Subject is `TRIGGER_EVENT`. Payload (`after_state`): `event_id`, `error_category` (free-text — examples: `CONSUMER_CRASH`, `WORKFLOW_ENGINE_DOWN`, `BUSINESS_CONFIG_LOOKUP_FAILED`), `error_message` (1..2000 chars; truncated to 200 in audit `reason`). See `record_statement_upload_event_handler_failed`.

Note on the producer/consumer split (B07·P09): Block 07 Phase 09 is the **producer** (emit RPC + outbox table); Block 03 Phase 09 is the **consumer** (the Python loop that polls the outbox and calls the consume RPC; the manual-trigger UI surface). The consume RPC itself is SQL (shipped here so the lifecycle is testable), but the Python wrapper that schedules consumption / handles retries / exposes the manual trigger lives in B03·P09 entirely. The outbox pattern ensures emission and the `statement_uploads` row commit are atomic in the same transaction, while the consume side runs in a separate transaction for failure isolation. `trigger_events_processed` (with PK on `event_id text`) provides cross-call replay protection independent of outbox state.

`PIPELINE_FIXTURE_RAN` (LOW) — emitted by `public.record_pipeline_fixture_ran` once per CI invocation of a pipeline regression fixture from `pipeline_fixtures` (B07·P10 seeds 10 fixtures: 8 CSV + 2 PDF — see registry). LOW because fixture runs are the CI heartbeat. Rejects with `FIXTURE_NOT_FOUND` for unknown names and `FIXTURE_REMOVED` for fixtures with `removed_at NOT NULL` (spec: "Adding a new fixture is easy; removing one requires a documented reason"). Subject is `WORKFLOW_RUN` (loose semantic; pipeline_fixture_runs.id is the actual subject_id). Payload (`after_state`): `fixture_run_id`, `fixture_name`, `test_run_id` (caller-supplied — CI run / commit SHA), `format` (`CSV` / `PDF`). See `record_pipeline_fixture_ran`.

`PIPELINE_FIXTURE_PASSED` (LOW) — emitted by `public.record_pipeline_fixture_passed` when a fixture's actual output matches its expected output exactly (after canonical-JSON normalization + hash equality for evidence PDFs). LOW; this is the desired outcome of every CI run. Validates the fixture_run is currently `RAN` (CHECK enforces PASSED ⇔ duration_ms NOT NULL + failure_summary IS NULL + completed_at NOT NULL). Subject is `WORKFLOW_RUN`. Payload: `fixture_run_id`, `fixture_name`, `test_run_id`, `duration_ms`. See `record_pipeline_fixture_passed`.

`PIPELINE_FIXTURE_FAILED` (HIGH) — emitted by `public.record_pipeline_fixture_failed` when a fixture's actual output diverges from its expected output. HIGH because a fixture failure indicates pipeline drift — code change broke the contract a curated golden input exercised. Per spec: "Failure blocks merge." The `failure_summary` jsonb carries the structured diff (expected vs actual for the specific fields that differ — review-issue list, dedup statuses, evidence PDF hashes, etc.) so the CI log + this audit row together give the reviewer everything needed to triage. CHECK enforces FAILED ⇔ failure_summary NOT NULL + completed_at NOT NULL. Subject is `WORKFLOW_RUN`. Payload: `fixture_run_id`, `fixture_name`, `test_run_id`, `duration_ms`, `failure_summary` (verbatim diff). See `record_pipeline_fixture_failed`.

`PIPELINE_FIXTURE_REMOVED` (MEDIUM) — emitted by `public.record_pipeline_fixture_removed` when a fixture is retired from the registry. MEDIUM because removing a regression test is a load-bearing decision (the test was catching something; removal must be documented). Per spec: "A fixture removal requires a documented entry (mirrors Block 06 Phase 04's prompt-test corpus rule)." The RPC requires `removal_reason` (1..2000 chars); subsequent `record_pipeline_fixture_ran` calls on a removed fixture return `FIXTURE_REMOVED`. Idempotent on already-removed fixtures (returns `idempotent_replay:true` with prior `removed_at`). Subject is `WORKFLOW_RUN` (subject_id NULL — the fixture name lives in payload). Payload: `fixture_name`, `removal_reason`, `removed_by_user_id`. See `record_pipeline_fixture_removed`.

Note on the orchestrator-deferral pattern (B07·P10): the SQL contract is the **registry + audit scaffolding**. The Python test runner (`runPipelineFixture(fixture_name)` per spec) wraps the full INGESTION phase, captures actual output, compares against the fixture's `expected_*.json` files, and invokes `record_pipeline_fixture_ran` → `_passed`/`_failed`. CI wiring (GitHub Actions workflow that runs the fixtures on every PR touching B07 code, blocks merge on failure, enforces 90s budget) lives in `.github/workflows/`. Filesystem fixture content (curated CSV/PDF inputs + expected outputs per fixture, recorded Document AI responses for the 2 PDF fixtures) lives under `Docs/phases/07_bank_statement_pipeline/fixtures/<name>/` per spec — Stage-4 authoring.

`AI_CONFIG_MODEL_REVERTED` (MEDIUM) — emitted when an AI model version is rolled back to a previous version. MEDIUM because a rollback indicates a quality or stability regression in the newer model version. Payload: `config_id`, `reverted_from`, `reverted_to`.

`AI_ROLLOUT_STAGE_ADVANCED` (LOW) — emitted when a canary rollout advances to the next deployment stage. LOW because stage advancement is the expected outcome of a passing canary evaluation. Payload: `config_id`, `stage_from`, `stage_to`, `percentage`.

`AI_CLASSIFICATION_CONFIG_CREATED` (LOW) — emitted when an AI classification configuration is created for a business entity. LOW because initial config creation is an expected administrative action. Payload: `config_id`, `business_entity_id`.

`AI_CLASSIFICATION_CONFIG_UPDATED` (LOW) — emitted when an AI classification configuration is updated. LOW because configuration updates are routine administrative actions. Payload: `config_id`, `changed_fields`.

`AI_MODEL_ROLLBACK_COMPLETED` (MEDIUM) — emitted when an AI model version rollback completes successfully. MEDIUM because a rollback indicates a quality or stability regression in the newer model version that required reverting to a previous known-good state. Payload: `config_id`, `rolled_back_from`, `rolled_back_to`.

`AI_CLASSIFICATION_OVERRIDDEN` (MEDIUM) — emitted by `tool_classification_override` when a reviewer overrides an AI classification result. MEDIUM because a manual override of an AI decision is a significant audit event that should be visible to supervisors and used to improve model training. Payload: `classification_result_id`, `override_vat_category`, `override_account_code`, `reviewer_id`.

`AI_TIER_ROUTED` (LOW) — emitted by `public.route_ai_call` on every routing decision that resolves to `ALLOW`, including Tier 1 (no-AI) routings. Issued once per call regardless of tier so the audit trail captures every AI tier decision. Actor is SYSTEM (`actor_system='ai_router'`) when no user is in the call context, USER otherwise. Payload (`after_state`): `tool_name`, `tier` (enum value), `tier_label` (canonical spec name), `decision`, `routing_reason` (`TIER_1_NO_AI` or `TIER_MATCHED`), `model_id`, `calling_phase`, `workflow_run_id`. See `route_ai_call`, `business_ai_config_schema`.

`AI_TIER_BLOCKED` (LOW) — emitted by `public.route_ai_call` when the tool's declared tier is opted out for the business (`business_ai_config.tier2_enabled=false` or `tier3_enabled=false`). The calling phase receives `decision=BLOCK` and decides whether to fall back, surface a review issue, or skip the operation — `route_ai_call` never silently escalates. LOW because per-business opt-out is the expected outcome of operator policy; the consequence (caller behaviour change) is owned by the calling phase. Payload: identical shape to `AI_TIER_ROUTED` with `routing_reason` ∈ {`TIER_2_DISABLED_FOR_BUSINESS`, `TIER_3_DISABLED_FOR_BUSINESS`} and `model_id=NULL`.

`AI_TIER_CONFIG_UPDATED` (LOW) — emitted by `public.update_business_ai_config` on a successful INSERT or UPDATE of a `business_ai_config` row. LOW because operator-driven config changes are routine administrative actions. Includes a `before_state` snapshot on UPDATE (NULL on first write) so reviewers can diff. Payload (`after_state`): `config_id`, `business_id`, `tier2_enabled`, `tier3_enabled`, `first_write` (boolean). See `update_business_ai_config`, `business_ai_config_schema`.

`AI_TIER_CONFIG_UPDATE_REJECTED` (MEDIUM) — emitted by `public.update_business_ai_config` on permission failure (`can_perform` returned DENY or an unexpected decision). Captures the requested tier-flag values without applying them. MEDIUM because a denied configuration change against `business_ai_config` indicates either a misconfigured role assignment or an attempted unauthorised policy mutation and warrants investigation. Payload (`after_state`): `rejection_code` (currently `PERMISSION_DENIED`), `business_id`, `requested.tier2_enabled`, `requested.tier3_enabled`.

`AI_GATEWAY_INVOKED` (LOW) — emitted by `public.ai_gateway_invoke_begin` once per invocation that successfully completes input-schema validation, payload minimization, and routing, and is about to be dispatched to a model. Every gateway invocation that reaches model dispatch is recorded by exactly one of `AI_GATEWAY_INVOKED` or (on a cache hit, Phase 09) `AI_CACHE_HIT`. Subject is the `ai_gateway_invocations` row (`subject_type = AI_GATEWAY_INVOCATION`). Actor is SYSTEM (`actor_system='ai_gateway'`) when invoked engine-side without a user context, USER otherwise. Payload (`after_state`): `invocation_id`, `tool_name`, `tier`, `tier_label`, `model_id`, `calling_phase`, `workflow_run_id`. See `ai_gateway_invoke_begin`, `ai_gateway_invocations`.

`AI_GATEWAY_VALIDATION_FAILED` (MEDIUM) — emitted by `public.ai_gateway_invoke_begin` when the caller's input fails the tool's declared `input_schema`. The invocation row is created with terminal status `COMPLETED_SCHEMA_VIOLATION_INPUT` and no model dispatch is attempted. MEDIUM because input-schema violations indicate either a caller bug or a contract drift between tool registration and call sites, and they should not happen in steady state. Payload (`after_state`): `invocation_id`, `tool_name`, `variant` (`SCHEMA_VIOLATION_INPUT`), `errors` (the schema-check error array). See `ai_gateway_invoke_begin`, `_jsonb_matches_schema`.

`AI_GATEWAY_RESPONSE_INVALID` (MEDIUM) — emitted by `public.ai_gateway_invoke_finalize` when the model's raw response fails the tool's declared `output_schema`. The invocation row transitions to terminal status `COMPLETED_SCHEMA_VIOLATION_OUTPUT`. Treated as a tool failure for B03·P08 retry/escalation logic. MEDIUM because unparseable model output is a quality signal that must be investigated (it does not fall back to best-effort parsing — see spec §Strict-validation principle). Payload (`after_state`): `invocation_id`, `tool_name`, `variant` (`SCHEMA_VIOLATION_OUTPUT`), `errors`. See `ai_gateway_invoke_finalize`, `validate_tool_output`.

Note on `AI_GATEWAY_REJECTED`: this name is listed in the AI section header but is **not** emitted by B06·P02. It remains reserved for higher-level rejections in later phases (e.g. kill-switch / quota / circuit-breaker rejections that happen before validation). B06·P02 uses the more specific `AI_GATEWAY_VALIDATION_FAILED` and `AI_GATEWAY_RESPONSE_INVALID` events. Tier-block decisions are recorded by `AI_TIER_BLOCKED` from `route_ai_call`.

`AI_REDACTION_APPLIED` (LOW) — emitted by `public.ai_gateway_invoke_begin` once per call that reaches the redaction step. Records what the redaction engine did, never the values. LOW because this is the steady-state event for every AI invocation. Payload (`after_state`): `tool_name`, `tier`, `policy_version`, `drop_count`, `mask_count`, `kept_count`, `drops_by_field_kind` (object: field_kind → count), `masks_by_field_kind` (object: field_kind → count). See `apply_redaction`, `redaction_policies`.

`AI_REDACTION_REJECTED` (HIGH) — emitted by `public.ai_gateway_invoke_begin` when the redaction engine refuses the payload because a PII pattern matched in a non-PII-declared field. The invocation row transitions to `COMPLETED_REDACTION_REJECTED` and the model is not dispatched. HIGH because a PII match in a free-text field usually indicates the caller is sending data it should have classified explicitly. Payload (`after_state`): `invocation_id`, `tool_name`, `reason` (`PII_IN_NON_DECLARED_FIELD`), `offending_field` (key name only, never the value), `matched_pattern` (`IBAN_LIKE` / `US_SSN` / `CREDIT_CARD_DIGITS` / `BANK_ACCOUNT_DIGITS`). Paired with `AI_PII_DETECTED_IN_NON_DECLARED_FIELD`.

`AI_PII_DETECTED_IN_NON_DECLARED_FIELD` (HIGH) — security signal emitted alongside `AI_REDACTION_REJECTED` whenever the PII pattern scan rejects a payload. Spec calls this severity "CRITICAL"; mapped to project severity `HIGH` because the project severity enum is `{LOW, MEDIUM, HIGH, BLOCKING}` with BLOCKING reserved for system-halt severity. This event is the auditor-facing signal that "a calling phase tried to pass PII through a non-PII field" — likely a code bug or a contract drift. Payload (`after_state`): `invocation_id`, `tool_name`, `offending_field`, `matched_pattern`. Never includes the value.

`AI_REDACTION_ALLOWLIST_DROP` (LOW) — emitted by `public.ai_gateway_invoke_begin` when one or more top-level keys in the input were dropped by payload minimization (P02 step 2) because they were not declared in the tool's `input_schema.properties`. Emitted only when `dropped_count > 0`. LOW because allowlist drops are routine when callers send slightly more than the schema declares; an unexpected key name showing up here regularly is a signal to update the tool's schema or fix the caller. Payload (`after_state`): `tool_name`, `dropped_count`, `dropped_keys` (array of key names).

`AI_REDACTION_POLICY_ACTIVATED` (LOW) — emitted by `public.activate_redaction_policy` on a successful forward activation (`is_rollback=false`) of a redaction policy version. LOW because policy activations are administrative actions. The complementary `AI_REDACTION_POLICY_ROLLED_BACK` is emitted on the same RPC when `is_rollback=true`. Payload (`before_state` / `after_state`): `active_policy_version` (previous and new), `is_rollback`. See `redaction_active_policy`, `activate_redaction_policy`.

`AI_REDACTION_POLICY_ACTIVATE_REJECTED` (MEDIUM) — emitted by `public.activate_redaction_policy` on a policy failure (`can_perform` returned DENY) or when the requested target version does not exist in `redaction_policies`. MEDIUM because attempted policy mutations against the redaction subsystem warrant investigation. Payload (`after_state`): `rejection_code` (`PERMISSION_DENIED` or `POLICY_VERSION_NOT_FOUND`), `target_version`, `is_rollback`.

`AI_REDACTION_POLICY_ROLLED_BACK` (LOW) — emitted by `public.activate_redaction_policy` on a successful rollback (`is_rollback=true`). Mirror of `AI_REDACTION_POLICY_ACTIVATED`; identical payload. The split is so reviewers can distinguish "we moved forward to a newer policy" from "we reverted to an older one" without re-comparing version strings.

`AI_PROMPT_REGISTERED` (LOW) — emitted by `public.register_prompt` when a new `(prompt_id, version)` is inserted into `prompt_registry`. Inserts the prompt template, schemas, and the full test corpus atomically. LOW because registration is a routine administrative action. Payload (`after_state`): `prompt_id`, `version`, `ai_tier`, `content_hash`, `test_case_count`, `adversarial_anchor_count`.

`AI_PROMPT_REGISTER_REJECTED` (MEDIUM) — emitted by `public.register_prompt` on policy failure (DENY), duplicate version, malformed test cases, or missing adversarial anchor. MEDIUM because rejected registrations indicate either a misconfigured operator role or a workflow drift (e.g. operator omitted required test cases). Payload (`after_state`): `rejection_code` (`PERMISSION_DENIED` / `DUPLICATE_VERSION` / `TEST_CASES_NOT_ARRAY` / `TEST_CASES_INSUFFICIENT` / `NO_ADVERSARIAL_ANCHOR`), `prompt_id`, `version`.

`AI_PROMPT_DEPLOYED` (LOW) — emitted by `public.deploy_prompt` on a successful forward deploy (no override). Flips the `is_current` pointer in `prompt_deployments` for `(environment, prompt_id)`. LOW because forward deploys are the routine deployment path. Payload (`after_state`): `deployment_id`, `prompt_id`, `version`, `environment`, `is_override` (always false here — overrides emit `AI_PROMPT_PROMOTION_OVERRIDE_USED` instead).

`AI_PROMPT_DEPLOY_REJECTED` (MEDIUM) — emitted by `public.deploy_prompt` or `public.rollback_prompt` on policy / soak / version-not-found / missing-override-reason failure. MEDIUM because every rejected deployment attempt warrants investigation, especially `SOAK_NOT_ELAPSED` (someone is trying to skip the safety window) and `PERMISSION_DENIED` (potential authorization drift). Payload (`after_state`): `rejection_code` (`PERMISSION_DENIED` / `VERSION_NOT_FOUND` / `SOAK_NOT_ELAPSED` / `MISSING_OVERRIDE_REASON`), `prompt_id`, `version` (or `target_version` for rollback), `environment`, `is_override` (for deploy), `rollback` (true for rollback path).

`AI_PROMPT_ROLLED_BACK` (MEDIUM) — emitted by `public.rollback_prompt` on a successful rollback. MEDIUM because rollbacks indicate a quality or stability regression in the newer version that required reverting. Payload (`before_state`): `previous_version`. Payload (`after_state`): `deployment_id`, `prompt_id`, `version` (target), `environment`, `rollback_reason` (required non-empty).

`AI_PROMPT_PROMOTION_OVERRIDE_USED` (MEDIUM) — emitted by `public.deploy_prompt` when `is_override=true` is passed (with a required `override_reason`). MEDIUM because bypassing the 7-day soak window or any other promotion safety is an explicit deviation from the normal promotion path and should be reviewed. Payload (`after_state`): `deployment_id`, `prompt_id`, `version`, `environment`, `is_override` (true), `override_reason`. See B06·P04 spec §Promotion path.

`AI_PROMPT_REGRESSION_FAILED` (HIGH) — emitted by `public.record_prompt_regression_failed` when the CI prompt-regression runner reports failing test cases for a prompt version. HIGH because a regression failure should block promotion of that version and indicates a real quality issue. Actor is SYSTEM (`actor_system='prompt_regression_runner'`) when called from headless CI, USER when triggered by an operator. Payload (`after_state`): `prompt_id`, `version`, `failed_case_count`, `failed_cases` (array of case-level detail objects with at minimum `case_name` and `reason`), `ci_run_id`.

`TIER_3_INVOKED` (LOW) — emitted by `public.record_ai_tier3_event` (called from `api/.../ai_integrations/anthropic_client.py`) immediately before the HTTP POST to Anthropic's `/v1/messages` endpoint. Pairs with `AI_GATEWAY_INVOKED` (from B06·P02) — `AI_GATEWAY_INVOKED` records that the gateway prepared a dispatch, `TIER_3_INVOKED` records that Tier 3 specifically was reached. Subject is the `ai_gateway_invocations.id` (`subject_type=AI_GATEWAY_INVOCATION`). Actor SYSTEM (`actor_system='tier3_dispatcher'`) when no user is in the call chain, USER otherwise. Payload (`after_state`): `invocation_id`, `model_id`, `max_tokens`, `temperature`.

`TIER_3_RESPONSE_RECEIVED` (LOW) — emitted on a successful Anthropic 200 response. LOW because this is the steady-state success event. Payload (`after_state`): `invocation_id`, `model_id`, `input_tokens`, `output_tokens`, `latency_ms`, `parsed_json` (boolean — true if the response body parsed as a JSON object for downstream output-schema validation in the gateway).

`TIER_3_FAILED` (MEDIUM) — emitted on any non-200 HTTP response, timeout, or network error. MEDIUM because failures should be tracked but a transient failure is recoverable (B03·P08's retry policy reads the `transient` flag). Payload (`after_state`): `invocation_id`, `model_id`, `code` (`RATE_LIMIT` / `SERVER_ERROR_5xx` / `CLIENT_ERROR_4xx` / `TIMEOUT` / `NETWORK_ERROR`), `transient` (boolean), `http_status`, `latency_ms`.

`TIER_3_BYPASS_ATTEMPT_BLOCKED` (HIGH) — emitted by `AnthropicEUClient.complete` when it is called with `CallContext(via_gateway=False)`. HIGH because reaching this event means either a code bug (someone built an alternate dispatch path) or an attempt to bypass the redaction / routing / audit pipeline. Pair with the static lint at `scripts/lint_no_direct_ai_imports.py` — between them the two halves of bypass detection. Payload (`after_state`): `invocation_id` (if available), `model_id`, `reason` (currently `'CallContext.via_gateway is False'`).

`TIER_2_INVOKED` (LOW) — emitted by `LocalLlmClient.complete` immediately before the HTTP POST to the operator's local LLM endpoint (Ollama-compatible by default — final runtime choice in the local-model-selection sub-doc). Pairs with `AI_GATEWAY_INVOKED` (B06·P02). Subject is the gateway invocation row (`subject_type=AI_GATEWAY_INVOCATION`). Actor SYSTEM (`actor_system='tier2_dispatcher'`) when no user is in the call chain, USER otherwise. Payload (`after_state`): `invocation_id`, `model_id`, `max_tokens`, `temperature`, `breaker_state_before` (CLOSED / OPEN / HALF_OPEN — useful for reconstructing why a HALF_OPEN probe was attempted).

`TIER_2_RESPONSE_RECEIVED` (LOW) — emitted on a successful 200 response from the local LLM. LOW because this is the steady-state success event. Cost telemetry for B06·P07 is keyed on compute rather than tokens: wall-clock `latency_ms` is the primary signal; `eval_count` (output tokens) and `eval_duration_ms` (model generation time in milliseconds, from Ollama's `eval_duration` in nanoseconds) let us derive tokens-per-second throughput. Payload (`after_state`): `invocation_id`, `model_id`, `latency_ms`, `eval_count`, `eval_duration_ms`, `parsed_json` (boolean).

`TIER_2_FAILED` (MEDIUM) — emitted on every Tier 2 dispatch failure: HTTP non-200, network error, timeout, or short-circuit when the breaker is OPEN. The `code` discriminates: `RATE_LIMIT` / `SERVER_ERROR_5xx` / `CLIENT_ERROR_4xx` / `TIMEOUT` / `NETWORK_ERROR` / `CIRCUIT_OPEN`. The local LLM is by nature operator-managed and unreachable conditions are routine, so transient=True is the common case (only `CLIENT_ERROR_4xx` other than 429 is non-transient). Payload (`after_state`): `invocation_id`, `model_id`, `code`, `transient`, `http_status`, `latency_ms`, `breaker` (snapshot of breaker state and counters).

`TIER_2_HEALTH_CHECK_FAILED` (MEDIUM) — emitted by `LocalLlmClient.health_check` when the `GET /api/tags` probe fails (HTTP non-200, network error, timeout). MEDIUM because a failed health probe usually means the local LLM is offline or the private channel is down — operator-attention level. Health-check failures tick the same breaker counter that dispatch failures use, so a sequence of health probes can open the breaker before any real Tier 2 dispatch is attempted. Payload (`after_state`): `endpoint`, `reason` (exception class name or `http_<status>`), `message` (truncated).

`TIER_2_CIRCUIT_BREAKER_OPENED` (HIGH) — emitted by `LocalLlmClient` (via the underlying `CircuitBreaker`) on the CLOSED→OPEN transition only — once per outage onset, not once per short-circuited call during the OPEN window. HIGH because classifier quality is now degraded across all Tier 2 calls until the breaker recovers (or the operator restores the local LLM). HALF_OPEN→OPEN transitions on a failed probe do not re-emit this event (it would be noisy and inaccurate — the breaker was already known to be in a bad state). Payload (`after_state`): `trigger_reason` (`health_check_*` / `dispatch_*`), `state` (always `OPEN`), `failure_count`, `failure_threshold`, `recovery_timeout_s`, `previous_state` (always `CLOSED`).

`TIER_2_BYPASS_ATTEMPT_BLOCKED` (HIGH) — emitted by `LocalLlmClient.complete` when called with `CallContext(via_gateway=False)`. Same severity rationale as `TIER_3_BYPASS_ATTEMPT_BLOCKED`: reaching this event means either a code bug or an attempt to bypass the redaction / routing / audit pipeline. Payload (`after_state`): `invocation_id` (if available), `model_id`, `reason` (currently `'CallContext.via_gateway is False'`).

`AI_USAGE_RECORDED` (LOW) — emitted by `public.record_ai_usage` once per gateway call. One row inserted into `ai_usage_records` carrying tier, model id, prompt id/version, redaction policy version, token / compute counts, validation outcome, and cost estimate. SYSTEM actor (`actor_system='ai_usage_logger'`) because the writer runs from the gateway / dispatcher, not a user action. Subject is the gateway invocation row (`subject_type=AI_GATEWAY_INVOCATION`, `subject_id=gateway_invocation_id`). LOW because this is the steady-state per-call event; consumers (B06·P08 cost ceiling, B16 reporting) read `ai_usage_run_totals` rather than the audit log. Payload (`after_state`): `usage_record_id`, `tool_name`, `ai_tier`, `model_id`, `validation_outcome`, `latency_ms`, `input_tokens`, `output_tokens`, `compute_seconds`, `cost_estimate`, `currency`, `rate_version`, `cache_hit`. See `ai_usage_records`, `record_ai_usage`.

`AI_USAGE_AGGREGATION_REFRESHED` (LOW) — reserved for a future materialised version of `ai_usage_run_totals`. The plain VIEW shipped in B06·P07 computes on-read so no refresh event fires. When the per-run-aggregation sub-doc decides to materialise (for query performance under load), the refresh job should emit this event with `(refresh_started_at, refresh_completed_at, refreshed_row_count)`. Not currently emitted.

### STORAGE (purge lifecycle and quota management)

```
STORAGE_PURGE_COMPLETED    STORAGE_PURGE_FAILED    STORAGE_QUOTA_WARNING
```

`STORAGE_PURGE_COMPLETED` (LOW) — emitted when a scheduled TTL purge job completes successfully. LOW because successful purge completion is the expected outcome of routine scheduled maintenance. Payload: `job_id`, `zone`, `files_purged`, `bytes_freed`.

`STORAGE_PURGE_FAILED` (HIGH) — emitted when a scheduled TTL purge job fails. HIGH because a failed purge means files are not being cleaned up on schedule, potentially causing quota pressure or compliance violations. Payload: `job_id`, `zone`, `error_message`.

`STORAGE_QUOTA_WARNING` (MEDIUM) — emitted when storage usage for a zone exceeds the 80% quota threshold. MEDIUM because approaching quota requires operator attention before the limit is hit and operations are interrupted. Payload: `zone`, `usage_bytes`, `quota_bytes`, `usage_percent`.

### BANK_UPLOAD (Block 07 — bank statement upload lifecycle)

```
BANK_UPLOAD_RECEIVED
BANK_UPLOAD_PARSE_COMPLETED           BANK_UPLOAD_PARSE_FAILED
BANK_UPLOAD_ROW_SKIPPED
BANK_UPLOAD_DEDUP_HARD_DUPLICATE_DETECTED
BANK_UPLOAD_COMPLETED
BANK_STATEMENT_PARSED                 BANK_STATEMENT_PARSE_FAILED
BANK_STATEMENT_QUARANTINED            BANK_STATEMENT_REPARSED
BANK_STATEMENT_REPARSE_REQUESTED      BANK_STATEMENT_UPLOADED
```

`BANK_UPLOAD_RECEIVED` (LOW) — emitted when a `bank_uploads` row is created; the file has landed in the Raw Upload zone and the completion handler has run successfully. Payload: `upload_id`, `business_id`, `original_filename`, `sha256_hex`, `file_size_bytes`, `uploaded_by_user_id`. See `bank_upload_schema`.
`BANK_UPLOAD_PARSE_COMPLETED` (LOW) — emitted when `upload_status` transitions to `PARSED`; `row_count`, `period_start`, `period_end`, and `currency` are now populated. Payload: `upload_id`, `row_count`, `parse_error_count`, `period_start`, `period_end`. See `bank_upload_schema`.
`BANK_UPLOAD_PARSE_FAILED` (MEDIUM) — emitted when `upload_status` transitions to `FAILED` due to a parse-level error. Payload: `upload_id`, `parse_error_count`, `error_summary`. See `bank_upload_schema`.
`BANK_UPLOAD_ROW_SKIPPED` (LOW) — emitted by the Revolut CSV parser (and any future provider parsers that implement state filtering) for each row whose `State` column value is in `{PENDING, REVERTED, FAILED}`. Rows in these states are not ingested. One event per skipped row. Payload: `upload_id`, `business_id`, `row_index`, `state_value`, `description_truncated` (first 80 chars of the raw description), `amount_raw`. The total count of skipped rows is summarised in the parse result's `skipped_row_count` field on `bank_uploads`. See `csv_parser_revolut_format_spec`.
`BANK_UPLOAD_DEDUP_HARD_DUPLICATE_DETECTED` (LOW) — emitted by the deduplication engine for each row rejected as a HARD duplicate during bank statement ingestion. A HARD duplicate is a row whose `dedup_fingerprint` already exists in `transactions` for the same `business_id`. The row is not inserted. Payload: `upload_id`, `business_id`, `fingerprint` (SHA-256 hex), `original_transaction_id` (the ID of the previously-inserted row), `row_index`. See `deduplication_policy.md`.
`BANK_UPLOAD_COMPLETED` (LOW) — emitted when a bank upload's full ingestion pipeline completes: parse, deduplication, and row insert stages have all finished. Signals that the upload is fully processed and all rows have been either inserted or skipped. Payload: `upload_id`, `business_id`, `run_id`, `row_count_inserted`, `row_count_skipped_dedup`. See `bank_upload_schema`.

`BANK_STATEMENT_UPLOADED` (LOW) — emitted when a bank statement file is uploaded and queued for parsing (`parse_status = PENDING`). Alias/canonical name used by `bank_statement_raw_schema.md`; maps to the same lifecycle point as `BANK_UPLOAD_RECEIVED`. Payload: `file_id`, `run_id`, `filename`, `business_id`.

`BANK_STATEMENT_PARSED` (LOW) — emitted when a bank statement is successfully parsed and rows are extracted (`parse_status = PARSED`). Payload: `file_id`, `run_id`, `row_count`, `business_id`.

`BANK_STATEMENT_PARSE_FAILED` (MEDIUM) — emitted when a bank statement parse attempt fails (`parse_status = PARSE_FAILED`). Payload: `file_id`, `run_id`, `error`, `business_id`.

`BANK_STATEMENT_QUARANTINED` (HIGH) — emitted when a bank statement is quarantined due to repeated parse failures or malware detection (`parse_status = QUARANTINED`). Triggers security alert routing. Payload: `file_id`, `run_id`, `reason`, `business_id`.

`BANK_STATEMENT_REPARSED` (LOW) — emitted when a bank statement is re-parsed after an initial parse failure. Payload: `file_id`, `run_id`, `attempt_count`, `business_id`.

`BANK_STATEMENT_REPARSE_REQUESTED` (LOW) — emitted when a re-parse of a bank statement is manually triggered. Payload: `file_id`, `run_id`, `triggered_by`, `business_id`.

### BANK_STATEMENT (Block 07 — bank statement import lifecycle)

```
BANK_STATEMENT_IMPORTED               BANK_STATEMENT_ROWS_SKIPPED
```

`BANK_STATEMENT_IMPORTED` (LOW) — emitted when a bank statement is successfully imported and all rows have been written to the statement rows table. LOW because a successful import is the expected outcome of the upload pipeline. Payload: `bank_statement_id`, `line_count`, `business_entity_id`.

`BANK_STATEMENT_ROWS_SKIPPED` (LOW) — emitted by the bank statement importer when one or more rows are skipped during parsing (duplicates, out-of-range dates, malformed). LOW for routine skips; severity may be escalated by the importer when the skip count exceeds policy thresholds. Payload: `bank_statement_id`, `business_id`, `skipped_count`, `skip_reasons` (array). See `bank_statement_pipeline_overview.md`.

### VENDOR_MEMORY (Block 08 — vendor classification memory)

```
VENDOR_MEMORY_WRITTEN
```

`VENDOR_MEMORY_WRITTEN` (LOW) — emitted when a `vendor_memory` row is inserted or updated by `classification.write_vendor_memory`. Payload: `memory_id`, `business_id`, `vendor_key`, `suggested_transaction_type`, `suggested_vat_treatment`, `confidence`, `sample_count`, `write_kind` (`INSERT` or `UPDATE`). See `vendor_memory_schema`.

### MATCH (Block 10 — match record lifecycle)

```
MATCH_PROPOSED                        MATCH_CONFIRMED
MATCH_REJECTED
```

`MATCH_PROPOSED` (LOW) — emitted when a `match_records` row is created with `status = PROPOSED`. Payload: `match_id`, `transaction_id`, `invoice_id`, `match_level`, `match_score`, `match_type`. See `match_record_schema`.
`MATCH_CONFIRMED` (LOW) — emitted when `status` transitions to `CONFIRMED` (auto or human). Payload: `match_id`, `match_level`, `confirmed_by_user_id` (null for auto-confirm), `confirmed_at`. See `match_record_schema`.
`MATCH_REJECTED` (LOW) — emitted when `status` transitions to `REJECTED`. Payload: `match_id`, `rejection_reason`. See `match_record_schema`.

### COUNTERPARTY (Block 11 — counterparty record lifecycle)

```
COUNTERPARTY_CREATED                  COUNTERPARTY_UPDATED
COUNTERPARTY_RESOLVED                 COUNTERPARTY_MERGED
COUNTERPARTY_PLACEHOLDER_CREATED
```

`COUNTERPARTY_CREATED` (LOW) — emitted when a new `counterparties` row is inserted by `ledger.resolve_counterparty`. Payload: `counterparty_id`, `business_id`, `normalised_name`, `country_code`, `is_intraeu_supplier`. See `counterparty_schema`.
`COUNTERPARTY_UPDATED` (LOW) — emitted when an existing `counterparties` row is updated. Payload: `counterparty_id`, `changed_fields` (list of field names), new values for non-encrypted fields. Encrypted fields (`vat_number`) record only `field_name` and the fact of change, not the decrypted value. See `counterparty_schema`.
`COUNTERPARTY_RESOLVED` (LOW) — emitted by `ledger.resolve_counterparty` when a counterparty is successfully resolved from raw transaction data (either a new record is created or an existing one is matched and reused). Payload: `counterparty_id`, `business_id`, `country_code`, `country_code_source` (`IBAN` or `BIC`), `canonical_name`, `is_intraeu_supplier`, `vies_triggered`, `run_id`. See `counterparty_resolution_policy`.
`COUNTERPARTY_MERGED` (LOW) — emitted when the dedup rule fires and two counterparty records are merged; the older record's `id` is retained and the newer record is discarded. Payload: `retained_counterparty_id`, `discarded_counterparty_id`, `business_id`, `merge_reason`, `run_id`. See `counterparty_resolution_policy`.
`COUNTERPARTY_PLACEHOLDER_CREATED` (MEDIUM) — emitted when counterparty resolution fails (no valid IBAN, BIC, or recognisable name) and a placeholder record is inserted. MEDIUM because the associated transaction will carry `UNKNOWN` VAT treatment until a reviewer resolves the placeholder. Payload: `counterparty_id`, `business_id`, `raw_name`, `raw_iban`, `raw_bic`, `run_id`. See `counterparty_resolution_policy`.

### STATEMENT / INTAKE (Blocks 07, 09 — shared `intake` namespace)

```
STATEMENT_UPLOADED                    STATEMENT_UPLOAD_COMPLETED
STATEMENT_UPLOAD_RECEIVED             STATEMENT_UPLOAD_PARSING_STARTED
STATEMENT_UPLOAD_FAILED
STATEMENT_UPLOAD_REQUESTED            STATEMENT_UPLOAD_REJECTED_PERMISSION
STATEMENT_UPLOAD_REJECTED_DUPLICATE_HASH
STATEMENT_DEDUP_HARD_DUPLICATE_DETECTED
STATEMENT_DEDUP_SOFT_DUPLICATE_FLAGGED
STATEMENT_PARSER_FAILED               STATEMENT_FORMAT_REJECTED_UNSUPPORTED
STATEMENT_PARSER_REGISTERED           STATEMENT_PARSER_REGISTRATION_DENIED
STATEMENT_PARSE_STARTED               STATEMENT_PARSE_COMPLETED
STATEMENT_PARSE_FAILED
STATEMENT_PDF_OCR_STARTED             STATEMENT_PDF_OCR_COMPLETED
STATEMENT_PDF_OCR_FAILED              STATEMENT_PDF_PARSE_LOW_CONFIDENCE_ROW
TRANSACTION_NORMALIZED                STATEMENT_NORMALIZATION_FAILED
STATEMENT_NORMALIZATION_FX_PAIR_RESOLVED
STATEMENT_NORMALIZATION_AI_FALLBACK_USED
TRANSACTION_DEDUP_NEW                 TRANSACTION_DEDUP_EXACT_DUPLICATE
TRANSACTION_DEDUP_PROBABLE_DUPLICATE  TRANSACTION_DEDUP_NEEDS_REVIEW
STATEMENT_DEDUP_BATCH_COMPLETED
EVIDENCE_PDF_GENERATED                EVIDENCE_PDF_REGENERATED
EVIDENCE_PDF_GENERATION_FAILED        STATEMENT_UPLOAD_ACCEPTED
INGESTION_PHASE_STARTED               INGESTION_PHASE_COMPLETED
INGESTION_PHASE_HOLDING
STATEMENT_PARTIAL_UPLOAD_DETECTED     STATEMENT_ROW_OUTSIDE_DECLARED_PERIOD
STATEMENT_DECLARED_PERIOD_MISMATCH    TRANSACTION_EXCLUDED_FROM_PERIOD
STATEMENT_UPLOAD_EVENT_EMITTED        STATEMENT_UPLOAD_EVENT_CONSUMED
STATEMENT_UPLOAD_EVENT_REPLAY_NOOP    STATEMENT_UPLOAD_EVENT_HANDLER_FAILED
PIPELINE_FIXTURE_RAN                  PIPELINE_FIXTURE_PASSED
PIPELINE_FIXTURE_FAILED               PIPELINE_FIXTURE_REMOVED
STATEMENT_DUPLICATE_DETECTED          STATEMENT_PARTIAL_UPLOAD_FLAGGED
STATEMENT_EVIDENCE_PDF_GENERATED      STATEMENT_INGESTION_COMPLETED
INTAKE_FIXTURE_LOADED
DOCUMENT_FORMAT_REJECTED_UNSUPPORTED  DOCUMENT_OCR_COMPLETED  DOCUMENT_OCR_FAILED
INTAKE_OCR_COMPLETED                  INTAKE_OCR_FAILED
INTAKE_OCR_ESCALATED
INTAKE_GMAIL_QUERY_UPDATED            INTAKE_GMAIL_QUERY_MATCHED
INTAKE_FILE_REJECTED
INTAKE_DEDUP_RESOLVED
```

`STATEMENT_INGESTION_COMPLETED` (LOW) — emitted when the INGESTION phase of a workflow run completes successfully for a statement upload. Used as the internal coordination signal that triggers the `IN_MONTHLY` event-driven run creation (see `in_monthly_type_definition`).
`INTAKE_OCR_COMPLETED` (LOW) — emitted by `intake.ocr_and_extract` when OCR and field extraction succeed and the result is written to the Processing zone scratch record. Payload: `document_id`, `business_id`, `run_id`, `source_type`, `page_count`, `confidence`, `tier_used`, `escalated`. See `tool_ocr_extract_document`.
`INTAKE_OCR_FAILED` (MEDIUM) — emitted by `intake.ocr_and_extract` on any failure mode: `DOCUMENT_UNREADABLE`, `EXTRACTION_TIMEOUT`, or `UNSUPPORTED_FORMAT`. MEDIUM because the document cannot be processed until the failure is resolved. Payload: `document_id`, `business_id`, `run_id`, `source_type`, `error_code`, `error_detail`. See `tool_ocr_extract_document`.
`INTAKE_OCR_ESCALATED` (LOW) — emitted by `intake.ocr_and_extract` immediately before the TIER_3 escalation gateway call, when the TIER_2 first-pass confidence is below 0.65. Payload: `document_id`, `business_id`, `run_id`, `tier_2_confidence`, `escalation_reason`. See `tool_ocr_extract_document`.
`INTAKE_GMAIL_QUERY_UPDATED` (LOW) — emitted on any INSERT, UPDATE, or soft-deactivation of a `document_gmail_queries` row. Payload: `query_id`, `business_id`, `query_name`, `change_kind` (`CREATED`, `UPDATED`, or `DEACTIVATED`), `changed_by_user_id`. See `document_gmail_query_schema`.
`INTAKE_GMAIL_QUERY_MATCHED` (LOW) — emitted by `intake.fetch_gmail_attachments` when an email is found by matching against an active `document_gmail_queries` entry and an attachment is staged for processing. One event per matched email-attachment pair. Payload: `query_id`, `business_id`, `run_id`, `email_message_id` (Gmail message ID, not stored elsewhere), `attachment_filename`, `attachment_size_bytes`, `matched_at`. See `document_intake_per_source_fixture_content.md` for the EMAIL_ATTACHMENT fixture that asserts this event.
`INTAKE_DEDUP_RESOLVED` (LOW) — emitted when a NEEDS_REVIEW deduplication flag on an intake file is manually resolved by an operator. LOW because resolution is the expected outcome once the operator has reviewed the flagged entry. Payload: `intake_file_id`, `resolution`, `resolved_by`.

`INTAKE_FILE_REJECTED` (MEDIUM) — emitted when an intake file fails validation and is rejected by the intake pipeline. Covers rejections at the content-sniff step (disallowed MIME type, size limit exceeded, magic-byte mismatch), the format detection step (unsupported bank format), or the structural validation step (corrupt file, zero rows extractable). MEDIUM because rejection means the document cannot be processed and the business must re-submit a valid file. Payload: `file_id`, `business_id`, `run_id`, `rejection_stage` (`CONTENT_SNIFF` | `FORMAT_DETECTION` | `STRUCTURAL_VALIDATION`), `rejection_reason`, `filename`, `detected_mime_type`. See `intake_size_limits_policy.md`, `upload_content_sniff_policy.md`.

### UPLOAD (Blocks 04, 07, 09 — upload pipeline)

```
UPLOAD_CONTENT_SNIFF_REJECTED
```

`UPLOAD_CONTENT_SNIFF_REJECTED` (MEDIUM) — emitted when a file upload is rejected by the content-sniff pipeline. Covers rejections due to disallowed MIME type, zero-byte files, size limit exceeded, or magic-byte mismatch. See `upload_content_sniff_policy` for the full rejection taxonomy.

### EVIDENCE (Block 07 — bank statement evidence PDFs)

```
EVIDENCE_PDF_UPLOADED
EVIDENCE_PDF_OCR_COMPLETED            EVIDENCE_PDF_OCR_FAILED
```

`EVIDENCE_PDF_UPLOADED` (LOW) — emitted when a new `evidence_pdfs` row is inserted, either via the pipeline-generated path or the manual upload path.
`EVIDENCE_PDF_OCR_COMPLETED` (LOW) — emitted when `ocr_status` transitions to `COMPLETED` for an evidence PDF row.
`EVIDENCE_PDF_OCR_FAILED` (MEDIUM) — emitted when `ocr_status` transitions to `FAILED`; indicates the OCR pass over the file did not produce a usable result.

### CLASSIFICATION (Block 08)

```
CLASSIFICATION_RUN_STARTED            CLASSIFICATION_RUN_COMPLETED
CLASSIFICATION_RULE_NO_MATCH          CLASSIFICATION_LAYER_1_DECIDED
CLASSIFICATION_LAYER_2_DECIDED        CLASSIFICATION_LAYER_3_DECIDED
CLASSIFICATION_USER_CONFIRMED         CLASSIFICATION_USER_RECLASSIFIED
CLASSIFICATION_RULE_CREATED           CLASSIFICATION_RULE_UPDATED
CLASSIFICATION_RULE_DEACTIVATED
CLASSIFICATION_TAG_TAXONOMY_VERSION_CREATED
CLASSIFICATION_TAG_CREATED            CLASSIFICATION_TAG_RETIRED
TAG_TAXONOMY_VERSION_BUMPED           CUSTOM_TAG_RETIRED
CLASSIFICATION_VENDOR_MEMORY_INCREMENTED
CLASSIFICATION_VENDOR_MEMORY_TIER_TRANSITION
CLASSIFICATION_VENDOR_MEMORY_HIT      CLASSIFICATION_VENDOR_MEMORY_MISS
CLASSIFICATION_VENDOR_MEMORY_MARKED_STALE
CLASSIFICATION_VENDOR_MEMORY_PRUNED   CLASSIFICATION_VENDOR_MEMORY_REACTIVATED
TRANSACTION_TAG_REMOVED
CLASSIFICATION_MANUAL_OVERRIDE_SET
```

`TRANSACTION_TAG_REMOVED` (LOW) — emitted by `classification.apply_tags` when an Owner or Admin removes a primary or secondary tag from a transaction. LOW because tag removal is a deliberate user action with a clear audit trail but does not affect security posture. Payload: `transaction_id`, `business_id`, `removed_tag`, `tag_kind` (`PRIMARY` or `SECONDARY`), `removed_by_user_id`, `workflow_run_id`. See `transaction_tag_policy`.
`CLASSIFICATION_MANUAL_OVERRIDE_SET` (LOW) — emitted when a `MANUAL_OVERRIDE` tag is set or cleared on a transaction by an Owner, Admin, or Bookkeeper. LOW because manual overrides are deliberate, authorised actions; the event provides the audit trail for each individual set/clear operation. Payload: `transaction_id`, `business_id`, `tag_type`, `tag`, `action` (`SET` | `CLEARED`), `actor_user_id`. See `transaction_tag_policy`.
`CLASSIFICATION_VENDOR_MEMORY_HIT` (LOW) — emitted by `classification.apply_vendor_memory` when the lookup returns a qualifying hit (≥ 3 confirmed transactions with consistent category). Payload: `transaction_id`, `counterparty_id`, `business_id`, `suggested_category`, `confidence_boost`, `source_transaction_count`, `tier_promoted_to_tier_1`. See `tool_classification_vendor_memory_apply`.
`CLASSIFICATION_VENDOR_MEMORY_MISS` (LOW) — emitted by `classification.apply_vendor_memory` when no qualifying hit is found. Payload: `transaction_id`, `counterparty_id`, `business_id`, `miss_reason` (`INSUFFICIENT_HISTORY`, `CATEGORY_DISAGREEMENT`, or `NO_CONFIRMED_RECORDS`). See `tool_classification_vendor_memory_apply`.
`CLASSIFICATION_VENDOR_MEMORY_MARKED_STALE` (LOW) — emitted by the monthly staleness background job for each `vendor_memory` row whose `last_seen_at` has crossed the 12-month threshold and `is_stale` is transitioning to `TRUE`. LOW because staleness marking is a routine background operation; operators may review marked entries before they are pruned. Payload: `memory_id`, `business_id`, `vendor_key`, `last_seen_at`, `marked_stale_at`. See `vendor_memory_staleness_policy.md`.
`CLASSIFICATION_VENDOR_MEMORY_PRUNED` (LOW) — emitted by the monthly staleness background job for each `vendor_memory` row soft-deleted after 3 months of continuous staleness. Soft-deleted rows remain in the table for audit and retention; they are excluded from all classification lookups. LOW because pruning is the expected outcome of the staleness lifecycle. Payload: `memory_id`, `business_id`, `vendor_key`, `stale_marked_at`, `pruned_at`. See `vendor_memory_staleness_policy.md`.
`CLASSIFICATION_VENDOR_MEMORY_REACTIVATED` (LOW) — emitted by `classification.write_vendor_memory` when a new transaction from the same counterparty is classified and the existing stale (but not yet pruned) entry is reactivated: `is_stale` returns to `FALSE`, `stale_marked_at` is cleared, and `last_seen_at` is updated. LOW because reactivation is the healthy outcome when a dormant supplier resumes activity. Payload: `memory_id`, `business_id`, `vendor_key`, `was_stale_for_days`, `reactivated_at`. See `vendor_memory_staleness_policy.md`.

### DOCUMENT (Block 09)

```
DOCUMENT_INTAKE_STARTED               DOCUMENT_INTAKE_COMPLETED
DOCUMENT_STATE_CHANGED                DOCUMENT_DISMISSED
DOCUMENT_EXTRACTED_FIELDS_PERSISTED
DOCUMENT_EMAIL_FINDER_RAN             DOCUMENT_DRIVE_FINDER_RAN
DOCUMENT_MANUAL_UPLOADED              DOCUMENT_CROSS_SOURCE_DEDUPED
DOCUMENT_SOURCE_INDEXED               DOCUMENT_MANUAL_UPLOAD_RECEIVED
```

### MATCHING / INCOME_MATCHING / SPLIT_PAYMENT_GROUP (Block 10)

```
MATCHING_PAIR_SCORED                  MATCHING_AUTO_CONFIRMED
MATCHING_USER_CONFIRMED               MATCHING_USER_REJECTED
MATCHING_USER_ALTERNATIVE_PROPOSED
MATCHING_REASON_GENERATED             MATCHING_REASON_FALLBACK_APPLIED
MATCHING_REJECTION_RECORDED           MATCHING_REJECTION_SUPPRESSED
MATCHING_REJECTION_OVERRIDDEN_PRIVILEGED
MATCHING_SCORING_CONFIG_UPDATED       MATCHING_SCORING_CONFIG_INVALID
MATCHING_PROPOSED                     MATCHING_CONFIRMED
INCOME_MATCHING_PAIR_SCORED           INCOME_MATCHING_OUTCOME_RECORDED
INCOME_MATCHING_MULTIPLE_INVOICES_DETECTED
SPLIT_PAYMENT_GROUP_PROPOSED          SPLIT_PAYMENT_GROUP_CONFIRMED
SPLIT_PAYMENT_GROUP_REJECTED          SPLIT_PAYMENT_GROUP_STATUS_CHANGED
INCOME_MATCH_PROPOSED                 INCOME_MATCH_CONFIRMED  INCOME_MATCH_REJECTED
MATCHING_CALIBRATION_VERSION_UPDATED
```

`MATCHING_CALIBRATION_VERSION_UPDATED` (MEDIUM) — emitted after a successful recalibration migration completes and the new threshold version is active. MEDIUM because recalibration affects routing of existing proposed matches and may change auto-confirm outcomes for the current period. Payload: `previous_calibration_version`, `new_calibration_version`, `strong_match_threshold`, `probable_match_threshold`, `weak_match_threshold`, `records_rescored_count`, `records_downgraded_count`, `records_auto_confirmed_count`, `migration_run_id`. See `match_scoring_calibration_policy`.

`MATCHING_SCORING_CONFIG_INVALID` (BLOCKING) — emitted when the active `match_scoring_configs` record for a business has a `weight_sum_check` that deviates from 1.0, indicating the signal weights do not sum to the required total. BLOCKING because an invalid scoring configuration prevents the matching engine from producing calibrated scores and must be corrected before the workflow run can proceed. Payload: `business_id`, `workflow_run_id`, `weight_sum_found`, `expected_sum`, `deviation`. See `match_scoring_config_schema.md`, `match_scoring_weights_policy.md`.

`INCOME_MATCH_PROPOSED` (LOW) — emitted when an `income_match_records` row is created with `status = PROPOSED`. Payload: `income_match_id`, `transaction_id`, `invoice_id`, `match_level`, `match_score`, `match_type`. See `income_matching_schema`.
`INCOME_MATCH_CONFIRMED` (LOW) — emitted when `status` transitions to `CONFIRMED` (auto or human). Payload: `income_match_id`, `match_level`, `confirmed_by_user_id` (null for auto-confirm), `confirmed_at`. See `income_matching_schema`.
`INCOME_MATCH_REJECTED` (LOW) — emitted when `status` transitions to `REJECTED`. Payload: `income_match_id`, `unmatched_reason`. See `income_matching_schema`.

`MATCHING_PROPOSED` (LOW) — emitted when a match proposal is created (manual or system). LOW because creating a proposal is the expected routine outcome of the scoring pass. Payload: `match_proposal_id`, `match_level`, `match_score`.

`MATCHING_CONFIRMED` (LOW) — emitted when a match proposal is confirmed (auto or human). LOW because confirmation is the expected outcome for scored proposals above the auto-confirm threshold. Payload: `match_proposal_id`, `confirmed_by`.

### LEDGER (Block 11)

```
LEDGER_COUNTERPARTY_RESOLVED          LEDGER_COUNTERPARTY_UNRESOLVED
LEDGER_COUNTERPARTY_DISAGREEMENT_DETECTED
LEDGER_VAT_TREATMENT_DECIDED          LEDGER_VAT_TREATMENT_UNKNOWN_RAISED
LEDGER_VAT_TREATMENT_HONORED_MANUAL_OVERRIDE
LEDGER_ENTRIES_PREPARED               LEDGER_ENTRIES_RECOMPUTED
LEDGER_ADJUSTMENT_ENTRY_PREPARED      LEDGER_INVOICE_LIFECYCLE_ENTRY_PREPARED
LEDGER_COUNTERPARTY_RESOLVER_TRACE_RECORDED
LEDGER_ACCOUNTANT_REVIEW_FLAGGED
LEDGER_PHASE_HOLDING
LEDGER_VIES_PERIOD_ASSIGNED           LEDGER_VIES_PERIOD_CHANGED
CHART_MAPPING_VERSION_CREATED         CHART_MAPPING_VERSION_FROZEN
CHART_ACCOUNT_ADDED
CHART_ACCOUNT_RETIRED                 CHART_DEFAULT_VERSION_CHANGED
INTERNAL_TRANSFER_DETECTED            INTERNAL_TRANSFER_BILATERAL_LINKED
FX_RATE_FETCHED_BANK                  FX_RATE_FETCHED_ECB  FX_RATE_UNRESOLVABLE
LEDGER_ECB_RATE_STALE                 LEDGER_CURRENCY_UNSUPPORTED
MANUAL_OVERRIDE_REJECTED_FINALIZED_PERIOD
LEDGER_MAPPING_CREATED                LEDGER_MAPPING_UPDATED
LEDGER_MAPPING_VERSION_CREATED
LEDGER_MAPPING_VERSION_FROZEN
LEDGER_VAT_RATE_TABLE_UPDATED         VAT_RATE_CHANGED
CHART_OF_ACCOUNTS_UPDATED
LEDGER_ENTRY_CREATED                  LEDGER_ENTRY_LOCKED
LEDGER_ENTRY_REVERSED
VAT_ENTRY_CREATED
ECB_RATE_FETCHED
LEDGER_RECONCILIATION_COMPLETED       LEDGER_RECONCILIATION_FAILED
```

`LEDGER_ENTRY_CREATED` (LOW) — emitted when a `ledger_entries` row is inserted by `ledger.prepare_entries`. Payload: `entry_id`, `transaction_id`, `debit_account_id`, `credit_account_id`, `amount_eur`, `vat_treatment`, `vat_amount_eur`. See `ledger_entry_schema`.
`LEDGER_ENTRY_LOCKED` (LOW) — emitted when `is_locked` transitions to `true` on a `ledger_entries` row during period finalization. Payload: `entry_id`, `business_id`, `locked_at`. The aggregate event `FINALIZATION_LEDGER_BULK_LOCKED` (Block 15) covers the full-period locking; this event is the per-row signal. See `ledger_entry_schema`.
`LEDGER_ENTRY_REVERSED` (MEDIUM) — emitted when a ledger entry is reversed via `tool_ledger_reverse`. MEDIUM because a reversal modifies the accounting record and requires the offsetting entry to be posted in the same period. Payload: `original_entry_id`, `reversal_entry_id`, `business_id`, `transaction_id`, `amount_eur`, `reversed_by_user_id`, `reversal_reason`, `run_id`. See `tool_ledger_reverse.md`.
`VAT_ENTRY_CREATED` (LOW) — emitted when a `vat_entries` row is inserted by `ledger.compute_vat_amounts`. Payload: `vat_entry_id`, `ledger_entry_id`, `business_id`, `vat_treatment`, `vat_rate`, `net_amount_eur`, `vat_amount_eur`, `gross_amount_eur`. See `vat_entry_schema`.
`ECB_RATE_FETCHED` (LOW) — emitted when a new `ecb_fx_rates` row is inserted after retrieval from the ECB XML feed (not on cache hits). Payload: `rate_id`, `currency_pair`, `rate_date`, `rate` (decimal string), `source`, `fetched_at`. See `ecb_rate_schema`.
`LEDGER_ECB_RATE_STALE` (MEDIUM) — emitted when the ECB FX rate cache lookup for today's date finds a row whose `fetched_at` is more than 24 hours ago (the daily background fetch has not run or has failed). The run continues with the stale rate; the event is the alerting signal to the operator. Payload: `currency_code`, `rate_date`, `fetched_at`, `staleness_seconds`, `business_id`, `workflow_run_id`. See `ecb_fx_rate_cache_reference`.
`LEDGER_CURRENCY_UNSUPPORTED` (MEDIUM) — emitted when the full ECB rate fallback chain is exhausted for a non-EUR transaction: no ECB daily rate, no prior-date fallback, and no `MANUAL_OVERRIDE` row for the currency. A review issue of type `LEDGER_CURRENCY_UNSUPPORTED` is created; ledger posting for the affected transaction is blocked until resolved. Payload: `transaction_id`, `business_id`, `currency_code`, `transaction_date`, `workflow_run_id`. See `ecb_fx_rate_cache_reference`.
`LEDGER_MAPPING_VERSION_CREATED` (LOW) — emitted when a new `ledger_account_mapping_versions` row is inserted. LOW because adding a version is routine administrative configuration. Payload: `version_id`, `business_id`, `version`, `effective_from`, `created_by_user_id`, `changed_category_count`. See `ledger_account_mapping_version_schema`.
`LEDGER_MAPPING_VERSION_FROZEN` (LOW) — emitted when `frozen_at` is set on a `ledger_account_mapping_versions` row during period finalization, making the version immutable for the finalized period. Payload: `version_id`, `business_id`, `version`, `frozen_at`, `frozen_during_run_id`. See `ledger_account_mapping_version_schema`.
`LEDGER_RECONCILIATION_COMPLETED` (LOW) — emitted by `ledger.reconcile` when all reconciliation checks pass: the trial balance is balanced, no missing ledger entries are detected, and the VAT control check passes. Payload: `business_id`, `workflow_run_id`, `period_id`, `balanced`, `vat_control_check_passed`. See `tool_ledger_reconcile.md`.
`LEDGER_RECONCILIATION_FAILED` (HIGH) — emitted by `ledger.reconcile` when any reconciliation check fails: the trial balance is unbalanced, missing entries are detected, or the VAT control check fails. HIGH because a failed reconciliation blocks period finalization and requires immediate operator action. Payload: `business_id`, `workflow_run_id`, `period_id`, `balanced`, `missing_entries_count`, `vat_control_check_passed`, `failure_reasons`. See `tool_ledger_reconcile.md`.

`CHART_MAPPING_VERSION_FROZEN` (LOW) — emitted during finalization when the chart mapping version is locked (frozen), preventing any further changes to the chart-of-accounts mapping for the finalized period. Emitted alongside `CHART_MAPPING_VERSION_CREATED` in the chart mapping version lifecycle. Payload: `version_id`, `business_id`, `frozen_at`, `frozen_during_run_id`. See `ledger_account_mapping_version_schema`, `match_scoring_config_schema.md`.

`LEDGER_COUNTERPARTY_DISAGREEMENT_DETECTED` (MEDIUM) — Emitted when two resolution sources produce conflicting counterparty identities for the same transaction. Payload: `counterparty_id`, `business_id`, `source_a`, `source_b`, `disagreement_field`, `run_id`.

`VAT_RATE_CHANGED` (MEDIUM) — emitted when the platform-level VAT rate table is updated and a rate's value or effective date changes. MEDIUM because rate changes affect downstream VAT computation for every in-scope transaction. Payload: `rate_code`, `previous_rate`, `new_rate`, `effective_date`, `changed_by_user_id`. See `vat_rate_policy.md`.

### VIES (Block 11 — VAT Information Exchange System lookups)

```
VIES_LOOKUP_COMPLETED                 VIES_LOOKUP_FAILED
VIES_VALIDATION_SYSTEM_ERROR
```

`VIES_LOOKUP_COMPLETED` (LOW) — emitted when a VIES SOAP call succeeds and a new `vies_records` row is inserted. Payload includes `vies_record_id`, `counterparty_vat_number`, `is_valid`, `query_country_code`, and `cache_expires_at`.
`VIES_LOOKUP_FAILED` (MEDIUM) — emitted when all VIES SOAP call attempts are exhausted without a usable result; no `vies_records` row is inserted. Payload includes `counterparty_vat_number`, `query_country_code`, `error_code`, and `attempt_count`. A failed lookup may block `EU_REVERSE_CHARGE` treatment assignment.
`VIES_VALIDATION_SYSTEM_ERROR` (HIGH) — emitted when the VIES SOAP API returns `INVALID_REQUESTER_INFO`, indicating a platform-level configuration problem with the VIES requester credentials rather than a per-counterparty lookup failure. HIGH because this error affects all VIES lookups for the business until the requester configuration is corrected. Payload: `counterparty_vat_number`, `query_country_code`, `error_code`, `attempted_at`. See `vies_record_schema.md`.

### NOTIFICATION (Block 03 / cross-block — notification dispatch)

```
NOTIFICATION_SENT
```

`NOTIFICATION_SENT` (LOW) — emitted when a notification is dispatched via `tool_notify_send`. Covers push notifications to mobile clients, in-app notifications, and email notifications triggered by workflow events. LOW because successful dispatch is the expected outcome of any notification trigger. Payload: `notification_id`, `business_id`, `user_id` (nullable — null for broadcast notifications), `channel` (`PUSH` | `IN_APP` | `EMAIL`), `event_type` (the triggering audit event name, e.g., `INTAKE_OCR_COMPLETED`), `dispatched_at`. See `tool_notify_send.md`.

### PAYMENT (Block 13 — payment recording and reconciliation)

```
PAYMENT_RECEIVED
PAYMENT_RECONCILED
```

`PAYMENT_RECEIVED` (LOW) — emitted when a payment is recorded against an invoice via `tool_payment_record`. Covers both full and partial payments. LOW because recording a payment is a routine accounting action. Payload: `payment_id`, `invoice_id`, `business_id`, `amount_eur`, `payment_date`, `payment_method`, `recorded_by_user_id`, `run_id`. See `tool_payment_record.md`.
`PAYMENT_RECONCILED` (LOW) — emitted when a payment is matched to an invoice during the matching phase, completing the payment-to-invoice reconciliation. LOW because successful reconciliation is the expected outcome of the matching pipeline. Payload: `payment_id`, `invoice_id`, `transaction_id`, `business_id`, `match_level`, `reconciled_at`, `run_id`. See `tool_match_confirm.md`, `matching_policy.md`.

### WEBHOOK (Block 03 / integrations — webhook delivery)

```
WEBHOOK_FAILED
```

`WEBHOOK_FAILED` (HIGH) — emitted when a webhook delivery fails after all retries have been exhausted. HIGH because a failed delivery means an external integration did not receive an event that may be critical to the integration's state machine, and operator intervention or retry is required. Payload: `webhook_id`, `business_id`, `event_type`, `endpoint_url` (hashed per redaction policy — raw URL is not stored in audit payload), `attempt_count`, `last_error_code`, `last_error_detail`, `first_attempted_at`, `last_attempted_at`. See `tool_webhook_deliver.md`, `webhook_event_catalog.md`.

### API_KEY (Block 02 — API key validation)

```
API_KEY_USED
```

`API_KEY_USED` (LOW) — emitted when an API key is successfully validated for an API request via `auth.validate_api_key`. Sampled at 1% on high-volume integrations to prevent log flooding; every usage still updates `api_keys.last_used_at` regardless of sampling. LOW because successful key validation is the expected routine outcome of an authenticated API call. Payload: `key_id`, `key_prefix`, `business_id`, `scopes_used`, `request_path`, `request_method`. Raw key material is never included. See `schemas/api_key_schema.md`, `tools/tool_api_key_validate.md`.

### ENGINE (Block 03 — run creation lifecycle)

The `ENGINE` domain covers workflow run creation and compensation lifecycle events not already captured under `WORKFLOW`. `WORKFLOW` owns phase, gate, and tool-invocation events; `ENGINE` owns run creation acceptance/rejection and compensation exhaustion. `ENGINE_WORKFLOW_TYPE_REGISTERED` (listed above in the WORKFLOW block) shares the domain prefix per `audit_log_policies`.

```
ENGINE_COMPENSATION_EXHAUSTED
ENGINE_GATE_FAILED
ENGINE_GATE_EVALUATED
ENGINE_PHASE_ADVANCED
ENGINE_RUN_CREATED
ENGINE_RUN_CREATION_REJECTED_BACKDATED
ENGINE_RUN_CREATION_REJECTED_DUPLICATE
ENGINE_RUN_HELD
ENGINE_RUN_STARTED
ENGINE_RUN_AWAITING_APPROVAL
ENGINE_RUN_CANCELLED
ENGINE_RUN_COMPENSATION_SUCCEEDED
ENGINE_RUN_COMPENSATION_FAILED
ENGINE_APPROVAL_REREQUESTED           ENGINE_APPROVAL_EXPIRED
ENGINE_RUN_STALE_PAUSED
```

`ENGINE_RUN_CREATED` (LOW) — emitted by `engine.create_run` when a new `workflow_runs` row is successfully inserted. LOW because run creation is the expected routine outcome for both scheduler and manual triggers. Payload: `workflow_run_id`, `business_id`, `workflow_type`, `period_year`, `period_month`, `trigger_kind`, `triggered_by_user_id` (nullable), `prior_run_id` (nullable; populated for RERUN trigger only). See `workflow_run_creation_policy`.

`ENGINE_RUN_CREATION_REJECTED_DUPLICATE` (MEDIUM) — emitted when a run creation attempt is rejected because an active run already exists for the same `(business_id, workflow_type, period_year, period_month)`. MEDIUM because a duplicate attempt may indicate a scheduling misconfiguration or a concurrent operator action requiring investigation. Payload: `business_id`, `workflow_type`, `period_year`, `period_month`, `conflicting_run_id`, `trigger_kind`, `attempted_by_user_id`. See `workflow_run_creation_policy`.

`ENGINE_RUN_CREATION_REJECTED_BACKDATED` (MEDIUM) — emitted when a backdated run creation (period more than 13 months in the past) is attempted without OWNER-level authorisation. MEDIUM because an unauthorised backdated run creation is an access boundary event. Payload: `business_id`, `workflow_type`, `period_year`, `period_month`, `trigger_kind`, `attempted_by_user_id`, `required_role`. See `workflow_run_creation_policy`.

`ENGINE_COMPENSATION_EXHAUSTED` (HIGH) — emitted when `compensation_triggers.status` transitions to `EXHAUSTED` (all retry attempts consumed without completing all rollback steps). HIGH because exhaustion leaves a run in an indeterminate state requiring operator investigation before a re-run can be requested. Payload: `compensation_trigger_id`, `workflow_run_id`, `business_id`, `trigger_phase`, `retries_used`, `retry_budget`, `incomplete_steps`, `last_error`, `exhausted_at`. See `compensation_trigger_schema`.

`ENGINE_GATE_FAILED` (MEDIUM) — emitted when an engine gate check fails, blocking phase advance. MEDIUM because a gate failure halts run progression and requires operator review or data correction before the run can continue. Payload: `run_id`, `phase`, `gate_name`, `failure_reason`, `business_id`.

`ENGINE_PHASE_ADVANCED` (LOW) — emitted when a run phase transition completes successfully. LOW because phase advancement is the expected routine outcome of gate passage. Payload: `run_id`, `from_phase`, `to_phase`, `business_id`.

`ENGINE_RUN_HELD` (LOW) — emitted when a run is placed in REVIEW_HOLD status by the engine. LOW because a hold is an expected workflow state used to pause execution for accountant review. Payload: `run_id`, `phase`, `hold_reason`, `business_id`.

`ENGINE_RUN_STARTED` (HIGH) — emitted when a workflow run transitions from CREATED to RUNNING. HIGH because run start is the gate that commits resources to the execution pipeline. Payload: `run_id`, `run_type`, `initiated_by`.

`ENGINE_RUN_AWAITING_APPROVAL` (LOW) — emitted when a run transitions to AWAITING_APPROVAL. LOW because awaiting approval is an expected, routine checkpoint in the approval flow. Payload: `run_id`, `completed_by`.

`ENGINE_RUN_CANCELLED` (MEDIUM) — emitted when a run is cancelled before completion. MEDIUM because cancellation halts a workflow run and requires operator awareness. Payload: `run_id`, `cancel_reason`, `cancelled_by`.

`ENGINE_GATE_EVALUATED` (LOW) — emitted on every gate check regardless of result. LOW because gate evaluation is the expected routine step before each phase transition. Payload: `run_id`, `gate_name`, `result`, `failure_reason`.

`ENGINE_RUN_COMPENSATION_SUCCEEDED` (HIGH) — emitted when the compensating transaction rollback completes successfully. HIGH because successful compensation closes an indeterminate failure and requires operator confirmation before a re-run. Payload: `run_id`, `steps_reversed`.

`ENGINE_RUN_COMPENSATION_FAILED` (BLOCKING) — emitted when compensation itself fails, leaving the run in an unrecoverable state. BLOCKING because a failed compensation requires immediate operator escalation and manual data reconciliation. Payload: `run_id`, `failure_step`.

`ENGINE_APPROVAL_EXPIRED` (LOW) — emitted when a `workflow_run_approvals` row transitions from `PENDING` to `EXPIRED` during gate evaluation because its 72-hour TTL elapsed without resolution. LOW because expiry is the expected non-resolved outcome; the gate blocks until a new approval is requested. Payload: `run_id`, `approval_id`, `business_id`, `requested_at`, `expires_at`. See `approval_expiry_policy.md`.

`ENGINE_APPROVAL_REREQUESTED` (LOW) — emitted by `review_queue.request_approval` when a new PENDING approval is created for a run that already has at least one EXPIRED row. LOW because re-requesting is a routine operator action after an approval lapses. Payload: `run_id`, `approval_id`, `business_id`, `requested_at`, `expires_at`. See `approval_expiry_policy.md`.

`ENGINE_RUN_STALE_PAUSED` (LOW) — emitted once per calendar day for any run that has remained in PAUSED state for more than 7 days, until the run is resumed or cancelled. LOW because the event is an informational alert signal; the run state does not change. Payload: `run_id`, `business_id`, `paused_at`, `days_paused`. See `workflow_pause_resume_policy.md`.

---

### OUT_WORKFLOW / OUT_FILTER / OUT_ADJUSTMENT (Block 12)

```
OUT_WORKFLOW_TYPE_REGISTERED          OUT_FILTER_RAN
OUT_FILTER_INCLUDED_TRANSACTION       OUT_FILTER_EXCLUDED_TRANSACTION
OUT_WORKFLOW_DOCUMENT_EXCEPTION_RECORDED
OUT_WORKFLOW_CONFIG_INITIALIZED       OUT_WORKFLOW_CONFIG_UPDATED
OUT_WORKFLOW_AUTO_START_SUPPRESSED
OUT_WORKFLOW_RUN_TRIGGERED
OUT_WORKFLOW_RUN_CONFIGURED
OUT_WORKFLOW_MANUAL_HOLD_APPLIED      OUT_WORKFLOW_MANUAL_HOLD_RELEASED
OUT_ADJUSTMENT_RUN_CREATED
OUT_ADJUSTMENT_CREATED                OUT_ADJUSTMENT_LEDGER_PREP_COMPLETED
OUT_ADJUSTMENT_HUMAN_REVIEW_HELD      OUT_ADJUSTMENT_APPROVED
OUT_ADJUSTMENT_RECORD_CREATED         OUT_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED
TRANSACTION_FILTER_STATUS_CHANGED
ADJUSTMENT_TOUCHED_RECORD
OUT_WORKFLOW_EXCEPTION_DOCUMENTED     OUT_WORKFLOW_EXCEPTION_REVERSED
WORKFLOW_MANUAL_UPLOAD_REMINDER_SENT
```

`OUT_WORKFLOW_RUN_TRIGGERED` (LOW) — emitted by `out_workflow.create_run` when a new `OUT_MONTHLY` run row is written successfully, for both manual and event-driven trigger paths. Payload includes `workflow_run_id`, `business_id`, `period_start`, `period_end`, `trigger_kind`, `triggered_by_user_id` (MANUAL only), `triggered_by_event_id` (EVENT only), `manual_trigger_note` (MANUAL only). See `out_monthly_trigger_policy`.

`OUT_WORKFLOW_RUN_CONFIGURED` (LOW) — emitted by `out_workflow.configure_run` when an `out_run_configs` row is successfully inserted. LOW because config creation is the expected outcome following every run creation. Payload: `config_id`, `workflow_run_id`, `business_id`, `period_year`, `period_month`, `bank_upload_ids_count`, `manual_trigger`, `triggered_by_user_id` (nullable), `phase_override_config_present`. See `out_run_config_schema`.

`OUT_MANUAL_UPLOAD_EXCEPTION_DOCUMENTED` (LOW) — emitted by `out_workflow.document_exception` when a transaction's `match_status` is set to `EXCEPTION_DOCUMENTED`. LOW because the accountant has explicitly reviewed and accepted the situation; the event is the audit trail of that decision. Payload: `transaction_id`, `workflow_run_id`, `prior_match_status`, `exception_reason`, `exception_documented_by`, `exception_documented_at`. See `out_exception_documented_policy`. **Renamed 2026-05-24 audit H2b** (was `OUT_WORKFLOW_EXCEPTION_DOCUMENTED`; DB name kept as more specific).

`OUT_WORKFLOW_EXCEPTION_REVERSED` (MEDIUM) — emitted by `out_workflow.reverse_exception` when a documented exception is reversed before finalization. MEDIUM because reversal re-opens a transaction that was accepted as resolved and may cause `engine.gate_matching_complete` to hold again. Payload: `transaction_id`, `workflow_run_id`, `restored_match_status`, `reversed_by_user_id`, `reversed_at`. See `out_exception_documented_policy`.

`OUT_WORKFLOW_MANUAL_HOLD_APPLIED` (LOW) — Emitted when an operator applies a manual hold to a transaction within an OUT_MONTHLY run. Payload: `workflow_run_id`, `transaction_id`, `user_id`, `hold_reason`.

`OUT_WORKFLOW_MANUAL_HOLD_RELEASED` (LOW) — Emitted when an operator releases a manual hold on a transaction. Payload: `workflow_run_id`, `transaction_id`, `user_id`.

`OUT_MANUAL_UPLOAD_REMINDER_SENT` (LOW) — emitted by `out_workflow.send_reminder` when the MANUAL_UPLOAD_HOLD reminder fires. Entry-anchored cadence per `out_workflow_business_config.manual_upload_hold_reminder_days` (default 7); 24h dedup; ordinal monotonically increases per run, reset on re-entry. LOW because the reminder is an informational nudge; the hold persists regardless. Payload: `workflow_run_id`, `business_id`, `ordinal`, `payload.unresolved_count`, `payload.unresolved_total_amount`, `payload.oldest_age_days`. See `out_monthly_trigger_policy`. **Renamed 2026-05-24 audit H2a** (was `WORKFLOW_MANUAL_UPLOAD_REMINDER_SENT`; DB name kept as more specific to the OUT family).

`OUT_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED` (MEDIUM) — emitted by `out_workflow.adjustment_intake` when an adjustment is rejected because its parent run is not in `FINALIZED` state (or wrong workflow_type, or different business, or not found). MEDIUM because an unexpected rejection at this gate suggests either a stale UI assumption about the parent's state or a programmatic misuse of the adjustment surface. Payload: `business_id`, `parent_run_id`, `parent_check.reason` ∈ {parent_not_found, parent_business_mismatch, parent_not_out_monthly, parent_not_finalized}, `requesting_user_id`. See `out_adjustment_type_definition.md`. **Tool renamed 2026-05-24 audit H2c** (was `out_workflow.start_adjustment_run`; DB tool name kept as `out_workflow.adjustment_intake`).

### IN_WORKFLOW / IN_FILTER / IN_ADJUSTMENT / INVOICE / CLIENT / RECURRING_INVOICE (Block 13)

```
IN_FILTER_RAN
IN_WORKFLOW_RUN_CREATED               IN_WORKFLOW_RUN_PAIR_LINKED
IN_WORKFLOW_TYPE_REGISTERED           IN_WORKFLOW_RUN_STARTED_MANUALLY
IN_WORKFLOW_RUN_STARTED_BY_EVENT      IN_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED
IN_WORKFLOW_CONFIG_INITIALIZED        IN_WORKFLOW_CONFIG_UPDATED
IN_WORKFLOW_AUTO_START_SUPPRESSED
IN_WORKFLOW_RUN_TRIGGERED
IN_WORKFLOW_RUN_CONFIGURED
IN_WORKFLOW_RUN_REJECTED_RETENTION_EXPIRED
IN_ADJUSTMENT_RUN_CREATED             IN_ADJUSTMENT_REJECTED_RETENTION_EXPIRED
IN_ADJUSTMENT_CREATED                 IN_ADJUSTMENT_APPROVED
INVOICE_CREATED                       INVOICE_SENT  INVOICE_VIEWED  INVOICE_PAID
INVOICE_PAYMENT_EXPECTED
INVOICE_PARTIALLY_PAID                INVOICE_OVERPAID  INVOICE_REFUNDED  INVOICE_CREDITED
INVOICE_WRITTEN_OFF                   INVOICE_VOIDED
INVOICE_AMENDED
INVOICE_PRO_FORMA_CONVERTED_TO_TAX
INVOICE_PRO_FORMA_EXPIRED             INVOICE_PRO_FORMA_EXPIRING_SOON
INVOICE_PRO_FORMA_EXTENDED            INVOICE_PRO_FORMA_CANCELLED
INVOICE_PDF_RENDERED                  INVOICE_PDF_RENDER_REJECTED_INAPPLICABLE_VAT_TREATMENT
INVOICE_PDF_GENERATED
INVOICE_LIFECYCLE_TRANSITION_FAILED
INVOICE_FINALIZED
CLIENT_CREATED                        CLIENT_UPDATED  CLIENT_DEACTIVATED
CLIENT_REGISTRY_LOOKUP
CLIENT_ALIAS_ADDED                    CLIENT_ALIAS_RETIRED
CLIENT_CANONICAL_NAME_CHANGED         CLIENT_ALIAS_LOOKUP_HIT
CLIENT_VIES_VALIDATED                 CLIENT_DATA_EXPORTED
RECURRING_INVOICE_TEMPLATE_CREATED    RECURRING_INVOICE_GENERATED
RECURRING_INVOICE_GENERATION_SKIPPED  RECURRING_INVOICE_GENERATION_FAILED
RECURRING_SCHEDULE_UPDATED            RECURRING_SCHEDULE_CANCELLED
IN_ADJUSTMENT_RECORD_CREATED
INVOICE_PDF_SUPERSEDED
INVOICE_CREDIT_NOTE_ISSUED            INVOICE_CREDIT_NOTE_CAP_REJECTED
CREDIT_NOTE_CREATED                   CREDIT_NOTE_NUMBER_ALLOCATED
CREDIT_NOTE_ISSUED                    CREDIT_NOTE_VOIDED
IN_INCOME_MATCHING_INVOKED
IN_MULTI_INVOICE_ALLOCATION_PROPOSED
IN_MULTI_INVOICE_ALLOCATION_CONFIRMED IN_MULTI_INVOICE_ALLOCATION_EDITED_AND_CONFIRMED
IN_MULTI_INVOICE_ALLOCATION_REJECTED  IN_ALLOCATION_INVARIANT_VIOLATION_REJECTED
IN_INVOICE_ALLOCATION_APPLIED         IN_INVOICE_ALLOCATION_REVERSED
IN_INVOICE_RUNNING_TOTAL_CROSSED_FULL_PAID
IN_PRO_FORMA_PAYMENT_DETECTED
INVOICE_NUMBER_ALLOCATED              INVOICE_NUMBER_GAP_DETECTED
INVOICE_SEQUENCE_GAP_DETECTED
INVOICE_DRAFT_STALE_DETECTED          INVOICE_STALE_AUTO_VOIDED
INVOICE_DRAFT_SAVED
IN_WORKFLOW_CLIENT_NOT_FOUND
IN_WORKFLOW_RECURRING_INVOICE_GENERATED
IN_WORKFLOW_CREDIT_NOTE_APPLIED
```

`IN_WORKFLOW_RUN_TRIGGERED` (LOW) — emitted by `in_workflow.create_run` when a new `IN_MONTHLY` run row is written successfully, for both paired event-driven and standalone manual trigger paths. Payload includes `workflow_run_id`, `business_id`, `period_start`, `period_end`, `trigger_kind`, `triggered_by_user_id` (MANUAL only), `triggered_by_event_id` (EVENT only), `manual_trigger_note` (MANUAL only), `paired_run_id` (EVENT path only). See `in_monthly_trigger_policy`.

`CREDIT_NOTE_ISSUED` (LOW) — emitted by `in_workflow.issue_credit_note` when a credit note transitions from `DRAFT` to `ISSUED` and a `CN-YYYY-NNNN` sequence number is allocated. Distinct from `CREDIT_NOTE_CREATED` (row insertion) in that this event marks the point the number is allocated and the credit becomes externally visible. Payload includes `credit_note_id`, `credit_note_number`, `invoice_id`, `amount_eur` (decimal string), `reason`. See `credit_note_schema`.

`CREDIT_NOTE_VOIDED` (MEDIUM) — emitted when an `ISSUED` credit note is transitioned to `VOIDED` by Owner or Admin. MEDIUM severity because voiding is irreversible. Payload includes `credit_note_id`, `credit_note_number`, `invoice_id`, `voided_by_user_id`, `voided_at`. See `credit_note_schema`.

`RECURRING_SCHEDULE_UPDATED` (LOW) — emitted when a recurring invoice template's configuration is modified via `in_workflow.update_recurring_schedule`. Payload includes `template_id`, `business_id`, changed field names with before/after values. See `recurring_invoice_policy`.

`RECURRING_SCHEDULE_CANCELLED` (MEDIUM) — emitted when a recurring invoice template is set to `ENDED` via `in_workflow.cancel_recurring_schedule`. MEDIUM severity because cancellation is terminal. Payload includes `template_id`, `business_id`, `client_id`, `cancelled_by_user_id`. See `recurring_invoice_policy`.

`INVOICE_VOIDED` (MEDIUM) — emitted by `in_workflow.void_invoice` when an ISSUED invoice is voided. MEDIUM severity because voiding is irreversible, retires the sequence number, and automatically triggers credit note creation. Payload includes `invoice_id`, `invoice_number`, `invoice_type`, `total_amount` (decimal string), `void_reason`, `voided_by_user_id`, `credit_note_id`. See `invoice_amendment_policy`, `invoice_schema`.

`INVOICE_AMENDED` (LOW) — emitted when any field or line item on a `DRAFT` invoice is modified. LOW severity because `DRAFT` invoices have not been issued and no sequence number has been allocated. Payload includes `invoice_id`, `business_id`, `changed_sections` (array — e.g., `["line_items", "due_date"]`), `amended_by_user_id`. See `invoice_amendment_policy`, `invoice_line_item_schema`.

`INVOICE_SEQUENCE_GAP_DETECTED` (HIGH) — emitted by `review_queue.audit_invoice_number_gaps` when an unexplained gap is found in a business's invoice sequence for a given series and year. HIGH because an unexplained gap is a regulatory concern that may indicate a data integrity failure in the allocation path. Gaps attributable to voided invoices are explained and do not emit this event. Payload: `business_id`, `series` (`INV`, `PRO`, or `CN`), `year`, `missing_counter_value`, `max_allocated_counter`, `detected_at`. See `invoice_numbering_sequence_policy`.

`IN_WORKFLOW_RUN_CONFIGURED` (LOW) — emitted by `in_workflow.configure_run` when an `in_run_configs` row is successfully inserted. LOW because config creation is the expected outcome following every run creation. Payload: `config_id`, `workflow_run_id`, `business_id`, `period_year`, `period_month`, `recurring_invoice_enabled`, `invoice_generation_config_client_count`, `manual_trigger`, `triggered_by_user_id` (nullable). See `in_run_config_schema`.

`INVOICE_DRAFT_STALE_DETECTED` (LOW) — emitted by `engine.detect_stale_drafts` background job for each DRAFT invoice that first crosses the 30-calendar-day staleness threshold and has no active `INVOICE_DRAFT_STALE` review issue. One event per invoice per detection cycle. Payload: `invoice_id`, `business_id`, `client_id`, `created_at`, `days_stale`. See `invoice_draft_stale_policy`.

`INVOICE_STALE_AUTO_VOIDED` (LOW) — emitted by `engine.detect_stale_drafts` background job when a DRAFT invoice is automatically voided under the `auto_archive_stale_drafts = true` business config, after exceeding 90 calendar days in DRAFT status. Payload: `invoice_id`, `business_id`, `created_at`, `days_stale`, `auto_archive_config_flag`. See `invoice_draft_stale_policy`.
`IN_WORKFLOW_CLIENT_NOT_FOUND` (HIGH) — emitted when workflow processing cannot locate the client record for a transaction or invoice being processed in the IN_MONTHLY workflow. HIGH because a missing client record blocks ledger posting and matching for all affected transactions and requires operator resolution before the run can advance. Payload: `business_id`, `workflow_run_id`, `phase`, `lookup_key`, `lookup_key_type` (`COUNTERPARTY_ID` | `VAT_NUMBER` | `IBAN` | `NAME`), `transaction_id` (nullable), `invoice_id` (nullable). See `clients_registry_schema.md`, `counterparty_resolution_policy.md`.
`IN_WORKFLOW_RECURRING_INVOICE_GENERATED` (LOW) — emitted when the recurring invoice generator creates a new invoice from a `RECURRING_INVOICE_TEMPLATE` row during the IN_MONTHLY workflow run. LOW because recurring invoice generation is the expected outcome of an active schedule. Payload: `template_id`, `invoice_id`, `business_id`, `client_id`, `period_year`, `period_month`, `amount_eur`, `workflow_run_id`. See `recurring_invoice_policy.md`, `tool_invoice_create.md`.

`INVOICE_DRAFT_SAVED` (LOW) — emitted when a draft invoice is created or updated before issuance. LOW because saving a draft is a routine, non-irreversible action. Payload: `invoice_id`, `business_entity_id`, `is_new`.

`IN_WORKFLOW_CREDIT_NOTE_APPLIED` (LOW) — emitted when a credit note is applied to an invoice within the IN_MONTHLY workflow. LOW because applying a credit note is an expected accounting action initiated by the accountant. Payload: `credit_note_id`, `invoice_id`, `applied_amount`.

`IN_ADJUSTMENT_REJECTED_RETENTION_EXPIRED` (MEDIUM) — emitted by `in_workflow.adjustment_intake` when an adjustment for a period older than the 6-year retention window is rejected. MEDIUM because retention-bound rejection prevents back-period correction and may require operator awareness for legacy reconciliation work. Payload: `business_id`, `parent_period_start`, `attempted_by_user_id`. See `in_adjustment_type_definition.md`.

`CLIENT_VIES_VALIDATED` (LOW) — emitted on each client VAT-number validation against VIES from the client UI. LOW because a per-client validation attempt is routine; the validation result (valid/invalid) is captured in the payload. Payload: `client_id`, `business_id`, `vat_number`, `validation_result`, `validated_by_user_id`. See `client_detail_ui_spec.md`.

`CLIENT_DATA_EXPORTED` (LOW) — emitted when an export bundle that includes client records is generated. LOW because authorized data export is an expected, routine action. Payload: `export_id`, `business_id`, `client_count`, `exported_by_user_id`. See `client_data_policy.md`.

### REVIEW (Block 14)

```
REVIEW_ISSUE_CREATED                  REVIEW_ISSUE_RESOLVED
REVIEW_ISSUE_DISMISSED                REVIEW_ISSUE_SNOOZED
REVIEW_ISSUE_SNOOZE_AUTO_CLEARED      REVIEW_ISSUE_REASSIGNED
REVIEW_ISSUE_SELF_LINKED              REVIEW_NOTE_ADDED
REVIEW_CARD_REGENERATED               REVIEW_BULK_ACTION_APPLIED
REVIEW_AUTO_RESOLVED_BY_RESCAN
REVIEW_ASSIGNMENT_NOTIFICATION_DISPATCHED
REVIEW_ISSUE_TYPE_REGISTERED
REVIEW_ISSUE_CARRY_FORWARD_ESCALATED
REVIEW_ISSUE_BULK_ACTION_COMPLETED
REVIEW_ISSUE_ESCALATED
```

`REVIEW_ISSUE_ESCALATED` (MEDIUM) — emitted by `review_queue.unsnooze_at_run_start` when an issue's severity is automatically promoted (LOW → MEDIUM, or MEDIUM → HIGH) because `carry_forward_count` has reached the escalation threshold on consecutive snoozed runs. Payload includes `review_issue_id`, `previous_severity`, `new_severity`, `carry_forward_count`, `workflow_run_id`, `business_id`. See `issue_escalation_policy`.

### REVIEW_QUEUE (Block 14 — registry, snooze lifecycle, rescan, bulk-preview)

`REVIEW_QUEUE` is a sub-domain of Block 14's `REVIEW` domain. It covers the operational infrastructure of the review queue — issue type registration, snooze state transitions, carry-forward writes, bulk-preview tokens, and rescan execution — as distinct from the per-issue action events in the `REVIEW` domain above. Adding `REVIEW_QUEUE` as a named domain required a `Docs/decisions_log.md` amendment (2026-05-15).

```
REVIEW_QUEUE_ISSUE_TYPE_REGISTERED
REVIEW_QUEUE_BULK_PREVIEW_TOKEN_ISSUED
REVIEW_QUEUE_ISSUE_SNOOZED
REVIEW_QUEUE_SNOOZE_CLEARED_TTL
REVIEW_QUEUE_SNOOZE_CLEARED_DATA_CHANGE
REVIEW_QUEUE_SNOOZE_CLEARED_SEVERITY_ESCALATION
REVIEW_QUEUE_ISSUE_CARRIED_FORWARD
REVIEW_QUEUE_RESCAN_TRIGGERED
REVIEW_QUEUE_RESCAN_COMPLETED
REVIEW_QUEUE_RESCAN_DEPTH_EXCEEDED
REVIEW_QUEUE_BULK_ACTION_PREVIEW_ISSUED
REVIEW_QUEUE_BULK_ACTION_COMPLETED
REVIEW_QUEUE_BULK_ACTION_REJECTED
```

`REVIEW_QUEUE_ISSUE_TYPE_REGISTERED` (LOW) — emitted by `review_queue.registerIssueType` when a new `issue_type_registry` row is inserted (not the idempotent no-op path). Payload: `issue_type`, `issue_group`, `default_severity`, `auto_resolve_eligible`, `registered_by_block`, `registered_at`. See `issue_type_registry_schema`.

`REVIEW_QUEUE_BULK_PREVIEW_TOKEN_ISSUED` (LOW) — emitted by `review_queue.preview_bulk_action` when a `bulk_preview_tokens` row is inserted. Payload: `token_id` (UUID v7 PK — not the secret token value), `workflow_run_id`, `issue_type`, `expires_at`, `issued_by_user_id`. See `issue_type_registry_schema`.

`REVIEW_QUEUE_ISSUE_SNOOZED` (LOW) — emitted by `review_queue.snooze_issue` on each successful snooze write. Payload: `review_issue_id`, `workflow_run_id`, `snoozed_until`, `snooze_count`, `snoozed_by_user_id`, `snooze_reason`. See `snooze_carry_forward_policy`.

`REVIEW_QUEUE_SNOOZE_CLEARED_TTL` (LOW) — emitted on the queue load that first detects an expired `snoozed_until` value (lazy unsnooze). Payload: `review_issue_id`, `workflow_run_id`, `original_snoozed_until`, `cleared_at`, `cleared_by_queue_load_user_id`. See `snooze_carry_forward_policy`.

`REVIEW_QUEUE_SNOOZE_CLEARED_DATA_CHANGE` (LOW) — emitted when a snooze is cleared because the underlying data record changed or because the run advanced to `FINALIZING`. Payload: `review_issue_id`, `workflow_run_id`, `trigger_type` (`DATA_CHANGE` or `PERIOD_FINALIZING`), `cleared_at`. See `snooze_carry_forward_policy`.

`REVIEW_QUEUE_SNOOZE_CLEARED_SEVERITY_ESCALATION` (MEDIUM) — emitted when a snooze is cleared because the issue's severity was elevated. MEDIUM because a policy-driven visibility override should be visible to supervisors. Payload: `review_issue_id`, `workflow_run_id`, `previous_severity`, `new_severity`, `cleared_at`, `escalation_rule_id`. See `snooze_carry_forward_policy`.

`REVIEW_QUEUE_ISSUE_CARRIED_FORWARD` (LOW) — emitted by `review_queue.carry_forward_issues` for each issue transferred to a new period's run. Payload: `review_issue_id`, `source_run_id`, `target_run_id`, `carry_forward_count`, `issue_type`, `severity`. See `snooze_carry_forward_policy`.

`REVIEW_QUEUE_RESCAN_TRIGGERED` (LOW) — emitted by `review_queue.schedule_rescan` when a rescan is scheduled following a resolution action. Payload: `workflow_run_id`, `trigger_issue_id`, `resolved_issue_type`, `affected_issue_count`, `rescan_depth`, `triggered_at`. See `review_queue_rescan_on_resolution_policy`.

`REVIEW_QUEUE_RESCAN_COMPLETED` (LOW) — emitted by `review_queue.execute_rescan` when a rescan pass finishes normally. Payload: `workflow_run_id`, `rescan_depth`, `evaluated_issue_count`, `auto_resolved_count`, `unchanged_count`, `completed_at`. See `review_queue_rescan_on_resolution_policy`.

`REVIEW_QUEUE_RESCAN_DEPTH_EXCEEDED` (HIGH) — emitted when `rescan_depth > 3` and a recursive rescan pass is aborted. HIGH because depth exhaustion indicates a misconfigured `rescan_triggers` dependency graph or an unusually deep issue chain requiring operator investigation. Payload: `workflow_run_id`, `rescan_depth`, `aborted_trigger_issue_id`, `unprocessed_affected_count`, `detected_at`. See `review_queue_rescan_on_resolution_policy`.

`REVIEW_QUEUE_BULK_ACTION_PREVIEW_ISSUED` (LOW) — emitted by `review_queue.preview_bulk_action` when a `bulk_preview_tokens` row is inserted. LOW because requesting a preview is a routine read-proposer step before any bulk execution. Payload: `token_id` (UUID v7 PK of the token row — not the token value), `action`, `issue_count`, `blocking_issue_count`, `issued_by_user_id`, `expires_at`. See `review_queue_bulk_action_policy`.

`REVIEW_QUEUE_BULK_ACTION_COMPLETED` (LOW) — emitted by `review_queue.execute_bulk_action` when a bulk action commits successfully for all issues in the batch. LOW because a successful bulk action is the expected outcome after a valid preview token is supplied. Payload: `token_id`, `action`, `workflow_run_id`, `issues_acted_on_count`, `executed_by_user_id`, `executed_at`. See `review_queue_bulk_action_policy`.

`REVIEW_QUEUE_BULK_ACTION_REJECTED` (MEDIUM) — emitted when a bulk action is rejected for any reason (limit exceeded, BLOCKING issue in batch, expired token, stale batch, or mobile write rejection). MEDIUM because a rejection may indicate a misconfigured caller, a concurrent resolution conflict, or an access policy violation. Payload: `action`, `rejection_reason`, `attempted_by_user_id`, `issue_count`, `blocking_issue_count_in_batch` (nullable). See `review_queue_bulk_action_policy`.

`REVIEW_QUEUE_ITEM_ESCALATED` (MEDIUM) — emitted by `tool_review_queue_escalate` when a review item is escalated to a higher-priority handler or supervisor. MEDIUM because an escalation indicates a review item that could not be resolved through the standard review path and requires elevated attention. Payload: `queue_item_id`, `escalated_by`, `escalation_reason`, `escalated_to`.

### ARCHIVE (Block 15 — archive lifecycle; standalone domain additions)

The following events extend the archive domain with named constants for use in archive tooling, manifest schemas, and runbooks. They complement the `FINALIZATION / ARCHIVE` section below.

```
ARCHIVE_BUNDLE_PROMOTED               ARCHIVE_DOCUMENT_ACCESSED
ARCHIVE_DOCUMENT_SIGNED               ARCHIVE_FINALIZATION_COMPLETED
ARCHIVE_INTEGRITY_FAILURE             ARCHIVE_INTEGRITY_VERIFIED
ARCHIVE_LEGAL_HOLD_REMOVED            ARCHIVE_LEGAL_HOLD_SET
ARCHIVE_PROMOTED                      ARCHIVE_PROMOTION_HASH_MISMATCH
ARCHIVE_RESTORE_COMPLETED             ARCHIVE_RESTORE_REQUESTED
ARCHIVE_SIGN_FAILED                   ARCHIVE_SIGN_NO_CERTIFICATE
ARCHIVE_URL_EXPIRED_UNUSED            ARCHIVE_VERIFICATION_COMPLETED
ARCHIVE_VERIFICATION_STARTED
```

`ARCHIVE_BUNDLE_PROMOTED` (LOW) — Bundle of finalized documents promoted to Object Lock S3 storage. Payload: `run_id`, `manifest_id`, `file_count`, `s3_prefix`, `business_id`.

`ARCHIVE_DOCUMENT_ACCESSED` (LOW) — A document was retrieved from the archive (e.g., for tax audit). Payload: `manifest_id`, `document_key`, `accessor_id`, `reason`, `business_id`.

`ARCHIVE_DOCUMENT_SIGNED` (LOW) — RFC 3161 timestamp and digital signature applied to archive bundle. Payload: `manifest_id`, `timestamp_token`, `signing_certificate_id`, `business_id`.

`ARCHIVE_FINALIZATION_COMPLETED` (LOW) — Run archival fully completed — all documents signed and locked. Payload: `run_id`, `manifest_id`, `business_id`.

`ARCHIVE_INTEGRITY_FAILURE` (BLOCKING) — Archive integrity check failed — possible tamper detected. Payload: `manifest_id`, `expected_hash`, `actual_hash`, `business_id`.

`ARCHIVE_INTEGRITY_VERIFIED` (LOW) — Archive integrity check passed — hash chain verified. Payload: `manifest_id`, `file_count`, `business_id`.

`ARCHIVE_LEGAL_HOLD_REMOVED` (MEDIUM) — Legal hold removed from archived documents. Payload: `manifest_id`, `removed_by`, `reason`, `business_id`.

`ARCHIVE_LEGAL_HOLD_SET` (MEDIUM) — Legal hold applied to archived documents. Payload: `manifest_id`, `set_by`, `reason`, `business_id`.

`ARCHIVE_PROMOTED` (LOW) — Alias for `ARCHIVE_BUNDLE_PROMOTED` — emitted in manifest schema context. Payload: `run_id`, `manifest_id`, `business_id`.

`ARCHIVE_PROMOTION_HASH_MISMATCH` (HIGH) — Hash mismatch detected during archive promotion. Payload: `manifest_id`, `expected_hash`, `actual_hash`, `business_id`.

`ARCHIVE_RESTORE_COMPLETED` (LOW) — Archive restore request fulfilled — documents delivered to requester. Payload: `manifest_id`, `requester_id`, `document_count`, `business_id`.

`ARCHIVE_RESTORE_REQUESTED` (MEDIUM) — Archive restore initiated — audit log entry created before access. Payload: `manifest_id`, `requester_id`, `reason`, `business_id`.

`ARCHIVE_SIGN_FAILED` (HIGH) — RFC 3161 timestamp request failed after max retries. Payload: `manifest_id`, `tsa_endpoint`, `attempt_count`, `business_id`.

`ARCHIVE_SIGN_NO_CERTIFICATE` (HIGH) — Archive signing failed — no valid signing certificate configured. Payload: `manifest_id`, `business_id`.

`ARCHIVE_URL_EXPIRED_UNUSED` (LOW) — Pre-signed archive access URL expired without being used. Payload: `manifest_id`, `url_id`, `business_id`.

`ARCHIVE_VERIFICATION_COMPLETED` (LOW) — Archive verification job completed. Payload: `manifest_id`, `files_verified`, `business_id`.

`ARCHIVE_VERIFICATION_STARTED` (LOW) — Archive verification job started. Payload: `manifest_id`, `business_id`.

`ARCHIVE_DOCUMENT_RESTORED` (MEDIUM) — emitted by `archive.restore_document` when a document is retrieved from the archive zone for legal or audit purposes. MEDIUM because document restoration from archive is an access event that should be visible to compliance officers and auditors. Payload: `document_id`, `document_type`, `requested_by`, `purpose`.

Note: `ARCHIVE_TAMPER_DETECTED` is listed in the KEY/BACKUP/SECURITY block above (Block 05) and also in the FINALIZATION/ARCHIVE block below (Block 15). The event is canonical and shared across both domains; the payload always includes `manifest_id`, `document_key`, and `business_id`.

---

### FINALIZATION / ARCHIVE (Block 15)

```
FINALIZATION_PRECONDITION_EVALUATED   FINALIZATION_PRECONDITION_FAILED
FINALIZATION_APPROVAL_RECORDED        FINALIZATION_APPROVAL_REVOKED
FINALIZATION_LOCK_STARTED             FINALIZATION_LOCK_COMMITTED
FINALIZATION_LEDGER_BULK_LOCKED       FINALIZATION_LOCK_AUDIT_RECOVERED
FINALIZATION_FAILED                   FINALIZATION_ROLLED_BACK
FINALIZATION_MANIFEST_VERSION_INCREMENTED
FINALIZATION_ADJUSTMENT_PRECONDITIONS_PASSED
FINALIZATION_ADJUSTMENT_PRECONDITIONS_FAILED
FINALIZATION_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED
FINALIZATION_ADJUSTMENT_REJECTED_RETENTION_EXPIRED
FINALIZATION_ADJUSTMENT_REJECTED_CONCURRENT_CONFLICT
FINALIZATION_AUDIT_LOG_QUIESCENT_EVALUATED
FINALIZATION_AUDIT_LOG_QUIESCENT_HOLD
ARCHIVE_PACKAGE_BUILT                 ARCHIVE_PACKAGE_VERIFIED
ARCHIVE_MANIFEST_TWO_PASS_CONVERGED
ARCHIVE_PROMOTION_COMPLETED           ARCHIVE_PROMOTION_FAILED
ARCHIVE_DATA_READ_SESSION_SUMMARY     ARCHIVE_TAMPER_DETECTED
ARCHIVE_PROMOTION_RECOVERY_INITIATED  ARCHIVE_PROMOTION_RECOVERY_COMPLETED
ARCHIVE_TAMPER_FALSE_POSITIVE_CLEARED
ARCHIVE_BUNDLE_DOWNLOADED
ARCHIVE_VERIFIED                      ARCHIVE_VERIFICATION_FAILED
RFC3161_TIMESTAMP_APPLIED             RFC3161_TIMESTAMP_FAILED
PERIOD_LOCKED
PERIOD_LOCK_OVERRIDE
ARCHIVE_PERIOD_LOCKED                 ARCHIVE_LOCK_VIOLATION_ATTEMPTED
COMPENSATION_LOG_APPENDED
ARCHIVE_BUNDLE_PASS1_COMPLETED        ARCHIVE_BUNDLE_PASS2_COMPLETED
ARCHIVE_BUNDLE_INTEGRITY_FAILED
ARCHIVE_DETERMINISM_VALIDATION_FAILED
```

`PERIOD_LOCK_OVERRIDE` (BLOCKING) — emitted when an emergency unlock is performed on a locked period. BLOCKING severity is required to ensure an immutable audit trail for any emergency override of a finalized period lock. Payload: `period_id`, `override_by`, `override_reason`.

`PERIOD_LOCKED` (LOW) — emitted by `archive.promote_manifest` (lock sequence Step 5) when a `period_lock_status` row is inserted. Signals that a business period has been finalized and its archive bundle is Object-Locked. Payload includes `lock_id`, `business_id`, `period_start`, `period_end`, `manifest_version`, `workflow_run_id`, `archive_bundle_storage_key`. See `period_lock_status_schema`.

`ARCHIVE_PERIOD_LOCKED` (MEDIUM) — emitted on successful commit of a `period_locks` row during finalization, signalling that all writes to finalized-period rows will be rejected by the `period_lock_check` trigger. MEDIUM because period lock is a compliance-critical state transition that affects downstream writeability. Payload: `business_id`, `period_start`, `period_end`, `workflow_run_id`, `locked_by_user_id`. See `period_lock_policy.md`.

`ARCHIVE_LOCK_VIOLATION_ATTEMPTED` (HIGH) — emitted by the `period_lock_check` trigger when a write attempt against a locked period is blocked. HIGH because a violation attempt indicates either a programming error or an unauthorized correction attempt against finalized data. Payload: `business_id`, `attempted_table`, `attempted_operation`, `user_id`, `session_id`, `period_start`, `period_end`. See `period_lock_policy.md`.

`COMPENSATION_LOG_APPENDED` (HIGH) — emitted when a new `compensation_log` row is inserted, i.e., when a run enters the `COMPENSATING` state and the rollback infrastructure record is created. HIGH severity because a compensating rollback represents a partial-write failure during finalization. Payload includes `log_id`, `workflow_run_id`, `business_id`, `partial_write_description`, `auto_retry_queued`. See `compensation_log_schema`.

`ARCHIVE_BUNDLE_DOWNLOADED` (LOW) — emitted by `archive.generate_download_url` when an authorized user downloads a sealed archive bundle after completing a step-up MFA challenge. LOW because an authorized download is the expected outcome. Payload: `user_id`, `bundle_id` (`archive.archive_packages.id`), `workflow_run_id`, `ip_address` (SHA-256 hex of the raw IP address — hashed per GDPR data minimisation), `download_id`, `step_up_token_id`. See `archive_access_control_policy`.

`ARCHIVE_VERIFIED` (LOW) — emitted by `archive.verify_bundle` when all post-finalization verification checks pass (or when Check 2 is `SKIPPED_TSA_UNAVAILABLE` with all other checks passing). LOW severity because a successful verification is the expected outcome following every finalization. Payload includes `archive_package_id`, `business_id`, `period_start`, `period_end`, `manifest_version`, `verification_check_detail_json`. See `archive_verification_policy`.

`ARCHIVE_VERIFICATION_FAILED` (BLOCKING) — emitted by `archive.verify_bundle` when any verification check fails. BLOCKING because a failure indicates potential data corruption or evidence incompleteness in the archived bundle and must be investigated before the period can be considered reliably finalized. Raises a review issue and a `SECURITY_ALERT`. Payload includes `archive_package_id`, `business_id`, `period_start`, `period_end`, `failed_check`, `failure_detail`. See `archive_verification_policy`.

`RFC3161_TIMESTAMP_APPLIED` (LOW) — emitted by `archive.apply_rfc3161_timestamp` (lock sequence Step 4) when the TSA response passes all validation checks and the `.tsr` file is stored in the `archive-bundles` bucket. LOW severity because timestamping is the expected outcome of Step 4. Payload includes `archive_package_id`, `business_id`, `tsa_token_hash`, `tsa_endpoint`, `gen_time`. See `rfc3161_timestamp_policy`.

`RFC3161_TIMESTAMP_FAILED` (HIGH) — emitted by `archive.apply_rfc3161_timestamp` when three TSA retries are exhausted without a valid response, or when a hard validation error (e.g., `messageImprint` mismatch) occurs. HIGH because the absence of a trusted timestamp weakens the archival evidence chain and triggers the compensation sequence. Payload includes `archive_package_id`, `business_id`, `attempt_count`, `failure_reason`, `tsa_endpoint`. See `rfc3161_timestamp_policy`.

`ARCHIVE_BUNDLE_PASS1_COMPLETED` (LOW) — emitted by `archive.construct_bundle` when Pass 1 of the two-pass manifest construction completes: all document references have been collected and no missing Object Storage objects were detected. Payload: `archive_manifest_id`, `workflow_run_id`, `business_id`, `manifest_version`, `entry_count`. See `archive_bundle_construction_schema`.

`ARCHIVE_BUNDLE_PASS2_COMPLETED` (LOW) — emitted by `archive.construct_bundle` when Pass 2 of the two-pass manifest construction completes: all referenced objects have been retrieved, their SHA-256 hashes have been computed and verified against source row values, and the manifest is ready for ZIP assembly. Payload: `archive_manifest_id`, `workflow_run_id`, `business_id`, `manifest_version`, `entry_count`, `total_size_bytes`. See `archive_bundle_construction_schema`.

`ARCHIVE_BUNDLE_INTEGRITY_FAILED` (BLOCKING) — emitted by `archive.construct_bundle` during Pass 2 when the SHA-256 computed from a retrieved object's bytes does not match the hash stored on the corresponding source row. BLOCKING because a mismatch indicates object corruption or a tampered source record; neither is safe to finalize. The bundle is aborted and a `REVIEW_HOLD` is raised. Payload: `archive_manifest_id`, `workflow_run_id`, `business_id`, `object_key`, `expected_sha256_hex`, `computed_sha256_hex`, `manifest_version`. See `archive_bundle_construction_schema`.

`ARCHIVE_DETERMINISM_VALIDATION_FAILED` (BLOCKING) — emitted in the CI test audit context (not the runtime audit chain) by the CI determinism check step when two independent renders of the same fixture inputs produce different output bytes. BLOCKING because non-deterministic output invalidates the RFC 3161-timestamped hash and breaks post-seal verification. Payload (CI context): `failing_component` (`ZIP_ASSEMBLY` or `PDF_RENDER`), `fixture_name`, `render_1_sha256_hex`, `render_2_sha256_hex`, `git_commit_sha`. See `zip_bundle_determinism_policy`.

### EXPORT / DASHBOARD / ACCOUNTANT_PACK / REPORT / ANALYTICS (Block 16)

```
EXPORT_REQUESTED                      EXPORT_COMPLETED  EXPORT_FAILED
EXPORT_FORCE_REGENERATED              EXPORT_DELIVERED_SIGNED_URL
EXPORT_CSV_RENDERED                   EXPORT_XLSX_RENDERED  EXPORT_PDF_RENDERED
EXPORT_REQUEST_REJECTED_PERMISSION
DASHBOARD_VIEWED                      DASHBOARD_REFRESH_REQUESTED
DASHBOARD_NOTIFICATION_DISPATCHED
DASHBOARD_PREFERENCES_UPDATED         DASHBOARD_REFRESH_COMPLETED
DASHBOARD_AUDIT_HISTORY_SLICE_READ
DASHBOARD_DRILL_DOWN_ACCESSED         DASHBOARD_DRILL_DOWN_DETAIL_ACCESSED
DASHBOARD_DRILL_DOWN_BLOCKED_TAMPER_DETECTED
DASHBOARD_DRILL_DOWN_QUERIED          DASHBOARD_DRILL_DOWN_FILTERED_INACCESSIBLE_BUSINESSES
DASHBOARD_MULTI_BUSINESS_VIEWED       DASHBOARD_MULTI_BUSINESS_DRILL_DOWN_ACCESSED
EXPORT_VIES_GENERATED                 EXPORT_VIES_CORRECTIVE_FILING_FLAGGED
VIES_XML_GENERATED
ACCOUNTANT_PACK_CONFIG_UPDATED
ACCOUNTANT_PACK_GENERATION_STARTED
ACCOUNTANT_PACK_GENERATION_COMPLETED
ACCOUNTANT_PACK_GENERATION_FAILED
ACCOUNTANT_PACK_REJECTED_PERIOD_NOT_FINALIZED
ACCOUNTANT_PACK_REJECTED_TAMPER_DETECTED
ACCOUNTANT_PACK_MANIFEST_TAMPER_DETECTED
ACCOUNTANT_PACK_MANIFEST_SCHEMA_VERSION_BUMPED
ACCOUNTANT_PACK_SENT
ACCOUNTANT_PACK_DELIVERY_FAILED
ANALYTICS_SNAPSHOT_REBUILT
PERIOD_COMPARISON_QUERIED
REPORT_JOB_QUEUED                     REPORT_JOB_COMPLETED  REPORT_JOB_FAILED
REPORT_DATA_SOURCE_FAILED
REPORT_PDF_ACCESSIBILITY_VALIDATION_FAILED
REPORT_ACCESSIBILITY_AUDIT_COMPLETED
```

`ANALYTICS_SNAPSHOT_REBUILT` (LOW) — emitted when a new `analytics_snapshots` row is inserted following an `ARCHIVE_PROMOTION_COMPLETED` rebuild trigger. Payload includes `snapshot_id`, `business_id`, `period_start`, `period_end`, `snapshot_version`, `workflow_run_id`, `computed_at`. See `analytics_snapshot_schema`.

`EXPORT_REQUEST_REJECTED_PERMISSION` (MEDIUM) — emitted when an export request is denied because the caller lacks the required surface for the requested export type. MEDIUM because permission denials at the export surface are security-relevant signals. Payload: `business_id`, `export_type`, `attempted_by_user_id`, `role_at_check`, `required_surface`. See `export_pipeline_policy.md`.

`DASHBOARD_DRILL_DOWN_FILTERED_INACCESSIBLE_BUSINESSES` (LOW) — emitted when a multi-business drill-down query filters out rows belonging to businesses the caller cannot read. LOW because the filter activity is recorded for security review even though no access boundary was breached. Payload: `user_id`, `query_context`, `filtered_business_count`, `filtered_at`. See `drill_down_routing_and_permissions.md`.

`PERIOD_COMPARISON_QUERIED` (LOW) — emitted once per `report.compare_periods` invocation. Records that a user requested a period-over-period comparison view. Payload includes `business_id`, `base_period_start`, `base_period_end`, `comparison_period_start`, `comparison_period_end`, `base_snapshot_id`, `comparison_snapshot_id`, `generated_at`. See `period_comparison_schema`.

`REPORT_JOB_QUEUED` (LOW) — emitted when a new `report_jobs` row is inserted via `report.queue_report_job`. Payload: `job_id`, `business_id`, `report_type`, `workflow_run_id`, `requested_by_user_id`. See `report_job_schema`.

`REPORT_JOB_COMPLETED` (LOW) — emitted when a `report_jobs` row transitions to `COMPLETED`. Payload: `job_id`, `report_type`, `storage_key`, `completed_at`, `expires_at`. See `report_job_schema`.

`REPORT_JOB_FAILED` (MEDIUM) — emitted when a `report_jobs` row transitions to `FAILED`. MEDIUM because the failure requires user awareness and action (regenerate). Payload: `job_id`, `report_type`, `error_message`, `completed_at`. See `report_job_schema`.

`REPORT_DATA_SOURCE_FAILED` (MEDIUM) — emitted by a dashboard card's data-source tool when the tool returns an error response that prevents the card from rendering. MEDIUM because the failure leaves one or more dashboard cards in an error state visible to the user, requiring operator investigation and potential manual cache refresh. The card enters "Data temporarily unavailable" display state when this event is emitted. Payload: `card_id`, `tool_name`, `business_id`, `workflow_run_id` (nullable — not all cards are run-scoped), `error_class`, `error_detail`. See `dashboard_widget_config_schema` for card configuration and `dashboard_refresh_failure_runbook` for recovery steps.

`REPORT_PDF_ACCESSIBILITY_VALIDATION_FAILED` (BLOCKING) — emitted in the CI test audit context (not the runtime audit chain) by the `pdfvalidate` CI step when any PDF in the fixture set fails `veraPDF` PDF/A-2a validation or fails the WCAG 2.1 AA contrast check. BLOCKING because non-compliant PDF output would enter the archive bundle and fail post-seal verification. Payload (CI context): `failing_pdf_type` (`INVOICE`, `REPORT`, or `EVIDENCE`), `validation_rule_id` (the `veraPDF` rule identifier or `WCAG_CONTRAST`), `failure_detail`, `git_commit_sha`. See `pdf_accessibility_policy`.

`REPORT_ACCESSIBILITY_AUDIT_COMPLETED` (LOW) — emitted after each manual or CI-automated accessibility audit session per `disability_simulation_audit_runbook`. Emitted to the CI audit context, not the runtime business audit chain. LOW because a completed audit with no blocking findings is the expected outcome. Payload: `auditor_user_id`, `audit_type` (`MANUAL` or `CI_AUTOMATED`), `release_label`, `procedures_run` (array of procedure IDs), `blocking_issues_found` (integer), `non_blocking_issues_found` (integer), `outcome` (`PASSED` or `BLOCKED`). See `disability_simulation_audit_runbook`.

### LIVE_TEST (Block 05 — Security & Audit; live integration test infrastructure)

```
LIVE_TEST_RUN_STARTED                 LIVE_TEST_RUN_COMPLETED
LIVE_TEST_BUDGET_EXCEEDED             LIVE_TEST_DRIFT_DETECTED
LIVE_TEST_FAILED
INTEGRATION_REPLAY_NO_MATCH
```

`LIVE_TEST_RUN_STARTED` (LOW) — emitted when live integration test mode is activated.
`LIVE_TEST_RUN_COMPLETED` (LOW) — emitted when a live integration test run finishes successfully.
`LIVE_TEST_BUDGET_EXCEEDED` (MEDIUM) — emitted when the cost cap for live test runs is hit; halts further live runs and triggers an operator alert.
`LIVE_TEST_DRIFT_DETECTED` (MEDIUM) — emitted when a recorded fixture response diverges from the live API response.
`LIVE_TEST_FAILED` (MEDIUM) — emitted when a live integration test step fails an assertion. The test step has run but the actual response did not match the expected assertion. Payload: `test_name`, `business_id`, `step_failed`, `assertion_failure_message`, `fixture_suffix`. See `live_integration_test_runbook`.
`INTEGRATION_REPLAY_NO_MATCH` (MEDIUM) — emitted when the replay runner cannot find a matching recorded fixture for a live request.

Per `live_integration_test_runbook`: these events are test/audit-infrastructure events owned by Block 05.

---

### INTEGRATION (Block 02 — external integration credential lifecycle)

```
INTEGRATION_CREDENTIAL_ROTATED
INTEGRATION_CREDENTIAL_ROTATION_FAILED
```

`INTEGRATION_CREDENTIAL_ROTATED` (MEDIUM) — emitted when an integration credential (e.g., OAuth token, API key) is rotated successfully. MEDIUM because credential rotation changes the active authentication material for an external integration. Payload: `credential_id`, `integration_type`, `rotated_by`.

`INTEGRATION_CREDENTIAL_ROTATION_FAILED` (HIGH) — emitted when a credential rotation attempt fails. HIGH because a failed rotation may leave an integration using expired or compromised credentials. Payload: `credential_id`, `integration_type`, `failure_reason`.

---

### VIES — submission tracking (Block 16; extends Block 11 VIES domain)

Block 11 owns the `VIES_LOOKUP_*` events covering per-counterparty VIES SOAP calls. Block 16 extends the same `VIES` domain with ESL submission lifecycle events from `vies_submissions`.

```
VIES_SUBMISSION_CREATED               VIES_SUBMISSION_RESUBMITTED
VIES_SUBMISSION_ACCEPTED              VIES_SUBMISSION_REJECTED
```

`VIES_SUBMISSION_CREATED` (LOW) — emitted when a new `vies_submissions` row is inserted with `submission_status = DRAFT`, i.e., when `report.generate_vies_xml` generates and stores the XML file. LOW severity because XML generation is the expected, routine outcome for eligible quarters. Payload includes `submission_id`, `business_id`, `submission_period`, `workflow_run_id`, `xml_storage_key`, `xml_sha256_hex`. See `vies_submission_tracking_schema`.

`VIES_SUBMISSION_RESUBMITTED` (MEDIUM) — emitted when a previously-submitted VIES return is regenerated and resubmitted (e.g., after a reference-not-returned outcome triggers a corrective filing). MEDIUM because resubmission indicates a prior submission could not be confirmed and operator-led correction was required. Payload: `submission_id`, `business_id`, `submission_period`, `resubmit_reason`, `resubmitted_by_user_id`. See `vies_submission_failure_runbook.md`.

`VIES_SUBMISSION_ACCEPTED` (LOW) — emitted when `submission_status` transitions to `ACCEPTED` and the operator records the `tax_authority_reference` returned by the Cyprus Tax Department. LOW severity because acceptance is the expected outcome of a correctly filed return. Payload includes `submission_id`, `business_id`, `submission_period`, `tax_authority_reference`, `accepted_by_user_id`. See `vies_submission_tracking_schema`.

`VIES_SUBMISSION_REJECTED` (MEDIUM) — emitted when `submission_status` transitions to `REJECTED`. MEDIUM severity because a rejection requires operator action (investigate the rejection reason and generate a corrective filing) and may indicate a data quality issue in the underlying VIES-relevant transactions. Payload includes `submission_id`, `business_id`, `submission_period`, `rejection_reason`, `recorded_by_user_id`. See `vies_submission_tracking_schema`.

---

### RFC 3161 anchoring (Block 05 sub-domain)

```
TIMESTAMP_AUTHORITY_INVOKED           TIMESTAMP_RECORDED  TIMESTAMP_AUTHORITY_UNREACHABLE
```

---

### AUDIT (Block 05 — audit log export lifecycle)

```
AUDIT_LOG_EXPORTED
```

`AUDIT_LOG_EXPORTED` (LOW) — emitted when a signed download URL is generated for an audit log export, confirming that the export file has been made available to the requesting user. LOW because an authorized export is the expected outcome of a compliant export request. Payload: `export_id`, `exported_by`, `row_count`, `filter_from`, `filter_to`.

---

## Cross-block events

A handful of events are emitted by one block and explicitly consumed by another via event subscription. The cross-block contract is owned by the producer:

| Event | Producer | Consumer(s) |
| --- | --- | --- |
| `STATEMENT_UPLOAD_COMPLETED` | Block 07 Phase 01 | Block 03 Phase 09 (trigger engine), Block 12 Phase 08, Block 13 |
| `ARCHIVE_PROMOTION_COMPLETED` | Block 15 Phase 04 + 06 | Block 04 Phase 09 (analytics rebuild), Block 16 (dashboard refresh) |
| `WORKFLOW_RUN_STATE_CHANGED` | Block 03 Phase 04 | Block 16 (run progress), Block 14 (issue re-evaluation) |

Per `event_subscription_pipeline_integration` (Integrations, Block 03), the subscription mechanism is event-bus pattern using `subscribeByEventType` from Block 05 Phase 02.

## Aggregation events

Some events are aggregations to control audit volume. Per Stage 2 fixes:

- `OUT_FILTER_RAN` is the canonical aggregate; per-row `OUT_FILTER_INCLUDED_TRANSACTION` events were collapsed (per Block 12 scan).
- `IN_FILTER_RAN` is the canonical aggregate; per-row `IN_FILTER_INCLUDED_TRANSACTION` events were collapsed (per Block 13 scan).
- `ARCHIVE_DATA_READ_SESSION_SUMMARY` aggregates per-session archive reads (per Block 15 scan).
- `FINALIZATION_LEDGER_BULK_LOCKED` aggregates per-row `FINALIZATION_FILE_INDEXED` events (per Block 15 scan).

## Removed during Stage 2 (do NOT use)

Drift caught and removed by scans:

- `MATCH_*` family — renamed to `MATCHING_*` per the `<DOMAIN>_<PAST_VERB>` convention
- `INCOME_MATCH_*` family — renamed to `INCOME_MATCHING_*`
- `PROMPT_*` family — renamed to `AI_PROMPT_*`
- `CLASSIFICATION_RULES_NO_MATCH` (plural) — renamed to `CLASSIFICATION_RULE_NO_MATCH` (singular, for symmetry)
- `FINALIZATION_AUDIT_INTEGRITY_FAILURE` — removed; persistent audit failure halts globally instead
- `INTAKE_FIXTURE_REMOVED` — removed (repo-governance, not a runtime audit)
- `WORKFLOW_GATE_REEVALUATION_REQUESTED` — removed (use standard `WORKFLOW_GATE_PASSED` / `_HOLD` / `_ROUTED_TO_SIDE_PHASE`)
- `CRITICAL` severity references in `severity` fields — replaced with `BLOCKING`

A repo-wide `audit_event_drift_lint_check` fixture (Block 05) scans for any reference to a removed event name.

## Cross-references

- `audit_log_policies` — naming convention, RLS, query patterns, chain partitioning
- `audit_event_payload_schemas` (Layer 2) (Layer 2, Block 05) — per-event payload shapes
- `data_layer_conventions_policy` — canonical JSON serialization for `event_payload_canonical_json`
- `event_subscription_pipeline_integration` — cross-block subscription mechanism
- Block 05 Phase 02 — audit log schema + `emitAudit()`
- Block 05 Phase 03 — hash-chain tamper resistance
- Per-block phase docs — emission sites

---

## Appendix A — Auto-extracted action inventory (2026-05-24)

**Source of truth for what's currently emitted by DB code**, generated via:
```
grep -rhoE "p_action[[:space:]]*(=>|:=)[[:space:]]*'[A-Z][A-Z0-9_]+'" supabase/migrations/ \
  | grep -oE "'[A-Z][A-Z0-9_]+'" | tr -d "'" | sort -u
```

Total: **325 distinct audit actions** across all migrations as of 2026-05-24. Use this as the canonical list when reconciling per-domain narrative sections above — many narrative sections list deprecated or never-emitted names, or omit recently-added ones. See `Docs/sub/audit/2026-05-24_post_block_12_audit.md` finding M2 for the drift pattern.

**Reconciliation status**: narrative sections still drift from this inventory. Future grooming pass should walk each narrative section against this list. Per-domain HIGH-priority renames (audit H2) already applied: `OUT_MANUAL_UPLOAD_EXCEPTION_DOCUMENTED` (was `OUT_WORKFLOW_EXCEPTION_DOCUMENTED`), `OUT_MANUAL_UPLOAD_REMINDER_SENT` (was `WORKFLOW_MANUAL_UPLOAD_REMINDER_SENT`), tool name `out_workflow.adjustment_intake` (was `out_workflow.start_adjustment_run`).

**ACCESS**
- `ACCESS_ALLOWED`
- `ACCESS_DECISION_THREW`
- `ACCESS_DENIED`
- `ACCESS_STEP_UP_TRIGGERED`

**AI**
- `AI_CACHE_HIT`
- `AI_CACHE_PRUNED`
- `AI_CACHE_STORED`
- `AI_CLASSIFICATION_FAILED`
- `AI_CLASSIFICATION_INVOKED`
- `AI_CLASSIFICATION_RESULT`
- `AI_CLASSIFICATION_TIER2_LOW_CONFIDENCE`
- `AI_CLASSIFICATION_TIER3_INVOKED`
- `AI_COST_CEILING_HIT`
- `AI_COST_CONFIG_UPDATED`
- `AI_COST_CONFIG_UPDATE_REJECTED`
- `AI_COST_OVERRIDE_DENIED`
- `AI_COST_OVERRIDE_GRANTED`
- `AI_COST_OVERRIDE_REQUESTED`
- `AI_COST_WARNING`
- `AI_GATEWAY_INVOKED`
- `AI_GATEWAY_RESPONSE_INVALID`
- `AI_GATEWAY_VALIDATION_FAILED`
- `AI_PII_DETECTED_IN_NON_DECLARED_FIELD`
- `AI_PROMPT_DEPLOY_REJECTED`
- `AI_PROMPT_REGISTERED`
- `AI_PROMPT_REGISTER_REJECTED`
- `AI_PROMPT_REGRESSION_FAILED`
- `AI_PROMPT_ROLLED_BACK`
- `AI_REDACTION_ALLOWLIST_DROP`
- `AI_REDACTION_APPLIED`
- `AI_REDACTION_POLICY_ACTIVATE_REJECTED`
- `AI_REDACTION_REJECTED`
- `AI_TIER_CONFIG_UPDATED`
- `AI_TIER_CONFIG_UPDATE_REJECTED`
- `AI_USAGE_RECORDED`

**ALERT**
- `ALERT_RULE_ADDED`
- `ALERT_RULE_DISABLED`
- `ALERT_RULE_UPDATED`

**AUDIT**
- `AUDIT_LOG_QUERIED`

**BACKUP**
- `BACKUP_COMPLETED`
- `BACKUP_FAILED`
- `BACKUP_REPLICATION_LAG_EXCEEDED`
- `BACKUP_STARTED`

**CHAIN**
- `CHAIN_CHECKPOINTED`
- `CHAIN_CHECKPOINT_FAILED`
- `CHAIN_RESTORED_AND_VERIFIED`
- `CHAIN_VERIFICATION_FAILED`
- `CHAIN_VERIFIED`

**CHART**
- `CHART_ACCOUNT_CREATED`
- `CHART_ACCOUNT_DISABLED`
- `CHART_ACCOUNT_UPDATED`
- `CHART_DEFAULT_SEEDED`
- `CHART_MAPPING_RULE_CREATED`
- `CHART_MAPPING_RULE_DISABLED`
- `CHART_MAPPING_VERSION_CREATED`
- `CHART_MAPPING_VERSION_FROZEN`

**CLASSIFICATION**
- `CLASSIFICATION_AUTO_CONFIRMED`
- `CLASSIFICATION_LAYER_DISAGREEMENT_FLAGGED`
- `CLASSIFICATION_MULTI_LAYER_AGREEMENT_BOOST`
- `CLASSIFICATION_NEEDS_CONFIRMATION`
- `CLASSIFICATION_RULE_CONFLICT`
- `CLASSIFICATION_RULE_DISABLED`
- `CLASSIFICATION_RULE_MATCHED`
- `CLASSIFICATION_RULE_MUTATION_DENIED`
- `CLASSIFICATION_RULE_NO_MATCH`
- `CLASSIFICATION_USER_CONFIRMED`
- `CLASSIFICATION_USER_OVERRIDDEN`
- `CLASSIFICATION_USER_REJECTED`

**CLASSIFIER**
- `CLASSIFIER_FIXTURE_FAILED`
- `CLASSIFIER_FIXTURE_PASSED`
- `CLASSIFIER_FIXTURE_RAN`
- `CLASSIFIER_FIXTURE_REGISTERED`
- `CLASSIFIER_FIXTURE_REMOVED`

**CLASSIFY**
- `CLASSIFY_PHASE_COMPLETED`
- `CLASSIFY_PHASE_HOLDING`
- `CLASSIFY_PHASE_STARTED`

**CUSTOM**
- `CUSTOM_TAG_CREATED`
- `CUSTOM_TAG_MUTATION_DENIED`
- `CUSTOM_TAG_REMAPPED`
- `CUSTOM_TAG_RENAMED`
- `CUSTOM_TAG_RESTORED`
- `CUSTOM_TAG_RETIRED`

**DATA**
- `DATA_SUBJECT_ANONYMIZATION_SCHEDULED`
- `DATA_SUBJECT_ANONYMIZED`
- `DATA_SUBJECT_EXPORT_DOWNLOADED`
- `DATA_SUBJECT_EXPORT_GENERATED`
- `DATA_SUBJECT_PSEUDONYMIZED`
- `DATA_SUBJECT_REQUEST_DEFERRED_LEGAL_HOLD`
- `DATA_SUBJECT_REQUEST_FULFILLED`
- `DATA_SUBJECT_REQUEST_IDENTITY_VERIFIED`
- `DATA_SUBJECT_REQUEST_RECEIVED`
- `DATA_SUBJECT_REQUEST_REJECTED`

**DEK**
- `DEK_CREATED`
- `DEK_DESTROYED`
- `DEK_RETIRED`
- `DEK_ROTATED`

**DOCUMENT**
- `DOCUMENT_CONFIDENCE_BOOSTED_VIA_CROSS_SOURCE`
- `DOCUMENT_CROSS_SOURCE_DUPLICATE_DETECTED`
- `DOCUMENT_EXTRACTION_FAILED`
- `DOCUMENT_EXTRACTION_LAYER1_MATCHED`
- `DOCUMENT_EXTRACTION_RESULT`
- `DOCUMENT_EXTRACTION_TIER2_INVOKED`
- `DOCUMENT_EXTRACTION_TIER2_LOW_CONFIDENCE`
- `DOCUMENT_EXTRACTION_TIER3_INVOKED`
- `DOCUMENT_FIELD_VALIDATION_FAILED`
- `DOCUMENT_FORMAT_CONVERTED`
- `DOCUMENT_FORMAT_REJECTED_UNSUPPORTED`
- `DOCUMENT_MANUAL_LINKED_TO_TRANSACTION`
- `DOCUMENT_OCR_COMPLETED`
- `DOCUMENT_OCR_FAILED`
- `DOCUMENT_OCR_STARTED`
- `DOCUMENT_STATE_CHANGED`
- `DOCUMENT_STATE_CHANGE_REJECTED`
- `DOCUMENT_STUB_CREATED`
- `DOCUMENT_THIRD_SOURCE_OBSERVED`

**DRIVE**
- `DRIVE_FINDER_FILES_LISTED`
- `DRIVE_FINDER_FOLDERS_SELECTED`
- `DRIVE_FINDER_NON_CONVENTION_DETECTED`
- `DRIVE_FINDER_RESULT_DUPLICATE_SOURCE`
- `DRIVE_FINDER_RESULT_FOUND`

**DR**
- `DR_DRILL_COMPLETED`

**EMAIL**
- `EMAIL_FINDER_QUERY_EXECUTED`
- `EMAIL_FINDER_RESULT_DUPLICATE_SOURCE`
- `EMAIL_FINDER_RESULT_FOUND`

**END**
- `END_SCAN_CHECK_RAN`
- `END_SCAN_ISSUE_RAISED`
- `END_SCAN_RESCAN_AFFECTED`
- `END_SCAN_STARTED`

**EVIDENCE**
- `EVIDENCE_DISCOVERY_PHASE_COMPLETED`
- `EVIDENCE_DISCOVERY_PHASE_HOLDING`
- `EVIDENCE_DISCOVERY_PHASE_STARTED`
- `EVIDENCE_PDF_GENERATION_FAILED`

**FIELD**
- `FIELD_DECRYPTED`

**GATE**
- `GATE_REGISTRY_REGISTERED`

**INGESTION**
- `INGESTION_PHASE_COMPLETED`
- `INGESTION_PHASE_HOLDING`
- `INGESTION_PHASE_STARTED`

**INTAKE**
- `INTAKE_FIXTURE_FAILED`
- `INTAKE_FIXTURE_PASSED`
- `INTAKE_FIXTURE_RAN`

**INVOICE**
- `INVOICE_LIFECYCLE_TRANSITIONED`
- `INVOICE_LIFECYCLE_TRANSITION_FAILED`

**KEK**
- `KEK_CREATED`
- `KEK_ROTATED`

**KEY**
- `KEY_ACCESSED`
- `KEY_ACCESS_DENIED`

**LEDGER**
- `LEDGER_ACCOUNTANT_REVIEW_FLAGGED`
- `LEDGER_COUNTERPARTY_DISAGREEMENT_DETECTED`
- `LEDGER_COUNTERPARTY_RESOLVED`
- `LEDGER_COUNTERPARTY_UNRESOLVED`
- `LEDGER_DRAFT_ENTRY_CREATED`
- `LEDGER_DRAFT_ENTRY_RECOMPUTED`
- `LEDGER_EVIDENCE_FLAGS_SET`
- `LEDGER_FIXTURE_FAILED`
- `LEDGER_FIXTURE_PASSED`
- `LEDGER_FIXTURE_RAN`
- `LEDGER_HELD_PENDING_CLASSIFICATION`
- `LEDGER_MAPPING_RULE_FALLBACK_USED`
- `LEDGER_MISSING_REQUIRED_EVIDENCE_RAISED`
- `LEDGER_MULTI_LINE_INVOICE_CONSOLIDATED`
- `LEDGER_PHASE_COMPLETED`
- `LEDGER_PHASE_HOLDING`
- `LEDGER_PHASE_STARTED`
- `LEDGER_REVERSE_CHARGE_FLAGGED`
- `LEDGER_VAT_AMOUNTS_COMPUTED`
- `LEDGER_VAT_TREATMENT_DECIDED`
- `LEDGER_VAT_TREATMENT_HONORED_MANUAL_OVERRIDE`
- `LEDGER_VAT_TREATMENT_MANUAL_OVERRIDE_APPLIED`
- `LEDGER_VAT_TREATMENT_MANUAL_OVERRIDE_CLEARED`
- `LEDGER_VAT_TREATMENT_TAG_MISMATCH_DETECTED`
- `LEDGER_VAT_TREATMENT_UNKNOWN_RAISED`
- `LEDGER_VIES_RELEVANCE_DECIDED`
- `LEDGER_VIES_VAT_NUMBER_MISSING_RAISED`

**MANUAL**
- `MANUAL_UPLOAD_COMPLETED`
- `MANUAL_UPLOAD_INITIATED`

**MATCHING**
- `MATCHING_AUTO_CONFIRMED`
- `MATCHING_CROSS_CURRENCY_FX_RESOLVED`
- `MATCHING_CROSS_PERIOD_CANDIDATE_FOUND`
- `MATCHING_DUPLICATE_PATTERN_DETECTED`
- `MATCHING_DUPLICATE_PATTERN_RESOLVED`
- `MATCHING_FIXTURE_FAILED`
- `MATCHING_FIXTURE_PASSED`
- `MATCHING_FIXTURE_RAN`
- `MATCHING_LEVEL_ASSIGNED`
- `MATCHING_NEEDS_CONFIRMATION_RAISED`
- `MATCHING_POSSIBLE_RAISED`
- `MATCHING_REASON_CACHE_HIT`
- `MATCHING_REASON_FALLBACK_APPLIED`
- `MATCHING_REASON_GENERATED`
- `MATCHING_REASON_REGENERATED`
- `MATCHING_REJECTION_OVERRIDDEN_PRIVILEGED`
- `MATCHING_REJECTION_RECORDED`
- `MATCHING_REJECTION_SUPPRESSED`
- `MATCHING_SCORE_COMPUTED`
- `MATCHING_SPLIT_PAYMENT_CANDIDATE_PROPOSED`
- `MATCHING_SPLIT_PAYMENT_CANDIDATE_SET_TRUNCATED`
- `MATCHING_SPLIT_PAYMENT_DETECTOR_RAN`
- `MATCHING_USER_CONFIRMED`
- `MATCHING_USER_EDITED_AND_CONFIRMED`
- `MATCHING_USER_REJECTED`

**OUT**
- `OUT_ADJUSTMENT_INTAKE_COMPLETED`
- `OUT_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED`
- `OUT_ADJUSTMENT_REJECTED_RETENTION_EXPIRED`
- `OUT_ADJUSTMENT_RUN_CREATED`
- `OUT_FILTER_INCLUDED_TRANSACTION`
- `OUT_FILTER_RAN`
- `OUT_FILTER_SCOPE_TRANSITIONED`
- `OUT_FILTER_UNKNOWN_BLOCKER_RAISED`
- `OUT_GATE_EVALUATED`
- `OUT_GATE_ROUTED_TO_SIDE_PHASE`
- `OUT_HUMAN_REVIEW_APPROVAL_RECORDED`
- `OUT_HUMAN_REVIEW_APPROVAL_REVOKED`
- `OUT_HUMAN_REVIEW_APPROVAL_STALENESS_DETECTED`
- `OUT_HUMAN_REVIEW_HOLD_CLEARED`
- `OUT_HUMAN_REVIEW_HOLD_ENTERED`
- `OUT_MANUAL_UPLOAD_EXCEPTION_DOCUMENTED`
- `OUT_MANUAL_UPLOAD_HOLD_CLEARED`
- `OUT_MANUAL_UPLOAD_INVOICE_UPLOADED`
- `OUT_MANUAL_UPLOAD_REMINDER_SENT`
- `OUT_WORKFLOW_AUTO_START_SUPPRESSED`
- `OUT_WORKFLOW_CONFIG_INITIALIZED`
- `OUT_WORKFLOW_CONFIG_UPDATED`
- `OUT_WORKFLOW_EVENT_TRIGGER_DEDUPLICATED`
- `OUT_WORKFLOW_FIXTURE_RAN`
- `OUT_WORKFLOW_PAIRED_RUN_LINKED`
- `OUT_WORKFLOW_RUN_ALREADY_ACTIVE_REJECTED`
- `OUT_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED`
- `OUT_WORKFLOW_RUN_REJECTED_RETENTION_EXPIRED`
- `OUT_WORKFLOW_RUN_STARTED_BY_EVENT`
- `OUT_WORKFLOW_RUN_STARTED_MANUALLY`
- `OUT_WORKFLOW_SHARED_PHASE_DEDUP_APPLIED`
- `OUT_WORKFLOW_TYPE_REGISTERED`

**PIPELINE**
- `PIPELINE_FIXTURE_FAILED`
- `PIPELINE_FIXTURE_PASSED`
- `PIPELINE_FIXTURE_RAN`
- `PIPELINE_FIXTURE_REMOVED`

**RESTORE**
- `RESTORE_INITIATED`
- `RESTORE_PROMOTED_TO_PRODUCTION`
- `RESTORE_QUARANTINE_LOADED`
- `RESTORE_REJECTED`

**SECONDARY**
- `SECONDARY_TAG_ADDED`

**SECRET**
- `SECRET_ACCESSED`
- `SECRET_ACCESS_DENIED`
- `SECRET_ACCESS_FAILED`
- `SECRET_CREATED`
- `SECRET_ROTATED`
- `SECRET_ROTATION_FAILED`
- `SECRET_ROTATION_STARTED`
- `SECRET_STALE_DETECTED`

**SECURITY**
- `SECURITY_ALERT_ACKNOWLEDGED`
- `SECURITY_ALERT_DEDUPLICATED`
- `SECURITY_ALERT_FIRED`
- `SECURITY_ALERT_RESOLVED`

**SPLIT**
- `SPLIT_PAYMENT_GROUP_CONFIRMED`
- `SPLIT_PAYMENT_GROUP_CREATED`
- `SPLIT_PAYMENT_GROUP_REJECTED`

**STATEMENT**
- `STATEMENT_DECLARED_PERIOD_MISMATCH`
- `STATEMENT_DEDUP_BATCH_COMPLETED`
- `STATEMENT_NORMALIZATION_AI_FALLBACK_USED`
- `STATEMENT_NORMALIZATION_FAILED`
- `STATEMENT_NORMALIZATION_FX_PAIR_RESOLVED`
- `STATEMENT_PARSER_REGISTERED`
- `STATEMENT_PARSER_REGISTRATION_DENIED`
- `STATEMENT_PARSE_COMPLETED`
- `STATEMENT_PARSE_FAILED`
- `STATEMENT_PARSE_STARTED`
- `STATEMENT_PARTIAL_UPLOAD_DETECTED`
- `STATEMENT_PDF_OCR_COMPLETED`
- `STATEMENT_PDF_OCR_FAILED`
- `STATEMENT_PDF_OCR_STARTED`
- `STATEMENT_PDF_PARSE_LOW_CONFIDENCE_ROW`
- `STATEMENT_ROW_OUTSIDE_DECLARED_PERIOD`
- `STATEMENT_UPLOAD_ACCEPTED`
- `STATEMENT_UPLOAD_COMPLETED`
- `STATEMENT_UPLOAD_EVENT_CONSUMED`
- `STATEMENT_UPLOAD_EVENT_EMITTED`
- `STATEMENT_UPLOAD_EVENT_HANDLER_FAILED`
- `STATEMENT_UPLOAD_EVENT_REPLAY_NOOP`
- `STATEMENT_UPLOAD_REJECTED_DUPLICATE_HASH`
- `STATEMENT_UPLOAD_REJECTED_PERMISSION`
- `STATEMENT_UPLOAD_REQUESTED`

**TAG**
- `TAG_ASSIGNED`
- `TAG_DEFAULT_FALLBACK_USED`
- `TAG_OVERRIDDEN_BY_USER`
- `TAG_TAXONOMY_SNAPSHOT_CAPTURED`
- `TAG_TAXONOMY_VERSION_ASSIGNED_TO_BUSINESS`
- `TAG_TAXONOMY_VERSION_CREATED`
- `TAG_TAXONOMY_VERSION_RETIRED`

**TOOL**
- `TOOL_REGISTRY_REGISTERED`
- `TOOL_REGISTRY_REJECTED`

**TRANSACTION**
- `TRANSACTION_EXCLUDED_FROM_PERIOD`
- `TRANSACTION_NORMALIZED`

**VAULT**
- `VAULT_INITIALIZED`

**VENDOR**
- `VENDOR_MEMORY_HIT`
- `VENDOR_MEMORY_PROMOTED_TO_HIGH`
- `VENDOR_MEMORY_REVOKED`

**WORKFLOW**
- `WORKFLOW_ADJUSTMENT_CREATED`
- `WORKFLOW_ADJUSTMENT_FINALIZED`
- `WORKFLOW_ADJUSTMENT_RECORD_ADDED`
- `WORKFLOW_CONFIG_UPDATED`
- `WORKFLOW_GATE_THREW`
- `WORKFLOW_PHASE_COMPLETED`
- `WORKFLOW_PHASE_ENTERED`
- `WORKFLOW_PHASE_HOLDING`
- `WORKFLOW_PHASE_ROUTED`
- `WORKFLOW_RESUMED_AFTER_RESTART`
- `WORKFLOW_REVIEW_ISSUE_REQUESTED`
- `WORKFLOW_RUN_ABORTED`
- `WORKFLOW_RUN_FINALIZED`
- `WORKFLOW_RUN_PAUSED`
- `WORKFLOW_RUN_REJECTED_DUPLICATE`
- `WORKFLOW_RUN_RESUMED`
- `WORKFLOW_RUN_STATE_CHANGED`
- `WORKFLOW_RUN_STATE_CHANGE_REJECTED`
- `WORKFLOW_RUN_TRIGGERED_BY_EVENT`
- `WORKFLOW_RUN_TRIGGERED_MANUAL`
- `WORKFLOW_RUN_TRIGGER_REJECTED`
- `WORKFLOW_SHARED_PHASE_COORDINATED`
- `WORKFLOW_SHARED_PHASE_DEDUP_HIT`
- `WORKFLOW_TOOL_DEDUP_HIT`
- `WORKFLOW_TOOL_INVOKED`
- `WORKFLOW_TOOL_REPLAY_VIA_EXTERNAL_REQUEST_ID`
- `WORKFLOW_TOOL_RETRY_REQUESTED`
- `WORKFLOW_TOOL_RETRY_SCHEDULED`
- `WORKFLOW_TOOL_SKIPPED_BY_USER`
