# failure_review_issue_shape_policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Co-owner:** 14 — Review Queue & Human Review · **Stage:** 4 sub-doc (Layer 2)

The canonical shape for review-queue issues produced when a tool invocation fails persistently. Defines the three issue types the engine emits on tool failure, their title format, description template with placeholders, severity assignment, and the suggested-action set per error class — the data that drives the user's choice of Retry / Skip / Abort per `failure_user_action_flow_policy`.

This policy sits between `error_classification_policy` (which categorises the failure) and `failure_user_action_flow_policy` (which handles the user's response). It does NOT define the user's button semantics — that's the action-flow policy's job.

---

## Three issue types (registered at boot)

Per phase doc B03·P08, the engine produces exactly three issue types for tool failures, keyed on the error class category:

| Issue type | Trigger | Severity | Maps from error_class |
| --- | --- | --- | --- |
| `TOOL_TRANSIENT_FAILURE_EXHAUSTED` | Retryable error class exhausted retry budget | `HIGH` (standard) or `BLOCKING` (FINALIZATION path) | `TRANSIENT_NETWORK`, `RATE_LIMITED`, `TIMEOUT`, `SERVICE_UNAVAILABLE` |
| `TOOL_FATAL_ERROR` | Non-retryable error class (other than VALIDATION) | `BLOCKING` | `PERMISSION_DENIED`, `DATA_INTEGRITY_ERROR`, `UNKNOWN` |
| `TOOL_SCHEMA_ERROR` | Schema-validation failure | `HIGH` | `VALIDATION_ERROR` |

Boot-time registration into `issue_type_registry` (per `issue_type_registry_schema` from B14·P02): all three rows are inserted with `producing_block = 03`, the canonical severity, and the `allowed_resolution_actions` per the action-set table below.

Gate failures and lock failures produce DIFFERENT issue types — `GATE_EVALUATION_FAILED`, `GATE_INFINITE_LOOP_PROTECTION_TRIPPED` (per `gate_throws_semantics_policy`), `ENGINE_LOCK_CONTENTION` (per `phase_execution_locking_policy`). Those are owned by their respective policies, not this one.

## Title format

```
Workflow run #<run_seq>: <human_phase_name> failed at <tool_friendly_name>
```

Examples:
- `Workflow run #2026-04-OUT-042: Bank Statement Import failed at Parse CSV`
- `Workflow run #2026-04-IN-013: Document OCR failed at Document AI Extract`
- `Workflow run #2026-04-OUT-042: Finalization failed at Hash Chain Verify`

Constraints:
- Max 120 characters; truncated with `…` if longer
- `<run_seq>` is the human-readable sequence ID (per `workflow_run_schema` derived from period + workflow_type + per-period counter), NOT the run UUID
- `<human_phase_name>` is from `workflow_phase_definitions.display_name` (NOT the SCREAMING_SNAKE_CASE enum value)
- `<tool_friendly_name>` is from `tool_registry.display_name` (NOT the dotted internal name)

The title is plain text — no HTML, no markdown. It's used both in the in-app card title AND in email notification subject lines, so it must render cleanly in both surfaces.

## Description template (placeholders)

Each issue type has a `plain_language_template_ref` (per `issue_type_registry`) pointing at a template under `Docs/templates/review_issue_descriptions/`. The templates are NOT in this policy — this policy pins the placeholder set every template must support.

Universal placeholders (every template):

| Placeholder | Source |
| --- | --- |
| `{run_seq}` | `workflow_runs.sequence_id` (human-readable) |
| `{run_uuid}` | `workflow_runs.id` (UUID v7) |
| `{phase_name}` | `workflow_phase_definitions.display_name` |
| `{tool_friendly_name}` | `tool_registry.display_name` |
| `{error_class}` | One of the 8 canonical values per `retry_policy` §1 |
| `{error_class_signal}` | Vendor-specific signal (e.g., "HTTP 429 from Gmail API") per `error_classification_policy` audit shape |
| `{last_error_message_redacted}` | PII-redacted vendor message |
| `{attempt_count}` | `tool_invocations.attempt_number` of the final failed attempt |
| `{failed_at}` | timestamptz, rendered in the business's display timezone |
| `{period_label}` | The VAT period the run targets (e.g., "April 2026") |

Issue-type-specific placeholders:

| Placeholder | Issue type | Notes |
| --- | --- | --- |
| `{retry_budget}` | TOOL_TRANSIENT_FAILURE_EXHAUSTED | The configured retry budget (typically 3, or 2 for AI tier) |
| `{retry_window_elapsed}` | TOOL_TRANSIENT_FAILURE_EXHAUSTED | Total time from first attempt to final failure (e.g., "14 seconds") |
| `{rejection_reason}` | TOOL_FATAL_ERROR | Best-effort human translation of the vendor's rejection |
| `{schema_path}` | TOOL_SCHEMA_ERROR | JSONPath to the validation-failed field (e.g., `$.input.transaction_id`) |
| `{schema_expected}` | TOOL_SCHEMA_ERROR | Expected type from the schema |
| `{schema_received}` | TOOL_SCHEMA_ERROR | Actual value type received (PII-safe) |

Templates use `{{handlebars}}`-style placeholders. Unfilled placeholders render as `<unknown>` rather than leaving the placeholder visible.

## Suggested-action set per error class

`issue_type_registry.allowed_resolution_actions` is a `resolution_action_kind_enum[]` (the 13-value enum per BOOK-197). For tool-failure issues:

| Error class category | allowed_resolution_actions |
| --- | --- |
| `TRANSIENT_NETWORK`, `RATE_LIMITED`, `TIMEOUT`, `SERVICE_UNAVAILABLE` | `RETRY`, `SKIP_IF_OPTIONAL`, `ABORT_RUN`, `RESOLVE_MANUALLY` |
| `PERMISSION_DENIED` | `RE_AUTHENTICATE`, `ABORT_RUN`, `RESOLVE_MANUALLY` |
| `DATA_INTEGRITY_ERROR` | `RESOLVE_MANUALLY`, `ABORT_RUN` |
| `UNKNOWN` | `RETRY` (single optimistic attempt), `ABORT_RUN`, `REPORT_BUG`, `RESOLVE_MANUALLY` |
| `VALIDATION_ERROR` | `REPORT_BUG`, `ABORT_RUN` |

The `allowed_resolution_actions` array is the universe of resolution buttons the review-queue UI may surface. The action-flow policy decides which subset is enabled (e.g., `SKIP_IF_OPTIONAL` is enabled only when the failing tool is declared optional in the phase).

`RESOLVE_MANUALLY` is the "I fixed it externally; mark this resolved" action — used when the user resolves the underlying cause outside the app (e.g., re-uploads a missing document, restores access in the vendor portal) and wants the issue closed without engine action.

## Severity assignment rules

Default severity per the table at §1:

- `TOOL_TRANSIENT_FAILURE_EXHAUSTED` = `HIGH`. Promoted to `BLOCKING` when the failed phase is in the FINALIZATION path (per `workflow_phase_definitions.is_finalization_critical = true` per B03·P02).
- `TOOL_FATAL_ERROR` = `BLOCKING`. The run cannot continue without operator action.
- `TOOL_SCHEMA_ERROR` = `HIGH`. Schema mismatches usually indicate engine bugs (not user error); they need engineering triage but rarely block the user from working around.

Severity feeds the dashboard's `v_blocking_issues` view: BLOCKING issues prevent finalization per `gate_finalization_zero_blocking_issues` (B15·P07). HIGH issues warn but do not block.

## Issue creation flow

Inside the engine's failure handler (per `phase_execution_loop_policy` E3 + `retry_policy` §5):

```sql
INSERT INTO review_issues (
  id,
  workflow_run_id,
  business_id,
  issue_type,                                   -- one of the three above
  severity,                                     -- HIGH or BLOCKING per §severity-rules
  status,                                       -- 'OPEN'
  title,                                        -- rendered per §title-format
  description_html,                             -- rendered from template + placeholders
  context_json,                                 -- full placeholder set as jsonb for re-rendering
  raised_by_phase_name,                         -- the failed phase
  raised_by_tool_name,                          -- the failed tool (dotted internal name)
  error_class,                                  -- the canonical class per error_classification_policy
  attempt_count,
  last_tool_invocation_id,                      -- FK to tool_invocations row
  created_at                                    -- now()
);
```

`review_issue_at_least_one_entity_chk` is satisfied via `workflow_run_id`. The insert is wrapped in the same transaction as the phase-state HOLDING transition and the audit event emission per `phase_execution_loop_policy` §3 atomicity guarantee.

Issue deduplication: if a tool fails, the user retries, and it fails again — the engine does NOT create a second issue. Instead, the existing `OPEN` issue for the same `(workflow_run_id, last_tool_invocation_id.tool_name)` is updated (`attempt_count` incremented; `description_html` re-rendered; new entry appended to `review_issue_history`). The user sees ONE issue card with a growing history. This is enforced by a UNIQUE partial index:

```sql
CREATE UNIQUE INDEX idx_review_issues_open_tool_per_run
  ON review_issues (workflow_run_id, raised_by_tool_name)
  WHERE status = 'OPEN' AND raised_by_tool_name IS NOT NULL;
```

## Issue lifecycle on user action

User actions (per `failure_user_action_flow_policy`) transition the issue:

| Action | Issue status | Notes |
| --- | --- | --- |
| `RETRY` succeeds | `RESOLVED` | Status flip + `review_issue_history` entry |
| `RETRY` fails again | `OPEN` (unchanged) | `attempt_count` incremented; description re-rendered |
| `SKIP_IF_OPTIONAL` | `RESOLVED` with `resolution_action = SKIP_IF_OPTIONAL` | Only if tool optional |
| `ABORT_RUN` | `DISMISSED` (with reason `RUN_ABORTED`) | Run goes to CANCELLED |
| `RE_AUTHENTICATE` | Stays `OPEN` until re-auth completes + engine re-tries | |
| `RESOLVE_MANUALLY` | `RESOLVED` with `resolution_action = RESOLVE_MANUALLY` | User-typed reason captured |
| `REPORT_BUG` | Stays `OPEN`; emits `ENGINEERING_BUG_REPORTED` to ops | Issue persists until eng acts |

`AUTO_RESOLVED_BY_RESCAN` is NOT used by failure issues — that's a B14 mechanism for stale data issues.

## Audit shape

```ts
emitAudit("WORKFLOW_TOOL_FAILURE_ISSUE_RAISED", {
  workflow_run_id,
  business_id,
  review_issue_id,
  issue_type,                                   // one of three
  severity,                                     // HIGH or BLOCKING
  error_class,                                  // canonical class
  raised_by_phase_name,
  raised_by_tool_name,
  attempt_count,
  last_tool_invocation_id,
  raised_at
});
```

Severity `LOW` (informational — the underlying tool failure already produced a HIGH/BLOCKING audit event). Domain `REVIEW`.

## Localization

Templates are bilingual: English (default) + Greek (per Cyprus locale). The `plain_language_template_ref` resolves to a `.en.md` or `.el.md` file based on the user's locale preference. `context_json` is stored once; rendering is per-locale at read time.

## Cross-block contract

- **Block 03 Phase 08** owns issue creation in the engine failure path.
- **Block 14 Phase 02** owns `issue_type_registry` (this policy's issue types are registered there); B14·P03 owns `review_issue_history` for action audit trail.
- **Block 06 / 07 / 09** error-class signals feed the placeholder set.
- **Block 16 dashboard** displays open issues per `dashboard_card_policies`; sort by severity desc + created_at desc.

## Cross-references

- `retry_policy` — error class taxonomy + retry exhaustion trigger
- `error_classification_policy` — per-service classification producing the error_class value
- `failure_user_action_flow_policy` — Retry / Skip / Abort semantics consuming the suggested-action set
- `issue_type_registry_schema` (B14·P02) — table this policy seeds three rows into
- `review_issue_history_schema` (B14·P03) — action audit trail referenced from lifecycle table
- `gate_throws_semantics_policy` — separate gate-failure issue types (NOT in this policy)
- `phase_execution_locking_policy` — separate lock-contention issue type (NOT in this policy)
- `phase_execution_loop_policy` — E3 fatal-tool path that triggers issue creation
- `dashboard_card_policies` — B16 rendering of open issues
- `audit_pii_redaction_policy` — `redactPII()` for `{last_error_message_redacted}` placeholder
- `audit_event_payload_schemas` (Stage-6 catalog) — `WORKFLOW_TOOL_FAILURE_ISSUE_RAISED` shape
- Block 03 Phase 08 — owning phase
- Block 14 — review queue infrastructure
- Block 16 — dashboard display
- Cyprus locale — bilingual rendering requirement
