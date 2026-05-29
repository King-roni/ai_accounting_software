# Fixture Content: Security & Audit Subsystem
**Category:** Fixtures · Block 05 — Security & Audit
**Last updated:** 2026-05-17

---

## Overview

This file defines per-fixture test data for the security and audit subsystem. Each fixture
specifies the input event sequence, the expected system state after processing, and the
verification assertions that test code must confirm.

All fixture event IDs use `gen_uuid_v7()` format for audit event PKs. Session IDs use
`gen_random_uuid()` format per the UUID policy.

---

## FIXTURE_SECURITY_HASH_CHAIN_VALID

**Purpose:** Verify that `hash_chain.verify` returns a clean result when all 10 audit events
in a sequence carry correct chain hashes.

**Setup:** Insert the following 10 events in order. Each `chain_hash` is the SHA-256 of
`(previous_chain_hash || event_id || event_type || actor_user_id || created_at_unix)`.

```json
[
  {
    "sequence": 1,
    "id": "01900000-0000-7000-8000-000000000001",
    "event_type": "WORKFLOW_RUN_CREATED",
    "actor_user_id": "usr_fixture_owner_01",
    "business_entity_id": "biz_fixture_01",
    "created_at": "2025-03-01T09:00:00Z",
    "chain_hash": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
    "previous_chain_hash": null
  },
  {
    "sequence": 2,
    "id": "01900000-0000-7000-8000-000000000002",
    "event_type": "WORKFLOW_PHASE_ADVANCED",
    "actor_user_id": "usr_fixture_owner_01",
    "business_entity_id": "biz_fixture_01",
    "created_at": "2025-03-01T09:01:00Z",
    "chain_hash": "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3",
    "previous_chain_hash": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
  },
  {
    "sequence": 3,
    "id": "01900000-0000-7000-8000-000000000003",
    "event_type": "LEDGER_ENTRY_POSTED",
    "actor_user_id": "usr_fixture_owner_01",
    "business_entity_id": "biz_fixture_01",
    "created_at": "2025-03-01T09:02:00Z",
    "chain_hash": "c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4",
    "previous_chain_hash": "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3"
  },
  {
    "sequence": 4,
    "id": "01900000-0000-7000-8000-000000000004",
    "event_type": "VAT_PERIOD_TOTALS_UPDATED",
    "actor_user_id": "usr_fixture_owner_01",
    "business_entity_id": "biz_fixture_01",
    "created_at": "2025-03-01T09:03:00Z",
    "chain_hash": "d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5",
    "previous_chain_hash": "c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"
  },
  {
    "sequence": 5,
    "id": "01900000-0000-7000-8000-000000000005",
    "event_type": "WORKFLOW_APPROVAL_REQUESTED",
    "actor_user_id": "usr_fixture_owner_01",
    "business_entity_id": "biz_fixture_01",
    "created_at": "2025-03-01T09:04:00Z",
    "chain_hash": "e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6",
    "previous_chain_hash": "d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5"
  },
  {
    "sequence": 6,
    "id": "01900000-0000-7000-8000-000000000006",
    "event_type": "WORKFLOW_APPROVAL_APPROVED",
    "actor_user_id": "usr_fixture_owner_01",
    "business_entity_id": "biz_fixture_01",
    "created_at": "2025-03-01T09:05:00Z",
    "chain_hash": "f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1",
    "previous_chain_hash": "e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6"
  },
  {
    "sequence": 7,
    "id": "01900000-0000-7000-8000-000000000007",
    "event_type": "WORKFLOW_RUN_ADVANCED_TO_FINALIZING",
    "actor_user_id": "usr_fixture_owner_01",
    "business_entity_id": "biz_fixture_01",
    "created_at": "2025-03-01T09:06:00Z",
    "chain_hash": "a7b8c9d0e1f2a7b8c9d0e1f2a7b8c9d0e1f2a7b8c9d0e1f2a7b8c9d0e1f2a7b8",
    "previous_chain_hash": "f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1"
  },
  {
    "sequence": 8,
    "id": "01900000-0000-7000-8000-000000000008",
    "event_type": "ARCHIVE_BUNDLE_CREATED",
    "actor_user_id": "usr_fixture_owner_01",
    "business_entity_id": "biz_fixture_01",
    "created_at": "2025-03-01T09:07:00Z",
    "chain_hash": "b8c9d0e1f2a3b8c9d0e1f2a3b8c9d0e1f2a3b8c9d0e1f2a3b8c9d0e1f2a3b8c9",
    "previous_chain_hash": "a7b8c9d0e1f2a7b8c9d0e1f2a7b8c9d0e1f2a7b8c9d0e1f2a7b8c9d0e1f2a7b8"
  },
  {
    "sequence": 9,
    "id": "01900000-0000-7000-8000-000000000009",
    "event_type": "WORKFLOW_RUN_FINALIZED",
    "actor_user_id": "usr_fixture_owner_01",
    "business_entity_id": "biz_fixture_01",
    "created_at": "2025-03-01T09:08:00Z",
    "chain_hash": "c9d0e1f2a3b4c9d0e1f2a3b4c9d0e1f2a3b4c9d0e1f2a3b4c9d0e1f2a3b4c9d0",
    "previous_chain_hash": "b8c9d0e1f2a3b8c9d0e1f2a3b8c9d0e1f2a3b8c9d0e1f2a3b8c9d0e1f2a3b8c9"
  },
  {
    "sequence": 10,
    "id": "01900000-0000-7000-8000-000000000010",
    "event_type": "ARCHIVE_BUNDLE_SEALED",
    "actor_user_id": "usr_fixture_owner_01",
    "business_entity_id": "biz_fixture_01",
    "created_at": "2025-03-01T09:09:00Z",
    "chain_hash": "d0e1f2a3b4c5d0e1f2a3b4c5d0e1f2a3b4c5d0e1f2a3b4c5d0e1f2a3b4c5d0e1",
    "previous_chain_hash": "c9d0e1f2a3b4c9d0e1f2a3b4c9d0e1f2a3b4c9d0e1f2a3b4c9d0e1f2a3b4c9d0"
  }
]
```

**Expected verification result:**
```json
{
  "verified": true,
  "rows_checked": 10,
  "first_broken_at_sequence": null
}
```

---

## FIXTURE_SECURITY_HASH_CHAIN_BROKEN

**Purpose:** Verify that `hash_chain.verify` detects a corrupted chain hash at sequence 6.

**Setup:** Use the same 10 events as `FIXTURE_SECURITY_HASH_CHAIN_VALID` with one change:
event at `sequence = 6` has its `chain_hash` deliberately corrupted:

```json
{
  "sequence": 6,
  "id": "01900000-0000-7000-8000-000000000006",
  "event_type": "WORKFLOW_APPROVAL_APPROVED",
  "actor_user_id": "usr_fixture_owner_01",
  "business_entity_id": "biz_fixture_01",
  "created_at": "2025-03-01T09:05:00Z",
  "chain_hash": "CORRUPTED000000000000000000000000000000000000000000000000000000000",
  "previous_chain_hash": "e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6"
}
```

Events 1–5 are identical to the valid fixture. Events 7–10 carry `previous_chain_hash` values
derived from the corrupted event 6 hash, so the chain break propagates from sequence 6 onward.

**Expected verification result:**
```json
{
  "verified": false,
  "rows_checked": 6,
  "first_broken_at_sequence": 6
}
```

**Assertion:** The verifier must stop at the first broken link and not report `rows_checked`
beyond the break point.

---

## FIXTURE_SECURITY_STEP_UP_FLOW

**Purpose:** Verify the complete step-up auth flow: token issued → consumed → protected action
completed.

**Event sequence:**
```json
[
  {
    "sequence": 1,
    "id": "01900000-0000-7000-8000-000000000101",
    "event_type": "AUTH_STEP_UP_ISSUED",
    "actor_user_id": "usr_fixture_admin_01",
    "session_id": "550e8400-e29b-41d4-a716-446655440001",
    "payload": {
      "step_up_token_id": "550e8400-e29b-41d4-a716-446655440099",
      "context": "finalization_approval",
      "expires_at": "2025-03-01T09:20:00Z"
    },
    "created_at": "2025-03-01T09:10:00Z"
  },
  {
    "sequence": 2,
    "id": "01900000-0000-7000-8000-000000000102",
    "event_type": "AUTH_STEP_UP_CONSUMED",
    "actor_user_id": "usr_fixture_admin_01",
    "session_id": "550e8400-e29b-41d4-a716-446655440001",
    "payload": {
      "step_up_token_id": "550e8400-e29b-41d4-a716-446655440099",
      "context": "finalization_approval",
      "consumed_at": "2025-03-01T09:11:30Z"
    },
    "created_at": "2025-03-01T09:11:30Z"
  },
  {
    "sequence": 3,
    "id": "01900000-0000-7000-8000-000000000103",
    "event_type": "WORKFLOW_APPROVAL_APPROVED",
    "actor_user_id": "usr_fixture_admin_01",
    "session_id": "550e8400-e29b-41d4-a716-446655440001",
    "payload": {
      "step_up_token_id": "550e8400-e29b-41d4-a716-446655440099",
      "workflow_run_id": "01900000-0000-7000-8000-000000000200",
      "approval_id": "01900000-0000-7000-8000-000000000201"
    },
    "created_at": "2025-03-01T09:11:35Z"
  }
]
```

**Expected state after sequence:**
- `step_up_tokens.status = CONSUMED` for token `550e8400-e29b-41d4-a716-446655440099`
- `step_up_tokens.consumed_at` is set
- `workflow_run_approvals.status = APPROVED` for approval `01900000-0000-7000-8000-000000000201`
- Protected action (`WORKFLOW_APPROVAL_APPROVED`) completed successfully

---

## FIXTURE_SECURITY_MAX_ATTEMPTS

**Purpose:** Verify that 5 consecutive `AUTH_STEP_UP_FAILED` events trigger
`AUTH_STEP_UP_FAILED_MAX_ATTEMPTS` and session invalidation.

**Event sequence:**
```json
[
  {
    "sequence": 1,
    "id": "01900000-0000-7000-8000-000000000301",
    "event_type": "AUTH_STEP_UP_FAILED",
    "actor_user_id": "usr_fixture_accountant_01",
    "session_id": "550e8400-e29b-41d4-a716-446655440002",
    "payload": { "attempt": 1, "failure_reason": "INVALID_TOTP_CODE" },
    "created_at": "2025-03-01T10:00:00Z"
  },
  {
    "sequence": 2,
    "id": "01900000-0000-7000-8000-000000000302",
    "event_type": "AUTH_STEP_UP_FAILED",
    "actor_user_id": "usr_fixture_accountant_01",
    "session_id": "550e8400-e29b-41d4-a716-446655440002",
    "payload": { "attempt": 2, "failure_reason": "INVALID_TOTP_CODE" },
    "created_at": "2025-03-01T10:03:00Z"
  },
  {
    "sequence": 3,
    "id": "01900000-0000-7000-8000-000000000303",
    "event_type": "AUTH_STEP_UP_FAILED",
    "actor_user_id": "usr_fixture_accountant_01",
    "session_id": "550e8400-e29b-41d4-a716-446655440002",
    "payload": { "attempt": 3, "failure_reason": "INVALID_TOTP_CODE" },
    "created_at": "2025-03-01T10:06:00Z"
  },
  {
    "sequence": 4,
    "id": "01900000-0000-7000-8000-000000000304",
    "event_type": "AUTH_STEP_UP_FAILED",
    "actor_user_id": "usr_fixture_accountant_01",
    "session_id": "550e8400-e29b-41d4-a716-446655440002",
    "payload": { "attempt": 4, "failure_reason": "INVALID_TOTP_CODE" },
    "created_at": "2025-03-01T10:09:00Z"
  },
  {
    "sequence": 5,
    "id": "01900000-0000-7000-8000-000000000305",
    "event_type": "AUTH_STEP_UP_FAILED",
    "actor_user_id": "usr_fixture_accountant_01",
    "session_id": "550e8400-e29b-41d4-a716-446655440002",
    "payload": { "attempt": 5, "failure_reason": "INVALID_TOTP_CODE" },
    "created_at": "2025-03-01T10:12:00Z"
  }
]
```

**Expected state after sequence 5:**
- `AUTH_STEP_UP_FAILED_MAX_ATTEMPTS` (HIGH) emitted synchronously after the 5th failure
- `sessions.status = INVALIDATED` for `session_id = 550e8400-e29b-41d4-a716-446655440002`
- `sessions.invalidation_reason = STEP_UP_MAX_ATTEMPTS`
- `sessions.invalidated_at` is set to the timestamp of the 5th failure
- No further step-up challenges accepted for this `session_id`

**Boundary condition:** All 5 failures must occur within a 1-hour rolling window. If the 5th
failure occurs more than 1 hour after the 1st, the counter resets and lockout is not triggered.
Test this boundary by re-running the fixture with `sequence 1 created_at` shifted to
`2025-03-01T09:11:00Z` (>60 minutes before sequence 5) — expected result: no lockout, counter
resets after sequence 1 ages out.

---

## Cross-References

- `hash_chain_verification_policy.md`
- `step_up_token_schema.md`
- `tool_emit_audit.md`
- `tool_hash_chain_append.md`
- `audit_event_taxonomy.md`
- `session_schema.md`
- `mfa_lockout_runbook.md`

---

## FIXTURE_AUTH_FAILED_LOGIN_THEN_MFA_SUCCESS

**Purpose:** Verify that a failed password attempt followed by a successful MFA-backed login
produces the correct audit trail: one `AUTH_LOGIN_FAILED` event, then the full successful
flow (`AUTH_LOGIN_ATTEMPTED`, `AUTH_MFA_CHALLENGED`, `AUTH_MFA_PASSED`, `AUTH_SESSION_CREATED`).

All `audit_log` rows use the full column set:
`id` (gen_uuid_v7), `event_name`, `actor_id`, `resource_type`, `resource_id`,
`payload` (jsonb), `ip_address`, `occurred_at`, `chain_hash`.

```json
[
  {
    "id": "01930001-0000-7000-8000-000000000001",
    "event_name": "AUTH_LOGIN_FAILED",
    "actor_id": "usr_fixture_owner_01",
    "resource_type": "user",
    "resource_id": "usr_fixture_owner_01",
    "payload": {
      "reason": "INVALID_PASSWORD",
      "email": "owner@example.cy",
      "attempt": 1
    },
    "ip_address": "185.34.12.88",
    "occurred_at": "2026-03-10T08:01:00Z",
    "chain_hash": "aa01bb02cc03dd04ee05ff06aa01bb02cc03dd04ee05ff06aa01bb02cc03dd04"
  },
  {
    "id": "01930001-0000-7000-8000-000000000002",
    "event_name": "AUTH_LOGIN_ATTEMPTED",
    "actor_id": "usr_fixture_owner_01",
    "resource_type": "user",
    "resource_id": "usr_fixture_owner_01",
    "payload": {
      "email": "owner@example.cy",
      "mfa_required": true
    },
    "ip_address": "185.34.12.88",
    "occurred_at": "2026-03-10T08:02:10Z",
    "chain_hash": "bb02cc03dd04ee05ff06aa01bb02cc03dd04ee05ff06aa01bb02cc03dd04ee05"
  },
  {
    "id": "01930001-0000-7000-8000-000000000003",
    "event_name": "AUTH_MFA_CHALLENGED",
    "actor_id": "usr_fixture_owner_01",
    "resource_type": "user",
    "resource_id": "usr_fixture_owner_01",
    "payload": {
      "mfa_method": "TOTP",
      "challenge_id": "chl_fixture_001"
    },
    "ip_address": "185.34.12.88",
    "occurred_at": "2026-03-10T08:02:12Z",
    "chain_hash": "cc03dd04ee05ff06aa01bb02cc03dd04ee05ff06aa01bb02cc03dd04ee05ff06"
  },
  {
    "id": "01930001-0000-7000-8000-000000000004",
    "event_name": "AUTH_MFA_PASSED",
    "actor_id": "usr_fixture_owner_01",
    "resource_type": "user",
    "resource_id": "usr_fixture_owner_01",
    "payload": {
      "mfa_method": "TOTP",
      "challenge_id": "chl_fixture_001"
    },
    "ip_address": "185.34.12.88",
    "occurred_at": "2026-03-10T08:02:28Z",
    "chain_hash": "dd04ee05ff06aa01bb02cc03dd04ee05ff06aa01bb02cc03dd04ee05ff06aa01"
  },
  {
    "id": "01930001-0000-7000-8000-000000000005",
    "event_name": "AUTH_SESSION_CREATED",
    "actor_id": "usr_fixture_owner_01",
    "resource_type": "session",
    "resource_id": "550e8400-e29b-41d4-a716-446655440010",
    "payload": {
      "session_id": "550e8400-e29b-41d4-a716-446655440010",
      "mfa_verified": true,
      "expires_at": "2026-03-10T20:02:28Z"
    },
    "ip_address": "185.34.12.88",
    "occurred_at": "2026-03-10T08:02:29Z",
    "chain_hash": "ee05ff06aa01bb02cc03dd04ee05ff06aa01bb02cc03dd04ee05ff06aa01bb02"
  }
]
```

**Expected outcome:** Session `550e8400-e29b-41d4-a716-446655440010` is ACTIVE, `mfa_verified
= true`. The failed login at event 1 does not increment the step-up failure counter (different
counter from `AUTH_STEP_UP_FAILED`).

---

## FIXTURE_STEP_UP_FOR_PERIOD_LOCK

**Purpose:** Verify that locking a VAT period requires a step-up token, and that the
correct audit trail is produced.

Note: `PERIOD_LOCKED` must exist in the audit event taxonomy before this fixture is
used in production test runs. Add it if not present.

```json
[
  {
    "id": "01930002-0000-7000-8000-000000000001",
    "event_name": "AUTH_STEP_UP_ISSUED",
    "actor_id": "usr_fixture_admin_01",
    "resource_type": "vat_period",
    "resource_id": "018f4e2a-0001-7000-8000-000000000001",
    "payload": {
      "step_up_token_id": "550e8400-e29b-41d4-a716-446655440020",
      "context": "period_lock",
      "expires_at": "2026-03-31T23:20:00Z"
    },
    "ip_address": "91.186.44.12",
    "occurred_at": "2026-03-31T23:10:00Z",
    "chain_hash": "ff06aa01bb02cc03dd04ee05ff06aa01bb02cc03dd04ee05ff06aa01bb02cc03"
  },
  {
    "id": "01930002-0000-7000-8000-000000000002",
    "event_name": "AUTH_STEP_UP_CONSUMED",
    "actor_id": "usr_fixture_admin_01",
    "resource_type": "vat_period",
    "resource_id": "018f4e2a-0001-7000-8000-000000000001",
    "payload": {
      "step_up_token_id": "550e8400-e29b-41d4-a716-446655440020",
      "context": "period_lock"
    },
    "ip_address": "91.186.44.12",
    "occurred_at": "2026-03-31T23:11:05Z",
    "chain_hash": "aa07bb08cc09dd0aee0bff0caa07bb08cc09dd0aee0bff0caa07bb08cc09dd0a"
  },
  {
    "id": "01930002-0000-7000-8000-000000000003",
    "event_name": "PERIOD_LOCKED",
    "actor_id": "usr_fixture_admin_01",
    "resource_type": "vat_period",
    "resource_id": "018f4e2a-0001-7000-8000-000000000001",
    "payload": {
      "step_up_token_id": "550e8400-e29b-41d4-a716-446655440020",
      "period_label": "Q1 2026",
      "locked_at": "2026-03-31T23:11:06Z"
    },
    "ip_address": "91.186.44.12",
    "occurred_at": "2026-03-31T23:11:06Z",
    "chain_hash": "bb08cc09dd0aee0bff0caa07bb08cc09dd0aee0bff0caa07bb08cc09dd0aee0b"
  }
]
```

**Expected outcome:** `vat_periods.locked = true` for period Q1 2026. `step_up_tokens.status
= CONSUMED`. `PERIOD_LOCKED` event is present in audit chain.

---

## FIXTURE_ADMIN_API_KEY_CREATE_AND_USE

**Purpose:** Verify that API key creation and first use each emit audit events, and that the
key creation requires ADMIN role.

```json
[
  {
    "id": "01930003-0000-7000-8000-000000000001",
    "event_name": "API_KEY_CREATED",
    "actor_id": "usr_fixture_admin_01",
    "resource_type": "api_key",
    "resource_id": "key_fixture_001",
    "payload": {
      "key_name": "CI pipeline read key",
      "scopes": ["reports:read", "ledger:read"],
      "expires_at": "2027-03-10T00:00:00Z",
      "key_prefix": "bk_live_abc123"
    },
    "ip_address": "91.186.44.12",
    "occurred_at": "2026-03-10T09:00:00Z",
    "chain_hash": "cc09dd0aee0bff0caa07bb08cc09dd0aee0bff0caa07bb08cc09dd0aee0bff0c"
  },
  {
    "id": "01930003-0000-7000-8000-000000000002",
    "event_name": "API_KEY_VIEWED",
    "actor_id": "usr_fixture_admin_01",
    "resource_type": "api_key",
    "resource_id": "key_fixture_001",
    "payload": {
      "key_name": "CI pipeline read key",
      "note": "Full key shown once at creation"
    },
    "ip_address": "91.186.44.12",
    "occurred_at": "2026-03-10T09:00:01Z",
    "chain_hash": "dd0aee0bff0caa07bb08cc09dd0aee0bff0caa07bb08cc09dd0aee0bff0caa07"
  },
  {
    "id": "01930003-0000-7000-8000-000000000003",
    "event_name": "API_KEY_USED",
    "actor_id": "key_fixture_001",
    "resource_type": "api_key",
    "resource_id": "key_fixture_001",
    "payload": {
      "endpoint": "GET /v1/reports",
      "http_status": 200,
      "key_prefix": "bk_live_abc123"
    },
    "ip_address": "10.0.1.55",
    "occurred_at": "2026-03-10T09:15:00Z",
    "chain_hash": "ee0bff0caa07bb08cc09dd0aee0bff0caa07bb08cc09dd0aee0bff0caa07bb08"
  },
  {
    "id": "01930003-0000-7000-8000-000000000004",
    "event_name": "API_KEY_USED",
    "actor_id": "key_fixture_001",
    "resource_type": "api_key",
    "resource_id": "key_fixture_001",
    "payload": {
      "endpoint": "GET /v1/ledger/entries",
      "http_status": 200,
      "key_prefix": "bk_live_abc123"
    },
    "ip_address": "10.0.1.55",
    "occurred_at": "2026-03-10T09:15:04Z",
    "chain_hash": "ff0caa07bb08cc09dd0aee0bff0caa07bb08cc09dd0aee0bff0caa07bb08cc09"
  }
]
```

**Expected outcome:** `api_keys` row for `key_fixture_001` exists with `status = ACTIVE`.
Both `API_KEY_USED` events are recorded. Key hash is stored; plain text is never stored
after the `API_KEY_VIEWED` event at creation time.

---

## FIXTURE_GDPR_ERASURE_REQUEST_AND_EXECUTION

**Purpose:** Verify the GDPR erasure flow: request submitted, operator reviews, execution
runs, confirmation emitted, and audit trail is preserved (audit log rows for the erasure
actor are retained per legal hold policy even after erasure).

```json
[
  {
    "id": "01930004-0000-7000-8000-000000000001",
    "event_name": "GDPR_ERASURE_REQUESTED",
    "actor_id": "usr_fixture_owner_01",
    "resource_type": "user",
    "resource_id": "usr_fixture_owner_01",
    "payload": {
      "request_id": "erasure_req_001",
      "reason": "Account closure",
      "deadline": "2026-04-09T00:00:00Z"
    },
    "ip_address": "185.34.12.88",
    "occurred_at": "2026-03-10T10:00:00Z",
    "chain_hash": "aa10bb11cc12dd13ee14ff15aa10bb11cc12dd13ee14ff15aa10bb11cc12dd13"
  },
  {
    "id": "01930004-0000-7000-8000-000000000002",
    "event_name": "GDPR_ERASURE_REVIEWED",
    "actor_id": "usr_fixture_admin_01",
    "resource_type": "user",
    "resource_id": "usr_fixture_owner_01",
    "payload": {
      "request_id": "erasure_req_001",
      "review_outcome": "APPROVED",
      "reviewed_at": "2026-03-11T09:00:00Z"
    },
    "ip_address": "91.186.44.12",
    "occurred_at": "2026-03-11T09:00:00Z",
    "chain_hash": "bb11cc12dd13ee14ff15aa10bb11cc12dd13ee14ff15aa10bb11cc12dd13ee14"
  },
  {
    "id": "01930004-0000-7000-8000-000000000003",
    "event_name": "GDPR_ERASURE_STARTED",
    "actor_id": "system",
    "resource_type": "user",
    "resource_id": "usr_fixture_owner_01",
    "payload": {
      "request_id": "erasure_req_001",
      "tables_targeted": ["users", "sessions", "notifications", "documents_metadata"]
    },
    "ip_address": "127.0.0.1",
    "occurred_at": "2026-03-11T09:01:00Z",
    "chain_hash": "cc12dd13ee14ff15aa10bb11cc12dd13ee14ff15aa10bb11cc12dd13ee14ff15"
  },
  {
    "id": "01930004-0000-7000-8000-000000000004",
    "event_name": "GDPR_ERASURE_COMPLETED",
    "actor_id": "system",
    "resource_type": "user",
    "resource_id": "usr_fixture_owner_01",
    "payload": {
      "request_id": "erasure_req_001",
      "rows_erased": 47,
      "fields_nulled": 12,
      "audit_log_retained": true,
      "retention_reason": "LEGAL_HOLD"
    },
    "ip_address": "127.0.0.1",
    "occurred_at": "2026-03-11T09:01:45Z",
    "chain_hash": "dd13ee14ff15aa10bb11cc12dd13ee14ff15aa10bb11cc12dd13ee14ff15aa10"
  },
  {
    "id": "01930004-0000-7000-8000-000000000005",
    "event_name": "GDPR_ERASURE_NOTIFICATION_SENT",
    "actor_id": "system",
    "resource_type": "user",
    "resource_id": "usr_fixture_owner_01",
    "payload": {
      "request_id": "erasure_req_001",
      "notification_channel": "email",
      "recipient": "owner@example.cy",
      "sent_at": "2026-03-11T09:02:00Z"
    },
    "ip_address": "127.0.0.1",
    "occurred_at": "2026-03-11T09:02:00Z",
    "chain_hash": "ee14ff15aa10bb11cc12dd13ee14ff15aa10bb11cc12dd13ee14ff15aa10bb11"
  }
]
```

**Expected outcome:** User `usr_fixture_owner_01` PII is erased (name, email, phone nulled).
Sessions invalidated. Audit log rows retained with `actor_id = usr_fixture_owner_01`
pseudonymised but chain intact. `gdpr_erasure_requests.status = COMPLETED`.

**Note on audit event taxonomy:** The following events used above must exist in
`audit_event_taxonomy.md` before this fixture is referenced in production test runs:
`GDPR_ERASURE_REQUESTED`, `GDPR_ERASURE_REVIEWED`, `GDPR_ERASURE_STARTED`,
`GDPR_ERASURE_COMPLETED`, `GDPR_ERASURE_NOTIFICATION_SENT`, `PERIOD_LOCKED`,
`API_KEY_CREATED`, `API_KEY_VIEWED`, `API_KEY_USED`, `AUTH_LOGIN_ATTEMPTED`,
`AUTH_MFA_CHALLENGED`, `AUTH_MFA_PASSED`, `AUTH_SESSION_CREATED`. Add any that are missing.
