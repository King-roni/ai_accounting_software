# High Classification Error Rate Runbook

**Block:** Classification
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This runbook covers detection, diagnosis, and resolution when the AI classification
error rate is elevated. The classification pipeline assigns VAT categories,
`income_outcome` values, and confidence scores to ingested transactions and documents.
An elevated error rate degrades auto-accept throughput and increases manual review
burden for accountants.

"Error rate" in this context means the rate at which auto-accepted classifications are
subsequently overridden by accountants (tracked via `AI_CLASSIFICATION_OVERRIDDEN`
audit events), plus the rate of failed classification attempts. These are distinct from
model confidence — a model can produce high-confidence incorrect results.

---

## Step 1 — Detect

### Primary Signals

1. **AI_CLASSIFICATION_OVERRIDDEN Spike**
   Query the audit log for a sudden increase in override events. A rolling 1-hour
   override rate above 15% of total classifications is the alerting threshold.

   ```sql
   -- Override rate for the last 1 hour vs. prior 1 hour
   WITH current_window AS (
     SELECT COUNT(*) AS overrides
     FROM audit_events
     WHERE event_name = 'AI_CLASSIFICATION_OVERRIDDEN'
       AND created_at >= now() - INTERVAL '1 hour'
   ),
   accepted_window AS (
     SELECT COUNT(*) AS accepted
     FROM audit_events
     WHERE event_name = 'AI_CLASSIFICATION_ACCEPTED'
       AND created_at >= now() - INTERVAL '1 hour'
   )
   SELECT
     overrides,
     accepted,
     ROUND(overrides::numeric / NULLIF(accepted + overrides, 0) * 100, 2) AS override_rate_pct
   FROM current_window, accepted_window;
   ```

2. **Review Queue Backlog Growth**
   When the auto-accept threshold is being met but classifications are wrong, the review
   queue grows as accountants push items back. Monitor:

   ```sql
   SELECT
     COUNT(*) AS open_issues,
     MIN(created_at) AS oldest_open
   FROM review_queue_issues
   WHERE status NOT IN ('RESOLVED', 'DISMISSED')
     AND issue_type = 'CLASSIFICATION_UNCERTAIN';
   ```

   A backlog exceeding 200 open classification issues, or oldest open > 48 hours,
   warrants investigation.

3. **Sentry Error Rate — classification.classify Tool**
   Filter Sentry for errors from the `classification.classify` tool. Hard failures
   (model API timeouts, deserialization errors) appear here and indicate a different
   failure mode than silent wrong answers.

---

## Step 2 — Diagnostic Queries

### Error Rate by Time Window

Identify when the degradation started.

```sql
SELECT
  date_trunc('hour', ae.created_at) AS hour_bucket,
  SUM(CASE WHEN ae.event_name = 'AI_CLASSIFICATION_OVERRIDDEN' THEN 1 ELSE 0 END) AS overrides,
  SUM(CASE WHEN ae.event_name = 'AI_CLASSIFICATION_ACCEPTED' THEN 1 ELSE 0 END) AS accepted,
  ROUND(
    SUM(CASE WHEN ae.event_name = 'AI_CLASSIFICATION_OVERRIDDEN' THEN 1 ELSE 0 END)::numeric
    / NULLIF(COUNT(*), 0) * 100, 2
  ) AS override_rate_pct
FROM audit_events ae
WHERE ae.event_name IN ('AI_CLASSIFICATION_OVERRIDDEN', 'AI_CLASSIFICATION_ACCEPTED')
  AND ae.created_at >= now() - INTERVAL '72 hours'
GROUP BY 1
ORDER BY 1 ASC;
```

### Error Rate by VAT Category

Identify which categories are failing most frequently.

```sql
SELECT
  (ae.payload->>'vat_category') AS vat_category,
  COUNT(*) AS total_overrides,
  AVG((ae.payload->>'original_confidence')::numeric) AS avg_confidence_at_override
FROM audit_events ae
WHERE ae.event_name = 'AI_CLASSIFICATION_OVERRIDDEN'
  AND ae.created_at >= now() - INTERVAL '24 hours'
GROUP BY 1
ORDER BY total_overrides DESC
LIMIT 20;
```

### Error Rate by Business Entity

A spike concentrated in one or a few businesses often points to a specific data
quality issue (unusual transaction descriptions, foreign-language documents, new
supplier not in training data) rather than a global model problem.

```sql
SELECT
  ae.business_entity_id,
  COUNT(*) AS overrides,
  COUNT(DISTINCT ae.payload->>'document_id') AS distinct_docs
FROM audit_events ae
WHERE ae.event_name = 'AI_CLASSIFICATION_OVERRIDDEN'
  AND ae.created_at >= now() - INTERVAL '24 hours'
GROUP BY 1
ORDER BY overrides DESC
LIMIT 20;
```

---

## Step 3 — Root Cause Analysis

### Root Cause 1: Model Drift

Over time, the distribution of real transaction descriptions shifts away from the
training data. Seasonal patterns (e.g. end-of-year tax payments, quarterly VAT
obligations) can cause temporary drift. Signs: override rate rises gradually over
weeks, not suddenly. Affected categories are broad.

Resolution: trigger a retraining run (see Step 4 — Long-Term Resolution).

### Root Cause 2: New Transaction Type Not in Training Data

A new supplier, bank, or document format introduces descriptions the model has never
seen. Signs: override rate spikes suddenly, concentrated in one or two businesses, and
the overridden `vat_category` values show a consistent wrong answer.

Resolution: add representative samples to the training feedback set (see Step 4). In
the short term, lower the auto-accept threshold for the affected category.

### Root Cause 3: OCR Quality Degradation

If the upstream OCR step is producing garbled text, classifications will be wrong
because the input is garbage. Signs: overrides correlate with specific document formats
or sources (e.g. scanned PDFs from a specific bank). Check `intake.parse_document`
tool logs for low OCR confidence scores.

```sql
-- Check OCR confidence distribution for recently classified documents
SELECT
  ROUND((d.metadata->>'ocr_confidence')::numeric, 2) AS ocr_confidence,
  COUNT(*) AS doc_count
FROM documents d
WHERE d.created_at >= now() - INTERVAL '24 hours'
  AND d.metadata->>'ocr_confidence' IS NOT NULL
GROUP BY 1
ORDER BY 1 ASC;
```

If OCR confidence is below 0.75 for more than 20% of documents, the problem is
upstream. Escalate to `bank_statement_parse_failure_runbook.md`.

---

## Step 4 — Resolution

### Immediate Actions (Temporary)

**Lower the auto-accept threshold.** The auto-accept threshold determines the minimum
model confidence required to accept a classification without human review. Lowering it
routes more classifications to review, reducing wrong auto-accepts at the cost of
higher accountant workload.

Update the threshold via the platform admin API:

```bash
curl -X PATCH "$PLATFORM_ADMIN_URL/api/classification/config" \
  -H "Authorization: Bearer $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "auto_accept_threshold": 0.92,
    "changed_by": "on-call-engineer",
    "reason": "Elevated error rate — lowering threshold while investigating"
  }'
```

Normal threshold: 0.85. Interim threshold: 0.92. Do not lower below 0.92 as this
routes nearly all classifications to review and renders auto-classification ineffective.

**Route affected category to review.** If the root cause is specific to one VAT
category, configure an override rule to force all classifications in that category to
`REVIEW_HOLD` regardless of confidence:

```bash
curl -X POST "$PLATFORM_ADMIN_URL/api/classification/category-overrides" \
  -H "Authorization: Bearer $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "vat_category": "CATEGORY_NAME",
    "force_review": true,
    "reason": "Model errors detected — forcing review during investigation"
  }'
```

### Long-Term Resolution — Trigger Retraining

When the root cause is model drift or missing training data, the model must be
retrained with recent accountant feedback as additional training signal.

1. Export the recent feedback dataset:

   ```bash
   curl -X POST "$PLATFORM_ADMIN_URL/api/classification/export-feedback" \
     -H "Authorization: Bearer $ADMIN_KEY" \
     -H "Content-Type: application/json" \
     -d '{"from": "2026-04-01", "to": "2026-05-17", "include_overrides": true}'
   ```

2. Submit the dataset to the ML pipeline (refer to the ML ops team or the AI training
   procedure in `tool_ai_tier_metadata.md`).

3. Run the new model in shadow mode for 72 hours (classifications are made but not
   applied; override rate is compared to the production model).

4. If the shadow error rate is lower by at least 5 percentage points, promote the new
   model to production.

---

## Step 5 — Rollback Procedure

If a recent model deployment caused the error rate spike, roll back to the prior
model version.

1. Identify the prior model version in the model registry.
2. Update the model version pointer via the admin API:

   ```bash
   curl -X PATCH "$PLATFORM_ADMIN_URL/api/classification/model-version" \
     -H "Authorization: Bearer $ADMIN_KEY" \
     -H "Content-Type: application/json" \
     -d '{"model_version": "v1.4.2", "rolled_back_by": "on-call-engineer",
          "reason": "Error rate spike after v1.5.0 deploy"}'
   ```

3. Monitor the override rate for 30 minutes after rollback to confirm it returns to
   baseline (below 10%).
4. Emit `AI_MODEL_ROLLBACK_COMPLETED` audit event (log manually if the automated
   emitter is not available).

---

## Step 6 — Communication to Accountants

If the review queue backlog has grown significantly, notify affected accountants.

Template (via in-app notification or email):

```
We are experiencing a temporary increase in transactions requiring manual review.
Our team is actively working to resolve the issue. You may notice a higher than
normal number of items in your review queue over the next [estimated timeframe].
We will notify you when the issue is resolved and the queue returns to normal.
No action beyond normal review is required from you.
```

Do not provide technical details in accountant-facing notifications. Use the audit
trail for internal tracking.

---

## Related Documents

- `/Docs/sub/runbooks/bulk_classification_runbook.md`
- `/Docs/sub/runbooks/classification_confidence_drop_runbook.md`
- `/Docs/sub/runbooks/review_queue_live_integration_runbook.md`
- `/Docs/sub/reference/audit_event_taxonomy.md`
- `/Docs/sub/reference/tool_ai_tier_metadata.md`
- `/Docs/sub/guides/accountant_workflow_guide.md`
