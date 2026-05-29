-- B12·P06 — MANUAL_UPLOAD_HOLD Phase
-- =====================================================================
-- Side-phase wiring for MANUAL_UPLOAD_HOLD: schema for documented exceptions,
-- a per-run reminder log, and 5 RPCs covering entry/upload/exception/reminder/clear.
--
-- Spec mapping: spec uses transactions.effective_match_status; in DB-reality
-- that column is the existing transactions.match_status enum (already includes
-- EXCEPTION_DOCUMENTED). The exception flow writes to transactions.match_status.
--
-- Stage 1 contract: no auto-fail / no auto-finalize / indefinite hold; reminders
-- are entry-anchored (within-phase activity does NOT reset the cadence; re-entry
-- after a clean clear DOES reset).
--
-- 6 audit actions:
--   OUT_MANUAL_UPLOAD_HOLD_ENTERED
--   OUT_MANUAL_UPLOAD_INVOICE_UPLOADED
--   OUT_MANUAL_UPLOAD_EXCEPTION_DOCUMENTED
--   OUT_MANUAL_UPLOAD_REMINDER_SENT
--   OUT_MANUAL_UPLOAD_HOLD_CLEARED
--   OUT_MANUAL_UPLOAD_HOLD_RE_ENTERED
-- =====================================================================

BEGIN;

-- 1. transactions exception columns
ALTER TABLE public.transactions
  ADD COLUMN exception_reason        text,
  ADD COLUMN exception_documented_by uuid REFERENCES public.users(id),
  ADD COLUMN exception_documented_at timestamptz;

ALTER TABLE public.transactions
  ADD CONSTRAINT transactions_exception_documented_chk
  CHECK (
    match_status <> 'EXCEPTION_DOCUMENTED'
    OR (exception_reason IS NOT NULL AND length(btrim(exception_reason)) > 0
        AND exception_documented_by IS NOT NULL
        AND exception_documented_at IS NOT NULL)
  );

COMMENT ON COLUMN public.transactions.exception_reason IS
  'Mandatory free-text reason supplied by the user when documenting an exception via out_workflow.document_exception (B12·P06).';
COMMENT ON COLUMN public.transactions.exception_documented_by IS
  'User who documented the matching exception. Always set together with exception_reason + exception_documented_at when match_status=EXCEPTION_DOCUMENTED.';


-- 2. Per-run reminder log
CREATE TABLE public.out_workflow_reminders (
  id                uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id   uuid NOT NULL REFERENCES public.organizations(id),
  business_id       uuid NOT NULL REFERENCES public.business_entities(id),
  workflow_run_id   uuid NOT NULL REFERENCES public.workflow_runs(id),
  ordinal           int  NOT NULL CHECK (ordinal >= 1),
  sent_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
  reminder_payload  jsonb NOT NULL DEFAULT '{}'::jsonb,
  UNIQUE (workflow_run_id, ordinal)
);
CREATE INDEX out_workflow_reminders_run_sent_idx
  ON public.out_workflow_reminders (workflow_run_id, sent_at DESC);

COMMENT ON TABLE public.out_workflow_reminders IS
  'Per-run reminder log for MANUAL_UPLOAD_HOLD (B12·P06). One row per fired reminder. ordinal is monotonically increasing per run; resets only on re-entry (DELETEd by out_workflow_enter_manual_upload_hold).';


-- 3. Enter / re-enter the hold (records timestamp + emits the right audit)
CREATE OR REPLACE FUNCTION public.out_workflow_enter_manual_upload_hold(
  p_organization_id uuid, p_business_id uuid, p_run_id uuid,
  p_actor_user_id uuid DEFAULT NULL, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_prior_cleared timestamptz;
  v_action text;
  v_now timestamptz := clock_timestamp();
BEGIN
  SELECT (summary_json->'manual_upload_hold'->>'cleared_at')::timestamptz
    INTO v_prior_cleared
    FROM public.workflow_runs WHERE id=p_run_id;

  IF v_prior_cleared IS NOT NULL THEN
    DELETE FROM public.out_workflow_reminders WHERE workflow_run_id=p_run_id;
    v_action := 'OUT_MANUAL_UPLOAD_HOLD_RE_ENTERED';
  ELSE
    v_action := 'OUT_MANUAL_UPLOAD_HOLD_ENTERED';
  END IF;

  UPDATE public.workflow_runs
     SET summary_json = jsonb_set(
           COALESCE(summary_json, '{}'::jsonb),
           '{manual_upload_hold}',
           jsonb_build_object('entered_at', v_now, 'cleared_at', NULL),
           true)
   WHERE id = p_run_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:=v_action,
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=p_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_workflow_manual_upload_hold',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=CASE WHEN v_prior_cleared IS NOT NULL
                         THEN jsonb_build_object('prior_cleared_at', v_prior_cleared)
                         ELSE NULL END,
    p_after_state:=jsonb_build_object('entered_at', v_now, 'initiating_user_id', p_actor_user_id),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','ENTERED','action', v_action, 'entered_at', v_now);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.out_workflow_enter_manual_upload_hold(uuid,uuid,uuid,uuid,jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.out_workflow_enter_manual_upload_hold(uuid,uuid,uuid,uuid,jsonb) TO service_role;


-- 4. Upload an invoice for a held transaction (thin wrapper; matcher details
--    delegated to Block 09's intake.manual_upload_handler)
CREATE OR REPLACE FUNCTION public.out_workflow_upload_invoice(
  p_organization_id uuid, p_business_id uuid, p_run_id uuid,
  p_transaction_id uuid, p_document_id uuid,
  p_actor_user_id uuid, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_prior public.transaction_match_status_enum;
  v_new   public.transaction_match_status_enum;
BEGIN
  IF p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'out_workflow.upload_invoice: actor_user_id required' USING ERRCODE='22000';
  END IF;
  SELECT match_status INTO v_prior FROM public.transactions
    WHERE id=p_transaction_id AND business_id=p_business_id;
  IF v_prior IS NULL THEN v_prior := 'UNMATCHED'; END IF;
  v_new := CASE WHEN v_prior IN ('UNMATCHED') THEN 'MATCHED_AUTO_CONFIRMED'::public.transaction_match_status_enum
                ELSE v_prior END;

  UPDATE public.transactions
     SET match_status = v_new, updated_at = clock_timestamp()
   WHERE id = p_transaction_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='OUT_MANUAL_UPLOAD_INVOICE_UPLOADED',
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=p_transaction_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_workflow_manual_upload_hold',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=jsonb_build_object('match_status', v_prior::text),
    p_after_state:=jsonb_build_object(
      'match_status', v_new::text,
      'document_id', p_document_id,
      'workflow_run_id', p_run_id,
      'initiating_user_id', p_actor_user_id),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'decision','APPLIED', 'transaction_id', p_transaction_id,
    'prior_match_status', v_prior::text, 'new_match_status', v_new::text);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.out_workflow_upload_invoice(uuid,uuid,uuid,uuid,uuid,uuid,jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.out_workflow_upload_invoice(uuid,uuid,uuid,uuid,uuid,uuid,jsonb) TO service_role;


-- 5. Document an exception for a held OUT_EXPENSE
CREATE OR REPLACE FUNCTION public.out_workflow_document_exception(
  p_organization_id uuid, p_business_id uuid, p_run_id uuid,
  p_transaction_id uuid, p_exception_reason text,
  p_actor_user_id uuid, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_prior public.transaction_match_status_enum;
  v_closed_issues int;
  v_now timestamptz := clock_timestamp();
BEGIN
  IF p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'out_workflow.document_exception: actor_user_id required' USING ERRCODE='22000';
  END IF;
  IF p_exception_reason IS NULL OR length(btrim(p_exception_reason)) = 0 THEN
    RAISE EXCEPTION 'out_workflow.document_exception: exception_reason required and must be non-empty' USING ERRCODE='22000';
  END IF;

  SELECT match_status INTO v_prior FROM public.transactions
    WHERE id=p_transaction_id AND business_id=p_business_id;

  UPDATE public.transactions
     SET match_status = 'EXCEPTION_DOCUMENTED'::public.transaction_match_status_enum,
         exception_reason = btrim(p_exception_reason),
         exception_documented_by = p_actor_user_id,
         exception_documented_at = v_now,
         updated_at = v_now
   WHERE id = p_transaction_id;

  UPDATE public.review_issues
     SET status = 'RESOLVED'::public.review_issue_status_enum,
         resolution_action = 'exception_documented',
         resolution_note = format('Exception documented: %s', btrim(p_exception_reason)),
         resolved_by = p_actor_user_id,
         resolved_at = v_now,
         updated_at = v_now
   WHERE transaction_id = p_transaction_id
     AND issue_group = 'MISSING_DOCUMENTS'::public.review_issue_group_enum
     AND status = 'OPEN'::public.review_issue_status_enum;
  GET DIAGNOSTICS v_closed_issues = ROW_COUNT;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='OUT_MANUAL_UPLOAD_EXCEPTION_DOCUMENTED',
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=p_transaction_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_workflow_manual_upload_hold',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=jsonb_build_object('match_status', v_prior::text),
    p_after_state:=jsonb_build_object(
      'match_status', 'EXCEPTION_DOCUMENTED',
      'exception_reason', btrim(p_exception_reason),
      'exception_documented_by', p_actor_user_id,
      'exception_documented_at', v_now,
      'workflow_run_id', p_run_id,
      'closed_review_issue_count', v_closed_issues),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'decision','APPLIED', 'transaction_id', p_transaction_id,
    'closed_review_issue_count', v_closed_issues);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.out_workflow_document_exception(uuid,uuid,uuid,uuid,text,uuid,jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.out_workflow_document_exception(uuid,uuid,uuid,uuid,text,uuid,jsonb) TO service_role;


-- 6. Send (or suppress / dedupe) a hold reminder
CREATE OR REPLACE FUNCTION public.out_workflow_send_reminder(
  p_organization_id uuid, p_business_id uuid, p_run_id uuid,
  p_actor_user_id uuid DEFAULT NULL, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_enabled boolean;
  v_recent  timestamptz;
  v_ordinal int;
  v_payload jsonb;
  v_period_start timestamptz; v_period_end timestamptz;
  v_unresolved_count int; v_unresolved_total numeric; v_oldest_age_days int;
BEGIN
  SELECT manual_upload_hold_reminder_enabled INTO v_enabled
    FROM public.out_workflow_business_config WHERE business_id=p_business_id;
  IF v_enabled IS NULL THEN v_enabled := true; END IF;
  IF NOT v_enabled THEN
    RETURN jsonb_build_object('decision','SUPPRESSED','reason','manual_upload_hold_reminder_enabled=false');
  END IF;

  SELECT max(sent_at) INTO v_recent FROM public.out_workflow_reminders
    WHERE workflow_run_id=p_run_id;
  IF v_recent IS NOT NULL AND v_recent > clock_timestamp() - interval '24 hours' THEN
    RETURN jsonb_build_object('decision','DEDUPED','reason','reminder fired within last 24h','last_sent_at',v_recent);
  END IF;

  SELECT period_start, period_end INTO v_period_start, v_period_end
    FROM public.workflow_runs WHERE id=p_run_id;

  SELECT count(*),
         COALESCE(sum(abs(amount)), 0),
         COALESCE(MAX(EXTRACT(DAY FROM clock_timestamp() - transaction_date::timestamptz))::int, 0)
    INTO v_unresolved_count, v_unresolved_total, v_oldest_age_days
    FROM public.transactions
   WHERE business_id=p_business_id
     AND transaction_type='OUT_EXPENSE'
     AND out_workflow_in_scope = true
     AND (match_status IS NULL OR match_status='UNMATCHED')
     AND transaction_date BETWEEN v_period_start::date AND v_period_end::date;

  SELECT COALESCE(max(ordinal), 0) + 1 INTO v_ordinal FROM public.out_workflow_reminders
    WHERE workflow_run_id=p_run_id;

  v_payload := jsonb_build_object(
    'unresolved_count', v_unresolved_count,
    'unresolved_total_amount', v_unresolved_total,
    'oldest_age_days', v_oldest_age_days,
    'period_start', v_period_start, 'period_end', v_period_end);

  INSERT INTO public.out_workflow_reminders (organization_id, business_id, workflow_run_id, ordinal, sent_at, reminder_payload)
    VALUES (p_organization_id, p_business_id, p_run_id, v_ordinal, clock_timestamp(), v_payload);

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='OUT_MANUAL_UPLOAD_REMINDER_SENT',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=p_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_workflow_manual_upload_hold',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('ordinal', v_ordinal, 'payload', v_payload),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','SENT','ordinal', v_ordinal, 'payload', v_payload);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.out_workflow_send_reminder(uuid,uuid,uuid,uuid,jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.out_workflow_send_reminder(uuid,uuid,uuid,uuid,jsonb) TO service_role;


-- 7. Clear the hold (requires the gate to say ADVANCE)
CREATE OR REPLACE FUNCTION public.out_workflow_clear_manual_upload_hold(
  p_organization_id uuid, p_business_id uuid, p_run_id uuid,
  p_actor_user_id uuid DEFAULT NULL, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_gate jsonb;
  v_period_start timestamptz; v_period_end timestamptz;
  v_now timestamptz := clock_timestamp();
BEGIN
  SELECT period_start, period_end INTO v_period_start, v_period_end
    FROM public.workflow_runs WHERE id=p_run_id;
  v_gate := public.gate_out_manual_upload_hold_exit_v1(p_run_id, p_business_id, v_period_start, v_period_end, p_context);
  IF v_gate->>'decision' <> 'ADVANCE' THEN
    RETURN jsonb_build_object('decision','NOT_READY','gate', v_gate);
  END IF;

  UPDATE public.workflow_runs
     SET summary_json = jsonb_set(
           COALESCE(summary_json, '{}'::jsonb),
           '{manual_upload_hold,cleared_at}',
           to_jsonb(v_now), true)
   WHERE id = p_run_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='OUT_MANUAL_UPLOAD_HOLD_CLEARED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id:=p_run_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_workflow_manual_upload_hold',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('cleared_at', v_now, 'initiating_user_id', p_actor_user_id, 'gate_observed', v_gate->'inputs_observed'),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','CLEARED','cleared_at', v_now);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.out_workflow_clear_manual_upload_hold(uuid,uuid,uuid,uuid,jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.out_workflow_clear_manual_upload_hold(uuid,uuid,uuid,uuid,jsonb) TO service_role;


-- 8. Tool registry seeds
SELECT public.register_tool(
  p_tool_name=>'out_workflow.upload_invoice', p_version=>'1.0.0',
  p_input_schema=>jsonb_build_object('organization_id','uuid','business_id','uuid','workflow_run_id','uuid','transaction_id','uuid','document_id','uuid','actor_user_id','uuid'),
  p_output_schema=>jsonb_build_object('decision','text','transaction_id','uuid','prior_match_status','text','new_match_status','text'),
  p_side_effect=>'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier=>'NONE'::ai_tier_enum,
  p_failure_semantics=>'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=>'out_workflow.upload_invoice.dedup_key_v1',
  p_description=>'User-driven manual invoice upload wrapper for MANUAL_UPLOAD_HOLD (B12·P06) — flips transactions.match_status; delegates document creation to Block 09 intake.manual_upload_handler',
  p_retry_max_attempts=>1, p_retry_backoff_base_ms=>100, p_retry_backoff_max_ms=>100);

SELECT public.register_tool(
  p_tool_name=>'out_workflow.document_exception', p_version=>'1.0.0',
  p_input_schema=>jsonb_build_object('organization_id','uuid','business_id','uuid','workflow_run_id','uuid','transaction_id','uuid','exception_reason','text','actor_user_id','uuid'),
  p_output_schema=>jsonb_build_object('decision','text','transaction_id','uuid','closed_review_issue_count','int'),
  p_side_effect=>'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier=>'NONE'::ai_tier_enum,
  p_failure_semantics=>'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=>'out_workflow.document_exception.dedup_key_v1',
  p_description=>'User-driven exception documentation for MANUAL_UPLOAD_HOLD (B12·P06) — requires mandatory free-text reason; flips match_status to EXCEPTION_DOCUMENTED; closes Missing Documents review issues',
  p_retry_max_attempts=>1, p_retry_backoff_base_ms=>100, p_retry_backoff_max_ms=>100);

SELECT public.register_tool(
  p_tool_name=>'out_workflow.send_reminder', p_version=>'1.0.0',
  p_input_schema=>jsonb_build_object('organization_id','uuid','business_id','uuid','workflow_run_id','uuid'),
  p_output_schema=>jsonb_build_object('decision','text','ordinal','int','payload','object'),
  p_side_effect=>'WRITES_RUN_STATE'::side_effect_class_enum,
  p_ai_tier=>'NONE'::ai_tier_enum,
  p_failure_semantics=>'IDEMPOTENT_AT_MOST_ONCE'::tool_failure_semantics_enum,
  p_dedup_key_generator_ref=>'out_workflow.send_reminder.dedup_key_v1',
  p_description=>'System-driven hold reminder for MANUAL_UPLOAD_HOLD (B12·P06) — entry-anchored cadence, 24h dedup, respects manual_upload_hold_reminder_enabled config',
  p_retry_max_attempts=>1, p_retry_backoff_base_ms=>100, p_retry_backoff_max_ms=>100);

COMMIT;
