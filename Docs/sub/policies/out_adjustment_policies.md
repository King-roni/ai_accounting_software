# out_adjustment_policies

**Category:** Policies · **Owning block:** 12 — OUT Workflow · **Co-owner:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 1 cross-block policy)

Three sub-policies bound together: dual-run-id audit recording on adjustment-touched entries, concurrent-adjustment ordering rules, and the boundary between adjustment-run remediation vs Block 11 manual-override remediation. Per the Layer 0 compression merge of `adjustment_concurrency_audit_policy` + `multiple_adjustments_per_period_policy` + `adjustment_vs_recompute_boundary_policy`.

---

## Section 1 — Dual-run-id audit recording

When an adjustment run modifies a previously-finalized record, the audit trail must capture BOTH:

- The original `workflow_run_id` that produced the locked state
- The `adjustment_run_id` that introduced the change

Per Block 12 Phase 09 + Block 13 Phase 11: every adjustment-driven write to operational tables emits:

```ts
emitAudit("ADJUSTMENT_TOUCHED_RECORD", {
  business_id,
  target_record_kind: "transactions" | "documents" | "invoices" | ...,
  target_record_id,
  original_run_id,                              // the run that locked the record
  adjustment_run_id,                            // the adjustment run modifying it
  adjustment_record_id,                         // FK to adjustment_records
  delta_kind,                                   // per adjustment_record_schema
  effective_at: timestamptz
});
```

The dual-run-id pattern lets forensics queries reconstruct: "what did this record look like at original finalization, what did it become after adjustment?"

Per `archive_manifest_schemas`'s manifest chain — the same dual-run-id is captured in the new manifest's `source_adjustment_run_id` column. Cross-version queries follow the chain.

## Section 2 — Multiple adjustments per period

Per Stage 1 decision: "Adjustment concurrency: an open adjustment does not block the next monthly run. Both can run concurrently."

The corollary: multiple adjustments against the SAME period can be open simultaneously. The rules:

### Ordering

Two adjustment runs A and B against the same parent_run_id apply per commit order:

1. A starts first; B starts second
2. A reaches AWAITING_APPROVAL; user approves A
3. A handoff to Block 15 (per `adjustment_archive_handoff_integration`); A becomes archive_v2_bundle.zip with manifest_v2
4. B may continue progressing or B reaches AWAITING_APPROVAL after A
5. When B handoffs: Block 15 reads manifest_v2 as prior, creates manifest_v3 referencing v2

If A and B race to handoff (both finishing AWAITING_APPROVAL near-simultaneously), Block 15's `manifest_version_collision` failure class triggers retry; one of them ends up at v3, the other at v2.

### Field-level conflicts

When A and B both touch the SAME field on the SAME target record:

- The earlier-committed adjustment's change is overlaid first
- The later-committed adjustment applies its delta against the post-A state
- The result: B's value wins (last-write-wins semantics on individual fields)

The "old_value" in B's `delta_payload` reflects the post-A state, NOT the pre-A locked state. This means a user who started B before A committed sees a different "old value" in the audit trail than what they originally observed. Per `archive_promotion_failure_runbook` Step 4: operator can investigate via the audit log.

### Cross-direction concurrency

OUT_ADJUSTMENT and IN_ADJUSTMENT against the same period are independent — each targets different record kinds typically. They can fully concurrently progress.

## Section 3 — Adjustment vs recompute boundary

When a user wants to correct a previously-finalized record, two paths exist:

| Path | When to use | Trigger |
| --- | --- | --- |
| **Block 11 manual override** | Single transaction's VAT treatment is wrong; user can fix it without opening an adjustment run | `LEDGER_MANUAL_OVERRIDE` action via review queue, on UNFINALIZED data only |
| **OUT_ADJUSTMENT run** | Finalized data needs correction OR multiple records need related changes | Manual trigger from settings or review queue |

The boundary is the FINALIZATION state of the record:

- Pre-finalization (operational data): manual override or in-place edit via Block 11's `recompute_ledger_entries` (per `ledger_recompute_side_effects_policy`)
- Post-finalization: requires an OUT_ADJUSTMENT run

### `CORRECT_VAT_TREATMENT` delta kind specifically

A `CORRECT_VAT_TREATMENT` adjustment is the formal path for changing a finalized transaction's VAT treatment. It does NOT short-circuit through `LEDGER_MANUAL_OVERRIDE` — the manual override is for operational data only.

Reason: the manual override changes the working state but doesn't create a versioned archive bundle. An adjustment creates a new bundle (archive_v{N}.zip) with the corrected treatment, preserving the prior state for audit.

A user who tries to manual-override a FINALIZED transaction's VAT treatment receives:

```
"This transaction is in a finalized period. Use Period Adjustment to correct VAT treatment."

[Open Adjustment Run]   [Cancel]
```

### Why the boundary matters

Without the rule, two paths would write conflicting state:

- Manual override updates `transactions.vat_treatment_override` directly
- An adjustment write creates a NEW archive_locked_ledger_entries row

Without enforcement, the manual override would silently mask the discrepancy from the audit trail. The boundary makes the path explicit.

## Audit events

| Event | When |
| --- | --- |
| `ADJUSTMENT_TOUCHED_RECORD` | Per dual-run-id capture |
| `OUT_ADJUSTMENT_CREATED` | Adjustment run created |
| `OUT_ADJUSTMENT_LEDGER_PREP_COMPLETED` | Adjustment ledger prep done |
| `OUT_ADJUSTMENT_APPROVED` | User approved the adjustment |
| `MANUAL_OVERRIDE_REJECTED_FINALIZED_PERIOD` | User tried to manual-override a finalized record |

## Cross-references

- `adjustment_record_schema` — delta_kind enum + payload shapes
- `archive_manifest_schemas` — manifest chain
- `archive_promotion_failure_runbook` — investigation of concurrent-adjustment outcomes
- `ledger_recompute_side_effects_policy` — Block 11 recompute path
- `human_review_approval_staleness_policy` — staleness when concurrent adjustments touch the same field
- `audit_log_policies` — event family
- Block 12 Phase 09 — OUT_ADJUSTMENT workflow type
- Block 13 Phase 11 — IN_ADJUSTMENT workflow type
- Stage 1 decision — adjustment concurrency

---

## Adjustment lifecycle state transitions

An adjustment record (in `adjustment_records`) progresses through a defined state machine. The states are stored in `adjustment_records.status`.

```
DRAFT → PENDING_REVIEW → APPROVED → APPLIED → REVERSED
                ↓
           REJECTED (terminal; user or system rejected the adjustment before approval)
```

**DRAFT**: The adjustment has been created (e.g., via the "Open Adjustment Run" prompt or programmatically) but has not yet been submitted for review. The delta_payload is being assembled; Block 11 has not yet computed the ledger impact. The user can edit or delete DRAFT adjustments freely.

**PENDING_REVIEW**: The adjustment has been submitted for review. The delta_payload is locked; Block 11 has computed the provisional ledger entries; the review queue may carry issues related to this adjustment. The run is in `HUMAN_REVIEW_HOLD` or `AWAITING_APPROVAL`. No edits to the delta are permitted once in PENDING_REVIEW.

**APPROVED**: The approver (Owner or Admin, with step-up per `step_up_auth_for_workflow_approval_policy`) has approved the adjustment. The run transitions to `AWAITING_APPROVAL → FINALIZING`. The adjustment record status moves to APPROVED when the approval is recorded.

**APPLIED**: Block 15 has committed the new archive bundle. The adjustment's delta is now reflected in `archive.locked_ledger_entries`. The operational state is updated. This is the terminal success state. The run's `run_status` is `FINALIZED`.

**REVERSED**: A subsequent adjustment run has created a delta that inverts this adjustment's effect. The `reversed_by_adjustment_record_id` field is set. The reversal is itself an adjustment record that goes through the same lifecycle. REVERSED is a terminal state for the original record.

**REJECTED**: The approver or Owner rejected the adjustment before it was applied. REJECTED is a terminal state. A new adjustment run must be opened if the correction is still needed.

---

## Concurrency rules for simultaneous adjustments

**Can two adjustments be applied to the same transaction simultaneously?**

No — they cannot commit simultaneously. They can be in-flight simultaneously (both in PENDING_REVIEW or AWAITING_APPROVAL at the same time), but they serialize at the Block 15 commit step per the manifest-versioning unique constraint.

The practical implication for field-level conflicts (see Section 2 above):

- Adjustment A touches `transactions.vat_treatment_override` for transaction T, setting it to `EU_REVERSE_CHARGE`
- Adjustment B also touches `transactions.vat_treatment_override` for transaction T, setting it to `DOMESTIC_STANDARD`
- A commits first → manifest_v2 reflects `EU_REVERSE_CHARGE`
- B commits second → its delta was drafted when the value was `OUTSIDE_SCOPE` (pre-A), but at commit time B's `old_value` check sees `EU_REVERSE_CHARGE` (post-A state)
- The system applies B's delta as a change from `EU_REVERSE_CHARGE` to `DOMESTIC_STANDARD` — last-write-wins
- The audit trail records this chain explicitly

If the user who opened adjustment B was unaware that A would commit first and change the value, they may end up with an unexpected result. The re-approval diff (per `human_review_approval_staleness_policy`) shows the changed baseline, but only if B's approval was given before A committed. If B's approval was given after A committed, B's `data_state_hash` will include A's changes, and the diff will accurately show the post-A state as the baseline.

---

## Additional cross-references

- `out_adjustment_type_definition` — delta_kind enum values (the specific types of adjustments)
- `adjustment_record_schema` — full schema for `adjustment_records` including `status`, `delta_payload`, `reversed_by_adjustment_record_id`
