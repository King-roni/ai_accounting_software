-- B09·P09 — EVIDENCE_DISCOVERY Workflow Phase Registration.
-- Wires the email finder, Drive finder, manual-upload handler, OCR +
-- extraction pipeline, and cross-source dedup into the workflow engine as
-- the EVIDENCE_DISCOVERY_GMAIL and EVIDENCE_DISCOVERY_DRIVE phases of
-- OUT_MONTHLY. (Spec names the email phase EVIDENCE_DISCOVERY_EMAIL, but
-- workflow_phase_definitions already uses EVIDENCE_DISCOVERY_GMAIL — we
-- align with the existing DB name; rename is a Stage-4 alignment task.)
--
-- Audit family additions:
--   EVIDENCE_DISCOVERY_PHASE_STARTED   (WORKFLOW_RUN subject)
--   EVIDENCE_DISCOVERY_PHASE_COMPLETED (WORKFLOW_RUN subject)
--   EVIDENCE_DISCOVERY_PHASE_HOLDING   (WORKFLOW_RUN subject)

-- 1. Tool seeds --------------------------------------------------------------

SELECT public.register_tool(
  p_tool_name              => 'intake.email_finder',
  p_version                => '1.0.0',
  p_input_schema           => jsonb_build_object(
    'workflow_run_id','uuid','transaction_ids','uuid[]'
  ),
  p_output_schema          => jsonb_build_object(
    'finder_runs','uuid[]','found_count','int','duplicate_count','int'
  ),
  p_side_effect            => 'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier                => 'NONE'::ai_tier_enum,
  p_failure_semantics      => 'RETRYABLE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=> 'email_finder.dedup_key_v1',
  p_description            => 'Runs Phase 05 Gmail search per OUT_EXPENSE transaction; writes documents + dsl rows on novel candidates',
  p_retry_max_attempts     => 3,
  p_retry_backoff_base_ms  => 1000,
  p_retry_backoff_max_ms   => 10000
);

SELECT public.register_tool(
  p_tool_name              => 'intake.drive_finder',
  p_version                => '1.0.0',
  p_input_schema           => jsonb_build_object(
    'workflow_run_id','uuid','transaction_ids','uuid[]'
  ),
  p_output_schema          => jsonb_build_object(
    'finder_runs','uuid[]','found_count','int','duplicate_count','int'
  ),
  p_side_effect            => 'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier                => 'NONE'::ai_tier_enum,
  p_failure_semantics      => 'RETRYABLE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=> 'drive_finder.dedup_key_v1',
  p_description            => 'Runs Phase 06 Drive search per OUT_EXPENSE transaction; writes documents + dsl rows on novel candidates',
  p_retry_max_attempts     => 3,
  p_retry_backoff_base_ms  => 1000,
  p_retry_backoff_max_ms   => 10000
);

SELECT public.register_tool(
  p_tool_name              => 'intake.cross_source_dedupe',
  p_version                => '1.0.0',
  p_input_schema           => jsonb_build_object(
    'document_id','uuid','document_hash','text(64-hex)'
  ),
  p_output_schema          => jsonb_build_object(
    'decision','text','canonical_document_id','uuid','boost_applied','bool'
  ),
  p_side_effect            => 'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier                => 'NONE'::ai_tier_enum,
  p_failure_semantics      => 'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=> 'cross_source_dedupe.dedup_key_v1',
  p_description            => 'Phase 08 chokepoint: collapses content-identical discoveries; boosts confidence on second source',
  p_retry_max_attempts     => 1,
  p_retry_backoff_base_ms  => 100,
  p_retry_backoff_max_ms   => 100
);

SELECT public.register_tool(
  p_tool_name              => 'intake.ocr_and_extract',
  p_version                => '1.0.0',
  p_input_schema           => jsonb_build_object('document_id','uuid','processor_id','text'),
  p_output_schema          => jsonb_build_object(
    'ocr_run_id','uuid','winning_layer','document_extraction_layer_enum','field_count','int'
  ),
  p_side_effect            => 'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier                => 'EXTERNAL_LLM'::ai_tier_enum,
  p_failure_semantics      => 'RETRYABLE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=> 'ocr_and_extract.dedup_key_v1',
  p_description            => 'Runs Phase 03 OCR + Phase 04 field extraction; declares EXTERNAL_LLM as the max tier in the chain (Document AI Tier 3 + Tier 3 escalation)',
  p_retry_max_attempts     => 3,
  p_retry_backoff_base_ms  => 1000,
  p_retry_backoff_max_ms   => 10000
);

SELECT public.register_tool(
  p_tool_name              => 'intake.manual_upload_handler',
  p_version                => '1.0.0',
  p_input_schema           => jsonb_build_object('upload_id','uuid'),
  p_output_schema          => jsonb_build_object('document_id','uuid','ocr_kicked_off','bool'),
  p_side_effect            => 'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier                => 'NONE'::ai_tier_enum,
  p_failure_semantics      => 'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=> 'manual_upload_handler.dedup_key_v1',
  p_description            => 'Post-confirm step of manual upload (Phase 07): hashes, runs cross-source dedup, kicks off OCR + extraction. AI tier NONE here; downstream intake.ocr_and_extract carries the EXTERNAL_LLM declaration',
  p_retry_max_attempts     => 1,
  p_retry_backoff_base_ms  => 100,
  p_retry_backoff_max_ms   => 100
);


-- 2. Gate seeds --------------------------------------------------------------

SELECT public.register_gate(
  p_gate_name   => 'intake.evidence_discovery_email_entry_v1',
  p_version     => '1.0.0',
  p_description => 'Entry: classification phase done; at least one OUT_EXPENSE transaction in the run period'
);
SELECT public.register_gate(
  p_gate_name   => 'intake.evidence_discovery_email_exit_v1',
  p_version     => '1.0.0',
  p_description => 'Exit: every OUT_EXPENSE transaction has had email_finder run to COMPLETED'
);
SELECT public.register_gate(
  p_gate_name   => 'intake.evidence_discovery_drive_entry_v1',
  p_version     => '1.0.0',
  p_description => 'Entry: EVIDENCE_DISCOVERY_GMAIL phase done; at least one OUT_EXPENSE transaction'
);
SELECT public.register_gate(
  p_gate_name   => 'intake.evidence_discovery_drive_exit_v1',
  p_version     => '1.0.0',
  p_description => 'Exit: every OUT_EXPENSE transaction has had drive_finder run to COMPLETED'
);


-- 3. phase_tool_expectations (OUT_MONTHLY only; IN_MONTHLY skipped per spec) --

INSERT INTO public.phase_tool_expectations
  (workflow_type, phase_name, tool_name, permitted_side_effects, required)
VALUES
  ('OUT_MONTHLY', 'EVIDENCE_DISCOVERY_GMAIL', 'intake.email_finder',
    ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('OUT_MONTHLY', 'EVIDENCE_DISCOVERY_GMAIL', 'intake.cross_source_dedupe',
    ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('OUT_MONTHLY', 'EVIDENCE_DISCOVERY_GMAIL', 'intake.ocr_and_extract',
    ARRAY['WRITES_RUN_STATE','CALLS_EXTERNAL_API']::public.side_effect_class_enum[], true),
  ('OUT_MONTHLY', 'EVIDENCE_DISCOVERY_DRIVE', 'intake.drive_finder',
    ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('OUT_MONTHLY', 'EVIDENCE_DISCOVERY_DRIVE', 'intake.cross_source_dedupe',
    ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true),
  ('OUT_MONTHLY', 'EVIDENCE_DISCOVERY_DRIVE', 'intake.ocr_and_extract',
    ARRAY['WRITES_RUN_STATE','CALLS_EXTERNAL_API']::public.side_effect_class_enum[], true)
ON CONFLICT DO NOTHING;


-- 4. phase_gate_assignments --------------------------------------------------

INSERT INTO public.phase_gate_assignments
  (workflow_type, phase_name, gate_name, kind, eval_order)
VALUES
  ('OUT_MONTHLY', 'EVIDENCE_DISCOVERY_GMAIL', 'intake.evidence_discovery_email_entry_v1', 'ENTRY', 1),
  ('OUT_MONTHLY', 'EVIDENCE_DISCOVERY_GMAIL', 'intake.evidence_discovery_email_exit_v1',  'EXIT',  1),
  ('OUT_MONTHLY', 'EVIDENCE_DISCOVERY_DRIVE', 'intake.evidence_discovery_drive_entry_v1', 'ENTRY', 1),
  ('OUT_MONTHLY', 'EVIDENCE_DISCOVERY_DRIVE', 'intake.evidence_discovery_drive_exit_v1',  'EXIT',  1)
ON CONFLICT DO NOTHING;


-- 5. STABLE evaluators -------------------------------------------------------

CREATE OR REPLACE FUNCTION public.evaluate_evidence_discovery_email_entry_gate(
  p_workflow_run_id uuid
)
RETURNS jsonb LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_business_id    uuid;
  v_period_start   timestamptz;
  v_period_end     timestamptz;
  v_out_expense_n  int;
BEGIN
  SELECT business_id, period_start, period_end
    INTO v_business_id, v_period_start, v_period_end
  FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('satisfied', false, 'reason', 'WORKFLOW_RUN_NOT_FOUND');
  END IF;

  SELECT count(*) INTO v_out_expense_n
  FROM public.transactions
  WHERE business_id = v_business_id
    AND transaction_type = 'OUT_EXPENSE'
    AND transaction_date >= v_period_start::date
    AND transaction_date <= v_period_end::date;

  IF v_out_expense_n = 0 THEN
    RETURN jsonb_build_object(
      'satisfied', false, 'reason', 'NO_OUT_EXPENSE_TRANSACTIONS',
      'out_expense_count', 0
    );
  END IF;

  RETURN jsonb_build_object(
    'satisfied', true, 'reason', 'READY',
    'out_expense_count', v_out_expense_n
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.evaluate_evidence_discovery_email_exit_gate(
  p_workflow_run_id uuid
)
RETURNS jsonb LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_business_id    uuid;
  v_period_start   timestamptz;
  v_period_end     timestamptz;
  v_out_expense_n  int;
  v_searched_n     int;
BEGIN
  SELECT business_id, period_start, period_end
    INTO v_business_id, v_period_start, v_period_end
  FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('satisfied', false, 'reason', 'WORKFLOW_RUN_NOT_FOUND');
  END IF;

  SELECT count(*) INTO v_out_expense_n
  FROM public.transactions
  WHERE business_id = v_business_id
    AND transaction_type = 'OUT_EXPENSE'
    AND transaction_date >= v_period_start::date
    AND transaction_date <= v_period_end::date;

  SELECT count(DISTINCT transaction_id) INTO v_searched_n
  FROM public.email_finder_runs efr
  WHERE efr.business_id = v_business_id
    AND efr.status = 'COMPLETED'
    AND efr.transaction_id IN (
      SELECT id FROM public.transactions
      WHERE business_id = v_business_id
        AND transaction_type = 'OUT_EXPENSE'
        AND transaction_date >= v_period_start::date
        AND transaction_date <= v_period_end::date
    );

  RETURN jsonb_build_object(
    'satisfied',         (v_searched_n >= v_out_expense_n AND v_out_expense_n > 0),
    'reason',            CASE WHEN v_searched_n >= v_out_expense_n THEN 'ALL_SEARCHED'
                              ELSE 'INCOMPLETE_COVERAGE' END,
    'out_expense_count', v_out_expense_n,
    'searched_count',    v_searched_n
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.evaluate_evidence_discovery_drive_entry_gate(
  p_workflow_run_id uuid
)
RETURNS jsonb LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email_exit jsonb;
BEGIN
  v_email_exit := public.evaluate_evidence_discovery_email_exit_gate(p_workflow_run_id);
  IF NOT COALESCE((v_email_exit->>'satisfied')::boolean, false) THEN
    RETURN jsonb_build_object(
      'satisfied', false, 'reason', 'EMAIL_PHASE_INCOMPLETE',
      'email_exit_envelope', v_email_exit
    );
  END IF;
  RETURN jsonb_build_object(
    'satisfied', true, 'reason', 'READY',
    'email_exit_envelope', v_email_exit
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.evaluate_evidence_discovery_drive_exit_gate(
  p_workflow_run_id uuid
)
RETURNS jsonb LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_business_id    uuid;
  v_period_start   timestamptz;
  v_period_end     timestamptz;
  v_out_expense_n  int;
  v_searched_n     int;
BEGIN
  SELECT business_id, period_start, period_end
    INTO v_business_id, v_period_start, v_period_end
  FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('satisfied', false, 'reason', 'WORKFLOW_RUN_NOT_FOUND');
  END IF;

  SELECT count(*) INTO v_out_expense_n
  FROM public.transactions
  WHERE business_id = v_business_id
    AND transaction_type = 'OUT_EXPENSE'
    AND transaction_date >= v_period_start::date
    AND transaction_date <= v_period_end::date;

  SELECT count(DISTINCT transaction_id) INTO v_searched_n
  FROM public.drive_finder_runs dfr
  WHERE dfr.business_id = v_business_id
    AND dfr.status = 'COMPLETED'
    AND dfr.transaction_id IN (
      SELECT id FROM public.transactions
      WHERE business_id = v_business_id
        AND transaction_type = 'OUT_EXPENSE'
        AND transaction_date >= v_period_start::date
        AND transaction_date <= v_period_end::date
    );

  RETURN jsonb_build_object(
    'satisfied',         (v_searched_n >= v_out_expense_n AND v_out_expense_n > 0),
    'reason',            CASE WHEN v_searched_n >= v_out_expense_n THEN 'ALL_SEARCHED'
                              ELSE 'INCOMPLETE_COVERAGE' END,
    'out_expense_count', v_out_expense_n,
    'searched_count',    v_searched_n
  );
END;
$$;


-- 6. Phase-boundary audit RPCs -----------------------------------------------

CREATE OR REPLACE FUNCTION public.record_evidence_discovery_phase_started(
  p_workflow_run_id uuid,
  p_phase_name      text,
  p_context         jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_organization_id uuid; v_business_id uuid;
BEGIN
  SELECT organization_id, business_id INTO v_organization_id, v_business_id
  FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','WORKFLOW_RUN_NOT_FOUND','workflow_run_id',p_workflow_run_id);
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='EVIDENCE_DISCOVERY_PHASE_STARTED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=p_workflow_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='evidence_discovery',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('phase_name', p_phase_name),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','RECORDED','workflow_run_id',p_workflow_run_id,'phase_name',p_phase_name
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.record_evidence_discovery_phase_completed(
  p_workflow_run_id        uuid,
  p_phase_name             text,
  p_discovered_count       int,
  p_collapsed_count        int,
  p_extraction_failed_count int,
  p_context                jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_organization_id uuid; v_business_id uuid;
BEGIN
  IF p_discovered_count < 0 OR p_collapsed_count < 0 OR p_extraction_failed_count < 0 THEN
    RAISE EXCEPTION 'COUNTS_MUST_BE_NONNEGATIVE' USING errcode='check_violation';
  END IF;

  SELECT organization_id, business_id INTO v_organization_id, v_business_id
  FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','WORKFLOW_RUN_NOT_FOUND','workflow_run_id',p_workflow_run_id);
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='EVIDENCE_DISCOVERY_PHASE_COMPLETED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=p_workflow_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='evidence_discovery',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'phase_name', p_phase_name,
      'discovered_count', p_discovered_count,
      'collapsed_count',  p_collapsed_count,
      'extraction_failed_count', p_extraction_failed_count
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','RECORDED','workflow_run_id',p_workflow_run_id,
    'phase_name',p_phase_name,
    'discovered_count',p_discovered_count,
    'collapsed_count',p_collapsed_count,
    'extraction_failed_count',p_extraction_failed_count
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.record_evidence_discovery_phase_holding(
  p_workflow_run_id uuid,
  p_phase_name      text,
  p_reason          text,
  p_review_issue_id uuid    DEFAULT NULL,
  p_context         jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_organization_id uuid; v_business_id uuid;
BEGIN
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'REASON_REQUIRED' USING errcode='check_violation';
  END IF;
  SELECT organization_id, business_id INTO v_organization_id, v_business_id
  FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','WORKFLOW_RUN_NOT_FOUND','workflow_run_id',p_workflow_run_id);
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='EVIDENCE_DISCOVERY_PHASE_HOLDING',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=p_workflow_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='evidence_discovery',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'phase_name', p_phase_name,
      'review_issue_id', p_review_issue_id,
      'hold_reason', p_reason
    ),
    p_reason:=p_reason, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','RECORDED','workflow_run_id',p_workflow_run_id,
    'phase_name',p_phase_name,'review_issue_id',p_review_issue_id
  );
END;
$$;


-- 7. Privilege grants --------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.record_evidence_discovery_phase_started(uuid, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_evidence_discovery_phase_completed(uuid, text, int, int, int, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_evidence_discovery_phase_holding(uuid, text, text, uuid, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.record_evidence_discovery_phase_started(uuid, text, jsonb) TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.record_evidence_discovery_phase_completed(uuid, text, int, int, int, jsonb) TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.record_evidence_discovery_phase_holding(uuid, text, text, uuid, jsonb) TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.evaluate_evidence_discovery_email_entry_gate(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.evaluate_evidence_discovery_email_exit_gate(uuid)  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.evaluate_evidence_discovery_drive_entry_gate(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.evaluate_evidence_discovery_drive_exit_gate(uuid)  TO authenticated, service_role;
