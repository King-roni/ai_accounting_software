# Issue Type Registry Schema

**Category:** Schemas · **Owning block:** 14 — Review Queue · **Block reference:** BLOCK_14 · **Stage:** 4 sub-doc (Layer 2)

This document specifies the `issue_type_registry` table, the `bulk_preview_tokens` table, the `registerIssueType` boot-time mechanism, and the audit events emitted when issue types are registered or bulk-action scope tokens are issued.

---

## Purpose

Every review issue raised anywhere in the system carries an `issue_type` string that identifies what the issue is. The `issue_type_registry` table is the authoritative catalogue of all known issue types. It is populated at application boot, not by migrations, so that each block module declares its own types at the point of registration rather than in a shared migration file. The registry enforces naming stability: once an issue type is registered, its `issue_group` assignment is immutable.

`bulk_preview_tokens` are short-lived tokens that allow the UI to show an accountant the exact set of issues that would be affected by a bulk action before the write is committed. The token is issued atomically against a specific `workflow_run_id` and `issue_type`, expires after 15 minutes, and can only be consumed once.

---

## Table DDL — `issue_type_registry`

```sql
CREATE TABLE issue_type_registry (
    id                    uuid          NOT NULL DEFAULT gen_uuid_v7(),
    issue_type            text          NOT NULL,
    issue_group           text          NOT NULL
                            REFERENCES issue_group_enum (value),
    display_label         text          NOT NULL,
    default_severity      severity_enum NOT NULL,
    auto_resolve_eligible boolean       NOT NULL DEFAULT false,
    registered_by_block   text          NOT NULL,
    registered_at         timestamptz   NOT NULL DEFAULT now(),
    deprecated_at         timestamptz   NULL,

    CONSTRAINT issue_type_registry_pkey       PRIMARY KEY (id),
    CONSTRAINT issue_type_registry_type_uniq  UNIQUE (issue_type)
);
```

### Column notes

| Column | Detail |
| --- | --- |
| `id` | UUID v7 (`gen_uuid_v7()`). Time-ordered; no security-token concern, so v7 applies. |
| `issue_type` | Text identifier in `UPPER_SNAKE_CASE`. The unique constraint enforces the catalogue. |
| `issue_group` | Foreign key into `issue_group_enum`. Cannot be changed after first registration (see mutation rules below). |
| `default_severity` | One of `LOW`, `MEDIUM`, `HIGH`, `BLOCKING`. Used when no per-run severity override is present. |
| `auto_resolve_eligible` | When `true`, a downstream rescan pass is permitted to resolve this issue type without human confirmation, provided the trigger condition is cleared. See `review_queue_rescan_on_resolution_policy` for rescan semantics. |
| `registered_by_block` | Short string identifying the registering block module — e.g., `BLOCK_08`, `BLOCK_11`. Informational; not a FK. |
| `registered_at` | Timestamp of first successful registration. Set once; not updated on idempotent re-registration. |
| `deprecated_at` | Nullable. Set when an issue type is retired. Deprecated types remain in the table and in existing open issues; no new issues may be raised with a deprecated `issue_type`. |

### Severity enum

`severity_enum` is a Postgres `ENUM` type with values: `LOW`, `MEDIUM`, `HIGH`, `BLOCKING`. The `CRITICAL` label is not used in this system; use `BLOCKING` for issues that halt gate evaluation.

---

## Table DDL — `bulk_preview_tokens`

```sql
CREATE TABLE bulk_preview_tokens (
    id               uuid        NOT NULL DEFAULT gen_uuid_v7(),
    workflow_run_id  uuid        NOT NULL,
    issue_type       text        NOT NULL REFERENCES issue_type_registry (issue_type),
    token            uuid        NOT NULL DEFAULT gen_random_uuid(),
    expires_at       timestamptz NOT NULL
                       DEFAULT (now() + interval '15 minutes'),
    consumed_at      timestamptz NULL,

    CONSTRAINT bulk_preview_tokens_pkey        PRIMARY KEY (id),
    CONSTRAINT bulk_preview_tokens_token_uniq  UNIQUE (token)
);

CREATE INDEX bulk_preview_tokens_run_type_idx
    ON bulk_preview_tokens (workflow_run_id, issue_type)
    WHERE consumed_at IS NULL;
```

### Column notes

| Column | Detail |
| --- | --- |
| `id` | UUID v7. PK; time-ordered. |
| `token` | UUID v4 (`gen_random_uuid()`). The value handed to the client. v4 is used here because this is a short-lived security token — the creation time must not be inferable from the token value. |
| `expires_at` | `now() + 15 minutes` at insert time. The bulk-action commit endpoint rejects tokens where `expires_at < now()` or `consumed_at IS NOT NULL`. |
| `consumed_at` | Set atomically when the bulk action is committed. Once set, the token cannot be reused. The composite partial index above supports the expiry-and-consumed check efficiently. |

### Token lifecycle

1. Accountant requests a bulk action preview — `review_queue.preview_bulk_action` issues a token by inserting a row with `consumed_at = NULL`.
2. The client receives the token UUID and a scoped preview payload (issue count, affected run, type).
3. Accountant confirms the bulk action — `review_queue.commit_bulk_action` verifies the token (`expires_at > now()` AND `consumed_at IS NULL`), applies the bulk write, then sets `consumed_at = now()` in the same transaction.
4. A nightly job purges rows where `expires_at < now() - interval '24 hours'` to keep the table compact.

---

## `registerIssueType` mechanism

`registerIssueType` is called by each block module during application boot, before any workflow run can start. The engine refuses to start a run if any issue type referenced by a phase tool is absent from the registry.

### Call shape

```ts
review_queue.registerIssueType({
  issue_type:            "CLASSIFICATION_CONFIDENCE_LOW",
  issue_group:           "CLASSIFICATION_REVIEW",
  display_label:         "Classification confidence below threshold",
  default_severity:      "MEDIUM",
  auto_resolve_eligible: true,
  registered_by_block:   "BLOCK_08",
});
```

### Idempotency

The insertion uses `ON CONFLICT (issue_type) DO NOTHING`. If the row already exists, no write occurs and no error is raised. This makes boot-order between modules irrelevant — re-registrations are safe.

### Immutability of `issue_group`

The `ON CONFLICT DO NOTHING` clause means that if a module attempts to re-register an existing `issue_type` with a different `issue_group`, the original value is silently preserved. This is intentional. Changing an `issue_group` after issues have been raised against the type would invalidate filter routing, carry-forward logic, and historical grouping. A formal type rename (which is treated as a new type) requires a `Docs/decisions_log.md` amendment and a data migration that closes open issues on the old type and re-raises them under the new type.

### Boot validation

After all modules complete `registerIssueType` calls, the engine runs a post-boot assertion:

- Every `issue_type` value referenced in any registered tool's `audit_events` or phase config is present in `issue_type_registry`.
- No `issue_type` in the registry has an `issue_group` value absent from `issue_group_enum`.
- No two registrations share an `issue_type` with different `issue_group` values (impossible via `DO NOTHING`, but checked as a sanity assertion).

Boot fails with a fatal error and logs a structured message if any assertion fails. The `TOOL_REGISTRY_STARTUP_FAILED` audit event is emitted.

### Deprecation

Deprecating an issue type sets `deprecated_at = now()` on the registry row. The engine then:

1. Rejects new `review_issues` rows with that `issue_type`.
2. Allows existing open issues of that type to remain open and resolve normally.
3. Excludes the type from `registerIssueType` boot assertions going forward.

Deprecation is not the same as deletion. The row is retained permanently for audit-history queries.

---

## Audit events

### `REVIEW_QUEUE_ISSUE_TYPE_REGISTERED`

Severity: `LOW`

Emitted by `review_queue.registerIssueType` when a new row is successfully inserted (i.e., not the idempotent no-op path).

Payload:

| Field | Type | Description |
| --- | --- | --- |
| `issue_type` | text | The registered type identifier |
| `issue_group` | text | The group it was assigned to |
| `default_severity` | text | Severity enum value |
| `auto_resolve_eligible` | boolean | Whether auto-resolution is permitted |
| `registered_by_block` | text | Originating block |
| `registered_at` | timestamptz | Insertion timestamp |

Chain: business chain if a business context is active at boot; global chain otherwise.

---

### `REVIEW_QUEUE_BULK_PREVIEW_TOKEN_ISSUED`

Severity: `LOW`

Emitted by `review_queue.preview_bulk_action` when a `bulk_preview_tokens` row is inserted.

Payload:

| Field | Type | Description |
| --- | --- | --- |
| `token_id` | uuid | PK of the `bulk_preview_tokens` row (UUID v7) |
| `workflow_run_id` | uuid | Run the preview is scoped to |
| `issue_type` | text | Issue type the bulk action targets |
| `expires_at` | timestamptz | Token expiry |
| `issued_by_user_id` | uuid | Accountant who initiated the preview |

The token UUID itself (`token` column, UUID v4) is not included in the audit payload. The audit record proves the token was issued without exposing the secret value.

---

## Cross-references

- `review_queue_filter_schema.md` — filter clauses reference `issue_type` and `issue_group` columns from this registry
- `full_issue_type_to_group_routing_table.md` — exhaustive mapping of every registered type to its group, with default severity
- `issue_group_enum.md` — defines the `issue_group_enum` FK target values
- `issue_escalation_policy.md` — escalation rules reference `default_severity` and `auto_resolve_eligible` from this registry
- `review_queue_rescan_on_resolution_policy.md` — rescan triggers are declared per `issue_type` in the registry; `auto_resolve_eligible` gates whether a rescan can resolve without human action
- `audit_event_taxonomy.md` — `REVIEW_QUEUE_ISSUE_TYPE_REGISTERED`, `REVIEW_QUEUE_BULK_PREVIEW_TOKEN_ISSUED`
- `data_layer_conventions_policy.md` — UUID v7 for PKs, UUID v4 for the security token field
