-- B08·P09 CLASSIFY phase registration
-- Seeds 6 tools, 2 gates, 12 phase_tool_expectations, 4 phase_gate_assignments,
-- gate-evaluation helpers, and phase-boundary audit RPCs.
-- Notes:
--   * Existing seed phase name is CLASSIFY (not CLASSIFICATION).
--   * classification_status enum has CONFIRMED (not AUTO_CONFIRMED) — exit gate accepts CONFIRMED|NEEDS_CONFIRMATION.

-- 1. Tool registry seeds ------------------------------------------------------

INSERT INTO public.tool_registry(
  tool_name, version, input_schema, output_schema, side_effect, ai_tier,
  failure_semantics, dedup_key_generator_ref, description,
  registered_at, updated_at, retry_max_attempts, retry_backoff_base_ms, retry_backoff_max_ms
) VALUES
  ('classification.snapshot_taxonomy', '1.0.0',
   '{"type":"object","required":["workflow_run_id","user_id"],"properties":{"workflow_run_id":{"type":"string","format":"uuid"},"user_id":{"type":"string","format":"uuid"}}}'::jsonb,
   '{"type":"object","required":["ok"],"properties":{"ok":{"type":"boolean"},"already_captured":{"type":"boolean"},"taxonomy_version_id":{"type":"string","format":"uuid"},"audit_event_id":{"type":"string","format":"uuid"}}}'::jsonb,
   'WRITES_RUN_STATE'::public.side_effect_class_enum, 'NONE'::public.ai_tier_enum,
   'RETRYABLE'::public.tool_failure_semantics_enum, 'workflow_run_id',
   'Captures the active taxonomy + custom tags onto workflow_runs.classification_taxonomy_snapshot. Idempotent: re-calls return already_captured=true.',
   clock_timestamp(), clock_timestamp(), 3, 250, 4000),
  ('classification.apply_layer1', '1.0.0',
   '{"type":"object","required":["workflow_run_id"],"properties":{"workflow_run_id":{"type":"string","format":"uuid"},"transaction_ids":{"type":"array","items":{"type":"string","format":"uuid"}}}}'::jsonb,
   '{"type":"object","properties":{"layer1_results":{"type":"array","items":{"type":"object","properties":{"transaction_id":{"type":"string","format":"uuid"},"chosen_type":{"type":"string"},"chosen_tag_id":{"type":"string","format":"uuid"},"confidence":{"type":"number"},"rule_id":{"type":"string","format":"uuid"}}}}}}'::jsonb,
   'READ_ONLY'::public.side_effect_class_enum, 'NONE'::public.ai_tier_enum,
   'RETRYABLE'::public.tool_failure_semantics_enum, NULL,
   'Layer 1 — deterministic rules. Stateless from DB perspective; returns proposed classifications in memory.',
   clock_timestamp(), clock_timestamp(), 3, 100, 2000),
  ('classification.apply_layer2', '1.0.0',
   '{"type":"object","required":["workflow_run_id"],"properties":{"workflow_run_id":{"type":"string","format":"uuid"},"transaction_ids":{"type":"array","items":{"type":"string","format":"uuid"}}}}'::jsonb,
   '{"type":"object","properties":{"layer2_results":{"type":"array","items":{"type":"object","properties":{"transaction_id":{"type":"string","format":"uuid"},"vendor_memory_id":{"type":"string","format":"uuid"},"chosen_type":{"type":"string"},"chosen_tag_id":{"type":"string","format":"uuid"},"confidence":{"type":"number"}}}}}}'::jsonb,
   'READ_ONLY'::public.side_effect_class_enum, 'NONE'::public.ai_tier_enum,
   'RETRYABLE'::public.tool_failure_semantics_enum, NULL,
   'Layer 2 — vendor memory lookup for transactions Layer 1 did not resolve cleanly. Read-only.',
   clock_timestamp(), clock_timestamp(), 3, 100, 2000),
  ('classification.apply_layer3', '1.0.0',
   '{"type":"object","required":["workflow_run_id"],"properties":{"workflow_run_id":{"type":"string","format":"uuid"},"transaction_ids":{"type":"array","items":{"type":"string","format":"uuid"}}}}'::jsonb,
   '{"type":"object","properties":{"layer3_results":{"type":"array","items":{"type":"object","properties":{"transaction_id":{"type":"string","format":"uuid"},"chosen_type":{"type":"string"},"confidence":{"type":"number"},"reached_tier":{"type":"integer"}}}},"tier2_invocations":{"type":"integer"},"tier3_invocations":{"type":"integer"}}}'::jsonb,
   'READ_ONLY'::public.side_effect_class_enum, 'EXTERNAL_LLM'::public.ai_tier_enum,
   'RETRYABLE'::public.tool_failure_semantics_enum, NULL,
   'Layer 3 — AI fallback via Block 06 gateway. Tier 2 → Tier 3 escalation is an explicit second invocation (audit-distinct), not a retry. Declared at max tier (EXTERNAL_LLM) so the gateway''s cost ceiling/redaction policy covers both tiers.',
   clock_timestamp(), clock_timestamp(), 3, 500, 8000),
  ('classification.merge_and_score', '1.0.0',
   '{"type":"object","required":["workflow_run_id","layer_results"],"properties":{"workflow_run_id":{"type":"string","format":"uuid"},"layer_results":{"type":"array"}}}'::jsonb,
   '{"type":"object","properties":{"merged":{"type":"array","items":{"type":"object","properties":{"transaction_id":{"type":"string","format":"uuid"},"chosen_type":{"type":"string"},"chosen_tag_id":{"type":"string","format":"uuid"},"merged_confidence":{"type":"number"},"agreement_boost_applied":{"type":"boolean"},"disagreement_penalty_applied":{"type":"boolean"}}}}}}'::jsonb,
   'READ_ONLY'::public.side_effect_class_enum, 'NONE'::public.ai_tier_enum,
   'RETRYABLE'::public.tool_failure_semantics_enum, NULL,
   'Merge per-layer outputs via Phase 07 merge_layer_confidence; resolve primary tag from snapshot; fall back to type-default tag if none pinned.',
   clock_timestamp(), clock_timestamp(), 3, 100, 2000),
  ('classification.assign_status', '1.0.0',
   '{"type":"object","required":["workflow_run_id","decisions"],"properties":{"workflow_run_id":{"type":"string","format":"uuid"},"decisions":{"type":"array"}}}'::jsonb,
   '{"type":"object","properties":{"transactions_confirmed":{"type":"integer"},"transactions_needs_confirmation":{"type":"integer"},"review_issues_created":{"type":"integer"},"vendor_memory_confirmations":{"type":"integer"}}}'::jsonb,
   'WRITES_RUN_STATE'::public.side_effect_class_enum, 'NONE'::public.ai_tier_enum,
   'IDEMPOTENT_AT_MOST_ONCE'::public.tool_failure_semantics_enum, 'workflow_run_id',
   'Writes final classification (transaction_type, system_tag, secondary_tags, classification_status, classification_confidence, classification_method) + raises NEEDS_CONFIRMATION review issues + bumps vendor_memory.confirmations_count for CONFIRMED rows.',
   clock_timestamp(), clock_timestamp(), 1, 100, 100)
ON CONFLICT (tool_name) DO UPDATE
  SET version             = EXCLUDED.version,
      input_schema        = EXCLUDED.input_schema,
      output_schema       = EXCLUDED.output_schema,
      side_effect         = EXCLUDED.side_effect,
      ai_tier             = EXCLUDED.ai_tier,
      failure_semantics   = EXCLUDED.failure_semantics,
      dedup_key_generator_ref = EXCLUDED.dedup_key_generator_ref,
      description         = EXCLUDED.description,
      updated_at          = clock_timestamp(),
      retry_max_attempts  = EXCLUDED.retry_max_attempts,
      retry_backoff_base_ms = EXCLUDED.retry_backoff_base_ms,
      retry_backoff_max_ms  = EXCLUDED.retry_backoff_max_ms;


-- 2. Gate registry seeds ------------------------------------------------------

INSERT INTO public.gate_registry(gate_name, version, description, registered_at, updated_at) VALUES
  ('classification.entry_v1', '1.0.0',
   'Entry gate for CLASSIFY phase: every transaction in the run has classification_status IN (PENDING, NULL).',
   clock_timestamp(), clock_timestamp()),
  ('classification.exit_v1', '1.0.0',
   'Exit gate for CLASSIFY phase: every transaction has CONFIRMED|NEEDS_CONFIRMATION, every transaction_type non-null, every NEEDS_CONFIRMATION row has a review_issue.',
   clock_timestamp(), clock_timestamp())
ON CONFLICT (gate_name) DO UPDATE
  SET version     = EXCLUDED.version,
      description = EXCLUDED.description,
      updated_at  = clock_timestamp();


-- 3. workflow_phase_definitions ON CONFLICT update -----------------------------
-- Both rows already exist (CLASSIFY at order 7/6 for OUT/IN). We just align
-- description + is_shared_with_pair to make this migration idempotent on
-- environments where prior runs may have inconsistent values.

INSERT INTO public.workflow_phase_definitions(
  id, workflow_type, phase_order, phase_name, optional, description, created_at, is_shared_with_pair
) VALUES
  (public.gen_uuid_v7(), 'OUT_MONTHLY'::public.workflow_type_enum, 7, 'CLASSIFY', false,
   'Layer 1+2+3 classification, confidence merge, auto-confirm vs needs-confirmation. Shared coordination with IN_MONTHLY''s CLASSIFY phase per Block 03 Phase 10.',
   clock_timestamp(), true),
  (public.gen_uuid_v7(), 'IN_MONTHLY'::public.workflow_type_enum, 6, 'CLASSIFY', false,
   'Layer 1+2+3 classification, confidence merge, auto-confirm vs needs-confirmation. Shared coordination with OUT_MONTHLY''s CLASSIFY phase per Block 03 Phase 10.',
   clock_timestamp(), true)
ON CONFLICT (workflow_type, phase_name) DO UPDATE
  SET description         = EXCLUDED.description,
      optional            = EXCLUDED.optional,
      is_shared_with_pair = EXCLUDED.is_shared_with_pair;


-- 4. phase_tool_expectations — 6 tools × 2 workflows = 12 rows ----------------

WITH tools AS (
  SELECT t.tool_name, ARRAY[t.side_effect]::public.side_effect_class_enum[] AS permitted
    FROM public.tool_registry t
   WHERE t.tool_name LIKE 'classification.%'
), workflows AS (
  SELECT unnest(ARRAY['OUT_MONTHLY','IN_MONTHLY'])::public.workflow_type_enum AS wt
)
INSERT INTO public.phase_tool_expectations(id, workflow_type, phase_name, tool_name, permitted_side_effects, required, created_at)
SELECT public.gen_uuid_v7(), w.wt, 'CLASSIFY', t.tool_name, t.permitted, true, clock_timestamp()
  FROM tools t CROSS JOIN workflows w
ON CONFLICT (workflow_type, phase_name, tool_name) DO UPDATE
  SET permitted_side_effects = EXCLUDED.permitted_side_effects,
      required               = EXCLUDED.required;


-- 5. phase_gate_assignments — ENTRY + EXIT × 2 workflows = 4 rows -------------

INSERT INTO public.phase_gate_assignments(id, workflow_type, phase_name, gate_name, kind, eval_order, created_at) VALUES
  (public.gen_uuid_v7(), 'OUT_MONTHLY'::public.workflow_type_enum, 'CLASSIFY', 'classification.entry_v1', 'ENTRY'::public.gate_kind_enum, 1, clock_timestamp()),
  (public.gen_uuid_v7(), 'OUT_MONTHLY'::public.workflow_type_enum, 'CLASSIFY', 'classification.exit_v1',  'EXIT'::public.gate_kind_enum,  1, clock_timestamp()),
  (public.gen_uuid_v7(), 'IN_MONTHLY'::public.workflow_type_enum,  'CLASSIFY', 'classification.entry_v1', 'ENTRY'::public.gate_kind_enum, 1, clock_timestamp()),
  (public.gen_uuid_v7(), 'IN_MONTHLY'::public.workflow_type_enum,  'CLASSIFY', 'classification.exit_v1',  'EXIT'::public.gate_kind_enum,  1, clock_timestamp())
ON CONFLICT (workflow_type, phase_name, gate_name, kind) DO UPDATE
  SET eval_order = EXCLUDED.eval_order;


-- 6. Gate evaluation helpers --------------------------------------------------

CREATE OR REPLACE FUNCTION public.evaluate_classify_entry_gate(
  p_workflow_run_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_run        public.workflow_runs%ROWTYPE;
  v_total      int;
  v_non_pending int;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('passes', false, 'reason', 'WORKFLOW_RUN_NOT_FOUND');
  END IF;

  SELECT count(*) FILTER (WHERE TRUE),
         count(*) FILTER (WHERE classification_status NOT IN ('PENDING'::public.transaction_classification_status_enum)
                            AND classification_status IS NOT NULL)
    INTO v_total, v_non_pending
    FROM public.transactions
   WHERE statement_upload_id IN (SELECT id FROM public.statement_uploads WHERE business_id = v_run.business_id);

  IF v_non_pending > 0 THEN
    RETURN jsonb_build_object(
      'passes', false,
      'reason', 'NON_PENDING_TX_EXISTS',
      'total_count', v_total,
      'non_pending_count', v_non_pending
    );
  END IF;

  RETURN jsonb_build_object(
    'passes', true,
    'total_count', v_total
  );
END$fn$;

REVOKE ALL ON FUNCTION public.evaluate_classify_entry_gate(uuid) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.evaluate_classify_entry_gate(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.evaluate_classify_exit_gate(
  p_workflow_run_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_run                public.workflow_runs%ROWTYPE;
  v_total              int;
  v_unresolved         int;
  v_null_type          int;
  v_needs_conf         int;
  v_needs_conf_no_iss  int;
  v_status_counts      jsonb;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('passes', false, 'reason', 'WORKFLOW_RUN_NOT_FOUND');
  END IF;

  WITH tx AS (
    SELECT t.id, t.classification_status, t.transaction_type
      FROM public.transactions t
     WHERE t.statement_upload_id IN (SELECT id FROM public.statement_uploads WHERE business_id = v_run.business_id)
  )
  SELECT count(*) FILTER (WHERE TRUE),
         count(*) FILTER (WHERE classification_status NOT IN
                                ('CONFIRMED'::public.transaction_classification_status_enum,
                                 'NEEDS_CONFIRMATION'::public.transaction_classification_status_enum)
                            OR classification_status IS NULL),
         count(*) FILTER (WHERE transaction_type IS NULL),
         count(*) FILTER (WHERE classification_status = 'NEEDS_CONFIRMATION'::public.transaction_classification_status_enum)
    INTO v_total, v_unresolved, v_null_type, v_needs_conf
    FROM tx;

  -- Count NEEDS_CONFIRMATION rows that have NO review_issue referencing them
  SELECT count(*)
    INTO v_needs_conf_no_iss
    FROM public.transactions t
   WHERE t.statement_upload_id IN (SELECT id FROM public.statement_uploads WHERE business_id = v_run.business_id)
     AND t.classification_status = 'NEEDS_CONFIRMATION'::public.transaction_classification_status_enum
     AND NOT EXISTS (SELECT 1 FROM public.review_issues ri WHERE ri.transaction_id = t.id);

  SELECT jsonb_object_agg(coalesce(s::text, 'NULL'), c) INTO v_status_counts
    FROM (
      SELECT classification_status::text AS s, count(*) AS c
        FROM public.transactions
       WHERE statement_upload_id IN (SELECT id FROM public.statement_uploads WHERE business_id = v_run.business_id)
       GROUP BY classification_status
    ) z;

  IF v_unresolved > 0 THEN
    RETURN jsonb_build_object('passes', false, 'reason', 'UNRESOLVED_TX_EXISTS',
      'total_count', v_total, 'unresolved_count', v_unresolved, 'status_counts', v_status_counts);
  END IF;
  IF v_null_type > 0 THEN
    RETURN jsonb_build_object('passes', false, 'reason', 'NULL_TRANSACTION_TYPE',
      'total_count', v_total, 'null_type_count', v_null_type, 'status_counts', v_status_counts);
  END IF;
  IF v_needs_conf_no_iss > 0 THEN
    RETURN jsonb_build_object('passes', false, 'reason', 'NEEDS_CONFIRMATION_MISSING_REVIEW_ISSUE',
      'total_count', v_total, 'missing_review_issues_count', v_needs_conf_no_iss, 'status_counts', v_status_counts);
  END IF;

  RETURN jsonb_build_object(
    'passes', true,
    'total_count', v_total,
    'needs_confirmation_count', v_needs_conf,
    'status_counts', v_status_counts
  );
END$fn$;

REVOKE ALL ON FUNCTION public.evaluate_classify_exit_gate(uuid) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.evaluate_classify_exit_gate(uuid) TO service_role;


-- 7. Phase-boundary audit RPCs -----------------------------------------------

CREATE OR REPLACE FUNCTION public.record_classify_phase_started(
  p_workflow_run_id uuid,
  p_user_id         uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_run       public.workflow_runs%ROWTYPE;
  v_audit_row audit.audit_events%ROWTYPE;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'WORKFLOW_RUN_NOT_FOUND');
  END IF;

  v_audit_row := audit.emit_audit(
    p_actor_kind      => 'USER'::audit.actor_kind_enum,
    p_action          => 'CLASSIFY_PHASE_STARTED',
    p_subject_type    => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id      => v_run.id,
    p_actor_user_id   => p_user_id,
    p_organization_id => v_run.organization_id,
    p_business_id     => v_run.business_id,
    p_after_state     => jsonb_build_object('phase_name', 'CLASSIFY', 'workflow_type', v_run.workflow_type::text),
    p_reason          => format('CLASSIFY phase started for run %s', v_run.id)
  );

  RETURN jsonb_build_object('ok', true, 'audit_event_id', v_audit_row.id);
END$fn$;

REVOKE ALL ON FUNCTION public.record_classify_phase_started(uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.record_classify_phase_started(uuid, uuid) TO service_role;


CREATE OR REPLACE FUNCTION public.record_classify_phase_completed(
  p_workflow_run_id   uuid,
  p_user_id           uuid,
  p_per_status_counts jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_run       public.workflow_runs%ROWTYPE;
  v_audit_row audit.audit_events%ROWTYPE;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'WORKFLOW_RUN_NOT_FOUND');
  END IF;
  IF p_per_status_counts IS NULL OR jsonb_typeof(p_per_status_counts) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'PER_STATUS_COUNTS_MUST_BE_OBJECT');
  END IF;

  v_audit_row := audit.emit_audit(
    p_actor_kind      => 'USER'::audit.actor_kind_enum,
    p_action          => 'CLASSIFY_PHASE_COMPLETED',
    p_subject_type    => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id      => v_run.id,
    p_actor_user_id   => p_user_id,
    p_organization_id => v_run.organization_id,
    p_business_id     => v_run.business_id,
    p_after_state     => jsonb_build_object(
                           'phase_name',         'CLASSIFY',
                           'workflow_type',      v_run.workflow_type::text,
                           'per_status_counts',  p_per_status_counts
                         ),
    p_reason          => format('CLASSIFY phase completed for run %s', v_run.id)
  );

  RETURN jsonb_build_object('ok', true, 'audit_event_id', v_audit_row.id);
END$fn$;

REVOKE ALL ON FUNCTION public.record_classify_phase_completed(uuid, uuid, jsonb) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.record_classify_phase_completed(uuid, uuid, jsonb) TO service_role;


CREATE OR REPLACE FUNCTION public.record_classify_phase_holding(
  p_workflow_run_id    uuid,
  p_user_id            uuid,
  p_hold_reason        text,
  p_failing_gate_check jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_run       public.workflow_runs%ROWTYPE;
  v_audit_row audit.audit_events%ROWTYPE;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'WORKFLOW_RUN_NOT_FOUND');
  END IF;
  IF p_hold_reason IS NULL OR length(trim(p_hold_reason)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'HOLD_REASON_REQUIRED');
  END IF;

  v_audit_row := audit.emit_audit(
    p_actor_kind      => 'USER'::audit.actor_kind_enum,
    p_action          => 'CLASSIFY_PHASE_HOLDING',
    p_subject_type    => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id      => v_run.id,
    p_actor_user_id   => p_user_id,
    p_organization_id => v_run.organization_id,
    p_business_id     => v_run.business_id,
    p_after_state     => jsonb_build_object(
                           'phase_name',          'CLASSIFY',
                           'workflow_type',       v_run.workflow_type::text,
                           'hold_reason',         p_hold_reason,
                           'failing_gate_check',  p_failing_gate_check
                         ),
    p_reason          => format('CLASSIFY phase HOLDING for run %s: %s', v_run.id, p_hold_reason)
  );

  RETURN jsonb_build_object('ok', true, 'audit_event_id', v_audit_row.id);
END$fn$;

REVOKE ALL ON FUNCTION public.record_classify_phase_holding(uuid, uuid, text, jsonb) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.record_classify_phase_holding(uuid, uuid, text, jsonb) TO service_role;
