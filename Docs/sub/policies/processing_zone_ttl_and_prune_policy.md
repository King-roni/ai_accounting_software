# processing_zone_ttl_and_prune_policy

**Category:** Policies · **Owning block:** 04 — Data Architecture · **Co-owner:** 11 — Legal-hold (B04·P11) · **Stage:** 4 sub-doc (Layer 2)

The TTL windows + prune background job + override mechanisms for `processing_artifacts`. The Processing zone is short-lived by design — artefacts are working data, not permanent records. This policy pins the per-artefact-type expiry rules, the prune-job behaviour, and how legal hold (Block 04 Phase 11) blocks pruning even past `expires_at`.

---

## TTL windows by run state

Per phase doc B04·P06: `expires_at` is set at artefact creation but actively updated as the parent workflow run transitions states.

| Parent run state | `expires_at` window | Rationale |
| --- | --- | --- |
| Run is in progress (CREATED / RUNNING / PAUSED / REVIEW_HOLD / AWAITING_APPROVAL) | NULL — no expiry while run is live | Artefacts may be re-read by downstream phases |
| Run reaches `FINALIZED` | `finalized_at + 24 hours` | Short diagnostic window post-finalization |
| Run reaches `FAILED` or `CANCELLED` | `terminal_at + 30 days` | Longer post-mortem window — operators may need to investigate failures |
| Run is in progress longer than 90 days | NULL but soft-alert raised | Long-running run probably needs human attention; do NOT auto-prune |

The 24-hour post-FINALIZED window is intentionally short: per Cyprus VAT retention rules, the operational + archive records hold the audit-grade evidence. The Processing zone is scratch state that does not need to survive into the 6-year retention window.

The 30-day post-failure window is longer because failed runs often need cross-team triage — engineering + ops + sometimes the business owner. 30 days is generous enough to bridge weekends + multi-step debug cycles.

Soft-alert at 90 days fires `WORKFLOW_RUN_PROCESSING_LONG_RUNNING` (MEDIUM severity) once per run. The alert directs ops to either complete or cancel the run.

## TTL override per artefact type

Some artefact types need slightly different TTL — particularly when used by post-finalization tooling:

| `artifact_type` | TTL override |
| --- | --- |
| `OCR_TEXT` | Default (per run state above) — but kept indefinitely if `documents.ocr_text_reference` still points at it (referential pin) |
| `EXTRACTED_FIELDS_DRAFT` | Default |
| `AI_PAYLOAD_REDACTED` | Default + 60 days if any post-finalization audit query is pending (per `audit_pii_redaction_policy` retention extension) |
| `AI_RESPONSE` | Same as `AI_PAYLOAD_REDACTED` (paired retention) |
| `MATCH_CANDIDATE_BUNDLE` | Default — pruned at 24h post-FINALIZED even if review queue still references via foreign-key (B14 reads via candidate-id resolver, not direct FK) |

Referential pins (e.g., `documents.ocr_text_reference`) extend the TTL beyond the default. The prune job checks for active references before deleting.

## Legal-hold interaction

Per Block 04 Phase 11: a business under legal hold has its retention windows EXTENDED indefinitely on all data including Processing-zone artefacts.

The prune job's deletion query:

```sql
DELETE FROM processing_artifacts
WHERE expires_at < now()
  AND business_id NOT IN (
    SELECT business_id FROM legal_holds
    WHERE hold_started_at <= now()
      AND (hold_ends_at IS NULL OR hold_ends_at >= now())
  );
```

Artefacts skipped due to legal hold emit `PROCESSING_ARTIFACT_PRUNE_SKIPPED` (LOW) with `reason = 'LEGAL_HOLD_ACTIVE'`.

## Prune background job

Per Stage 1 decision: prune is an internal background job, NOT a workflow trigger. Runs hourly on a schedule.

```
1. SELECT id, business_id, payload_storage_path, payload_inline IS NULL AS in_storage
   FROM processing_artifacts
   WHERE expires_at < now() - interval '5 minutes'   -- 5-min grace for clock skew
     AND business_id NOT IN (active_legal_hold_business_ids)
   LIMIT 5000;                                       -- bounded batch per run

2. For each row:
   a. If in_storage: DELETE the Storage object at payload_storage_path
   b. DELETE the DB row (CASCADE per the audit-event-id FK if present)
   c. Emit PROCESSING_ARTIFACT_PRUNED (LOW) with {artifact_id, artifact_type, age_days}

3. If any DELETE fails:
   a. Mark the row with prune_failure_count incremented
   b. Skip; retry next sweep
   c. After 3 failures: emit PROCESSING_ARTIFACT_PRUNE_FAILED (HIGH) for ops
```

The 5000-row batch cap prevents the prune job from monopolising connections. The 5-minute grace allows for clock-skew between application + DB.

## Skipped-prune reasons

`PROCESSING_ARTIFACT_PRUNE_SKIPPED` carries one of:

| Reason | Trigger |
| --- | --- |
| `LEGAL_HOLD_ACTIVE` | Business has an active legal hold per Block 04 Phase 11 |
| `RUN_STILL_ACTIVE` | Parent workflow run is not yet in terminal state (defensive — should not happen given expires_at is NULL while live) |
| `REFERENTIAL_PIN_ACTIVE` | Another operational table column points at the artefact (e.g., `documents.ocr_text_reference`) |
| `STORAGE_OBJECT_NOT_FOUND` | Storage object already gone — DB row deleted regardless (defensive) |

Sustained skip rate above 5% over 24 hours triggers ops review via `cross_tenant_alerting_runbook`.

## Audit events

```ts
emitAudit("PROCESSING_ARTIFACT_PRUNED", {
  artifact_id, business_id, workflow_run_id, artifact_type,
  age_at_prune_days: integer,
  storage_mode: "INLINE" | "STORAGE",
  pruned_at
});

emitAudit("PROCESSING_ARTIFACT_PRUNE_SKIPPED", {
  artifact_id, business_id,
  reason: "LEGAL_HOLD_ACTIVE" | "RUN_STILL_ACTIVE" | "REFERENTIAL_PIN_ACTIVE" | "STORAGE_OBJECT_NOT_FOUND",
  skipped_at
});

emitAudit("PROCESSING_ARTIFACT_PRUNE_FAILED", {
  artifact_id, business_id,
  failure_count: integer,
  error_class_redacted: text,
  failed_at
});
```

Pruned-event severity LOW (aggregated per audit-volume policy when bulk-pruning). Skip + failure severities per the §skipped-prune table.

## Idempotency

Re-running the prune job is safe: rows already deleted simply aren't in the SELECT. Storage objects already deleted return 404 from the storage gateway and emit `STORAGE_OBJECT_NOT_FOUND` skip reason.

## Non-goals

This policy does NOT cover:

- Operational table retention (per `retention_policies_schema` for B04)
- Archive bundle retention (Object Lock compliance mode per `storage_bucket_configuration` §4)
- Audit log retention (separate per `audit_retention_policy`)
- Legal-hold administration (filing / lifting holds — B02·P09)

## Cross-references

- `processing_artefact_taxonomy_policy` — sibling defining the 5 artifact_type values + producer rules
- `inline_vs_storage_decision_policy` — sibling defining payload_inline vs payload_storage_path
- `storage_bucket_configuration` §3 — processing-zone bucket
- `legal_holds` table (B02·P04 + B15·P09) — hold lookups in prune job
- `adjustment_six_year_cap_policy` — legal-hold interaction at retention boundaries (sibling pattern)
- `audit_pii_redaction_policy` — `AI_PAYLOAD_REDACTED` extension when audit query pending
- `cross_tenant_alerting_runbook` — sustained skip-rate ops alert
- `retention_policies_schema` (B04·P10) — sibling for operational table retention
- `audit_event_payload_schemas` (Stage-6 catalog) — `PROCESSING_ARTIFACT_PRUNE*` event shapes
- Block 04 Phase 06 — owning phase
- Block 04 Phase 11 — legal hold
- Stage 1 decision — prune is internal background job, not workflow trigger
