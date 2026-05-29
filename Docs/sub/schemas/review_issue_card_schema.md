# Review Issue Card Schema

**Category:** Schemas · **Owning block:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 2)

Defines two complementary schemas that together govern how issue types are declared and how new review issue cards are instantiated. First, the `issue_type_registry` table — the boot-time catalogue every producing block writes to via `review_queue.register_issue_type`. Second, the `registerIssueType` TypeScript function signature that every producing block calls at startup. Together these schemas ensure that every `review_issues` row is backed by a registered, validated type with known group, severity, and resolution vocabulary before the first run ever executes.

---

## 1. The `issue_type_registry` table

Resides in the operational Postgres schema alongside `review_issues`. Populated at engine boot by each producing block calling `review_queue.register_issue_type`. The table is append-only in normal operation — no row is deleted or updated outside a migration.

```sql
-- Canonical DDL: see issue_type_registry_schema.md (Block 14). This file references issue_type_registry for card rendering context only.
```

### Namespacing rule

`issue_type` strings follow the format `<block_short_name>.<check_name>` where:

- `block_short_name` is the exact value from the 14-namespace allowlist in `tool_naming_convention_policy` (e.g., `matching`, `intake`, `classification`, `ledger`, `review_queue`, `archive`).
- `check_name` is lowercase snake_case, present-tense descriptive of the condition detected.

The dot separator is the only permitted delimiter. Hyphens, slashes, and double underscores are rejected by the CHECK constraint.

### Well-formed `issue_type` examples by producing block

| Block | `block_short_name` | Example `issue_type` strings |
|---|---|---|
| 06 — AI Layer | `ai` | `ai.unusual_amount_detected`, `ai.large_outlier_amount` |
| 07 — Bank Statement Pipeline | `intake` | `intake.partial_upload_detected`, `intake.possible_duplicate_statement` |
| 08 — Transaction Classification | `classification` | `classification.unknown_type`, `classification.rule_conflict`, `classification.needs_confirmation` |
| 09 — Document Intake | `intake` | `intake.ocr_extraction_low_confidence`, `intake.document_intake_failed` |
| 10 — Matching Engine | `matching` | `matching.no_match_found`, `matching.possible_match`, `matching.matched_needs_confirmation`, `matching.split_payment_proposal`, `matching.document_used_multiple_times` |
| 11 — Ledger & Cyprus VAT | `ledger` | `ledger.accountant_review_unknown_treatment`, `ledger.tag_mismatch_detected`, `ledger.missing_required_evidence`, `ledger.vies_vat_number_missing` |
| 13 — IN Workflow | `in_workflow` | `in_workflow.invoice_numbering_gap`, `in_workflow.duplicate_payment_detected` |
| 14 — Review Queue (meta) | `review_queue` | `review_queue.finalization_blocking_issues_open`, `review_queue.approval_missing_or_not_step_up` |
| 15 — Finalization | `archive` | `archive.finalization_blocking_issues_open`, `archive.audit_log_pending_writes`, `archive.finalization_period_report_failed` |

Note: the `intake` namespace is intentionally shared by Blocks 07 and 09 per `tool_naming_convention_policy`. Both register their `issue_type` strings under the same prefix; the `registered_by_block` column distinguishes ownership.

---

## 2. The `registerIssueType` TypeScript function

Every producing block calls this function at engine boot, before any workflow run can be triggered. The call is idempotent — re-registering the same `issue_type` with identical parameters is a no-op; re-registering with different parameters fails fast with a boot-halt error.

```typescript
interface RegisterIssueTypeParams {
  /** Canonical namespaced key: "<block_short_name>.<check_name>" */
  issue_type: string;

  /** Block's short name from tool_naming_convention_policy allowlist */
  block_short_name: string;

  /** One of the 5 closed issue_group_enum values */
  issue_group: IssueGroup;

  /** Default severity from {LOW, MEDIUM, HIGH, BLOCKING} */
  default_severity: Severity;

  /** Non-empty subset of the 13 resolution_action_enum values */
  allowed_resolution_actions: ResolutionAction[];

  /** Integer block number (e.g. 10 for the Matching Engine) */
  registered_by_block: number;

  /** Human-readable description: when is this type raised? */
  description: string;
}

type IssueGroup =
  | 'Missing Documents'
  | 'Needs Confirmation'
  | 'Possible Wrong Match'
  | 'Possible Tax-VAT Issue'
  | 'Unusual Transaction';

type Severity = 'LOW' | 'MEDIUM' | 'HIGH' | 'BLOCKING';

type ResolutionAction =
  | 'mark_resolved'
  | 'confirm_match'
  | 'mark_as_no_invoice_available'
  | 'accept_classification'
  | 'reject_match'
  | 'reclassify_transaction'
  | 'propose_alternative_match'
  | 'snooze'
  | 'reassign'
  | 'send_to_my_inbox'
  | 'add_note'
  | 'request_regenerate_card'
  | 'dismiss_with_reason';

/**
 * Register an issue type at engine boot.
 * Idempotent: same params → no-op.
 * Conflict (same key, different params) → fatal boot error.
 * Emits REVIEW_ISSUE_TYPE_REGISTERED on successful first registration.
 */
declare function registerIssueType(params: RegisterIssueTypeParams): Promise<void>;
```

### Boot-time validation

The engine calls `review_queue.register_issue_type` inside the `engine.registerTool` boot sequence (Block 03 Phase 03). Failures surface as `TOOL_REGISTRY_STARTUP_FAILED` events and halt the process — no partial starts.

Validations enforced before the INSERT:

1. `issue_type` matches the regex `^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$`.
2. The prefix before the dot equals `block_short_name`.
3. `block_short_name` is in the 14-namespace allowlist from `tool_naming_convention_policy`.
4. `issue_group` is one of the 5 closed values.
5. `default_severity` is one of `{LOW, MEDIUM, HIGH, BLOCKING}`.
6. `allowed_resolution_actions` is non-empty and every element is in the 13-value `resolution_action_enum`.
7. The `issue_type` key is not already registered with conflicting parameters.

---

## 3. Registry query at issue-creation time

When a producing block raises a new issue, the insertion path queries the registry to resolve the canonical `issue_group` and `default_severity`:

```sql
SELECT
  issue_group,
  default_severity,
  allowed_resolution_actions
FROM issue_type_registry
WHERE issue_type = $1;
```

This query hits the `UNIQUE` index on `issue_type` and completes in under 1ms. The producing block must NOT pass `issue_group` or `default_severity` directly — the registry is the single source of truth. An unregistered `issue_type` causes the INSERT into `review_issues` to fail with a FK violation (deferred FK from `review_issues.issue_type → issue_type_registry.issue_type`).

The registry-derived values are written to `review_issues.issue_group` and `review_issues.severity` at insertion time and do not change for the lifetime of the row (they are frozen at creation, even if the registry entry is later amended by a migration).

---

## 4. Audit events

| Event | When |
|---|---|
| `REVIEW_ISSUE_TYPE_REGISTERED` | First successful `registerIssueType` call for a given `issue_type` (boot-time) |

This event already exists in the `REVIEW` domain of `audit_event_taxonomy`. No new events are required for this sub-doc.

---

## Cross-references
- `data_layer_conventions_policy` — UUID v7 PK generation; canonical JSON for `allowed_resolution_actions` JSONB
- `tool_naming_convention_policy` — 14-namespace block_short_name allowlist; namespacing rule
- `issue_group_enum` — closed 5-value `issue_group` enum
- `severity_enum` — closed 4-value `default_severity` enum
- `resolution_action_enum` — 13-value `allowed_resolution_actions` vocabulary
- `review_issues_schema` — `issue_type` FK target; `issue_group` and `severity` columns written from registry values
- `issue_type_to_group_mapping` — exhaustive per-type routing reference (Layer 2, Block 14)
- `audit_log_policies` — `REVIEW_ISSUE_TYPE_REGISTERED` event naming
- `audit_event_taxonomy` — `REVIEW` domain canonical events
- Block 14 Phase 02 — issue groups and routing (architecture)
- Block 03 Phase 03 — `engine.registerTool` boot framework
