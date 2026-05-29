# Finalization Gate SQL Schema

**Category:** Schemas · **Owning block:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 2)

Per-gate SQL definitions, expected indexes, latency budgets, and failure issue types for all 8 finalization precondition gates declared in Block 15 Phase 02. Each gate is a registered function called by the composite gate `engine.gate_finalization_preconditions_satisfied` before the lock sequence begins. This sub-doc provides the schema-level contract that Phase 02's architecture depends on.

The gate sequencing rule: run all 8 gates before returning — do not short-circuit on first failure. This produces richer diagnostics than early exit (the user learns about all blocking conditions at once rather than serially). The composite gate collects every `HOLD` result and surfaces them together.

---

## Gate 1 — `engine.gate_no_open_blocking_issues`

**What it checks:** Zero `review_issues` rows for the run with `severity IN ('HIGH','BLOCKING')` and `status = OPEN`.

```sql
SELECT COUNT(*) AS open_count
FROM review_issues
WHERE workflow_run_id = $1
  AND severity IN ('HIGH', 'BLOCKING')
  AND status NOT IN ('RESOLVED', 'AUTO_RESOLVED_BY_RESCAN', 'DISMISSED');
```

**Expected index:** `idx_review_issues_queue` on `(business_id, status, issue_group, severity DESC, created_at) WHERE status IN ('OPEN','SNOOZED')` — the partial index covers the open/snoozed rows, so non-qualifying rows are skipped.

**Latency budget:** 50ms at P95 for a typical period with up to 500 issues.

**Gate result:** `ADVANCE` when `open_count = 0`. `HOLD` otherwise.

**Failure issue type:** `archive.finalization_blocking_issues_open` — raises a `HIGH`-severity `Possible Tax-VAT Issue` group issue pointing the user back to the Review Queue. The raised issue is informational (the blocking issues are already visible in the queue); it ensures the finalization flow surfaces the blocker from within the finalization UI as well.

---

## Gate 2 — `engine.gate_all_transactions_classified`

**What it checks:** No transactions in the run with `transaction_type = 'UNKNOWN'`.

```sql
SELECT COUNT(*) AS unknown_count
FROM transactions
WHERE workflow_run_id = $1
  AND transaction_type = 'UNKNOWN'
  AND processing_status NOT IN ('EXCLUDED', 'DUPLICATE_EXACT');
```

**Expected index:** `(workflow_run_id, transaction_type)` composite index on `transactions`.

**Latency budget:** 30ms at P95 for runs with up to 2,000 transactions.

**Gate result:** `ADVANCE` when `unknown_count = 0`. `HOLD` otherwise.

**Failure issue type:** `archive.finalization_unclassified_transactions` — `BLOCKING` severity, `Possible Wrong Match` group. `BLOCKING` is intentional: an `UNKNOWN`-typed transaction in a finalized period would produce a ledger entry with no valid account mapping.

---

## Gate 3 — `engine.gate_all_transactions_matched_or_excepted`

**What it checks:** No OUT-expense transactions in the run that require evidence but have neither a confirmed match nor a documented exception.

```sql
SELECT COUNT(*) AS unmatched_count
FROM transactions t
WHERE t.workflow_run_id = $1
  AND t.direction = 'OUT'
  AND t.evidence_required = true
  AND t.effective_match_status NOT IN (
      'MATCHED_AUTO_CONFIRMED',
      'MATCHED_CONFIRMED',
      'EXCEPTION_DOCUMENTED'
  )
  AND t.processing_status NOT IN ('EXCLUDED', 'DUPLICATE_EXACT');
```

**Expected index:** `(workflow_run_id, direction, evidence_required, effective_match_status)` composite index on `transactions`.

**Latency budget:** 30ms at P95.

**Gate result:** `ADVANCE` when `unmatched_count = 0`. `HOLD` otherwise.

**Failure issue type:** `archive.finalization_unmatched_transactions` — `HIGH` severity, `Missing Documents` group. `HIGH` (not `BLOCKING`) because the matching engine may still find a candidate in a late-arriving document; the user can also document an exception.

---

## Gate 4 — `engine.gate_ledger_entries_complete`

**What it checks:** Every in-scope, non-excluded transaction has at least one `draft_ledger_entries` row.

```sql
SELECT COUNT(*) AS missing_entries_count
FROM transactions t
WHERE t.workflow_run_id = $1
  AND t.processing_status NOT IN ('EXCLUDED', 'DUPLICATE_EXACT')
  AND NOT EXISTS (
    SELECT 1
    FROM draft_ledger_entries dle
    WHERE dle.transaction_id = t.transaction_id
      AND dle.workflow_run_id = $1
  );
```

**Expected index:** FK index on `draft_ledger_entries(transaction_id)` plus the `(workflow_run_id, processing_status)` index on `transactions`.

**Latency budget:** 30ms at P95.

**Gate result:** `ADVANCE` when `missing_entries_count = 0`. `HOLD` otherwise.

**Failure issue type:** `archive.finalization_ledger_entries_missing` — `BLOCKING` severity, `Possible Tax-VAT Issue` group. Missing ledger entries mean the period's books are incomplete; this cannot be waived.

---

## Gate 5 — `engine.gate_vat_entries_present`

**What it checks:** Every `draft_ledger_entries` row in the run that should carry a VAT amount does so. `OUTSIDE_SCOPE` and `UNKNOWN` entries are excluded from the mandatory-amount check; all other VAT treatment values require a non-null `vat_amount`.

```sql
SELECT COUNT(*) AS missing_vat_count
FROM draft_ledger_entries
WHERE workflow_run_id = $1
  AND vat_treatment IS NOT NULL
  AND vat_treatment NOT IN ('OUTSIDE_SCOPE', 'UNKNOWN')
  AND vat_amount IS NULL;
```

**Expected index:** `(workflow_run_id, vat_treatment, vat_amount)` composite — partial index WHERE `vat_treatment IS NOT NULL` preferred.

**Latency budget:** 20ms at P95.

**Gate result:** `ADVANCE` when `missing_vat_count = 0`. `HOLD` otherwise.

**Failure issue type:** `archive.finalization_vat_amount_missing` — `BLOCKING` severity, `Possible Tax-VAT Issue` group. A VAT-applicable entry without an amount would produce an incorrect VAT return.

---

## Gate 6 — `engine.gate_approval_recorded`

**What it checks:** The `workflow_run_approvals` table contains at least one non-revoked approval row for this run with `approval_method = 'STEP_UP'`.

```sql
SELECT COUNT(*) AS qualifying_approvals
FROM workflow_run_approvals
WHERE run_id = $1
  AND revoked_at IS NULL
  AND approval_method = 'STEP_UP';
```

**Expected index:** `(run_id, approval_method, revoked_at)` on `workflow_run_approvals`. This is a point lookup; execution cost is negligible.

**Latency budget:** 10ms at P95.

**Gate result:** `ADVANCE` when `qualifying_approvals >= 1`. `HOLD` otherwise.

**Failure issue type:** `archive.finalization_approval_missing_or_not_step_up` — `HIGH` severity, `Needs Confirmation` group. Prompts the Owner/Admin to complete or repeat the step-up authentication flow.

---

## Gate 7 — `engine.gate_no_legal_hold`

**What it checks:** The business does not have an active legal hold that blocks archival.

```sql
SELECT COUNT(*) AS active_holds
FROM legal_holds
WHERE business_id = $1
  AND lifted_at IS NULL
  AND blocks_archival = true;
```

**Expected index:** `(business_id, lifted_at, blocks_archival)` partial index WHERE `lifted_at IS NULL`.

**Latency budget:** 10ms at P95.

**Gate result:** `ADVANCE` when `active_holds = 0`. `HOLD` otherwise.

**Failure issue type:** `archive.finalization_legal_hold_active` — `BLOCKING` severity, `Possible Tax-VAT Issue` group. Legal holds cannot be overridden by application users; they require operator intervention via Block 04's legal-hold management surface.

---

## Gate 8 — `engine.gate_audit_log_quiescent`

**What it checks:** Two conditions must both be true: (a) the audit subsystem is reachable, and (b) no audit-log write for `workflow_run_id = $1` has occurred within the last 5 seconds (the "settle window").

```sql
-- Reachability check: ping the chain_heads table
SELECT 1 FROM chain_heads LIMIT 1;

-- Settle-window check: no recent audit writes for the run
SELECT COUNT(*) AS recent_writes
FROM audit_log
WHERE workflow_run_id = $1
  AND event_time > now() - interval '5 seconds';
```

**Expected indexes:** `chain_heads` primary key (trivial); `(workflow_run_id, event_time)` on `audit_log`.

**Latency budget:** No fixed budget — if the audit subsystem is unreachable, the gate holds immediately. If reachable, the settle-window query targets 20ms P95.

**Gate result:** `ADVANCE` when both checks pass (reachability OK AND `recent_writes = 0`). `HOLD` on reachability failure or unsettled writes. If the gate holds due to unsettled writes, the engine waits the settle window and retries once before returning `HOLD` to the composite.

**Failure issue type:** `archive.audit_log_pending_writes` — `HIGH` severity, `Unusual Transaction` group. Typically self-resolves after a few seconds; the user can click "Retry finalization" and the gate re-evaluates.

---

## Composite gate behaviour

The composite gate `engine.gate_finalization_preconditions_satisfied` calls all 8 gates in the order listed above and collects all `HOLD` results before returning. This ensures the user receives complete diagnostics in one attempt rather than serially discovering blockers.

```typescript
async function gate_finalization_preconditions_satisfied(
  run_id: string,
  business_id: string
): Promise<GateResult> {
  const results = await Promise.all([
    gate_no_open_blocking_issues(run_id),
    gate_all_transactions_classified(run_id),
    gate_all_transactions_matched_or_excepted(run_id),
    gate_ledger_entries_complete(run_id),
    gate_vat_entries_present(run_id),
    gate_approval_recorded(run_id),
    gate_no_legal_hold(business_id),
    gate_audit_log_quiescent(run_id),
  ]);

  const failures = results.filter(r => r.result === 'HOLD');

  if (failures.length === 0) {
    return { result: 'ADVANCE' };
  }

  return {
    result: 'HOLD',
    failing_gates: failures.map(f => f.gate_name),
    failure_payloads: failures.map(f => f.failure_payload),
  };
}
```

Total composite latency budget: under 500ms at P95 (gates run in parallel; latency is bounded by the slowest gate, not the sum).

---

## Audit events

| Event | When |
|---|---|
| `FINALIZATION_PRECONDITION_EVALUATED` | Per gate per evaluation (emitted by each individual gate function) |
| `FINALIZATION_PRECONDITION_FAILED` | When the composite gate returns `HOLD` — one event with all failing gate names in payload |

Both events already exist in the `FINALIZATION` domain of `audit_event_taxonomy`.

---

## Cross-references
- `data_layer_conventions_policy` — UUID v7 identifiers; canonical JSON for gate failure payloads
- `locked_ledger_entries_schema` — target of the lock sequence that these gates guard
- `workflow_run_schema` — `workflow_run_id` parameter; `run_status_enum` (`FINALIZING` state requires these gates to pass first)
- `review_issues_schema` — Gate 1 queries `review_issues`; Gates 2–5 raise issues on failure
- `review_issue_card_schema` — `archive.*` issue types raised on gate failure must be registered in `issue_type_registry`
- `severity_enum` — per-gate failure severity assignments
- `issue_group_enum` — per-gate failure group assignments
- `audit_log_policies` — `FINALIZATION_PRECONDITION_EVALUATED`, `FINALIZATION_PRECONDITION_FAILED` naming
- `audit_event_taxonomy` — `FINALIZATION` domain events
- Block 15 Phase 02 — preconditions architecture; composite gate definition
- Block 03 Phase 05 — gate evaluation framework; `GateResult` shape
