# internal_transfer_cross_workflow_dedup_policy

**Category:** Policies · **Owning block:** 12 — OUT Workflow · **Co-owners:** 11, 13 · **Stage:** 4 sub-doc (Layer 1 cross-block policy)

The deduplication rule for INTERNAL_TRANSFER transactions across OUT_FILTER, IN_FILTER, and Block 11's ledger dispatcher. Per Stage 1 decision: "INTERNAL_TRANSFER routing: passes through both OUT_FILTER and IN_FILTER; Block 11's inter-account movement tool produces a single deduplicated ledger entry. Catches transfers visible on either statement direction."

This policy pins:
1. When two transactions represent the same internal transfer (the dedup signature)
2. Which side is the single writer (Block 11's dispatcher)
3. How the dedup is enforced against race conditions

---

## What gets deduplicated

An internal transfer between two bank accounts of the same business appears on the bank statements of BOTH accounts:

- The source account statement shows a negative amount (outflow)
- The destination account statement shows a positive amount (inflow)

If both statements are uploaded, both transactions land in the database. Without dedup, Block 11 would produce TWO ledger entries for ONE economic event — accounting error.

The dedup rule: produce exactly one ledger entry, regardless of how many statements show the transfer.

## Dedup signature

Two transactions are considered the same internal transfer when ALL of the following match:

| Component | Tolerance |
| --- | --- |
| `business_id` | Exact |
| `amount_eur_cents` | Exact (after FX conversion to always-EUR per `currency_comparison_reference_policy`) |
| `transaction_type = 'INTERNAL_TRANSFER'` | Exact |
| Sign opposition | One transaction has `amount_signed > 0`, the other `< 0` |
| Date proximity | Both transactions' `transaction_date` within ±2 calendar days |
| Bank account opposition | The two transactions reference different `bank_account_id` values, both owned by the same business |
| Counterparty signature match | Either: both signatures normalize to "TRANSFER FROM/TO <other_account>", OR neither has a meaningful counterparty signature |

Dedup hash:

```
internal_transfer_dedup_hash = sha256_hex(canonical_json({
  business_id,
  amount_eur_cents,
  earlier_date,                            // min(t1.date, t2.date)
  later_date,                              // max(t1.date, t2.date)
  source_account_id,                       // the negative-amount-side
  destination_account_id                   // the positive-amount-side
}))
```

The hash is computed identically regardless of which transaction the lookup starts from.

## Single-writer rule

Block 11's `prepareInternalTransferEntry` per `transaction_type_enum` is the **only** writer of ledger entries for INTERNAL_TRANSFER. Block 12's OUT_FILTER and Block 13's IN_FILTER both **include** the transaction (it passes filtering) but neither writes ledger entries.

The single-writer pattern eliminates the race condition where OUT_FILTER and IN_FILTER might race to produce entries for the same logical transfer.

## How Block 11 dedups

```sql
-- Inside ledger.prepare_internal_transfer_entry
BEGIN;
  -- Check if a ledger entry already exists for this dedup_hash
  SELECT id FROM draft_ledger_entries
   WHERE internal_transfer_dedup_hash = $hash
     FOR UPDATE;

  -- If exists, link the second transaction to the existing entry
  -- and skip creation
  IF FOUND THEN
    UPDATE transactions
       SET ledger_status = 'PREPARED',
           ledger_entry_id = $existing_entry_id
     WHERE id = $current_transaction_id;
    RETURN;
  END IF;

  -- Otherwise, create the entry and link both transactions
  INSERT INTO draft_ledger_entries (
    internal_transfer_dedup_hash,
    ...
  ) VALUES ($hash, ...);

  UPDATE transactions
     SET ledger_status = 'PREPARED',
         ledger_entry_id = $new_entry_id
   WHERE id IN ($current_transaction_id, $matched_transaction_id);
COMMIT;
```

The `FOR UPDATE` lock serializes concurrent ledger preparations on the same dedup hash. Two concurrent OUT_FILTER and IN_FILTER ledger-prep invocations see the lock; the second one waits, then finds the existing entry and skips creation.

## Detection — finding the matching transaction

Block 11's resolver runs at ledger-prep time:

```sql
SELECT id, bank_account_id, transaction_date, amount_eur_cents, transaction_type
  FROM transactions
 WHERE business_id = $business_id
   AND transaction_type = 'INTERNAL_TRANSFER'
   AND amount_eur_cents = -$current_amount_eur_cents          -- opposite sign
   AND ABS(EXTRACT(DAY FROM (transaction_date - $current_date))) <= 2
   AND bank_account_id != $current_bank_account_id
   AND id != $current_id
   AND (ledger_status = 'PENDING' OR ledger_status = 'PREPARED')
 LIMIT 2;
```

Cases:
- 1 match found: this is the other side of the transfer; compute dedup_hash; proceed
- 0 matches found: the other side hasn't been uploaded (yet); proceed to create the single-side entry with `internal_transfer_unilateral = true` flag; the entry will be re-evaluated if the other side appears later
- 2+ matches found: ambiguous; raise `intake.internal_transfer_ambiguous` review issue (per `issue_type_to_group_mapping`) — user disambiguates

## Re-evaluation when the other side arrives

If a unilateral transfer's other side appears in a later statement upload:

1. `prepare_internal_transfer_entry` finds the unilateral row
2. Computes the dedup_hash
3. Links the new transaction to the existing entry
4. Sets `internal_transfer_unilateral = false`
5. Emits `INTERNAL_TRANSFER_BILATERAL_LINKED` (per `audit_event_taxonomy`)

The existing ledger entry is unchanged — no second creation, no balance change.

## Adjustment-run interaction

Per `out_adjustment_policies`: an OUT_ADJUSTMENT correcting a previously-finalized INTERNAL_TRANSFER follows the same single-writer rule. The adjustment_record_id links to the existing ledger entry; the entry is annotated with the adjustment.

## Audit events

| Event | When |
| --- | --- |
| `INTERNAL_TRANSFER_DETECTED` | Block 11 ledger-prep recognizes the pair |
| `INTERNAL_TRANSFER_BILATERAL_LINKED` | Unilateral → bilateral linking on later upload |
| `LEDGER_ENTRIES_PREPARED` | The single ledger entry creation |

## Cross-references

- `transaction_type_enum` — `INTERNAL_TRANSFER` definition
- `filter_rule_type_direction_table` — both filters include INTERNAL_TRANSFER
- `currency_comparison_reference_policy` — always-EUR comparison
- `audit_log_policies` — event naming
- `issue_type_to_group_mapping` — ambiguous-pair routing
- `out_adjustment_policies` (consolidated) — adjustment-run handling
- Block 11 Phase 07 — type-aware ledger preparation paths (canonical writer)
- Block 12 Phase 03 — OUT_FILTER
- Block 13 Phase 08 — IN_FILTER
- Stage 1 decision — single deduplicated ledger entry across filters
