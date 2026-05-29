# Runbook: Classification Confidence Drop

**Category:** Runbooks · Block 08 — Transaction Classification

---

## Purpose

Investigation and remediation steps for a sustained drop in AI classification confidence
scores for a given business. This runbook is initiated automatically or manually when
the confidence thresholds defined in `business_ai_config_schema.md` are breached.

---

## Trigger Conditions

This runbook is initiated when either of the following conditions is true for a business:

1. The average `classification_results.confidence_score` across transactions in a given
   run drops below **0.70** (configurable per business in
   `business_ai_config_schema.md` as `confidence_drop_threshold`).
2. The proportion of transactions with issue type `CLASSIFICATION_REVIEW` exceeds
   **40%** of classified transactions in a run (configurable as
   `review_issue_threshold_pct`).

Both thresholds are evaluated at run completion. A single run below threshold does not
automatically trigger this runbook — the intent is sustained or trending drops.
See Step 1 for the trending assessment.

---

## Step 1 — Baseline Assessment

Query `classification_results` for the affected business across the last 3 completed
runs:

```sql
SELECT run_id, AVG(confidence_score) AS avg_confidence, COUNT(*) AS tx_count
FROM classification_results
WHERE business_id = :business_id
  AND run_id IN (
    SELECT id FROM runs WHERE business_id = :business_id
    ORDER BY completed_at DESC LIMIT 3
  )
GROUP BY run_id
ORDER BY run_id DESC;
```

Interpret results:

| Pattern                              | Action                              |
|--------------------------------------|-------------------------------------|
| Single run below threshold           | Likely transient; monitor next run  |
| Two consecutive runs below threshold | Proceed to Step 2                   |
| Three runs trending downward         | High priority; proceed through all steps |

Record the average confidence per run and the delta from the business's historical
baseline (available in `business_ai_config_schema.md` as `confidence_baseline`).

---

## Step 2 — Rule Engine Check

A misconfigured classification rule can suppress rule engine matches, causing the pipeline
to escalate all transactions to AI classification. This increases AI load and lowers
average confidence (AI confidence is typically lower than rule engine confidence).

Check:

1. Query `classification_rules` for this business. Verify `is_active = true` for rules
   that should be active. Verify no rule has a `predicate` that is either empty or
   matches all transactions (e.g. a wildcard amount range covering all values).
2. Inspect the `classification_results` for the affected run and check the
   `resolution_method` distribution:

```sql
SELECT resolution_method, COUNT(*) AS count
FROM classification_results
WHERE run_id = :affected_run_id
GROUP BY resolution_method;
```

If `resolution_method = AI_TIER_*` accounts for a significantly higher proportion than
the historical baseline, rule engine suppression is the likely cause.

Remediation: correct the misconfigured rule in `classification_rule_schema.md` and
re-run classification for the affected run's unresolved transactions.

---

## Step 3 — Vendor Memory Freshness

Stale vendor memory entries are skipped by the vendor memory pass. If a high proportion
of the business's counterparties have stale entries, the vendor memory pass provides no
coverage and transactions fall through to the rule engine or AI.

Check:

```sql
SELECT COUNT(*) AS stale_entries
FROM vendor_memory
WHERE business_id = :business_id
  AND staleness_flag = true;
```

Compare against total vendor memory entries for the business. If more than 30% of entries
are stale, vendor memory staleness is a contributing factor.

Remediation: apply `vendor_memory_staleness_policy.md` remediation steps. This typically
involves a bulk re-confirmation pass (`classification.vendor_memory_update` with
`source = BULK_IMPORT`) using confirmed historical classification data.

---

## Step 4 — AI Tier Assignment Check

If the business's AI tier assignment in `ai_tier_escalation_policy.md` was recently
changed to a lower tier (e.g. `TIER_1` — fast, cost-optimized), classification confidence
will be lower as TIER_1 models trade accuracy for throughput.

Check the business's current tier:

```sql
SELECT ai_classification_tier, tier_updated_at
FROM business_ai_config
WHERE business_id = :business_id;
```

If `ai_classification_tier = TIER_1` and `tier_updated_at` correlates with the start of
the confidence drop, the tier downgrade is the cause.

Remediation: escalate the business to `TIER_3` in `ai_tier_escalation_policy.md`. Document
the escalation reason. Re-run classification for the affected run.

---

## Step 5 — Prompt Version Check

A regression in the prompt used for AI classification can cause a confidence drop across
all businesses using that prompt. This step checks whether a recent prompt update
correlates with the drop.

Check:

1. Review the deployment history for `tier_3_classifier_prompt.md` and
   `extraction_prompt.md`. Note any updates in the period before the confidence drop.
2. Compare the `prompt_version` field in `classification_results` for the affected run
   against the prior run.

```sql
SELECT DISTINCT prompt_version
FROM classification_results
WHERE run_id IN (:affected_run_id, :prior_run_id);
```

If the prompt version differs between the two runs, a prompt regression is likely.

Remediation: roll back the prompt to the prior version and re-run classification for the
affected run. Open a prompt regression issue in the AI engineering backlog.

---

## Remediation Summary

| Root Cause                  | Remediation Action                                         |
|-----------------------------|-------------------------------------------------------------|
| Misconfigured rule          | Fix predicate in classification_rule_schema.md; re-run     |
| Stale vendor memory         | Bulk re-confirmation via classification.vendor_memory_update|
| AI tier downgraded          | Escalate to TIER_3 via ai_tier_escalation_policy.md        |
| Prompt regression           | Roll back prompt; re-run; log regression issue             |
| Unknown / multi-factor      | Escalate to AI engineering (see Escalation section)        |

After applying any remediation, re-run classification for the affected run's transactions
using the appropriate re-run mechanism. Monitor the next completed run's average confidence
to confirm the fix.

---

## Escalation

If the average confidence remains below 0.70 after completing all remediation steps
in this runbook:

1. Assign a HIGH severity incident.
2. Escalate to the AI engineering team with:
   - The business_id and affected run_ids
   - The output of the Step 1 query (3-run trend)
   - The resolution_method distribution from Step 2
   - The prompt versions from Step 5
   - Any remediation steps already applied
3. Do not re-run classification further until the AI engineering team has reviewed the
   prompt and model outputs.

---

## Cross-References

- `classification_rule_schema.md` — rule table definition and predicate structure
- `vendor_memory_schema.md` — vendor memory table and staleness_flag
- `ai_tier_escalation_policy.md` — tier assignment rules and escalation criteria
- `business_ai_config_schema.md` — per-business confidence thresholds and baseline
- `tier_3_classifier_prompt.md` — TIER_3 classification prompt and version history
- `audit_event_taxonomy.md` — classification-related audit event definitions
