# end_scan_schema

**Category:** Schemas · **Owning block:** 06 — AI Layer · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the `end_scan_results` table, which records the output of the Block 06 End-Scan Engine. The end scan runs after all processing phases complete (classification, matching, ledger preparation) and before the review gate. Its purpose is to surface anomalies, data-quality issues, and AI-detectable patterns that rule-based checks cannot catch. One row is written per workflow run invocation of the `ai.run_end_scan` tool; the row is the authoritative record of what the scan found, how many findings it produced, and whether any findings block workflow advancement.

---

## Table definition

```sql
CREATE TYPE end_scan_status_enum AS ENUM (
  'PENDING',
  'RUNNING',
  'COMPLETED',
  'FAILED'
);

CREATE TABLE end_scan_results (
  scan_id                  uuid                    PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id              uuid                    NOT NULL REFERENCES business_entities(id),
  workflow_run_id          uuid                    NOT NULL REFERENCES workflow_runs(id),
  scan_status              end_scan_status_enum    NOT NULL DEFAULT 'PENDING',
  started_at               timestamptz,
  completed_at             timestamptz,
  findings_json            jsonb                   NOT NULL DEFAULT '[]'::jsonb,
  finding_count            integer                 NOT NULL DEFAULT 0 CHECK (finding_count >= 0),
  high_finding_count       integer                 NOT NULL DEFAULT 0 CHECK (high_finding_count >= 0),
  blocking_finding_count   integer                 NOT NULL DEFAULT 0 CHECK (blocking_finding_count >= 0),
  model_identifier         text                    NOT NULL,
  input_token_count        integer                 NOT NULL DEFAULT 0 CHECK (input_token_count >= 0),
  ai_tier                  text                    NOT NULL DEFAULT 'EXTERNAL',
  created_at               timestamptz             NOT NULL DEFAULT now()
);
```

---

## Column notes

- `scan_id` — UUID v7 per `data_layer_conventions_policy §2`. Monotonically increasing; identifies this scan result uniquely across all businesses and runs.
- `business_id` — non-nullable. All scan results are tenant-scoped. RLS enforces tenant isolation using this column.
- `workflow_run_id` — non-nullable FK to `workflow_runs.id`. The End-Scan Engine runs exactly once per workflow run (or once per affected-only re-scan per Block 14 Phase 11). The uniqueness of a scan within a run is enforced at the application layer; multiple rows are permitted for affected-only re-scans in the same run (each targets a subset of the check catalogue).
- `scan_status` — lifecycle of the scan invocation. `PENDING` is set on row creation. `RUNNING` is set when `ai.run_end_scan` begins execution. `COMPLETED` or `FAILED` is written when the tool resolves. A `FAILED` status triggers `END_SCAN_FAILED` and raises a MEDIUM-severity review issue.
- `started_at` — the wall-clock timestamp when the scan began executing. Null until the tool transitions status to `RUNNING`.
- `completed_at` — wall-clock timestamp when the scan completed (either `COMPLETED` or `FAILED`). Null while `PENDING` or `RUNNING`.
- `findings_json` — JSONB array of finding objects. Each finding conforms to the finding object shape defined below. An empty array (`[]`) is valid — a clean scan produces zero findings.
- `finding_count` — total number of findings in `findings_json`, including all severities. Must equal `jsonb_array_length(findings_json)`. The application layer enforces this invariant at write time; no DB CHECK constraint is applied because JSONB length checks are expensive at scale.
- `high_finding_count` — count of findings with `severity = HIGH`. Used by the review gate to determine whether a run should be held for human review before any other check.
- `blocking_finding_count` — count of findings with `severity = BLOCKING`. Any non-zero value causes the workflow gate to halt advancement until the findings are resolved.
- `model_identifier` — the exact model identifier string as reported by the AI gateway for the invocation. For the end scan, this is always an Anthropic Claude model (Tier 3). Matches `ai_invocation_records.model_identifier` for the corresponding invocation row.
- `input_token_count` — the number of input tokens consumed by the end-scan invocation, as reported by `ai_invocation_records`. Zero for cached responses.
- `ai_tier` — always `EXTERNAL` for the end-scan engine. The end scan always invokes Tier 3 (Anthropic Claude) because its purpose is to surface anomalies that require the full reasoning capability of the external model. No local Tier 2 path exists for the end scan. The column is stored explicitly (not constrained to a single value) to allow future schema evolution.

---

## Finding object shape

Each element in `findings_json` conforms to the following structure:

```jsonc
{
  "finding_id": "<UUID v4 — token identifier for this finding within the scan>",
  "category": "<string — check category, e.g. 'missing_evidence' | 'match_quality' | 'vat_flags' | 'suspect_shape' | 'invoice_lifecycle'>",
  "severity": "<LOW | MEDIUM | HIGH | BLOCKING>",
  "description": "<string — plain-language description of the finding, rendered via Phase 10>",
  "affected_transaction_ids": ["<UUID>", "..."],
  "suggested_action": "<string — recommended next step for the reviewer>"
}
```

- `finding_id` — UUID v4 per `data_layer_conventions_policy §2`. Findings are volatile — they are recomputed on each scan run and on affected-only re-scans; temporal ordering within the array is not meaningful. UUID v4 is used because finding IDs carry no meaningful time prefix and are not persisted beyond the scan record itself.
- `category` — one of the five check categories registered in the End-Scan check catalogue (Block 06 Phase 11): `missing_evidence`, `match_quality`, `vat_flags`, `suspect_shape`, `invoice_lifecycle`. Category string values are validated by the end-scan engine at runtime; an unrecognised category is treated as a failed finding and triggers `END_SCAN_FAILED`.
- `severity` — one of `{LOW, MEDIUM, HIGH, BLOCKING}`. `LOW` and `MEDIUM` findings are surfaced in the scan summary panel but do not block workflow advancement. `HIGH` and `BLOCKING` findings automatically trigger `review_issues` row creation and cause the workflow gate to hold.
- `affected_transaction_ids` — array of UUID strings identifying transactions relevant to the finding. May be empty for findings that relate to the workflow run as a whole rather than to specific transactions.
- `suggested_action` — a short plain-language recommendation, rendered by Phase 10. Maximum 500 characters.

---

## Automatic `review_issues` creation

Findings with `severity = HIGH` or `severity = BLOCKING` automatically create a corresponding row in the `review_issues` table. This is performed by the end-scan engine after writing the `end_scan_results` row, before emitting `END_SCAN_COMPLETED`. The mapping is:

| Finding severity | `review_issues.severity` | Blocks advancement |
|---|---|---|
| `LOW` | — (not created) | No |
| `MEDIUM` | — (not created) | No |
| `HIGH` | `HIGH` | Holds the gate until resolved |
| `BLOCKING` | `BLOCKING` | Holds the gate; must be resolved before any finalization path |

`LOW` and `MEDIUM` findings appear in the scan summary accessible from the run detail panel but do not enter the review queue. The `END_SCAN_COMPLETED` audit event payload includes `finding_count`, `high_finding_count`, and `blocking_finding_count` to allow operators to quickly assess run health without querying `findings_json`.

---

## RLS

```sql
CREATE POLICY end_scan_results_isolation ON end_scan_results
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

Tenant isolation by `business_id`. No cross-business read path exists.

---

## Indexes

```sql
-- Run-level lookup (primary query path — one scan per run)
CREATE INDEX idx_end_scan_results_run
  ON end_scan_results (workflow_run_id, created_at);

-- Business-scoped history for dashboard and ops review
CREATE INDEX idx_end_scan_results_business_time
  ON end_scan_results (business_id, created_at DESC);

-- Status filter for in-flight scans
CREATE INDEX idx_end_scan_results_status
  ON end_scan_results (scan_status)
  WHERE scan_status IN ('PENDING', 'RUNNING');
```

---

## Mobile write rejection

`end_scan_results` is written exclusively by the `ai.run_end_scan` tool running server-side. No client or mobile write path exists. Any write attempt originating from a mobile client is rejected per `mobile_write_rejection_endpoints.md`.

---

## Audit events

| Event | When | Severity |
|---|---|---|
| `END_SCAN_COMPLETED` | `scan_status` transitions to `COMPLETED`; `findings_json` and counts are populated | LOW |
| `END_SCAN_FAILED` | `scan_status` transitions to `FAILED` | MEDIUM |

Both events are emitted via `emitAudit()` per `audit_log_policies`. The `END_SCAN_COMPLETED` payload includes `scan_id`, `workflow_run_id`, `finding_count`, `high_finding_count`, `blocking_finding_count`, and `model_identifier`. The `END_SCAN_FAILED` payload includes `scan_id`, `workflow_run_id`, and an `error_summary` field. These events exist in `audit_event_taxonomy` under the `AI` domain. Note that `END_SCAN_COMPLETED` and `END_SCAN_FAILED` are the table-lifecycle events for this schema; the existing taxonomy events `END_SCAN_TRIGGERED` and `END_SCAN_FINDING_RAISED` (Block 06) remain the operational end-scan domain events covering the check-level granularity.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK; UUID v4 for `finding_id`; JSONB canonical serialization for `findings_json`; no floating-point currency
- `ai_gateway_schema` — `ai_invocation_records`; `model_identifier` and `input_token_count` sourced from the corresponding invocation row; `ai_tier` fixed to `EXTERNAL`
- `audit_log_policies` — `AI` domain; `END_SCAN_COMPLETED`, `END_SCAN_FAILED` events; `<DOMAIN>_<PAST_VERB>` naming
- `audit_event_taxonomy` — `END_SCAN_COMPLETED`, `END_SCAN_FAILED`, `END_SCAN_TRIGGERED`, `END_SCAN_FINDING_RAISED`
- `review_issues_schema` — HIGH and BLOCKING findings automatically create rows; the `review_issues` table is the end scan's secondary write target
- `tool_naming_convention_policy` — `ai.run_end_scan` tool name; `ai.*` namespace
- Block 06 Phase 11 — End-Scan Engine implementation; check catalogue; affected-only re-scan protocol
- Block 06 Phase 10 — plain-language pipeline; renders `description` and `suggested_action` fields in each finding
- Block 06 Phase 02 — privacy gateway; all end-scan AI calls route through the gateway
- Block 14 Phase 11 — affected-only re-scan trigger; signals the end-scan engine to rerun checks for resolved issues
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
