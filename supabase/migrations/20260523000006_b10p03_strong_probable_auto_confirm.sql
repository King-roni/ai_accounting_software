-- B10·P03 — Strong Probable Auto-Confirm Rule — DB scaffold.
-- Layers decision logic on top of B10·P02's apply_match_score chokepoint.
-- Adds the Level-2 auto-confirm discriminator, review-issue creation paths,
-- user action RPCs, and a shared vendor-memory increment helper with
-- explicit (source, source_record_id) idempotency tracking.
--
-- Audit family MATCHING (6 new actions):
--   MATCHING_AUTO_CONFIRMED
--   MATCHING_NEEDS_CONFIRMATION_RAISED
--   MATCHING_POSSIBLE_RAISED
--   MATCHING_USER_CONFIRMED
--   MATCHING_USER_REJECTED
--   MATCHING_USER_EDITED_AND_CONFIRMED

-- 1. vendor_memory_increment_log (idempotency tracking) ----------------------

CREATE TABLE IF NOT EXISTS public.vendor_memory_increment_log (
  id                      uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id         uuid NOT NULL,
  business_id             uuid NOT NULL,
  counterparty_signature  text NOT NULL,
  source                  text NOT NULL,
  source_record_id        uuid NOT NULL,
  incremented_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT vmil_source_chk CHECK (source IN (
    'matching.auto_confirm',
    'matching.user_confirm',
    'classification.auto_confirm'
  )),
  CONSTRAINT vmil_signature_nonempty CHECK (length(trim(counterparty_signature)) > 0),
  CONSTRAINT vmil_org_fk      FOREIGN KEY (organization_id) REFERENCES public.organizations(id)    ON DELETE RESTRICT,
  CONSTRAINT vmil_business_fk FOREIGN KEY (business_id)     REFERENCES public.business_entities(id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS vmil_unique_event
  ON public.vendor_memory_increment_log
    (business_id, counterparty_signature, source, source_record_id);

ALTER TABLE public.vendor_memory_increment_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vmil_select ON public.vendor_memory_increment_log;
CREATE POLICY vmil_select ON public.vendor_memory_increment_log FOR SELECT USING (true);
DROP POLICY IF EXISTS vmil_no_insert ON public.vendor_memory_increment_log;
CREATE POLICY vmil_no_insert ON public.vendor_memory_increment_log FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS vmil_no_update ON public.vendor_memory_increment_log;
CREATE POLICY vmil_no_update ON public.vendor_memory_increment_log FOR UPDATE USING (false);
DROP POLICY IF EXISTS vmil_no_delete ON public.vendor_memory_increment_log;
CREATE POLICY vmil_no_delete ON public.vendor_memory_increment_log FOR DELETE USING (false);


-- 2. record_vendor_memory_confirmation (shared helper) -----------------------

CREATE OR REPLACE FUNCTION public.record_vendor_memory_confirmation(
  p_organization_id        uuid,
  p_business_id            uuid,
  p_counterparty_signature text,
  p_source                 text,
  p_source_record_id       uuid,
  p_context                jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_new_count int;
  v_inserted  boolean;
BEGIN
  IF p_source NOT IN ('matching.auto_confirm','matching.user_confirm','classification.auto_confirm') THEN
    RAISE EXCEPTION 'VENDOR_MEMORY_SOURCE_INVALID' USING errcode='check_violation';
  END IF;
  IF p_counterparty_signature IS NULL OR length(trim(p_counterparty_signature)) = 0 THEN
    RAISE EXCEPTION 'COUNTERPARTY_SIGNATURE_REQUIRED' USING errcode='check_violation';
  END IF;

  -- Idempotency: try to claim the event
  BEGIN
    INSERT INTO public.vendor_memory_increment_log
      (organization_id, business_id, counterparty_signature, source, source_record_id)
    VALUES
      (p_organization_id, p_business_id, p_counterparty_signature, p_source, p_source_record_id);
    v_inserted := true;
  EXCEPTION WHEN unique_violation THEN
    v_inserted := false;
  END;

  IF NOT v_inserted THEN
    RETURN jsonb_build_object(
      'decision','NOOP','reason','ALREADY_COUNTED',
      'counterparty_signature', p_counterparty_signature,
      'source', p_source, 'source_record_id', p_source_record_id
    );
  END IF;

  UPDATE public.recurring_vendor_memory
    SET confirmations_count = confirmations_count + 1,
        last_confirmation_at = clock_timestamp(),
        updated_at = clock_timestamp()
  WHERE business_id = p_business_id
    AND counterparty_signature = p_counterparty_signature
  RETURNING confirmations_count INTO v_new_count;

  IF v_new_count IS NULL THEN
    -- log entry recorded but no vendor_memory row exists; orchestrator can
    -- decide to create one. We return INCREMENTED=false envelope.
    RETURN jsonb_build_object(
      'decision','NOOP','reason','NO_VENDOR_MEMORY_ROW',
      'counterparty_signature', p_counterparty_signature,
      'source', p_source
    );
  END IF;

  RETURN jsonb_build_object(
    'decision','INCREMENTED',
    'counterparty_signature', p_counterparty_signature,
    'new_count', v_new_count,
    'source', p_source
  );
END;
$$;


-- 3. apply_match_decision (wrapper around B10·P02) ---------------------------

CREATE OR REPLACE FUNCTION public.apply_match_decision(
  p_organization_id            uuid,
  p_business_id                uuid,
  p_transaction_id             uuid,
  p_document_id                uuid,
  p_signal_breakdown           jsonb,
  p_match_score                numeric,
  p_match_level                public.match_level_enum,
  p_workflow_run_id            uuid,
  p_match_method               public.match_method_enum DEFAULT 'DETERMINISTIC_RULE',
  p_match_reason_plain_language text DEFAULT NULL,
  p_matched_by_system          text DEFAULT 'matching_engine',
  p_counterparty_signature     text DEFAULT NULL,
  p_actor_user_id              uuid DEFAULT NULL,
  p_context                    jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_score_env       jsonb;
  v_match_record_id uuid;
  v_recurring       numeric;
  v_amount_exact    numeric;
  v_txn_type        public.transaction_type_enum;
  v_severity        public.review_issue_severity_enum;
  v_review_issue_id uuid;
  v_final_status    public.match_record_status_enum;
  v_auto_confirmed  boolean := false;
  v_vendor_env      jsonb;
BEGIN
  -- Step 1: delegate to B10·P02 chokepoint (handles suppression + insert)
  v_score_env := public.apply_match_score(
    p_organization_id, p_business_id, p_transaction_id, p_document_id,
    p_signal_breakdown, p_match_score, p_match_level,
    p_match_method, p_match_reason_plain_language, p_matched_by_system, p_context
  );
  IF v_score_env->>'decision' = 'SUPPRESSED' THEN
    RETURN v_score_env;
  END IF;
  v_match_record_id := (v_score_env->>'match_record_id')::uuid;

  -- Look up transaction_type for severity rules
  SELECT transaction_type INTO v_txn_type FROM public.transactions WHERE id = p_transaction_id;

  -- Level-specific decision branches
  IF p_match_level = 'EXACT' THEN
    -- Auto-confirm (status already MATCHED_AUTO_HIGH_CONFIDENCE from B10·P02)
    v_final_status := 'MATCHED_AUTO_HIGH_CONFIDENCE';
    v_auto_confirmed := true;

    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='MATCHING_AUTO_CONFIRMED',
      p_subject_type:='MATCH_RECORD'::audit.subject_type_enum,
      p_subject_id:=v_match_record_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='matching_engine',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object(
        'match_record_id', v_match_record_id,
        'match_level', p_match_level,
        'transaction_id', p_transaction_id
      ),
      p_reason:=NULL, p_request_context:=p_context
    );

    IF p_counterparty_signature IS NOT NULL THEN
      v_vendor_env := public.record_vendor_memory_confirmation(
        p_organization_id, p_business_id, p_counterparty_signature,
        'matching.auto_confirm', v_match_record_id, p_context
      );
    END IF;

  ELSIF p_match_level = 'STRONG_PROBABLE' THEN
    v_recurring    := COALESCE((p_signal_breakdown->>'recurring_vendor_signal')::numeric, 0);
    v_amount_exact := COALESCE((p_signal_breakdown->>'amount_exact_match')::numeric,    0);

    IF v_recurring >= 0.88 AND v_amount_exact = 1.0 THEN
      -- Auto-confirm path: upgrade status
      UPDATE public.match_records
        SET match_status = 'MATCHED_AUTO_HIGH_CONFIDENCE'::public.match_record_status_enum,
            requires_user_confirmation = false,
            updated_at = clock_timestamp()
      WHERE id = v_match_record_id;
      v_final_status := 'MATCHED_AUTO_HIGH_CONFIDENCE';
      v_auto_confirmed := true;

      PERFORM audit.emit_audit(
        p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
        p_action:='MATCHING_AUTO_CONFIRMED',
        p_subject_type:='MATCH_RECORD'::audit.subject_type_enum,
        p_subject_id:=v_match_record_id,
        p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
        p_actor_system:='matching_engine',
        p_organization_id:=p_organization_id, p_business_id:=p_business_id,
        p_before_state:=NULL,
        p_after_state:=jsonb_build_object(
          'match_record_id', v_match_record_id,
          'match_level', p_match_level,
          'recurring_vendor_signal', v_recurring,
          'amount_exact_match', v_amount_exact,
          'note', 'strong_probable_with_high_vendor_signal_and_amount_exact'
        ),
        p_reason:=NULL, p_request_context:=p_context
      );

      IF p_counterparty_signature IS NOT NULL THEN
        v_vendor_env := public.record_vendor_memory_confirmation(
          p_organization_id, p_business_id, p_counterparty_signature,
          'matching.auto_confirm', v_match_record_id, p_context
        );
      END IF;
    ELSE
      -- Review path: keep MATCHED_NEEDS_CONFIRMATION; create review_issue
      v_final_status := 'MATCHED_NEEDS_CONFIRMATION';
      INSERT INTO public.review_issues (
        organization_id, business_id, workflow_run_id, transaction_id, match_record_id,
        issue_type, issue_group, severity,
        plain_language_title, plain_language_description, recommended_action
      ) VALUES (
        p_organization_id, p_business_id, p_workflow_run_id, p_transaction_id, v_match_record_id,
        'match.needs_confirmation',
        'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
        'MEDIUM'::public.review_issue_severity_enum,
        'A strong-probable match needs your confirmation',
        'We found a likely matching invoice but want you to confirm before booking it. Open the match card to see the details and either confirm, reject, or edit.',
        'Review the proposed match and confirm or reject'
      ) RETURNING id INTO v_review_issue_id;

      PERFORM audit.emit_audit(
        p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
        p_action:='MATCHING_NEEDS_CONFIRMATION_RAISED',
        p_subject_type:='MATCH_RECORD'::audit.subject_type_enum,
        p_subject_id:=v_match_record_id,
        p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
        p_actor_system:='matching_engine',
        p_organization_id:=p_organization_id, p_business_id:=p_business_id,
        p_before_state:=NULL,
        p_after_state:=jsonb_build_object(
          'match_record_id', v_match_record_id,
          'review_issue_id', v_review_issue_id,
          'recurring_vendor_signal', v_recurring,
          'amount_exact_match', v_amount_exact
        ),
        p_reason:=NULL, p_request_context:=p_context
      );
    END IF;

  ELSE
    -- WEAK_POSSIBLE: always review; severity depends on transaction_type
    v_final_status := 'POSSIBLE_MATCH';
    v_severity := CASE WHEN v_txn_type = 'OUT_EXPENSE'
                       THEN 'MEDIUM'::public.review_issue_severity_enum
                       ELSE 'LOW'::public.review_issue_severity_enum
                  END;
    INSERT INTO public.review_issues (
      organization_id, business_id, workflow_run_id, transaction_id, match_record_id,
      issue_type, issue_group, severity,
      plain_language_title, plain_language_description, recommended_action
    ) VALUES (
      p_organization_id, p_business_id, p_workflow_run_id, p_transaction_id, v_match_record_id,
      'match.possible_weak',
      'POSSIBLE_WRONG_MATCH'::public.review_issue_group_enum,
      v_severity,
      'A weakly possible match needs your judgement',
      'We found a candidate document for this transaction but the signals are weak. Open the match card to compare and decide.',
      'Review the candidate and confirm or reject'
    ) RETURNING id INTO v_review_issue_id;

    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='MATCHING_POSSIBLE_RAISED',
      p_subject_type:='MATCH_RECORD'::audit.subject_type_enum,
      p_subject_id:=v_match_record_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='matching_engine',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object(
        'match_record_id', v_match_record_id,
        'review_issue_id', v_review_issue_id,
        'severity', v_severity,
        'transaction_type', v_txn_type
      ),
      p_reason:=NULL, p_request_context:=p_context
    );
  END IF;

  RETURN jsonb_build_object(
    'decision','RECORDED',
    'match_record_id', v_match_record_id,
    'match_level', p_match_level,
    'final_status', v_final_status,
    'auto_confirmed', v_auto_confirmed,
    'review_issue_id', v_review_issue_id,
    'vendor_memory_envelope', v_vendor_env
  );
END;
$$;


-- 4. record_match_no_match ---------------------------------------------------

CREATE OR REPLACE FUNCTION public.record_match_no_match(
  p_organization_id uuid,
  p_business_id     uuid,
  p_transaction_id  uuid,
  p_workflow_run_id uuid,
  p_actor_user_id   uuid    DEFAULT NULL,
  p_context         jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_txn_type        public.transaction_type_enum;
  v_review_issue_id uuid;
BEGIN
  SELECT transaction_type INTO v_txn_type FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','TRANSACTION_NOT_FOUND','transaction_id',p_transaction_id);
  END IF;

  -- transactions.match_status enum has UNMATCHED (default) but no NO_MATCH;
  -- leave as UNMATCHED and signal via the review_issue + downstream audit.
  -- Only OUT_EXPENSE requires evidence, so only OUT_EXPENSE raises the issue.
  IF v_txn_type = 'OUT_EXPENSE' THEN
    INSERT INTO public.review_issues (
      organization_id, business_id, workflow_run_id, transaction_id,
      issue_type, issue_group, severity,
      plain_language_title, plain_language_description, recommended_action
    ) VALUES (
      p_organization_id, p_business_id, p_workflow_run_id, p_transaction_id,
      'match.missing_documents',
      'MISSING_DOCUMENTS'::public.review_issue_group_enum,
      'HIGH'::public.review_issue_severity_enum,
      'No supporting document found for this expense',
      'The matching engine could not find an invoice or receipt for this OUT expense. Please upload one, or use the Missing Documents action to attest the document is unavailable.',
      'Upload the document, or mark as no invoice available'
    ) RETURNING id INTO v_review_issue_id;
  END IF;

  RETURN jsonb_build_object(
    'decision','RECORDED','transaction_id',p_transaction_id,
    'transaction_type',v_txn_type,'review_issue_id',v_review_issue_id
  );
END;
$$;


-- 5. user_confirm_match ------------------------------------------------------

CREATE OR REPLACE FUNCTION public.user_confirm_match(
  p_match_record_id        uuid,
  p_actor_user_id          uuid,
  p_counterparty_signature text  DEFAULT NULL,
  p_context                jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid; v_business_id uuid; v_transaction_id uuid;
  v_current_status  public.match_record_status_enum;
  v_vendor_env      jsonb;
BEGIN
  SELECT organization_id, business_id, transaction_id, match_status
    INTO v_organization_id, v_business_id, v_transaction_id, v_current_status
  FROM public.match_records WHERE id = p_match_record_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','MATCH_RECORD_NOT_FOUND','match_record_id',p_match_record_id);
  END IF;

  UPDATE public.match_records
    SET match_status = 'MATCHED_CONFIRMED'::public.match_record_status_enum,
        user_confirmation_status = 'CONFIRMED',
        confirmed_by = p_actor_user_id,
        confirmed_at = clock_timestamp(),
        requires_user_confirmation = false,
        updated_at = clock_timestamp()
  WHERE id = p_match_record_id;

  IF p_counterparty_signature IS NOT NULL THEN
    v_vendor_env := public.record_vendor_memory_confirmation(
      v_organization_id, v_business_id, p_counterparty_signature,
      'matching.user_confirm', p_match_record_id, p_context
    );
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='MATCHING_USER_CONFIRMED',
    p_subject_type:='MATCH_RECORD'::audit.subject_type_enum,
    p_subject_id:=p_match_record_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:=NULL,
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=jsonb_build_object('match_status', v_current_status),
    p_after_state:=jsonb_build_object(
      'match_status','MATCHED_CONFIRMED',
      'transaction_id', v_transaction_id
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','CONFIRMED','match_record_id',p_match_record_id,
    'transaction_id',v_transaction_id,'vendor_memory_envelope',v_vendor_env
  );
END;
$$;


-- 6. user_reject_match -------------------------------------------------------

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

  -- Forever-remember the pair so future runs skip suggesting it
  INSERT INTO public.match_rejection_memory (
    organization_id, business_id, transaction_id, document_id,
    rejected_by, rejected_at, rejection_reason, original_match_record_id
  ) VALUES (
    v_organization_id, v_business_id, v_transaction_id, v_document_id,
    p_actor_user_id, clock_timestamp(), p_rejection_reason, p_match_record_id
  )
  ON CONFLICT (business_id, transaction_id, document_id) DO NOTHING
  RETURNING id INTO v_rejection_id;

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
      'match_status','REJECTED_MATCH',
      'transaction_id', v_transaction_id,
      'document_id', v_document_id,
      'rejection_memory_id', v_rejection_id,
      'reason', p_rejection_reason
    ),
    p_reason:=p_rejection_reason, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','REJECTED','match_record_id',p_match_record_id,
    'rejection_memory_id',v_rejection_id
  );
END;
$$;


-- 7. user_edit_and_confirm_match ---------------------------------------------

CREATE OR REPLACE FUNCTION public.user_edit_and_confirm_match(
  p_original_match_record_id    uuid,
  p_actor_user_id               uuid,
  p_replacement_document_id     uuid    DEFAULT NULL,
  p_replacement_match_record_id uuid    DEFAULT NULL,
  p_context                     jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid; v_business_id uuid; v_transaction_id uuid;
  v_current_status  public.match_record_status_enum;
BEGIN
  SELECT organization_id, business_id, transaction_id, match_status
    INTO v_organization_id, v_business_id, v_transaction_id, v_current_status
  FROM public.match_records WHERE id = p_original_match_record_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','MATCH_RECORD_NOT_FOUND','match_record_id',p_original_match_record_id);
  END IF;

  -- Reject the original WITHOUT banning the pair (edit != ban)
  UPDATE public.match_records
    SET match_status = 'REJECTED_MATCH'::public.match_record_status_enum,
        user_confirmation_status = 'EDITED',
        updated_at = clock_timestamp()
  WHERE id = p_original_match_record_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='MATCHING_USER_EDITED_AND_CONFIRMED',
    p_subject_type:='MATCH_RECORD'::audit.subject_type_enum,
    p_subject_id:=p_original_match_record_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:=NULL,
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=jsonb_build_object('match_status', v_current_status),
    p_after_state:=jsonb_build_object(
      'original_match_record_id', p_original_match_record_id,
      'replacement_document_id', p_replacement_document_id,
      'replacement_match_record_id', p_replacement_match_record_id,
      'transaction_id', v_transaction_id,
      'note', 'edit_does_not_add_to_rejection_memory'
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','EDITED',
    'original_match_record_id',p_original_match_record_id,
    'replacement_document_id',p_replacement_document_id,
    'replacement_match_record_id',p_replacement_match_record_id
  );
END;
$$;


-- 8. Privileges --------------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.record_vendor_memory_confirmation(uuid, uuid, text, text, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.apply_match_decision(uuid, uuid, uuid, uuid, jsonb, numeric, public.match_level_enum, uuid, public.match_method_enum, text, text, text, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_match_no_match(uuid, uuid, uuid, uuid, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.user_confirm_match(uuid, uuid, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.user_reject_match(uuid, uuid, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.user_edit_and_confirm_match(uuid, uuid, uuid, uuid, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.record_vendor_memory_confirmation(uuid, uuid, text, text, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.apply_match_decision(uuid, uuid, uuid, uuid, jsonb, numeric, public.match_level_enum, uuid, public.match_method_enum, text, text, text, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_match_no_match(uuid, uuid, uuid, uuid, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.user_confirm_match(uuid, uuid, text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.user_reject_match(uuid, uuid, text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.user_edit_and_confirm_match(uuid, uuid, uuid, uuid, jsonb) TO authenticated, service_role;

GRANT SELECT ON public.vendor_memory_increment_log TO authenticated, anon;
