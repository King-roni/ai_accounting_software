# Runbook: Period Lock Override (Emergency Unlock)

## Purpose

This runbook describes the emergency procedure for unlocking a locked VAT period. Unlocking should only be performed when a genuine error has been discovered in a finalized period that cannot be corrected through forward-looking instruments (credit notes or amended returns). It is a destructive operation with legal implications and must be treated accordingly.

**Default preference:** Use a credit note or submit an amended VAT return before resorting to an unlock. An unlock is the last resort.

---

## Prerequisites

Before proceeding:

1. **Two-factor authentication** — The operator executing the unlock must have completed step-up authentication within the last 15 minutes. Step-up tokens expire. Re-authenticate if needed via `tool_step_up_request`.

2. **org:owner permission** — Only users with the `org:owner` role on the affected business entity may initiate a period unlock. Accountant-level roles cannot perform this operation.

3. **Written justification** — A written justification must be recorded before the unlock is executed. The justification must include:
   - The nature of the error (describe which records are wrong and why).
   - Why a credit note or amended return is not sufficient.
   - The name and user ID of the approving stakeholder.
   - Expected scope of corrections (which accounts, which documents).

   The justification is stored as a `PERIOD_LOCK_OVERRIDE` audit event payload. It is immutable once written.

4. **Backup confirmation** — Confirm a recent database backup exists and is restorable. The backup timestamp must be after the period was locked. This is a safety requirement before any destructive operation.

---

## When NOT to Unlock

Do not unlock a period in the following circumstances:

- **VAT return has been submitted to the tax authority.** An unlocked period followed by corrections while a return is under assessment creates a mismatch between your books and the authority's records. File an amended return instead.
- **Minor rounding differences.** Rounding errors of < €1.00 should be corrected via a journal entry in the current period, not by unlocking a prior period.
- **Missing categorization.** If a transaction was miscategorized but the amount is correct, prefer a reclassification journal in the current period.
- **The period has been exported.** If the period data has been shared with a third party (auditor, bank, regulator), an unlock that results in changed exports requires notifying those parties.

---

## Step-by-Step Procedure

### Step 1: Record justification and emit pre-unlock audit event

Before any database changes, emit the `PERIOD_LOCK_OVERRIDE` audit event with status `INITIATED`:

```sql
-- Use emit_audit tool, not direct SQL, to ensure hash chain integrity
SELECT emit_audit(
  'PERIOD_LOCK_OVERRIDE',
  'ledger',
  jsonb_build_object(
    'period_id',         :'period_id',
    'business_entity_id', :'business_entity_id',
    'initiated_by',      :'operator_user_id',
    'justification',     :'justification_text',
    'approver',          :'approver_user_id',
    'status',            'INITIATED'
  )
);
```

Record the returned audit event ID. You will reference it in the re-lock step.

### Step 2: Verify current lock state

```sql
SELECT id, period_label, locked_at, locked_by, lock_type
FROM vat_periods
WHERE id = :'period_id'
  AND business_entity_id = :'business_entity_id';
```

Confirm `lock_type = 'HARD'` or `'SOFT'` as expected. If the period is not locked, stop — no action is needed.

### Step 3: Call tool_period_lock with action UNLOCK

Use the `tool_period_lock` tool with `action = 'UNLOCK'`. Do not use raw SQL to clear the lock; the tool manages dependent state (balance rows, run status checks).

```
tool_period_lock(
  period_id:           <period_id>,
  business_entity_id:  <business_entity_id>,
  action:              'UNLOCK',
  override_justification: <justification_text>,
  step_up_token:       <current_step_up_token>
)
```

The tool will:
1. Clear `vat_periods.locked_at` and `vat_periods.locked_by`.
2. Set `is_locked = false` on all `ledger_account_balances` rows for this period.
3. Force a recompute of all balance rows for the period.

### Step 4: Execute corrections

Make the required corrections using the normal tools (`tool_ledger_post`, `tool_ledger_reverse`, invoice adjustments, etc.). Do not perform corrections via raw SQL on production.

Keep the correction scope narrow. Only modify the records identified in the justification.

### Step 5: Notify affected users

After the unlock, the system automatically sends a notification to all users with `in_workflow:read` access to the business entity informing them that the period has been unlocked. This notification is sent via `tool_notify_send` with template `PERIOD_UNLOCKED_NOTIFICATION`.

If the period is visible to an external accountant via the accountant pack, notify them directly.

### Step 6: Re-lock the period

After corrections are complete, re-lock the period using the same gate requirements as the original lock. The period cannot remain unlocked. Run through all finalization gate checks:

```
tool_period_lock(
  period_id:           <period_id>,
  business_entity_id:  <business_entity_id>,
  action:              'LOCK',
  reason:              'RE_LOCK_AFTER_OVERRIDE',
  override_ref:        <audit_event_id_from_step_1>
)
```

The `override_ref` links the re-lock event back to the original `PERIOD_LOCK_OVERRIDE` event in the audit chain.

### Step 7: Emit post-lock audit event

After successful re-lock, emit a second `PERIOD_LOCK_OVERRIDE` event with status `COMPLETED`:

```sql
SELECT emit_audit(
  'PERIOD_LOCK_OVERRIDE',
  'ledger',
  jsonb_build_object(
    'period_id',         :'period_id',
    'business_entity_id', :'business_entity_id',
    'completed_by',      :'operator_user_id',
    'corrections_made',  :'brief_description_of_changes',
    'relocked_at',       now(),
    'status',            'COMPLETED',
    'initiated_event_id', :'audit_event_id_from_step_1'
  )
);
```

---

## Audit Trail Requirements

The complete audit trail for a period lock override must contain:

1. `PERIOD_LOCK_OVERRIDE` with `status: INITIATED` — records justification before the unlock.
2. `PERIOD_UNLOCKED` — emitted by `tool_period_lock` when the lock is cleared.
3. Individual audit events for each corrective action performed.
4. `PERIOD_LOCKED` — emitted by `tool_period_lock` when the period is re-locked.
5. `PERIOD_LOCK_OVERRIDE` with `status: COMPLETED` — closes the override record.

All five events must exist before the override is considered properly closed. Internal compliance review will verify this chain.

**Audit taxonomy note:** Verify `PERIOD_LOCK_OVERRIDE` exists in the taxonomy. If not present, add it with domain `PERIOD`, entity `LOCK`, verb `OVERRIDE`.

---

## Legal Implications Under Cyprus Companies Law

Under Cyprus Companies Law (Cap. 113) and the Income Tax Law (N.118(I)/2002), accounting records must be kept for a minimum of six years. Altering a locked period's records is a significant act that must be fully documented and retained.

- Any period that has been unlocked and re-locked must be flagged in the period register with `has_override_history = true`.
- The justification and audit events constitute part of the accounting records and must be retained for the statutory six-year minimum.
- If the correction affects a VAT return already filed with the Tax Department of Cyprus, the corrected data must be reported via an amended VAT return (VIES form update if applicable).

---

## Related Documents

- `tools/tool_period_lock.md` — The tool used to lock and unlock periods.
- `policies/period_lock_policy.md` — Standard period lock rules and requirements.
- `policies/finalization_lock_policy.md` — Finalization lock that precedes the period lock.
- `schemas/ledger_account_balance_schema.md` — Balance rows that are unlocked as part of this procedure.
- `schemas/period_lock_schema.md` — Lock state columns on `vat_periods`.
- `runbooks/vat_recalculation_runbook.md` — Follow-on procedure if VAT figures change after unlock.
