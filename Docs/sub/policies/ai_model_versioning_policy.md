# Policy: AI Model Versioning

**Namespace:** ai  
**Status:** Draft  
**Applies to:** `ocr_engine_configs`, `ai_classification_configs`, `ai_classification_results`, `engine.gate_ai_canary`

---

## Purpose

Define how AI model versions are pinned, rolled out, rolled back, and preserved in audit for the OCR and classification engines. This policy ensures that every classification decision is traceable to a specific model version and that period-lock guarantees extend to the model version that produced each result.

---

## 1. Version pinning

Each business entity has an `ocr_engine_configs` row and an `ai_classification_configs` row. Both tables include a `model_version` column (text, not null) that pins the model version active for that business.

The `model_version` value is a tag of the form `<engine>-<semver>` (e.g., `gpt-classification-1.4.2`, `tesseract-ocr-5.3.0`). The tag must match an entry in the platform's model registry before it can be written to either config table.

Default behavior: when a new business entity is created, the platform writes the current stable model version (the version at 100% rollout weight) into both config rows. The entity begins classifying immediately at the stable version without operator action.

Changes to `model_version` on either config table require a write via a controlled migration or admin API. Direct UPDATE statements in application code are not permitted per `data_layer_conventions_policy`. Every write to `model_version` is audited.

---

## 2. Rollout stages

New model versions progress through four stages before reaching 100% of tenants. Stage transitions are controlled by the `engine.gate_ai_canary` feature flag.

### Stage 0: Canary (internal tenants only)

The new version is written to `model_version` for internal-only business entities. No production tenants are affected. Accuracy metrics are collected for a minimum of 7 days. The canary stage is gated by `engine.gate_ai_canary`. If `engine.gate_ai_canary` is disabled, no tenant receives the new version.

### Stage 1: 10% rollout

`engine.gate_ai_canary` weight is set to 0.10. The platform selects 10% of production tenants at random and writes the new `model_version` to their config rows. Tenants are selected by consistent hashing on `business_entity_id` so the same 10% remain on the new version for the duration of this stage.

Minimum duration: 7 days. Promotion to Stage 2 requires that the accuracy delta (new version vs. stable) is within ±2% on the classification confidence metric measured against the same period's ground truth.

### Stage 2: 50% rollout

`engine.gate_ai_canary` weight is set to 0.50. An additional 40% of tenants are migrated. The same accuracy gate applies. Minimum duration: 7 days.

### Stage 3: 100% rollout (stable)

All remaining tenants are migrated. The new version becomes the platform default written to new business entities. The previous stable version is retained in the model registry but is no longer written to new config rows.

---

## 3. Rollback procedure

A rollback is triggered when accuracy drops more than 2% on the classification confidence metric compared to the previous stable version, or when a BLOCKING-severity classification error is detected in production.

### Steps

1. Disable `engine.gate_ai_canary` immediately. This prevents further tenants from receiving the new version.
2. Identify affected tenants: query `ai_classification_configs` WHERE `model_version = '<new_version>'`.
3. For each affected tenant, write `model_version = '<previous_stable_version>'` to both `ocr_engine_configs` and `ai_classification_configs`. Perform this write via the admin migration API, not direct SQL.
4. Re-classify any transactions classified by the rolled-back version that are still in `DRAFT` or unreviewed state. Transactions already locked (period closed) are not re-classified; the version they were classified under is preserved in `ai_classification_results.model_version`.
5. Emit an audit event for each tenant's config change. The event type is `AI_CONFIG_MODEL_REVERTED`. Note: this event must be added to `audit_event_taxonomy.md` if not already present.
6. File an incident report documenting the accuracy delta, affected tenant count, and rollback completion timestamp.

---

## 4. Version audit trail

Every invocation of the AI classification engine writes a row to `ai_classification_results`. The `model_version` column on that table records the exact version tag that produced the result, copied from `ai_classification_configs.model_version` at invocation time.

This means the model version is stamped on the result row, not looked up retroactively. If `ai_classification_configs.model_version` is later updated (rollout or rollback), previously classified transactions retain their original `model_version` in `ai_classification_results`. The audit trail is immutable after insert.

Operators can determine which version classified any transaction: `SELECT model_version FROM ai_classification_results WHERE transaction_id = '<id>'`.

To identify all transactions classified by a specific version: `SELECT transaction_id FROM ai_classification_results WHERE model_version = '<version>' AND business_entity_id = '<id>'`.

---

## 5. Frozen model guarantee

When a period is locked (via `tool_period_lock.md`), the model version that classified transactions in that period is preserved in `ai_classification_results` rows and becomes part of the period's audit record.

The `period_lock_schema` records the lock timestamp. Any `ai_classification_results` rows with `created_at <= lock_timestamp` for transactions in the locked period are considered frozen. These rows must not be updated after the period is locked.

Re-classification of locked transactions is not permitted. If a rolled-back model version produced results in a now-locked period, those results stand. The accountant may override individual classifications via `classification_override_log`, but the original `model_version` in `ai_classification_results` is preserved.

The archive bundle for a locked period includes a snapshot of `ai_classification_results` rows. See `archive_bundle_layout_schema.md` for the inclusion list.

---

## 6. A/B testing framework

The `engine.gate_ai_canary` feature flag is the sole mechanism for routing tenants between model versions during rollout. No other flag controls model version assignment.

Gate name: `engine.gate_ai_canary` (two-part, namespace `engine`, descriptor `ai_canary`).

The gate operates as a weighted random assignment on `business_entity_id`. Assignment is sticky: once a tenant is assigned to a version by the gate, their `ai_classification_configs.model_version` is written and the gate is no longer consulted for that tenant until the next rollout or rollback.

Metrics collected during A/B testing:
- Classification confidence score distribution (mean, p25, p75, p95)
- Override rate: fraction of AI classifications that were overridden by accountants
- Auto-confirm rate for matching: fraction of EXACT matches involving AI-classified transactions
- Latency: p50 and p95 of `ai_classification_results.latency_ms`

Metrics are evaluated after each stage's minimum duration. The decision to promote or roll back is made by the platform team based on these metrics and any reported BLOCKING-severity issues.

---

## Related Documents

- `ai_classification_result_schema.md` — `model_version` column definition
- `ocr_engine_config_schema.md` — OCR model version pinning
- `ai_gateway_schema.md` — gateway invocation that reads model_version from config
- `tool_gateway_invoke_ai.md` — tool that stamps model_version on results
- `period_lock_schema.md` — period lock timestamp used for frozen model guarantee
- `archive_bundle_layout_schema.md` — ai_classification_results in archive snapshot
- `classification_confidence_policy.md` — accuracy thresholds used in rollout gates
- `audit_event_taxonomy.md` — AI_CONFIG_MODEL_REVERTED event (to be added)

---

## 7. Operator controls

Operators with `ai:model_admin` permission may:
- Read the current `model_version` for any business entity via the admin API.
- Pin a specific business entity to a specific model version outside the rollout schedule (e.g., for a tenant that requires consistency across a multi-year audit).
- Pause rollout progression for a single tenant without triggering a platform-wide rollback.

Operators may not:
- Write `model_version` directly via SQL. All writes go through the admin API which enforces registry validation and audit logging.
- Set `model_version` to a version that has been formally deprecated (removed from the registry). Deprecated versions are blocked at the API layer.

All `model_version` changes emit an audit event scoped to the affected `business_entity_id`. The event payload includes `previous_version`, `new_version`, `changed_by`, and `change_reason`.

---

## 8. Taxonomy additions required

The following audit events referenced in this policy are not yet in `audit_event_taxonomy.md` and must be added before production deployment:

- `AI_CONFIG_MODEL_REVERTED` (MEDIUM) — emitted when a tenant's model version is rolled back. Payload: `business_entity_id`, `previous_version`, `new_version`, `changed_by`.
- `AI_ROLLOUT_STAGE_ADVANCED` (LOW) — emitted when `engine.gate_ai_canary` weight is updated to advance a rollout stage. Payload: `new_weight`, `model_version`, `tenant_count_migrated`.
