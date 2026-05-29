-- B10·P04 — Split-Payment Combinatorial Detection — DB scaffold.
-- Python orchestrator owns the subset-sum search; this phase delivers the
-- proposal table, constituent linkage, umbrella review-issue, and user
-- confirm/reject RPCs with cascade-reject of sibling proposals.
--
-- Audit family additions (6):
--   MATCHING_SPLIT_PAYMENT_DETECTOR_RAN              (TRANSACTION subject)
--   MATCHING_SPLIT_PAYMENT_CANDIDATE_PROPOSED        (TRANSACTION subject)
--   MATCHING_SPLIT_PAYMENT_CANDIDATE_SET_TRUNCATED   (TRANSACTION subject)
--   SPLIT_PAYMENT_GROUP_CREATED                      (TRANSACTION subject)
--   SPLIT_PAYMENT_GROUP_CONFIRMED                    (TRANSACTION subject)
--   SPLIT_PAYMENT_GROUP_REJECTED                     (TRANSACTION subject)

-- 1. Extend split_payment_groups with transaction_id -------------------------
-- The B10·P01 schema didn't include a direct link to the transaction the
-- group is proposed FOR. Confirmation needs this to (a) create match_records
-- on the right txn and (b) cascade-reject sibling PROPOSED groups for the
-- same txn. Table is currently empty so NOT NULL ADD is safe.

ALTER TABLE public.split_payment_groups
  ADD COLUMN IF NOT EXISTS transaction_id uuid;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid
    WHERE t.relname='split_payment_groups' AND c.conname='spg_transaction_fk'
  ) THEN
    ALTER TABLE public.split_payment_groups
      ADD CONSTRAINT spg_transaction_fk
      FOREIGN KEY (transaction_id) REFERENCES public.transactions(id) ON DELETE RESTRICT;
  END IF;
END$$;

ALTER TABLE public.split_payment_groups
  ALTER COLUMN transaction_id SET NOT NULL;

CREATE INDEX IF NOT EXISTS spg_by_transaction
  ON public.split_payment_groups (transaction_id, status);


-- 2. split_payment_group_constituents ----------------------------------------

CREATE TABLE IF NOT EXISTS public.split_payment_group_constituents (
  id              uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  group_id        uuid NOT NULL,
  document_id     uuid NOT NULL,
  per_pair_score  numeric,
  position        integer NOT NULL,
  CONSTRAINT spgc_score_range CHECK (per_pair_score IS NULL OR (per_pair_score >= 0 AND per_pair_score <= 1)),
  CONSTRAINT spgc_position_positive CHECK (position >= 1),
  CONSTRAINT spgc_group_fk    FOREIGN KEY (group_id)    REFERENCES public.split_payment_groups(id) ON DELETE RESTRICT,
  CONSTRAINT spgc_document_fk FOREIGN KEY (document_id) REFERENCES public.documents(id)            ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS spgc_unique_member
  ON public.split_payment_group_constituents (group_id, document_id);
CREATE INDEX IF NOT EXISTS spgc_by_doc
  ON public.split_payment_group_constituents (document_id);

ALTER TABLE public.split_payment_group_constituents ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS spgc_select ON public.split_payment_group_constituents;
CREATE POLICY spgc_select ON public.split_payment_group_constituents FOR SELECT USING (true);
DROP POLICY IF EXISTS spgc_no_insert ON public.split_payment_group_constituents;
CREATE POLICY spgc_no_insert ON public.split_payment_group_constituents FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS spgc_no_update ON public.split_payment_group_constituents;
CREATE POLICY spgc_no_update ON public.split_payment_group_constituents FOR UPDATE USING (false);
DROP POLICY IF EXISTS spgc_no_delete ON public.split_payment_group_constituents;
CREATE POLICY spgc_no_delete ON public.split_payment_group_constituents FOR DELETE USING (false);


-- 3. record_split_payment_detector_ran ---------------------------------------

CREATE OR REPLACE FUNCTION public.record_split_payment_detector_ran(
  p_organization_id uuid,
  p_business_id     uuid,
  p_transaction_id  uuid,
  p_candidate_count integer,
  p_proposed_count  integer,
  p_context         jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
BEGIN
  IF p_candidate_count < 0 OR p_proposed_count < 0 THEN
    RAISE EXCEPTION 'COUNTS_MUST_BE_NONNEGATIVE' USING errcode='check_violation';
  END IF;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='MATCHING_SPLIT_PAYMENT_DETECTOR_RAN',
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=p_transaction_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='matching_engine',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'transaction_id', p_transaction_id,
      'candidate_count', p_candidate_count,
      'proposed_count', p_proposed_count
    ),
    p_reason:=NULL, p_request_context:=p_context
  );
  RETURN jsonb_build_object(
    'decision','RECORDED','transaction_id',p_transaction_id,
    'candidate_count',p_candidate_count,'proposed_count',p_proposed_count
  );
END;
$$;


-- 4. record_split_payment_candidate_set_truncated ----------------------------

CREATE OR REPLACE FUNCTION public.record_split_payment_candidate_set_truncated(
  p_organization_id uuid,
  p_business_id     uuid,
  p_transaction_id  uuid,
  p_full_count      integer,
  p_truncated_to    integer,
  p_context         jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
BEGIN
  IF p_truncated_to <= 0 OR p_full_count < p_truncated_to THEN
    RAISE EXCEPTION 'TRUNCATION_BOUNDS_INVALID' USING errcode='check_violation';
  END IF;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='MATCHING_SPLIT_PAYMENT_CANDIDATE_SET_TRUNCATED',
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=p_transaction_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='matching_engine',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'transaction_id', p_transaction_id,
      'full_count', p_full_count,
      'truncated_to', p_truncated_to
    ),
    p_reason:=NULL, p_request_context:=p_context
  );
  RETURN jsonb_build_object(
    'decision','RECORDED','transaction_id',p_transaction_id,
    'full_count',p_full_count,'truncated_to',p_truncated_to
  );
END;
$$;


-- 5. propose_split_payment_group ---------------------------------------------

CREATE OR REPLACE FUNCTION public.propose_split_payment_group(
  p_organization_id        uuid,
  p_business_id            uuid,
  p_transaction_id         uuid,
  p_parent_target_kind     public.split_payment_parent_target_kind_enum,
  p_parent_target_id       uuid,
  p_proposed_total_amount  numeric,
  p_currency               char(3),
  p_constituent_document_ids uuid[],
  p_per_pair_scores        numeric[],
  p_candidate_score        numeric,
  p_context                jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_group_id          uuid;
  v_constituent_count int;
  v_i                 int;
BEGIN
  IF p_constituent_document_ids IS NULL OR array_length(p_constituent_document_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'CONSTITUENT_DOCUMENT_IDS_REQUIRED' USING errcode='check_violation';
  END IF;
  v_constituent_count := array_length(p_constituent_document_ids, 1);
  IF v_constituent_count < 2 OR v_constituent_count > 5 THEN
    RAISE EXCEPTION 'CONSTITUENT_COUNT_OUT_OF_RANGE_2_5' USING errcode='check_violation';
  END IF;
  IF p_per_pair_scores IS NOT NULL
     AND array_length(p_per_pair_scores, 1) <> v_constituent_count THEN
    RAISE EXCEPTION 'PER_PAIR_SCORES_LENGTH_MISMATCH' USING errcode='check_violation';
  END IF;

  INSERT INTO public.split_payment_groups (
    organization_id, business_id, transaction_id,
    parent_target_kind, parent_target_id,
    proposed_total_amount, currency, status
  ) VALUES (
    p_organization_id, p_business_id, p_transaction_id,
    p_parent_target_kind, p_parent_target_id,
    p_proposed_total_amount, p_currency, 'PROPOSED'
  ) RETURNING id INTO v_group_id;

  FOR v_i IN 1 .. v_constituent_count LOOP
    INSERT INTO public.split_payment_group_constituents (
      group_id, document_id, per_pair_score, position
    ) VALUES (
      v_group_id,
      p_constituent_document_ids[v_i],
      CASE WHEN p_per_pair_scores IS NOT NULL THEN p_per_pair_scores[v_i] ELSE NULL END,
      v_i
    );
  END LOOP;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='SPLIT_PAYMENT_GROUP_CREATED',
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=p_transaction_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='matching_engine',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'split_payment_group_id', v_group_id,
      'transaction_id', p_transaction_id,
      'parent_target_kind', p_parent_target_kind,
      'proposed_total_amount', p_proposed_total_amount,
      'currency', p_currency,
      'constituent_count', v_constituent_count,
      'status', 'PROPOSED'
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='MATCHING_SPLIT_PAYMENT_CANDIDATE_PROPOSED',
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=p_transaction_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='matching_engine',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'split_payment_group_id', v_group_id,
      'transaction_id', p_transaction_id,
      'candidate_score', p_candidate_score,
      'constituent_count', v_constituent_count
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','PROPOSED',
    'group_id', v_group_id,
    'constituent_count', v_constituent_count,
    'candidate_score', p_candidate_score
  );
END;
$$;


-- 6. raise_split_payment_review_issue ----------------------------------------

CREATE OR REPLACE FUNCTION public.raise_split_payment_review_issue(
  p_organization_id  uuid,
  p_business_id      uuid,
  p_transaction_id   uuid,
  p_workflow_run_id  uuid,
  p_candidate_summary jsonb,
  p_actor_user_id    uuid    DEFAULT NULL,
  p_context          jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_review_issue_id uuid;
BEGIN
  INSERT INTO public.review_issues (
    organization_id, business_id, workflow_run_id, transaction_id,
    issue_type, issue_group, severity,
    plain_language_title, plain_language_description, recommended_action,
    card_payload_json
  ) VALUES (
    p_organization_id, p_business_id, p_workflow_run_id, p_transaction_id,
    'matching.split_payment_proposal',
    'POSSIBLE_WRONG_MATCH'::public.review_issue_group_enum,
    'MEDIUM'::public.review_issue_severity_enum,
    'This transaction might cover several invoices',
    'We could not find a single invoice that matches this transaction''s amount, but we found a few combinations that add up to it. Pick the right combination, edit it, or reject all proposals.',
    'Review the proposed split-payment combinations',
    COALESCE(p_candidate_summary, '{}'::jsonb)
  ) RETURNING id INTO v_review_issue_id;

  RETURN jsonb_build_object(
    'decision','RAISED','review_issue_id',v_review_issue_id,
    'transaction_id',p_transaction_id
  );
END;
$$;


-- 7. confirm_split_payment_group ---------------------------------------------

CREATE OR REPLACE FUNCTION public.confirm_split_payment_group(
  p_group_id      uuid,
  p_actor_user_id uuid,
  p_match_level   public.match_level_enum  DEFAULT 'STRONG_PROBABLE',
  p_match_method  public.match_method_enum DEFAULT 'DETERMINISTIC_RULE',
  p_match_score   numeric                  DEFAULT 0.85,
  p_context       jsonb                    DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid;
  v_business_id     uuid;
  v_transaction_id  uuid;
  v_current_status  public.split_payment_group_status_enum;
  v_match_record_ids uuid[] := ARRAY[]::uuid[];
  v_new_mr_id       uuid;
  v_constituent     record;
  v_sibling_id      uuid;
  v_siblings_rejected int := 0;
BEGIN
  SELECT organization_id, business_id, transaction_id, status
    INTO v_organization_id, v_business_id, v_transaction_id, v_current_status
  FROM public.split_payment_groups WHERE id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','GROUP_NOT_FOUND','group_id',p_group_id);
  END IF;
  IF v_current_status <> 'PROPOSED' THEN
    RETURN jsonb_build_object(
      'decision','REJECTED','reason','GROUP_NOT_PROPOSED',
      'group_id',p_group_id,'current_status',v_current_status
    );
  END IF;

  UPDATE public.split_payment_groups
    SET status = 'CONFIRMED'::public.split_payment_group_status_enum,
        confirmed_by = p_actor_user_id,
        confirmed_at = clock_timestamp()
  WHERE id = p_group_id;

  -- Create one match_records row per constituent
  FOR v_constituent IN
    SELECT document_id, per_pair_score
    FROM public.split_payment_group_constituents
    WHERE group_id = p_group_id
    ORDER BY position
  LOOP
    INSERT INTO public.match_records (
      organization_id, business_id, transaction_id, document_id,
      match_level, match_method, match_score, match_signals,
      match_status, requires_user_confirmation,
      split_payment_flag, split_payment_group_id,
      matched_by_user_id, confirmed_by, confirmed_at, user_confirmation_status
    ) VALUES (
      v_organization_id, v_business_id, v_transaction_id, v_constituent.document_id,
      p_match_level, p_match_method, p_match_score,
      jsonb_build_object('split_payment_member', true, 'per_pair_score', v_constituent.per_pair_score),
      'MATCHED_CONFIRMED'::public.match_record_status_enum, false,
      true, p_group_id,
      p_actor_user_id, p_actor_user_id, clock_timestamp(), 'CONFIRMED'
    )
    RETURNING id INTO v_new_mr_id;
    v_match_record_ids := array_append(v_match_record_ids, v_new_mr_id);
  END LOOP;

  -- Cascade-reject sibling PROPOSED groups for the same transaction
  FOR v_sibling_id IN
    SELECT id FROM public.split_payment_groups
    WHERE transaction_id = v_transaction_id
      AND status = 'PROPOSED'
      AND id <> p_group_id
  LOOP
    UPDATE public.split_payment_groups
      SET status = 'REJECTED'::public.split_payment_group_status_enum,
          rejected_by = p_actor_user_id,
          rejected_at = clock_timestamp()
    WHERE id = v_sibling_id;

    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='SPLIT_PAYMENT_GROUP_REJECTED',
      p_subject_type:='TRANSACTION'::audit.subject_type_enum,
      p_subject_id:=v_transaction_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='matching_engine',
      p_organization_id:=v_organization_id, p_business_id:=v_business_id,
      p_before_state:=jsonb_build_object('status', 'PROPOSED'),
      p_after_state:=jsonb_build_object(
        'split_payment_group_id', v_sibling_id,
        'status', 'REJECTED',
        'reason', 'sibling_of_confirmed_group',
        'confirmed_sibling_group_id', p_group_id
      ),
      p_reason:='sibling cascade reject', p_request_context:=p_context
    );
    v_siblings_rejected := v_siblings_rejected + 1;
  END LOOP;

  -- Emit the CONFIRMED audit for the chosen group
  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='SPLIT_PAYMENT_GROUP_CONFIRMED',
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=v_transaction_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:=NULL,
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=jsonb_build_object('status', 'PROPOSED'),
    p_after_state:=jsonb_build_object(
      'split_payment_group_id', p_group_id,
      'status', 'CONFIRMED',
      'match_record_ids', to_jsonb(v_match_record_ids),
      'siblings_rejected', v_siblings_rejected
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','CONFIRMED',
    'group_id', p_group_id,
    'transaction_id', v_transaction_id,
    'match_record_ids', to_jsonb(v_match_record_ids),
    'siblings_rejected', v_siblings_rejected
  );
END;
$$;


-- 8. reject_split_payment_group ----------------------------------------------

CREATE OR REPLACE FUNCTION public.reject_split_payment_group(
  p_group_id        uuid,
  p_actor_user_id   uuid,
  p_rejection_reason text DEFAULT NULL,
  p_context         jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid; v_business_id uuid; v_transaction_id uuid;
  v_current_status  public.split_payment_group_status_enum;
BEGIN
  SELECT organization_id, business_id, transaction_id, status
    INTO v_organization_id, v_business_id, v_transaction_id, v_current_status
  FROM public.split_payment_groups WHERE id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','GROUP_NOT_FOUND','group_id',p_group_id);
  END IF;
  IF v_current_status <> 'PROPOSED' THEN
    RETURN jsonb_build_object(
      'decision','REJECTED','reason','GROUP_NOT_PROPOSED',
      'group_id',p_group_id,'current_status',v_current_status
    );
  END IF;

  UPDATE public.split_payment_groups
    SET status = 'REJECTED'::public.split_payment_group_status_enum,
        rejected_by = p_actor_user_id,
        rejected_at = clock_timestamp()
  WHERE id = p_group_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='SPLIT_PAYMENT_GROUP_REJECTED',
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=v_transaction_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:=NULL,
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=jsonb_build_object('status', 'PROPOSED'),
    p_after_state:=jsonb_build_object(
      'split_payment_group_id', p_group_id,
      'status', 'REJECTED',
      'reason', COALESCE(p_rejection_reason, 'user_rejected')
    ),
    p_reason:=p_rejection_reason, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','REJECTED','group_id',p_group_id,
    'transaction_id',v_transaction_id
  );
END;
$$;


-- 9. Privileges --------------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.record_split_payment_detector_ran(uuid, uuid, uuid, integer, integer, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_split_payment_candidate_set_truncated(uuid, uuid, uuid, integer, integer, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.propose_split_payment_group(uuid, uuid, uuid, public.split_payment_parent_target_kind_enum, uuid, numeric, char(3), uuid[], numeric[], numeric, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.raise_split_payment_review_issue(uuid, uuid, uuid, uuid, jsonb, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.confirm_split_payment_group(uuid, uuid, public.match_level_enum, public.match_method_enum, numeric, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.reject_split_payment_group(uuid, uuid, text, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.record_split_payment_detector_ran(uuid, uuid, uuid, integer, integer, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_split_payment_candidate_set_truncated(uuid, uuid, uuid, integer, integer, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.propose_split_payment_group(uuid, uuid, uuid, public.split_payment_parent_target_kind_enum, uuid, numeric, char(3), uuid[], numeric[], numeric, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.raise_split_payment_review_issue(uuid, uuid, uuid, uuid, jsonb, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.confirm_split_payment_group(uuid, uuid, public.match_level_enum, public.match_method_enum, numeric, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reject_split_payment_group(uuid, uuid, text, jsonb) TO authenticated, service_role;

GRANT SELECT ON public.split_payment_group_constituents TO authenticated, anon;
