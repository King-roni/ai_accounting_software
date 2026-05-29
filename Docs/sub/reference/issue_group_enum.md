# Issue Group Enum

**Category:** Reference data · **Owning block:** 14 — Review Queue · **Co-owners:** 04, 16 · **Stage:** 4 sub-doc (Layer 1 taxonomy)

The closed 5-value `issue_group` enum plus the `Ready to Finalize` queue-state projection. Each row in `review_issues` carries one of the 5 actionable values; `Ready to Finalize` is computed from queue state, not stored. The 2026-05-08 amendment locked this distinction after the Block 14 scan caught the prior 6-value enum drift.

Adding a value requires a `Docs/decisions_log.md` amendment.

---

## The 5 actionable values

| Value | What goes here | Typical severities |
| --- | --- | --- |
| `Missing Documents` | OUT transactions with no matched invoice; documents-fetcher failed to find evidence | HIGH (default); LOW for known exception-documented |
| `Needs Confirmation` | Strong-Probable matches (not auto-confirmed), classification needing user-confirm, `UNKNOWN_POSITIVE` IN-side transactions | MEDIUM (default); HIGH for IN-side `NO_MATCH` |
| `Possible Wrong Match` | Weak-Possible matches; rule_conflict in classifier; previously-confirmed match rejected on rescan | MEDIUM (default) |
| `Possible Tax-VAT Issue` | Accountant-review-flagged ledger entries; UNRESOLVED counterparty with non-OUTSIDE_SCOPE treatment; VIES-relevant gaps | HIGH (default); BLOCKING for missing required VAT fields |
| `Unusual Transaction` | Anomaly-detection hits from Block 06 End-Scan; significantly off-pattern amounts/dates; first-time vendor | MEDIUM (default); LOW for informational anomalies |

Storage: `review_issues.issue_group` column.

```sql
CREATE TYPE issue_group_enum AS ENUM (
  'Missing Documents',
  'Needs Confirmation',
  'Possible Wrong Match',
  'Possible Tax-VAT Issue',
  'Unusual Transaction'
);
```

Note the human-readable form (spaces, mixed case) — this is intentional because the value renders directly in the UI. The Postgres ENUM is case-sensitive; the comparison in code uses exact string match.

## The `Ready to Finalize` projection

`Ready to Finalize` is a queue-state projection, **not a `review_issues` row value**. Per the 2026-05-08 amendment fix to the Block 14 Phase 02 architecture:

> The six-bucket architecture decomposed into five actionable enum values + one `Ready to Finalize` queue-state projection (NOT a row value); Block 04 Phase 04's ENUM constraint reduced to five.

### Definition

A workflow run is in the `Ready to Finalize` state when:

1. No `review_issues` row exists for the run with `severity ∈ {HIGH, BLOCKING}` and `status = OPEN`
2. The run's state machine is `AWAITING_APPROVAL` (Block 03 Phase 04 state value)
3. The run's preconditions (Block 15 Phase 02 gates) are satisfied

Block 14's review queue renders runs in this state in a dedicated `Ready to Finalize` section above the 5 actionable buckets. The section is a query result, not a row scan; the run does NOT carry an issue with `issue_group = "Ready to Finalize"`.

### Wiring

The `Ready to Finalize` UI section wires to the per-workflow `user_approval` tools (`out_workflow.user_approval`, `in_workflow.user_approval`) — NOT directly to Block 15. Block 14 displays the section; clicking "Approve & Finalize" calls the workflow's approval tool; the approval tool triggers Block 15 from there.

Lint rule: code may NOT insert a `review_issues` row with `issue_group = "Ready to Finalize"`. CI catches the regression.

## Routing per producing block

| Producing block | Common issue groups |
| --- | --- |
| 07 — Bank Statement Pipeline | Missing Documents (rare on this side), Unusual Transaction (partial-upload) |
| 08 — Transaction Classification | Needs Confirmation (LOW/MEDIUM confidence), Possible Wrong Match (rule_conflict — per the Block 08 fix) |
| 09 — Document Intake | Missing Documents (intake failure), Needs Confirmation (extraction confidence low) |
| 10 — Matching Engine | Missing Documents (NO_MATCH on OUT), Needs Confirmation (Strong-Probable not auto-confirmed), Possible Wrong Match (Weak-Possible) |
| 11 — Ledger & Cyprus VAT | Possible Tax-VAT Issue (UNRESOLVED counterparty, missing VAT evidence) |
| 12 — OUT Workflow | Missing Documents (no evidence found), Needs Confirmation (HUMAN_REVIEW_HOLD prompts) |
| 13 — IN Workflow | Needs Confirmation (no matched client / invoice), Possible Wrong Match (multi-invoice allocation conflict) |
| 14 — Review Queue (meta) | Unusual Transaction (end-scan re-evaluation prompts) |

The full `issue_type → issue_group` mapping per producing block lives in `issue_type_to_group_mapping` (Reference data, Block 14).

## Bucket reordering

The 5 actionable buckets render in fixed order in the review queue UI:

1. Missing Documents
2. Needs Confirmation
3. Possible Wrong Match
4. Possible Tax-VAT Issue
5. Unusual Transaction

With the `Ready to Finalize` projection rendered above them when applicable. Within each bucket, issues sort by severity (BLOCKING → HIGH → MEDIUM → LOW), then by created_at ascending.

This ordering is pinned. Per-business custom ordering is out of MVP scope.

## Status orthogonality

`issue_group` and `severity` and `status` (`review_issues.status` — `OPEN` / `RESOLVED` / `SNOOZED` / `AUTO_RESOLVED_BY_RESCAN` / `DISMISSED`) are three orthogonal axes. A row carries one value from each.

Status enum is defined in `Docs/sub/reference/issue_status_enum.md` (Layer 2, Block 04, including the AUTO_RESOLVED_BY_RESCAN extension from the 2026-05-08 amendment).

## Cross-references

- `severity_enum` — orthogonal severity axis
- `issue_type_to_group_mapping` — per-issue-type → group routing
- `review_issues_schema` — `issue_group` column + constraint
- `permission_matrix` — REVIEW_QUEUE_VIEW / REVIEW_QUEUE_RESOLVE / REVIEW_ASSIGN / REVIEW_REGENERATE surfaces per the 2026-05-08 amendment
- `audit_log_policies` — `REVIEW_*` event naming
- Block 14 Phase 02 — issue routing (architecture)
- Block 14 Phase 03 — issue card rendering
- 2026-05-08 decisions-log amendment — the 6→5 reduction + `Ready to Finalize` projection lock

---

## Per-group routing rationale

### `Missing Documents`

Routes to the **Bookkeeper** role as primary resolver. Rationale: a missing invoice or receipt is a document-procurement problem, not a tax-interpretation problem. The bookkeeper's task is to locate the document, re-upload, or mark the transaction as `EXCEPTION_DOCUMENTED`. An Owner or Admin may also resolve, but accountant intervention is not required unless the amount is large enough to have VAT implications the bookkeeper can't assess alone.

Auto-escalation: if a `Missing Documents` issue is snoozed and the run's finalization deadline passes (per the business's configured close deadline), the issue severity escalates from HIGH to BLOCKING and sends a notification to the Owner. The snooze is cleared automatically.

Specific issue types in this group: `PAYMENT_NO_INVOICE`, `EXPENSE_NO_RECEIPT`, `DOCUMENT_FETCH_FAILED`, `LATE_DOCUMENT_UPLOAD_PENDING`.

### `Needs Confirmation`

Routes to the **Bookkeeper** role as primary resolver (for matching/classification confirms); routes to **Accountant** when the issue's `accountant_review_required = true` flag is set (e.g., a novel transaction type the system has not seen for this vendor). Rationale: confirming a proposed match or classification is a routine task; it requires judgment but not necessarily tax expertise. Accountant involvement is reserved for ambiguous cases.

Auto-escalation: if a `Needs Confirmation` issue on the IN side has `match_level = NO_MATCH` AND the amount exceeds €5,000, severity escalates from MEDIUM to HIGH after 48 hours without resolution.

Specific issue types: `STRONG_PROBABLE_MATCH_PENDING`, `CLASSIFICATION_NEEDS_CONFIRM`, `INCOME_SOURCE_UNKNOWN`, `UNKNOWN_POSITIVE_DEPOSIT`.

### `Possible Wrong Match`

Routes to the **Bookkeeper** role. Rationale: evaluating whether a proposed match is correct requires reviewing transaction and document details — a matching task, not a tax task. The bookkeeper either confirms the match, rejects it and selects a different document, or marks it as `EXCEPTION_DOCUMENTED`.

Auto-escalation: no automatic escalation. If the user confirms a `Possible Wrong Match` issue and later it's found incorrect at audit, that's a user-acceptance decision that was recorded; no retroactive escalation.

Specific issue types: `WEAK_POSSIBLE_MATCH`, `RULE_CONFLICT_CLASSIFICATION`, `MATCH_REJECTED_ON_RESCAN`.

### `Possible Tax-VAT Issue`

Routes to the **Accountant** role as primary resolver. Rationale: VAT treatment decisions and VIES implications require tax expertise. The Accountant reviews the flagged entry, corrects the VAT treatment if needed, or confirms the system's proposed treatment. The Bookkeeper and Owner can see the issue but cannot resolve it without Accountant confirmation (per `permission_matrix` `REVIEW_QUEUE_RESOLVE` surface for tax issues).

Auto-escalation: an `UNKNOWN` VAT treatment issue that is not resolved within 7 days of being raised fires a notification to the Owner AND escalates to BLOCKING if finalization has been attempted.

Specific issue types: `VAT_TREATMENT_UNKNOWN`, `UNRESOLVED_COUNTERPARTY_VAT`, `VIES_GAP`, `ACCOUNTANT_REVIEW_FLAGGED`, `MISSING_VAT_NUMBER_EU_REVERSE_CHARGE`.

### `Unusual Transaction`

Routes to the **Owner** role as primary resolver. Rationale: an anomaly or first-time vendor transaction may indicate fraud, misclassification, or a legitimate one-off. The Owner is best placed to recognize whether the pattern is intentional business activity. The Bookkeeper can see the issue; the Owner acknowledges or escalates to Accountant for tax implications.

Auto-escalation: an `Unusual Transaction` issue that the Owner snoozes more than 3 times in successive runs automatically escalates from MEDIUM to HIGH and sends a notification to the Admin.

Specific issue types: `ANOMALY_AMOUNT_OUTLIER`, `FIRST_TIME_VENDOR_HIGH_VALUE`, `FREQUENCY_ANOMALY`, `END_SCAN_PATTERN_DEVIATION`.

---

## Additional cross-references

- `issue_group_routing_policy` — formal routing rules per group including role permissions
- `issue_type_to_group_mapping` — complete per-issue-type → group mapping table
