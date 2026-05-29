# Cycle B03 — Workflow Engine — COMPLETE

**Date closed:** 2026-05-28
**Cycle UUID:** `430809b2-3204-4401-8bf9-833c7e2de000`
**Tickets:** 54/54 (100%) closed across 2 sessions (`2026-05-28a` + `2026-05-28b`)
**Status:** ✅ DONE

This document is the LOAD-BEARING cross-reference artifact downstream cycles read first.

---

## 1. Cycle scope

Cycle B03 covered the workflow-engine layer that drives every run in the system — schema, workflow-type registry, tool registration, state machine, gate evaluation, phase execution, resumability, failure handling, trigger engine, concurrency control, and adjustment runs. After this cycle, downstream blocks have the binding contracts they need to register tools, gates, phases, and adjustment workflows against a stable engine substrate.

The cycle spanned 11 phases (P01-P11) × ~4-5 sub-docs each. Total surface area: ~28 canonical sub-docs (including pre-existing ones ratified) + ~21 NEW Layer-2 policies authored across the two sessions.

## 2. Session-by-session disposition

| Session | Date | Tickets | Writes | Verifies |
| --- | --- | --- | --- | --- |
| `2026-05-28a` | first session | 15 (P01-P04 SD clusters; B02 + B10 also closed) | 3 in B03 | 12 |
| `2026-05-28b` | second session | 28 (P05-P11 SD clusters) | 14 in B03 | 14 |
| **TOTAL** | | **43 B03 sub-doc tickets + 11 phase tickets (Stage-2)** | **17 new B03 sub-docs** | **26 verifies + ratifications** |

(The other 11 tickets in B03 were Stage-2 phase tickets closed earlier in the project.)

## 3. NEW canonical sub-docs authored this cycle (17, all in `Docs/sub/policies/` unless noted)

### Session `2026-05-28a` (B03 portion only — 3 sub-docs)

1. `Docs/sub/reference/workflow_run_audit_trail_reconstruction.md` (BOOK-249) — audit-trail forensic reconstruction
2. `Docs/sub/reference/workflow_type_phase_optionality.md` (BOOK-255) — per-business effective phase sequence
3. `Docs/sub/ui/run_abort_confirmation_ui_spec.md` (BOOK-270) — abort UX confirm dialog

### Session `2026-05-28b` (14 sub-docs across P05-P11)

**P05 (Gates) — 2:**
4. `gate_composition_policy.md` (BOOK-274) — short-circuit + ordering + `boundary_eval_id uuid v7` join key
5. `gate_throws_semantics_policy.md` (BOOK-280) — exception capture + retry-then-BLOCKING-HOLD progression; resolves phase-doc-vs-tool-sig drift

**P06 (Phase Execution) — 4:**
6. `phase_execution_locking_policy.md` (BOOK-285) — `pg_advisory_xact_lock(bigint)` + `engine.run_lock_key(uuid)` MD5-truncated; closes 5× dangling reference
7. `estimated_completion_heuristic_policy.md` (BOOK-287) — P75 over last 10 runs + cold-start defaults
8. `engine_run_progress_api_policy.md` (BOOK-284) — `engine.fn_get_run_progress` + Supabase Realtime channel
9. `phase_execution_loop_policy.md` (BOOK-282) — ASCII flow diagram for `engine.advanceRun` + 3 error edges

**P07 (Resumability + Idempotency) — 2:**
10. `external_request_id_handling_policy.md` (BOOK-292) — 7-row per-service replay matrix
11. `crash_recovery_policy.md` (BOOK-294) — fleet-level companion to resumability_policy

**P08 (Failure + Retry) — 3:**
12. `error_classification_policy.md` (BOOK-296) — per-service vendor-signal → canonical-class mapping
13. `failure_review_issue_shape_policy.md` (BOOK-300) — 3 issue types + placeholder set + suggested-action matrix
14. `failure_user_action_flow_policy.md` (BOOK-302) — 6 user actions (Retry / Skip / Abort + 3 secondary) + RPCs

**P09 (Trigger Engine) — 2:**
15. `manual_trigger_api_policy.md` (BOOK-305) — 11-step validation order + 12 error codes
16. `system_principal_policy.md` (BOOK-310) — 8 SystemKind values + `upstream_actor` chain

**P10 (Concurrency) — 1:**
17. `race_condition_test_fixture_policy.md` (BOOK-320) — 7 deterministic fixtures (R1-R7)

**P11 (Adjustment Runs) — 2:**
18. `adjustment_reason_text_policy.md` (BOOK-323) — 5 content rules + EN/EL localisation
19. `adjustment_six_year_cap_policy.md` (BOOK-325) — AGE-based + business locale_timezone + legal_holds bypass

(Numbers 4-19 = 16 docs; total 19 authored in session b — note BOOK-282/284/285/287 covers 4 P06 sub-docs.)

## 4. The engine pipeline contract (binding across 14+ sub-docs)

```
advanceRun(run_id)
  → acquire pg_advisory_xact_lock(engine.run_lock_key(run_id))      [phase_execution_locking_policy]
  → for each phase boundary:
      → boundary_eval_id := uuid_v7()                                 [gate_composition_policy]
      → evaluateGates(entry)
          → for each gate in entry_gates[] in order:                   [gate_composition_policy]
              → invoke gate                                             [tool_gate_function_signature]
              → emit WORKFLOW_GATE_PASSED/_HOLD/_ROUTED/_TIMEOUT
              → if non-PASS: short-circuit                              [gate_composition_policy §3]
              → if throw: catch + WORKFLOW_GATE_THREW + retry           [gate_throws_semantics_policy → retry_policy §2]
      → for each tool in phase:
          → check tool_invocations dedup_key → return cache if SUCCESS  [dedup_key_generator_policy]
          → invoke proposer (READ_ONLY | EXTERNAL_CALL)                [tool_atomicity_policy]
          → external call: capture external_request_id BEFORE await     [external_request_id_handling_policy]
          → invoke single-writer with idempotency_key ON CONFLICT       [tool_atomicity_policy]
          → on retryable failure: retry per retry_policy §2/§3          [retry_policy]
          → on retry exhaustion: TOOL_FAILURE_POST_RETRY review issue   [failure_review_issue_shape_policy]
      → evaluateGates(exit) — same short-circuit semantics
      → recompute estimated_completion                                  [estimated_completion_heuristic_policy]
      → commit transaction (atomic boundary)                            [phase_execution_loop_policy §3]
      → if not terminal: recurse up to engine.advance_run_max_boundaries=8

Resume / crash recovery:
  → workers enumerate stalled runs (updated_at < now - 30s)            [crash_recovery_policy]
  → per-worker concurrency=4, per-business=1, throttle per service      [crash_recovery_policy]
  → for each: pg_try_advisory_xact_lock (non-blocking) → advanceRun     [phase_execution_locking_policy]
  → AWAITING_RESULT rows replay via external_request_id                 [external_request_id_handling_policy]
  → emit WORKFLOW_RUN_FORCE_RESUMED                                     [resumability_policy]

Manual trigger:
  → POST /api/v1/workflow-runs (11-step validation order)               [manual_trigger_api_policy]
  → transitionRun(null → CREATED)                                       [workflow state machine]
  → enqueue first advanceRun                                            [phase_execution_loop_policy]

Event trigger:
  → STATEMENT_UPLOAD_COMPLETED → trigger handler                        [event_subscription_pipeline_integration]
  → creates paired OUT_MONTHLY + IN_MONTHLY runs                        [out_run_concurrency_policy paired_run_id]
  → actor_kind=SYSTEM with upstream_actor pointing at uploader          [system_principal_policy]
  → shared INGESTION/CLASSIFICATION dedup via dedup_key                 [shared_phase_coordination_policy]

User action on failed run:
  → Retry / Skip / Abort / Re-authenticate / Resolve / Report bug       [failure_user_action_flow_policy]
  → review_issues OCC via version column                                [failure_review_issue_shape_policy]

Adjustment trigger:
  → manual_trigger with parent_run_id required                          [manual_trigger_api_policy step 6]
  → engine.validate_adjustment_six_year_cap                              [adjustment_six_year_cap_policy]
  → adjustment_records with reason_text validated by 5 content rules     [adjustment_reason_text_policy]
  → ADJUSTMENT_FINALIZATION → archive.handoff_adjustment_finalization    [adjustment_archive_handoff_integration]
  → Block 15 builds archive_v{N+1}_bundle.zip
```

## 5. Cross-block coordination punch list (grouped by consumer)

### B02 (Tenancy & Access) — schema additions
- `business_entities.locale_timezone text DEFAULT 'Europe/Nicosia'` (BOOK-325)
- `legal_holds` table (id, business_id, hold_kind, hold_started_at, hold_ends_at, hold_authority, filed_by_user_id, filed_at + dates_valid CHECK) (BOOK-325)
- `permission_matrix` rows for: `WORKFLOW_RUN/TRIGGER`, `WORKFLOW_RUN/RETRY`, `WORKFLOW_RUN/SKIP_TOOL`, `WORKFLOW_RUN/ABORT`, `OAUTH_TOKEN/REFRESH`, `REVIEW_ISSUE/RESOLVE`, `BUG_REPORT/CREATE` (BOOK-302, BOOK-305)

### B02·P09 (Legal-hold admin RPCs)
- File-hold RPC, lift-hold RPC; Owner + legal-staff role (BOOK-325)

### B03·P01 (Schema) — column additions
- `workflow_runs.estimated_completion timestamptz NULL` (BOOK-287)
- `workflow_runs.paired_run_id uuid NULL FK self-referential DEFERRABLE INITIALLY DEFERRED` (BOOK-312)
- `tool_invocations.dedup_key text` (BOOK-290 + multiple)
- `tool_invocations.external_request_id text NULL` (BOOK-292)
- `tool_invocations.external_service text NULL` (BOOK-292)
- `tool_invocations.error_class text NULL` (BOOK-296)
- `tool_invocations.error_class_signal text NULL` (BOOK-296)
- `tool_invocations.skipped_reason text NULL` (BOOK-302)
- `manual_trigger_idempotency_keys` table (business_id, client_idempotency_token, run_id, created_at) with 24h TTL (BOOK-305)
- `manual_trigger_rate_limit_buckets` table (BOOK-305)
- Partial index on `(external_service, external_request_id) WHERE non-null` (BOOK-292)

### B03·P03 (Tool registration)
- `tool_registry.external_service text NULL` column (BOOK-292)
- `tool_registry.classifier_function_ref text NOT NULL` for external-calling tools (BOOK-296)
- `tool_registry.retry_policy jsonb` per-tool override (BOOK-298 ratified)
- Boot-time lint: external_service cross-ref against bank_connector_replay_capability_table (BOOK-292)
- Boot-time lint: classifier_function_ref non-null for external-calling tools (BOOK-296)

### B03·P06 (Phase execution implementation) — RPCs + settings
- `engine.run_lock_key(uuid) RETURNS bigint IMMUTABLE PARALLEL SAFE` SECURITY DEFINER (BOOK-285)
- `engine.advance_run_max_boundaries = 8` recursion cap (BOOK-282)
- `engine.fn_get_run_progress(uuid)` SECURITY DEFINER STABLE in `engine.runtime_role` (BOOK-284)
- `engine.adminGetRunProgress` separate admin variant in `engine.admin_role` (BOOK-284)
- `engine.estimateCompletion(run_id)` + `engine_estimator_cold_start_constants` table (4h/6h/2h/3h) (BOOK-287)
- `engine.retry_failed_tool(issue_id)`, `engine.skip_failed_tool(issue_id, reason)`, `engine.abort_run(run_id, reason)`, `engine.resolve_issue_manually(issue_id, rationale)`, `engine.report_bug_on_issue(issue_id, repro)` SECURITY DEFINER RPCs (BOOK-302)
- `engine.manual_trigger_run(input jsonb) RETURNS uuid` SECURITY DEFINER (BOOK-305)
- `engine.acquire_recovery_token(service)` SECURITY DEFINER (BOOK-294)
- `engine.crashRecoverWorker` in-process flag (BOOK-294)
- `engine.evaluateGates` short-circuit + `boundary_eval_id` stamping (BOOK-274)
- `engine.test_barrier_arrive(name, count)` + `engine.test_barrier_reset()` CI-only RPCs (BOOK-320)
- `engine.validate_adjustment_reason(text)` SECURITY DEFINER IMMUTABLE (BOOK-323)
- `engine.validate_adjustment_six_year_cap(parent_run_id)` SECURITY DEFINER STABLE (BOOK-325)
- Crash recovery: `crash_recovery_concurrency=4`, `_inter_run_delay_ms=250`, `_per_business_max=1` (BOOK-294)
- Lock timeout: `SET LOCAL lock_timeout = '5s'` pattern in every `advanceRun` tx (BOOK-285)

### B03·P07
- `crash_recovery_throttle_state` table + token-bucket logic (BOOK-294)
- `engine.adjustment_reason_blocklist` + `engine.adjustment_reason_verb_list` tables boot-computed (BOOK-323)

### B03·P08 (Already canonicalised in retry_policy.md)
- Retry budgets: standard N=3 (2s/4s/8s ±10% jitter cap 30s); AI EXTERNAL N=2 (5s/10s)
- Classify `55P03` as `LOCK_BUSY` retryable (BOOK-285)
- Honor `gate_function_library_schema.retry_allowed` + `tool_registry.retry_allowed`

### B03·P10
- `test_race_barriers` table + GUC `app.test_mode` + `app.test_barrier_*` family (BOOK-320)
- 5-entry-per-side-phase loop cap counter; `SIDE_PHASE_LOOP_LIMIT_REACHED` event (BOOK-278)
- UUID-ascending cross-run advisory lock ordering (BOOK-285)

### B05·P02 (Audit taxonomy) — ~30+ NEW event kinds this cycle
- **Gate family** — `WORKFLOW_GATE_PASSED`, `_HOLD`, `_ROUTED_TO_SIDE_PHASE`, `_TIMEOUT`, `_THREW`, `_RETRY_EXHAUSTED`, `_FORCED_PASS`, `_FORCED_HOLD`, `SIDE_PHASE_LOOP_LIMIT_REACHED`
- **Phase family** — `WORKFLOW_PHASE_ENTERED`, `_COMPLETED`, `_HOLDING`, `_ROUTED`, `_COORDINATION_MISMATCH` (BLOCKING)
- **Run family** — `WORKFLOW_RUN_TERMINAL_REACHED`, `_STATE_CHANGED`, `_LOCK_ACQUIRED`, `_LOCK_TIMEOUT`, `_ESTIMATE_UPDATED`, `_PROGRESS_ADMIN_READ`, `_FORCE_RESUMED`, `_TRIGGERED_MANUAL`, `_TRIGGER_REJECTED`, `_RECOVERY_FAILED`
- **Tool family** — `WORKFLOW_TOOL_INVOKED`, `_INVOCATION_FAILED`, `_INVOCATION_RETRY_EXHAUSTED`, `_DEDUP_HIT`, `_REPLAY_VIA_EXTERNAL_REQUEST_ID`, `_FAILURE_ISSUE_RAISED`, `_USER_RETRY_REQUESTED`, `_USER_SKIPPED`
- **Adjustment family** — `WORKFLOW_ADJUSTMENT_REASON_OVERRIDE`, `_REJECTED_OUTSIDE_RETENTION`, `_LEGAL_HOLD_BYPASS`, `ADJUSTMENT_ARCHIVE_HANDOFF_REQUESTED`
- **Fleet recovery family** — `WORKFLOW_FLEET_CRASH_RECOVERY_STARTED`, `_COMPLETED`, `_DEGRADED`
- **System principal family** — `SYSTEM_PRINCIPAL_POLICY_MISMATCH` (HIGH), `_POLICY_REGISTRY_DRIFT` (HIGH)
- **Engine internal** — `ENGINEERING_BUG_REPORTED`, `ENGINE_RUN_ABORTED`, `WORKFLOW_ISSUE_RESOLVED_MANUALLY`
- **Composition field** — `boundary_eval_id uuid` field on ALL `WORKFLOW_GATE_*` events (BOOK-274)
- **actor_system field** — `jsonb` column with `system_kind_enum` (8 values), `triggered_by_event_id`, `triggered_by_event_type`, `upstream_actor`, `worker_id`, `policy_ref` (BOOK-310)
- **system_principal_policy_registry** table for policy_ref validation (BOOK-310)
- **`audit.emit_audit_as_system(...)`** SECURITY DEFINER helper (BOOK-310)

### B05·P03 (Audit read APIs)
- `v_audit_feed_personalized` consumes `actor_system.upstream_actor.user_id` for SYSTEM events caused by current user (BOOK-310)
- `audit_pii_redaction_policy` exemption for `adjustment_records.reason_text` (BOOK-323)

### B14 (Review queue) — NEW issue types
- `GATE_EVALUATION_FAILED` (BOOK-280)
- `GATE_INFINITE_LOOP_PROTECTION_TRIPPED` (BOOK-280)
- `ENGINE_LOCK_CONTENTION` (BOOK-285)
- `TOOL_FAILURE_POST_RETRY` (BOOK-282)
- `TOOL_TRANSIENT_FAILURE_EXHAUSTED` (BOOK-300)
- `TOOL_FATAL_ERROR` (BOOK-300)
- `TOOL_SCHEMA_ERROR` (BOOK-300)
- review_issues schema additions: `version bigint NOT NULL DEFAULT 1` (OCC), `resolution_action resolution_action_kind_enum`, `resolution_rationale text`, `resolution_user_id uuid`, `raised_by_tool_name text`, `error_class text`, `attempt_count integer`, `last_tool_invocation_id uuid FK`, `context_json jsonb` (BOOK-300, BOOK-302)
- Partial UNIQUE index on `(workflow_run_id, raised_by_tool_name) WHERE status='OPEN'` for issue dedup (BOOK-300)

### B15 (Finalize + Archive)
- `AWAITING_APPROVAL → FINALIZING → FINALIZED` boundary owned by B15 NOT B03·P06 (BOOK-282 non-goal)
- Uses same advisory lock key as advanceRun (BOOK-285)
- Step-up required for FINALIZATION-path ABORT (BOOK-302)
- B15·P09 retention engine respects active legal_holds (BOOK-325)

### B16 (Dashboard)
- run-list sort key by `estimated_completion`; NULL → em-dash; stale (>3× expected) → yellow indicator (BOOK-287)
- `engine_progress_api_latency` panel (BOOK-284)
- `engine_estimator_accuracy_dashboard` panel (BOOK-287)
- Realtime subscription on `workflow_runs` + `workflow_phase_states` filtered by run_id (BOOK-284)
- Start-run button POSTs to `/api/v1/workflow-runs` with `client_idempotency_token` (BOOK-305)
- Adjustment-start form pre-check with green/red/yellow indicators (BOOK-325)
- "Started by X (auto)" rendering rule for SYSTEM events with USER upstream_actor (BOOK-310)

### B12 + B13 (OUT/IN workflows) — phase configs
- Gate ordering per phase is part of the contract; cheap-predicate-first ordering binding (BOOK-274)
- CI gate-throw allowlist: `DatabaseError`, `NetworkError`, `InvalidGateInputError` only (BOOK-280)
- Each block owns its per-service classifier implementations (BOOK-296)
- B07 connector framework normalises bank-vendor signals BEFORE classification (BOOK-296)

### CI infrastructure
- `engine-race` job: `--maxWorkers=1` serialised; CI-only `engine.test_role` grant + `app.test_mode='true'` GUC (BOOK-320)
- Test-mode hooks check GUC; **NO test code in production**

## 6. Stage-6 drift queue — additions from Cycle B03

### To retire
- **`resumability_and_idempotency.md`** — defines competing `caller_idempotency_key SHA-256` construction. CONFLICTS with canonical two-mechanism model (`tool_invocations.dedup_key` engine cache + `workflow_phase_states.idempotency_key` single-writer guard).

### To reconcile
- **`adjustment_delta_kind_enum`** — `adjustment_record_schema.md` defines 8 values different from the project-meta drawer's 8 values. Stage-6 must reconcile both records to one canonical enum + migration + trigger + doc.
- **Subscription retry budget** — `event_subscription_pipeline_integration.md` cites 4-retries 1s/2s/4s/8s; `retry_policy.md` standard is 3-retries 2s/4s/8s. Stage-6 may converge.

### Mid-session drift corrected
- **`gate_throws_semantics_policy.md`** §3 initially cited `1s/5s/25s` for gate retry backoff. Replaced with canonical retry_policy §2 numbers (`base 2s × 2^(attempt-1)`, cap 30s, ±10% jitter). KG triple `BOOK-280 corrected_retry_constants` supersedes the earlier `defines_B03P08_default` triple.

### Stage-6 doc-write candidates flagged
- **`audit_event_payload_schemas.md`** — STILL missing; ~30+ new event kinds from this cycle alone need their payload shapes catalogued. **HIGHEST PRIORITY.**
- `audit_event_external_visibility_policy.md` — which events appear in external exports
- `audit_pii_redaction_policy.md` — `redactPII()` rules + adjustment_reason_text exemption
- `audit_log_volume_policy.md` — exclusion rules for high-frequency read audits
- `audit_log_visibility_policy.md` — uniform `RUN_NOT_FOUND` probing-resistance
- `bank_connector_replay_capability_table.md` (B07 reference)
- `cost_alerting_runbook.md` (Block 06 ops)
- `engine_estimator_accuracy_dashboard.md` (B16)
- `engine_estimator_cold_start_constants.md` (B03·P06)
- `step_up_token_policy.md` — ops-console raw-stack access
- `test_factories.md` — common CI fixture helpers
- Six reason-validation message templates: `Docs/templates/reason_validation_messages/{code}.{en,el}.md`

## 7. Two distinct idempotency mechanisms (binding, both legitimate)

After this cycle, every developer in the project binds to this model:

- **`tool_invocations.dedup_key`** — engine-level cache; skips tool invocation entirely on retry when prior `SUCCESS` row exists with matching `(workflow_run_id, tool_name, dedup_key)`. Per `dedup_key_generator_policy` 6 tool-category playbook.
- **`workflow_phase_states.idempotency_key`** — single-writer DB-write guard; `INSERT … ON CONFLICT (idempotency_key) DO NOTHING` pattern. Per `tool_atomicity_policy` proposer + single-writer pattern.

**NOT to use:** `caller_idempotency_key = SHA-256(run_id+phase_id+tool_name+call_seq)` from `resumability_and_idempotency.md` — competing/stale; retire in Stage 6.

## 8. Critical "watch this when implementing B03" items

1. **Use `(bigint)` overload of `pg_advisory_xact_lock`** — the `(bigint, bigint)` signature does not exist. Use `engine.run_lock_key(uuid) RETURNS bigint`.
2. **Always `SET LOCAL lock_timeout = '5s'`** before acquiring the advisory lock — prevents indefinite waits.
3. **NEVER use session-scoped `pg_advisory_lock`** — leaked locks in pooled connections will hang.
4. **`boundary_eval_id` MUST be stamped on every WORKFLOW_GATE_* event** in one composed evaluation — it's the join key for forensic reconstruction.
5. **Capture `external_request_id` BEFORE awaiting the external response** — otherwise recovery has nothing to look up.
6. **SYSTEM RPCs MUST set `policy_ref`** to a registered value; canonical-values lint enforced at boot.
7. **Tool retry-allowed=false for Anthropic + no-replay services** — overrides retry_policy's default 3-retry budget (cost-protective).
8. **`engine.advance_run_max_boundaries=8`** — bounded recursion per advanceRun call; yield to trigger engine after.
9. **Tests NEVER use OS sleep for synchronisation** — only `RaceBarrier` advisory-lock barrier or GUC-toggle barrier.
10. **adjustment_reason_text is exempt from PII redaction** — intentional disclosure; users must self-redact.

## 9. Cross-references

This entire cycle's sub-doc tree (all under `Docs/sub/policies/` unless noted):

**Session 2026-05-28a B03 contributions:**
- `Docs/sub/reference/workflow_run_audit_trail_reconstruction.md`
- `Docs/sub/reference/workflow_type_phase_optionality.md`
- `Docs/sub/ui/run_abort_confirmation_ui_spec.md`

**Session 2026-05-28b (this session) B03 contributions:**
- `gate_composition_policy.md`
- `gate_throws_semantics_policy.md`
- `phase_execution_locking_policy.md`
- `estimated_completion_heuristic_policy.md`
- `engine_run_progress_api_policy.md`
- `phase_execution_loop_policy.md`
- `external_request_id_handling_policy.md`
- `crash_recovery_policy.md`
- `error_classification_policy.md`
- `failure_review_issue_shape_policy.md`
- `failure_user_action_flow_policy.md`
- `manual_trigger_api_policy.md`
- `system_principal_policy.md`
- `race_condition_test_fixture_policy.md`
- `adjustment_reason_text_policy.md`
- `adjustment_six_year_cap_policy.md`

**Pre-existing ratified across this cycle:**
- `tool_gate_function_signature.md`
- `side_phase_routing_policy.md`
- `dedup_key_generator_policy.md`
- `tool_atomicity_policy.md`
- `retry_policy.md`
- `event_subscription_pipeline_integration.md`
- `trigger_events_processed_schema.md`
- `out_run_concurrency_policy.md`
- `shared_phase_coordination_policy.md`
- `adjustment_record_schema.md`
- `adjustment_archive_handoff_integration.md`
- `resumability_policy.md`

---

**End of Cycle B03 wrap-up.** Next: Cycle B04 (Data Architecture) per the execution order.

Per the resume pointer: Cycle B03 closed; next pickup is **Cycle B04 (Data Architecture)** — 54 backlog tickets at UUID `1de935db-12b4-4eb9-aa0b-4731cdf56725`.
