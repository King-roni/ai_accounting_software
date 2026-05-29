-- ============================================================================
-- Block 13 Phase 11 (BOOK-126) — IN_ADJUSTMENT Workflow Type
-- Conditional CHECK trigger on adjustment_records.delta_kind + 2 RPCs +
-- v_invoices_with_adjustments view + tool_registry/phase_tool_expectations.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_check_adjustment_delta_kind_vs_parent_workflow()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $function$
DECLARE v_parent_workflow_type public.workflow_type_enum;
BEGIN
  SELECT workflow_type INTO v_parent_workflow_type
    FROM public.workflow_runs WHERE id = NEW.parent_run_id;
  IF v_parent_workflow_type IS NULL THEN
    RAISE EXCEPTION 'adjustment_records.parent_run_id refers to a missing workflow_runs row: %', NEW.parent_run_id
      USING ERRCODE='23503';
  END IF;
  IF v_parent_workflow_type = 'IN_MONTHLY' AND NEW.delta_kind IN ('ADD_EVIDENCE','ADJUST_AMOUNT') THEN
    RAISE EXCEPTION 'delta_kind % is OUT_MONTHLY-only; parent run is IN_MONTHLY (parent_run_id=%)',
      NEW.delta_kind, NEW.parent_run_id USING ERRCODE='23514';
  END IF;
  IF v_parent_workflow_type = 'OUT_MONTHLY' AND NEW.delta_kind IN
     ('RETROACTIVE_CREDIT_NOTE','CORRECT_PAYMENT_ALLOCATION','MARK_INVOICE_WRITTEN_OFF') THEN
    RAISE EXCEPTION 'delta_kind % is IN_MONTHLY-only; parent run is OUT_MONTHLY (parent_run_id=%)',
      NEW.delta_kind, NEW.parent_run_id USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_check_adjustment_delta_kind_vs_parent_workflow
  BEFORE INSERT OR UPDATE OF delta_kind, parent_run_id ON public.adjustment_records
  FOR EACH ROW EXECUTE FUNCTION public.fn_check_adjustment_delta_kind_vs_parent_workflow();

CREATE OR REPLACE FUNCTION public.register_in_adjustment_type(
  p_actor_system text DEFAULT 'engine_bootstrap',
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE v_count int; v_emitted boolean;
BEGIN
  SELECT count(*) INTO v_count FROM public.workflow_phase_definitions WHERE workflow_type='IN_ADJUSTMENT';
  IF v_count <> 5 THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','PHASE_SHAPE_INVALID','expected', 5, 'actual', v_count);
  END IF;
  SELECT EXISTS (SELECT 1 FROM audit.audit_events WHERE action='IN_ADJUSTMENT_TYPE_REGISTERED' LIMIT 1)
    INTO v_emitted;
  IF v_emitted THEN
    RETURN jsonb_build_object('decision','ALLOW','idempotent', true, 'phase_count', v_count);
  END IF;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='IN_ADJUSTMENT_TYPE_REGISTERED',
    p_subject_type:='WORKFLOW_CONFIG'::audit.subject_type_enum, p_subject_id:=gen_uuid_v7(),
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
    p_organization_id:=NULL, p_business_id:=NULL,
    p_before_state:=NULL, p_after_state:=jsonb_build_object('workflow_type','IN_ADJUSTMENT','phase_count', v_count),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','ALLOW','idempotent', false, 'phase_count', v_count);
END;
$function$;

CREATE OR REPLACE FUNCTION public.in_workflow_adjustment_intake(
  p_actor_user_id  uuid,
  p_organization_id uuid,
  p_business_id     uuid,
  p_parent_run_id   uuid,
  p_reason          text,
  p_delta_kind      public.adjustment_delta_kind_enum,
  p_delta_payload   jsonb,
  p_context         jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_decision jsonb;
  v_parent public.workflow_runs%ROWTYPE;
  v_run_id uuid := gen_uuid_v7();
  v_adj_id uuid := gen_uuid_v7();
BEGIN
  v_decision := public.can_perform(p_actor_user_id,'WORKFLOW_TRIGGER','ADJUSTMENT_INTAKE',
    jsonb_build_object('parent_run_id', p_parent_run_id),
    p_business_id, p_organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision',
      'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;

  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','REASON_REQUIRED');
  END IF;
  IF p_delta_payload IS NULL OR jsonb_typeof(p_delta_payload) <> 'object' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','DELTA_PAYLOAD_REQUIRED');
  END IF;

  SELECT * INTO v_parent FROM public.workflow_runs WHERE id = p_parent_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','PARENT_RUN_NOT_FOUND');
  END IF;
  IF v_parent.workflow_type <> 'IN_MONTHLY' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','NOT_IN_MONTHLY_PARENT',
      'parent_workflow_type', v_parent.workflow_type::text);
  END IF;
  IF v_parent.status <> 'FINALIZED' THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='IN_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED',
      p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_parent_run_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state :=jsonb_build_object('parent_run_id', p_parent_run_id, 'parent_status', v_parent.status::text),
      p_reason:='PARENT_NOT_FINALIZED', p_request_context:=p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','PARENT_NOT_FINALIZED');
  END IF;
  IF v_parent.period_start::date < (CURRENT_DATE - INTERVAL '6 years') THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='IN_ADJUSTMENT_REJECTED_RETENTION_EXPIRED',
      p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_parent_run_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state :=jsonb_build_object('parent_run_id', p_parent_run_id,
                                          'parent_period_start', v_parent.period_start),
      p_reason:='RETENTION_EXPIRED', p_request_context:=p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','RETENTION_EXPIRED');
  END IF;

  INSERT INTO public.workflow_runs (
    id, organization_id, business_id, workflow_type, parent_run_id,
    principal_snapshot, status, trigger_kind,
    period_start, period_end,
    triggered_by_user_id, manual_trigger_note
  ) VALUES (
    v_run_id, p_organization_id, p_business_id, 'IN_ADJUSTMENT', p_parent_run_id,
    jsonb_build_object('actor_user_id', p_actor_user_id::text, 'trigger_kind','MANUAL', 'delta_kind', p_delta_kind::text),
    'CREATED', 'MANUAL',
    v_parent.period_start, v_parent.period_end,
    p_actor_user_id, p_reason
  );

  INSERT INTO public.adjustment_records (
    id, organization_id, business_id, run_id, parent_run_id,
    parent_period_start, parent_period_end,
    reason, delta_kind, delta_payload, requesting_user_id
  ) VALUES (
    v_adj_id, p_organization_id, p_business_id, v_run_id, p_parent_run_id,
    v_parent.period_start::date, v_parent.period_end::date,
    p_reason, p_delta_kind, p_delta_payload, p_actor_user_id
  );

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='IN_ADJUSTMENT_RUN_CREATED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=v_run_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state :=jsonb_build_object(
      'adjustment_run_id', v_run_id,
      'parent_run_id', p_parent_run_id,
      'period_start', v_parent.period_start, 'period_end', v_parent.period_end,
      'delta_kind', p_delta_kind::text),
    p_reason:=p_reason, p_request_context:=p_context);
  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='IN_ADJUSTMENT_INTAKE_COMPLETED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=v_run_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state :=jsonb_build_object(
      'adjustment_record_id', v_adj_id, 'delta_kind', p_delta_kind::text,
      'delta_payload', p_delta_payload),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'decision','ALLOW',
    'adjustment_run_id', v_run_id,
    'adjustment_record_id', v_adj_id,
    'delta_kind', p_delta_kind::text,
    'parent_period', jsonb_build_object('start', v_parent.period_start, 'end', v_parent.period_end));
END;
$function$;

CREATE OR REPLACE VIEW public.v_invoices_with_adjustments AS
SELECT
  i.*,
  CASE
    WHEN ar.delta_kind = 'MARK_INVOICE_WRITTEN_OFF' THEN 'WRITTEN_OFF'
    ELSE i.lifecycle_status::text
  END AS adjusted_lifecycle_status,
  ar.run_id AS adjustment_run_id,
  ar.created_at AS adjusted_at
FROM public.invoices i
LEFT JOIN LATERAL (
  SELECT ar2.run_id, ar2.delta_kind, ar2.created_at
    FROM public.adjustment_records ar2
    JOIN public.workflow_runs wr ON wr.id = ar2.run_id
   WHERE wr.workflow_type = 'IN_ADJUSTMENT'
     AND wr.status = 'FINALIZED'
     AND ar2.delta_kind = 'MARK_INVOICE_WRITTEN_OFF'
     AND (ar2.delta_payload->>'invoice_id')::uuid = i.id
   ORDER BY ar2.created_at DESC
   LIMIT 1
) ar ON true;

COMMENT ON VIEW public.v_invoices_with_adjustments IS
  'Block 13 P11 — read-only adjustment-overlay view. Base invoices.* + adjusted_lifecycle_status overlay (MARK_INVOICE_WRITTEN_OFF only Stage 1). Block 16 dashboards read here for "adjusted period view"; "as-finalized" reads public.invoices directly.';

INSERT INTO public.tool_registry (
  tool_name, version, input_schema, output_schema,
  side_effect, ai_tier, failure_semantics, dedup_key_generator_ref,
  description, retry_max_attempts, retry_backoff_base_ms, retry_backoff_max_ms
) VALUES (
  'in_workflow.adjustment_intake', '1.0.0',
  '{"actor_user_id":"uuid","organization_id":"uuid","business_id":"uuid","parent_run_id":"uuid","reason":"text","delta_kind":"adjustment_delta_kind_enum","delta_payload":"jsonb"}'::jsonb,
  '{"decision":"text","adjustment_run_id":"uuid","adjustment_record_id":"uuid","delta_kind":"text"}'::jsonb,
  'WRITES_RUN_STATE'::public.side_effect_class_enum,
  'NONE'::public.ai_tier_enum,
  'IDEMPOTENT_AT_MOST_ONCE'::public.tool_failure_semantics_enum,
  'in_workflow.adjustment_intake.dedup_key_v1',
  'Block 13 P11 — IN_ADJUSTMENT intake. Creates a child workflow_run + adjustment_records row tied to a finalized IN_MONTHLY parent run.',
  1, 100, 100
)
ON CONFLICT (tool_name) DO NOTHING;

INSERT INTO public.phase_tool_expectations (workflow_type, phase_name, tool_name, permitted_side_effects, required)
VALUES ('IN_ADJUSTMENT', 'ADJUSTMENT_INTAKE', 'in_workflow.adjustment_intake',
        ARRAY['WRITES_RUN_STATE']::public.side_effect_class_enum[], true);
