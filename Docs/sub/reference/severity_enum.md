# Severity Enum

**Category:** Reference data · **Owning block:** 14 — Review Queue · **Co-owners:** 04, 12, 13, 15, 16 · **Stage:** 4 sub-doc (Layer 1 taxonomy)

The closed 4-value severity enum every reviewable issue, gate, and audit-emitting tool binds to. This taxonomy is the contract Block 14 declares to every producing block. Adding or removing a value requires a `Docs/decisions_log.md` amendment.

The 2026-05-08 amendment locked the enum at `{LOW, MEDIUM, HIGH, BLOCKING}` after correcting a prior drift where some phase docs used `CRITICAL`. The drift was caught by the Block 13 / 14 scans and back-ported to Blocks 12 and 13.

---

## The 4 values

| Value | Gate-hold? | Finalization eligibility | Default dismissal eligibility |
| --- | --- | --- | --- |
| `BLOCKING` | Always halts the workflow run at the current gate | Blocks finalization until resolved | No role can dismiss; must be resolved |
| `HIGH` | Halts at HUMAN_REVIEW_HOLD; advances if approved by Owner/Admin | Blocks finalization until resolved or step-up-approved | Owner/Admin only, with reason text |
| `MEDIUM` | Does not halt; surfaces in the review queue | Blocks finalization until resolved | Owner/Admin/Bookkeeper, with reason text |
| `LOW` | Does not halt; surfaces with low priority | Does not block finalization; snoozable cross-run | Owner/Admin/Bookkeeper/Accountant, with reason text |

## Role × dismissal matrix

| Severity | Owner | Admin | Bookkeeper | Accountant | Reviewer | Read-only |
| --- | --- | --- | --- | --- | --- | --- |
| BLOCKING | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| HIGH | ✓ (with reason + step-up) | ✓ (with reason + step-up) | ✗ | ✗ | ✗ | ✗ |
| MEDIUM | ✓ (with reason) | ✓ (with reason) | ✓ (with reason) | ✗ | ✗ | ✗ |
| LOW | ✓ (with reason) | ✓ (with reason) | ✓ (with reason) | ✓ (with reason) | ✗ | ✗ |

Reviewer and Read-only never dismiss; their permission surface is `REVIEW_QUEUE_VIEW` only per `permission_matrix`.

Audit event on dismissal: `REVIEW_ISSUE_DISMISSED` with `severity`, `reason`, `actor_role`, `step_up_token_id` (where applicable).

## Severity is not status

Severity describes the state of a review issue. **Status** (success / warning / danger) describes the state of a generic UI element (toast, banner, button). The two are distinct taxonomies with distinct token sets:

- Severity tokens: `--severity-{blocking,high,medium,low}-{bg,border,text,icon}` (`severity_color_tokens`)
- Status tokens: `--color-status-{success,warning,danger}` (`design_system_tokens`)

Component code that conflates them fails the `design_token_lint_policy` severity-context lint rule.

## Producing blocks and typical severity assignments

| Producing block | Common severities | Examples |
| --- | --- | --- |
| 07 — Bank Statement Pipeline | HIGH (partial uploads), MEDIUM (duplicate-possible), LOW (informational) | Per Stage 1 decision: partial uploads raise HIGH |
| 08 — Transaction Classification | BLOCKING (`UNKNOWN` type), HIGH (rule_conflict), MEDIUM (NEEDS_CONFIRMATION) | `UNKNOWN` is canonically BLOCKING per Block 14 Phase 02 |
| 09 — Document Intake | HIGH (OCR failure), MEDIUM (missing field), LOW (format issue) | Confidence-driven |
| 10 — Matching Engine | HIGH (NO_MATCH on income), MEDIUM (Strong Probable needing confirmation) | Per Block 10 routing rules |
| 11 — Ledger & Cyprus VAT | BLOCKING (UNRESOLVED counterparty for non-OUTSIDE_SCOPE), HIGH (accountant-review flagged) | Per Block 11 Phase 08 |
| 12, 13 — Workflows | HIGH (gate failure), MEDIUM (timeout reminder) | Per gate functions |
| 15 — Finalization | BLOCKING (lock-sequence failure), HIGH (precondition violation) | Per Block 15 Phase 09 failure taxonomy |
| 16 — Dashboard & Reporting | HIGH (export failure), MEDIUM (stale dashboard data) | Per Block 16 card definitions |

## Gate-hold rule (Block 14 Phase 02)

A workflow phase's exit gate uses `severity ∈ {HIGH, BLOCKING}` as the standard predicate for holding the run at `HUMAN_REVIEW_HOLD`. The 2026-05-08 amendment corrected drift in Block 12 Phase 05 / 07 and Block 13 Phase 09 where the predicate had been written `('HIGH', 'CRITICAL')` — `CRITICAL` does not exist; the canonical predicate is `('HIGH', 'BLOCKING')`.

Block 15 finalization preconditions use the same `{HIGH, BLOCKING}` predicate per Phase 02's gate 6.

## Snooze eligibility (cross-run carry-forward)

Per Block 14 Phase 07:

| Severity | Snoozable | Auto-clear |
| --- | --- | --- |
| BLOCKING | No | — |
| HIGH | No | — |
| MEDIUM | Yes (Owner/Admin/Bookkeeper) | Auto-clear if re-scan raises severity to HIGH/BLOCKING |
| LOW | Yes (Owner/Admin/Bookkeeper/Accountant) | Auto-clear if re-scan raises severity to MEDIUM/HIGH/BLOCKING |

Audit event: `REVIEW_ISSUE_SNOOZED` and `REVIEW_ISSUE_SNOOZE_AUTO_CLEARED`.

## Storage

`review_issues.severity` column — Postgres `severity_enum` type defined in `review_issues_schema`. The Postgres type carries the same four values:

```sql
CREATE TYPE severity_enum AS ENUM ('LOW', 'MEDIUM', 'HIGH', 'BLOCKING');
```

A `severity_critical_drift_lint_check` fixture (per Block 14 Phase 10) does a repo-wide scan asserting no phase doc or sub-doc references the dropped `CRITICAL` value.

## Cross-references

- `severity_color_tokens` — UI token quartet per severity
- `issue_group_enum` — review-queue grouping (orthogonal to severity)
- `audit_log_policies` — severity-tagged audit emissions
- `permission_matrix` — role × surface authorization including dismissal
- `review_issues_schema` — `severity` column definition
- Block 14 Phase 02 — severity routing rules (architecture-level)
- Block 12/13 phase docs — gate predicates using `{HIGH, BLOCKING}`
- 2026-05-08 decisions-log amendment — `CRITICAL` drift correction

---

## Per-value usage guidance with examples

### `LOW`

Use for informational observations that do not affect correctness but are worth noting for the run record. An issue is LOW if the bookkeeper can ignore it this run without any accounting or regulatory consequence.

Concrete examples:
- A transaction description contains an unusual character sequence that couldn't be normalized (no data loss, cosmetic only)
- A vendor's name in the system differs from the bank statement by a single character after normalization (possible typo, not confirmed incorrect)
- An anomaly-detection signal fired at the lowest confidence band — "this amount is slightly larger than the trailing 6-month average" without other corroborating signals

Audit event guidance: LOW issues do not emit a separate gate-hold event. They appear in the review queue and may carry a `REVIEW_ISSUE_RAISED` event with `severity = LOW`. If dismissed, emit `REVIEW_ISSUE_DISMISSED` with `severity = LOW`.

### `MEDIUM`

Use for issues that require attention before finalizing but do not halt the workflow run at the gate. The run advances to the next phase; the issue must be cleared before `AWAITING_APPROVAL` transitions to `FINALIZING`.

Concrete examples:
- A `STRONG_PROBABLE` match was not auto-confirmed (recurring-vendor signal below threshold) — the bookkeeper should verify the proposed match is correct before close
- A classification was produced by AI with moderate confidence and has not been confirmed by the user
- A previously-confirmed match was found to have a minor amount discrepancy on re-scan (within 1% of the invoice total)
- An invoice extraction field (e.g., the payment due date) had low OCR confidence but all required tax fields were captured successfully

Audit event guidance: `REVIEW_ISSUE_RAISED` with `severity = MEDIUM`. Gate passes without hold. Snooze eligible.

### `HIGH`

Use for issues that halt the workflow run at `HUMAN_REVIEW_HOLD` and block finalization until resolved or step-up-approved. The gate predicate `severity ∈ {HIGH, BLOCKING}` applies.

Concrete examples:
- An IN-side `NO_MATCH` — a deposit has no matched invoice, invoice, or client; could indicate unrecorded income
- An OCR failure on a document that is the only evidence for a transaction — the bookkeeper must re-upload or manually provide the data
- A partial bank statement upload where the uploaded file covers only part of the period — transactions from the uncovered days may be missing
- A classification `rule_conflict` where two rules assign contradictory types to the same transaction

Audit event guidance: `REVIEW_ISSUE_RAISED` with `severity = HIGH`; gate emits `WORKFLOW_GATE_HOLD` with `reason` referencing the issue ID. On resolution: `REVIEW_ISSUE_RESOLVED`. If dismissed: `REVIEW_ISSUE_DISMISSED` with `severity = HIGH`, `actor_role`, and mandatory `reason` text.

### `BLOCKING`

Use for conditions that prevent the workflow from proceeding at any gate and cannot be dismissed by any role. BLOCKING issues represent a data integrity or regulatory correctness problem that must be fixed, not waived.

Concrete examples:
- A transaction classified as `UNKNOWN` — the type cannot be determined and no default ledger path exists; finalization with an UNKNOWN entry would produce an invalid VAT return
- A missing required VAT field on a transaction subject to `EU_REVERSE_CHARGE` treatment — VIES reporting would be incorrect
- The finalization lock sequence detected a hash mismatch on the locked bundle — archive integrity is suspect
- An `UNRESOLVED` counterparty on a non-`OUTSIDE_SCOPE` transaction — Block 11 cannot produce a valid VAT entry without a resolved counterparty

Audit event guidance: `REVIEW_ISSUE_RAISED` with `severity = BLOCKING`; gate emits `WORKFLOW_GATE_HOLD` with `blocking = true`. No dismissal path exists. Resolution requires fixing the underlying data issue. Audit event on resolution: `REVIEW_ISSUE_RESOLVED`.

---

## Escalation path table

| Severity | Auto-escalation trigger | Escalated to | Escalation event |
| --- | --- | --- | --- |
| LOW | Re-scan raises severity to MEDIUM/HIGH/BLOCKING | New severity | `REVIEW_ISSUE_SNOOZE_AUTO_CLEARED` |
| MEDIUM | Re-scan raises severity to HIGH/BLOCKING | New severity | `REVIEW_ISSUE_SNOOZE_AUTO_CLEARED` |
| HIGH | No auto-escalation to BLOCKING; BLOCKING is a classification, not an escalation of HIGH | — | — |
| BLOCKING | Cannot escalate further | — | — |

Manual escalation: an Owner/Admin can reopen a dismissed MEDIUM issue; this does not change its severity. Escalation is always driven by the producing block's re-evaluation, not by a user action.

---

## Cross-references (extended)

- `issue_escalation_policy` — escalation trigger conditions and automation rules
- `review_queue_filter_schema` — UI filter predicate on severity for queue display
