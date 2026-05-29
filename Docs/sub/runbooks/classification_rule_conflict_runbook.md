# Runbook: Classification Rule Conflict Resolution

**Block:** Classification  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

## Overview

A classification rule conflict occurs when two or more active classification rules match the same transaction and suggest different categories. The pipeline cannot automatically resolve the conflict without risking a wrong ledger entry, so it pauses the transaction, opens a `CLASSIFICATION_RULE_CONFLICT` review issue, and waits for human resolution.

This runbook covers the full resolution path: identifying the conflict, analysing the competing rules, selecting a resolution strategy, applying the fix, and preventing recurrence across all affected transactions in the run.

---

## When This Runbook Applies

Trigger: a review issue with `issue_type = 'CLASSIFICATION_RULE_CONFLICT'` appears in the review queue.

Common causes:
- Two rules with equal priority match the same transaction (e.g. a vendor-pattern rule and an amount-range rule both fire).
- A new rule was added without checking for overlap with existing rules.
- A rule was broadened during editing and now overlaps a pre-existing rule.
- Two rules target the same counterparty but assign it to different account categories (e.g. one business expense rule and one owner-drawings rule both match the same vendor name pattern).

---

## Step 1 — Identify the Conflict

Pull the open `CLASSIFICATION_RULE_CONFLICT` issues for the affected run:

```sql
SELECT
  ri.id            AS issue_id,
  ri.transaction_id,
  ri.context->>'rule_id_a'     AS rule_id_a,
  ri.context->>'rule_id_b'     AS rule_id_b,
  ri.context->>'category_id_a' AS category_id_a,
  ri.context->>'category_id_b' AS category_id_b,
  ri.created_at
FROM review_issues ri
WHERE ri.run_id    = :run_id
  AND ri.issue_type = 'CLASSIFICATION_RULE_CONFLICT'
  AND ri.status     = 'OPEN'
ORDER BY ri.created_at;
```

For each issue, record:
- `transaction_id` — the transaction that triggered the conflict.
- `rule_id_a` and `rule_id_b` — the two competing rules.
- `category_id_a` and `category_id_b` — their respective suggested categories.

If multiple issues share the same `rule_id_a` / `rule_id_b` pair, they stem from the same rule overlap and should be resolved together as a batch.

---

## Step 2 — Analyse the Rules

Retrieve the full predicate definitions for both rules:

```sql
SELECT
  cr.id,
  cr.name,
  cr.priority,
  cr.vendor_pattern,
  cr.amount_min,
  cr.amount_max,
  cr.reference_pattern,
  cr.date_range_start,
  cr.date_range_end,
  cr.category_id,
  coa.name AS category_name,
  cr.created_at,
  cr.updated_at
FROM classification_rules cr
JOIN chart_of_accounts coa ON coa.id = cr.category_id
WHERE cr.id IN (:rule_id_a, :rule_id_b);
```

Assess specificity of each rule using this ranking (most specific first):

1. Exact vendor name match (`vendor_pattern` with no wildcards, e.g. `'^Exact Vendor Name$'`).
2. Anchored vendor pattern match (`vendor_pattern` with `^` or `$` anchors).
3. Partial vendor pattern match (unanchored `vendor_pattern`).
4. Reference pattern match (`reference_pattern` set).
5. Amount range match (only `amount_min`/`amount_max` set, no vendor constraint).
6. Date range match (only `date_range_start`/`date_range_end` set).

The more specific rule is more likely to represent the correct business intent. A rule that matches by exact vendor name should take precedence over a rule that only matches by amount range.

If both rules are at the same specificity level, the conflict is a genuine design ambiguity and requires a policy decision (Step 3c or 3d).

---

## Step 3 — Resolution Options

Choose one of the following resolutions. Options are ordered from least disruptive (immediate fix, no schema change) to most robust (systemic fix):

### Option A — Increase Priority of the Correct Rule

If one rule is clearly more specific or more correct, raise its priority above the competing rule.

```sql
-- Increment priority of the correct rule to ensure it wins
UPDATE classification_rules
SET    priority    = :new_priority,
       updated_at  = now()
WHERE  id          = :correct_rule_id
  AND  business_id = :business_id;
```

`priority` is an integer; lower values win (1 beats 10). Set the correct rule's priority to at least `conflict_rule_priority - 1`.

**When to use:** the conflicting rule will not affect other transactions incorrectly; only the ordering is wrong.

### Option B — Add a Disambiguating Predicate

Add a more specific predicate to one rule so the two rules no longer overlap.

Example: if both rules match a vendor by name, narrow one rule with an `amount_min`/`amount_max` range that covers only the transactions it should handle.

```sql
UPDATE classification_rules
SET    amount_min  = :narrowing_amount_min,
       amount_max  = :narrowing_amount_max,
       updated_at  = now()
WHERE  id          = :rule_id_to_narrow
  AND  business_id = :business_id;
```

After the update, verify the overlap is eliminated:

```sql
-- Check whether any transaction still matches both rules
SELECT t.id, t.amount, t.counterparty_name, t.reference
FROM   transactions t
WHERE  t.run_id     = :run_id
  AND  t.phase      = 'CLASSIFICATION'
  AND  /* rule_id_a predicate */ (
    t.counterparty_name ~* :vendor_pattern_a
    AND (:amount_min_a IS NULL OR t.amount >= :amount_min_a)
    AND (:amount_max_a IS NULL OR t.amount <= :amount_max_a)
  )
  AND  /* rule_id_b predicate */ (
    t.counterparty_name ~* :vendor_pattern_b
    AND (:amount_min_b IS NULL OR t.amount >= :amount_min_b)
    AND (:amount_max_b IS NULL OR t.amount <= :amount_max_b)
  );
```

**When to use:** the rules represent genuinely different situations that happen to overlap on a predicate dimension.

### Option C — Manual Override for This Transaction Only

Apply a manual classification to the blocked transaction without modifying either rule. This is appropriate when the conflict is rare and the two rules themselves are both correct for different contexts.

Call `classification.apply` with `confidence_source = 'MANUAL'`:

```
tool: classification.apply
inputs:
  run_id:             <run_id>
  transaction_id:     <transaction_id>
  category_id:        <correct_category_id>
  confidence_source:  'MANUAL'
  override_reason:    "Rule conflict between rule_id_a and rule_id_b.
                       Applied correct category manually pending rule
                       review."
```

**When to use:** the conflict affects one or very few transactions and a systemic rule change is not warranted.

### Option D — Create a New Higher-Priority Rule

When both conflicting rules are broadly correct and neither should be narrowed, create a new, more specific rule that handles the overlapping case explicitly and assign it priority 1 (highest).

```sql
INSERT INTO classification_rules (
  id,
  business_id,
  name,
  priority,
  vendor_pattern,
  amount_min,
  amount_max,
  reference_pattern,
  category_id,
  created_at,
  updated_at
) VALUES (
  gen_uuid_v7(),
  :business_id,
  'Disambiguation: <description>',
  1,
  :specific_vendor_pattern,
  :amount_min,
  :amount_max,
  :reference_pattern,
  :correct_category_id,
  now(),
  now()
);
```

**When to use:** the overlap scenario is expected to recur and the two existing rules serve different purposes that should both be preserved as-is.

---

## Step 4 — Apply the Resolution

### Immediate fix (options A, B, D)

After applying the rule change, trigger a re-classification for all transactions affected by this conflict pair in the current run:

```sql
-- Reset affected transactions back to unclassified so re-classification runs
UPDATE transactions
SET    category_id       = NULL,
       confidence_source = NULL,
       classification_at = NULL,
       phase             = 'CLASSIFICATION'
WHERE  run_id = :run_id
  AND  id IN (
    SELECT transaction_id
    FROM   review_issues
    WHERE  run_id     = :run_id
      AND  issue_type = 'CLASSIFICATION_RULE_CONFLICT'
      AND  context->>'rule_id_a' = :rule_id_a
      AND  context->>'rule_id_b' = :rule_id_b
  );
```

Then signal the classification engine to re-process these transactions. The engine will pick up any transaction in `phase = 'CLASSIFICATION'` with `category_id IS NULL`.

### Immediate fix (option C — manual override only)

Call `classification.apply` for each affected transaction. Close the review issue after each successful apply:

```sql
UPDATE review_issues
SET    status      = 'RESOLVED',
       resolved_at = now(),
       resolved_by = :current_user_id,
       resolution_note = 'Manual classification applied. Rule review pending.'
WHERE  id = :issue_id;
```

### Audit events expected after fix

- `CLASSIFICATION_RULE_UPDATED` — emitted when a rule's `priority`, `vendor_pattern`, `amount_min`, `amount_max`, or `reference_pattern` is changed (options A, B).
- `CLASSIFICATION_MANUAL_OVERRIDE_SET` — emitted for each transaction resolved via option C.

---

## Step 5 — Prevent Recurrence

### Impact analysis

Count all transactions in the same run that were affected by either of the conflicting rules (not just those that surfaced a conflict issue):

```sql
SELECT
  cr.id            AS rule_id,
  cr.name          AS rule_name,
  COUNT(t.id)      AS affected_transaction_count
FROM   classification_rules cr
JOIN   transactions t
       ON  t.run_id       = :run_id
       AND t.counterparty_name ~* cr.vendor_pattern
       AND (:amount_min IS NULL OR t.amount >= cr.amount_min)
       AND (:amount_max IS NULL OR t.amount <= cr.amount_max)
WHERE  cr.id IN (:rule_id_a, :rule_id_b)
GROUP  BY cr.id, cr.name;
```

Review whether the broader affected set should also be reclassified.

### Rule priority schema reference

Rule priority is stored in `classification_rules.priority` (INT, lower = higher precedence). The engine evaluates rules in ascending priority order and applies the first match. Reference: `classification_rule_schema.md`, `classification_rule_predicate_schema.md`.

### Document the resolution in the review issue

Update the review issue with a resolution note explaining which option was chosen and why:

```sql
UPDATE review_issues
SET    status          = 'RESOLVED',
       resolved_at     = now(),
       resolved_by     = :current_user_id,
       resolution_note = :resolution_description
WHERE  id              = :issue_id;
```

The `resolution_note` should reference the rule IDs, the conflict type, the option chosen (A/B/C/D), and any rule changes made. This note is surfaced in the review history and is visible to the accountant and to auditors.

### Post-resolution test

After applying the fix, run the overlap check query from Step 3 Option B against the current run to verify no remaining overlapping matches exist for the same rule pair. If the overlap is eliminated and all affected transactions have been reclassified successfully, the runbook is complete.

---

## Audit Events Summary

| Event | When expected |
|---|---|
| `CLASSIFICATION_RULE_UPDATED` | Options A, B, D — rule record modified |
| `CLASSIFICATION_MANUAL_OVERRIDE_SET` | Option C — manual classification applied per transaction |
| Review issue status transitions | `OPEN` to `RESOLVED` when issue is closed in Step 4 |

---

## Related Documents

- `classification_rule_schema.md` — DDL for `classification_rules`
- `classification_rule_predicate_schema.md` — predicate field definitions
- `tool_classification_apply.md` — `classification.apply` tool used in option C
- `review_issues_schema.md` — review issue structure and status transitions
- `classification_override_log_schema.md` — override log written by `classification.apply`
- `classification_confidence_drop_runbook.md` — related runbook for AI confidence degradation
- `issue_escalation_policy.md` — escalation rules for unresolved issues
- `layer1_rule_evaluation_schema.md` — rule evaluation engine internals
