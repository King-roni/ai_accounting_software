-- B10·P06 — Rejection Memory operational layer.
-- Two additions on top of the already-shipped rejection plumbing (B10·P01
-- table + B10·P02 suppression check + B10·P03 user_reject_match RPC):
--
--   1) CREATE OR REPLACE user_reject_match to dual-emit MATCHING_REJECTION_RECORDED
--      alongside the existing MATCHING_USER_REJECTED, giving consumers both
--      lenses (user-action + memory-write).
--
--   2) override_match_rejection_privileged — Owner-only escape hatch that
--      DELETEs a memory row + restores the original match_record to
--      POSSIBLE_MATCH so it surfaces in the review queue again. Requires
--      step-up auth + non-empty reason. Owner-role enforcement is
--      INTENTIONALLY deferred to the orchestrator (which knows the role).
--
-- Audit family additions (1 new):
--   MATCHING_REJECTION_OVERRIDDEN_PRIVILEGED  (MATCH_RECORD subject; USER actor)

-- 1. user_reject_match dual-emit ---------------------------------------------

CREATE OR REPLACE FUNCTION public.user_reject_match(
  p_match_record_id  uuid,
  p_actor_user_id    uuid,
  p_rejection_reason text,
  p_context          jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid; v_business_id uuid;
  v_transaction_id  uuid; v_document_id uuid;
  v_current_status  public.match_record_status_enum;
  v_rejection_id    uuid;
BEGIN
  IF p_rejection_reason IS NULL OR length(trim(p_rejection_reason)) = 0 THEN
    RAISE EXCEPTION 'REJECTION_REASON_REQUIRED' USING errcode='check_violation';
  END IF;

  SELECT organization_id, business_id, transaction_id, document_id, match_status
    INTO v_organization_id, v_business_id, v_transaction_id, v_document_id, v_current_status
  FROM public.match_records WHERE id = p_match_record_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','MATCH_RECORD_NOT_FOUND','match_record_id',p_match_record_id);
  END IF;

  UPDATE public.match_records
    SET match_status = 'REJECTED_MATCH'::public.match_record_status_enum,
        user_confirmation_status = 'REJECTED',
        updated_at = clock_timestamp()
  WHERE id = p_match_record_id;

  INSERT INTO public.match_rejection_memory (
    organization_id, business_id, transaction_id, document_id,
    rejected_by, rejected_at, rejection_reason, original_match_record_id
  ) VALUES (
    v_organization_id, v_business_id, v_transaction_id, v_document_id,
    p_actor_user_id, clock_timestamp(), p_rejection_reason, p_match_record_id
  )
  ON CONFLICT (business_id, transaction_id, document_id) DO NOTHING
  RETURNING id INTO v_rejection_id;

  -- USER-action lens (already emitted in B10·P03; preserved here)
  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='MATCHING_USER_REJECTED',
    p_subject_type:='MATCH_RECORD'::audit.subject_type_enum,
    p_subject_id:=p_match_record_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:=NULL,
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=jsonb_build_object('match_status', v_current_status),
    p_after_state:=jsonb_build_object(
      'match_status','REJECTED_MATCH', 'transaction_id', v_transaction_id,
      'document_id', v_document_id, 'rejection_memory_id', v_rejection_id,
      'reason', p_rejection_reason
    ),
    p_reason:=p_rejection_reason, p_request_context:=p_context
  );

  -- Memory-write lens (newly emitted in B10·P06 to align with P01 spec)
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='MATCHING_REJECTION_RECORDED',
    p_subject_type:='MATCH_RECORD'::audit.subject_type_enum,
    p_subject_id:=p_match_record_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='matching_engine',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'rejection_memory_id', v_rejection_id,
      'transaction_id', v_transaction_id,
      'document_id', v_document_id,
      'original_match_record_id', p_match_record_id,
      'rejected_by', p_actor_user_id
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','REJECTED','match_record_id',p_match_record_id,
    'rejection_memory_id',v_rejection_id
  );
END;
$$;


-- 2. override_match_rejection_privileged -------------------------------------

CREATE OR REPLACE FUNCTION public.override_match_rejection_privileged(
  p_rejection_memory_id uuid,
  p_actor_user_id       uuid,
  p_business_id         uuid,
  p_reason              text,
  p_step_up_token_id    uuid    DEFAULT NULL,
  p_context             jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid;
  v_transaction_id  uuid;
  v_document_id     uuid;
  v_orig_match_record_id uuid;
  v_action_id       uuid := public.gen_uuid_v7();
  v_consumed        boolean;
  v_token_reason    text;
BEGIN
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'OVERRIDE_REASON_REQUIRED' USING errcode='check_violation';
  END IF;

  -- Step-up enforcement: privileged action always requires fresh step-up
  IF p_step_up_token_id IS NULL THEN
    RETURN jsonb_build_object(
      'decision','REJECTED','reason','STEP_UP_REQUIRED',
      'rejection_memory_id', p_rejection_memory_id
    );
  END IF;
  SELECT consumed, reason INTO v_consumed, v_token_reason
  FROM public.consume_step_up_token(
    p_step_up_token_id, p_business_id,
    'b10p06.override_match_rejection', v_action_id
  );
  IF NOT COALESCE(v_consumed, false) THEN
    RETURN jsonb_build_object(
      'decision','REJECTED','reason','STEP_UP_TOKEN_NOT_CONSUMED',
      'token_reason', v_token_reason,
      'rejection_memory_id', p_rejection_memory_id
    );
  END IF;

  -- Fetch the rejection
  SELECT organization_id, transaction_id, document_id, original_match_record_id
    INTO v_organization_id, v_transaction_id, v_document_id, v_orig_match_record_id
  FROM public.match_rejection_memory
  WHERE id = p_rejection_memory_id AND business_id = p_business_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'decision','REJECTED','reason','REJECTION_NOT_FOUND',
      'rejection_memory_id', p_rejection_memory_id
    );
  END IF;

  -- DELETE the memory row so the pair can be re-suggested
  DELETE FROM public.match_rejection_memory WHERE id = p_rejection_memory_id;

  -- Restore the original match_record to POSSIBLE_MATCH so it surfaces in
  -- the review queue again without re-running the engine.
  IF v_orig_match_record_id IS NOT NULL THEN
    UPDATE public.match_records
      SET match_status = 'POSSIBLE_MATCH'::public.match_record_status_enum,
          user_confirmation_status = NULL,
          requires_user_confirmation = true,
          updated_at = clock_timestamp()
    WHERE id = v_orig_match_record_id;
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='MATCHING_REJECTION_OVERRIDDEN_PRIVILEGED',
    p_subject_type:='MATCH_RECORD'::audit.subject_type_enum,
    p_subject_id:=v_orig_match_record_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:=NULL,
    p_organization_id:=v_organization_id, p_business_id:=p_business_id,
    p_before_state:=jsonb_build_object(
      'rejection_memory_id', p_rejection_memory_id,
      'original_match_record_status', 'REJECTED_MATCH'
    ),
    p_after_state:=jsonb_build_object(
      'rejection_memory_id', p_rejection_memory_id,
      'original_match_record_id', v_orig_match_record_id,
      'transaction_id', v_transaction_id,
      'document_id', v_document_id,
      'reason', p_reason,
      'note', 'rejection_memory_deleted; original_match_record_status=POSSIBLE_MATCH'
    ),
    p_reason:=p_reason, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','OVERRIDDEN',
    'rejection_memory_id', p_rejection_memory_id,
    'original_match_record_id', v_orig_match_record_id,
    'transaction_id', v_transaction_id,
    'document_id', v_document_id
  );
END;
$$;


-- 3. Privileges --------------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.override_match_rejection_privileged(uuid, uuid, uuid, text, uuid, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.override_match_rejection_privileged(uuid, uuid, uuid, text, uuid, jsonb) TO authenticated, service_role;
