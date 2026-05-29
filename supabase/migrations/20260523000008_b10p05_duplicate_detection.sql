-- B10·P05 — Duplicate Detection — DB scaffold.
-- 2 STABLE detector helpers + 2 RPCs (idempotent raise + resolved audit).
-- This phase ONLY detects Block-10-owned patterns:
--   Pattern A: one document with matches on multiple txns (no split group)
--   Pattern B: one txn with matches on multiple docs (no shared confirmed group)
-- Upstream-owned duplicates (content-hash, statement file hash, row dedup)
-- are referenced — NEVER re-detected here — to keep ownership clean.
--
-- Audit family MATCHING (2 new):
--   MATCHING_DUPLICATE_PATTERN_DETECTED  (DOCUMENT or TRANSACTION subject)
--   MATCHING_DUPLICATE_PATTERN_RESOLVED  (USER actor)

-- 1. detect_duplicate_pattern_a ----------------------------------------------
-- Pattern A: one document attached to multiple transactions, NOT in same
-- PROPOSED/CONFIRMED split_payment_group.

CREATE OR REPLACE FUNCTION public.detect_duplicate_pattern_a(
  p_business_id uuid,
  p_document_id uuid
)
RETURNS jsonb LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_total          int;
  v_distinct_txn   int;
  v_distinct_group int;
  v_only_group_id  uuid;
  v_group_status   public.split_payment_group_status_enum;
  v_txn_ids        uuid[];
  v_mr_ids         uuid[];
BEGIN
  SELECT
    count(*),
    count(DISTINCT transaction_id),
    count(DISTINCT split_payment_group_id) FILTER (WHERE split_payment_group_id IS NOT NULL),
    array_agg(DISTINCT transaction_id ORDER BY transaction_id),
    array_agg(id ORDER BY id)
  INTO v_total, v_distinct_txn, v_distinct_group, v_txn_ids, v_mr_ids
  FROM public.match_records
  WHERE business_id = p_business_id
    AND document_id = p_document_id
    AND match_status <> 'REJECTED_MATCH'::public.match_record_status_enum;

  IF v_total <= 1 OR v_distinct_txn <= 1 THEN
    RETURN jsonb_build_object(
      'detected', false, 'reason', 'SINGLE_TRANSACTION',
      'document_id', p_document_id, 'total_match_records', COALESCE(v_total,0)
    );
  END IF;

  -- Exclude when ALL rows share the same non-NULL group AND that group is
  -- PROPOSED or CONFIRMED.
  IF v_distinct_group = 1 THEN
    SELECT DISTINCT split_payment_group_id INTO v_only_group_id
    FROM public.match_records
    WHERE business_id = p_business_id AND document_id = p_document_id
      AND match_status <> 'REJECTED_MATCH'::public.match_record_status_enum
      AND split_payment_group_id IS NOT NULL;
    -- All non-rejected rows must have that group_id (no NULL group rows in mix)
    PERFORM 1 FROM public.match_records
    WHERE business_id = p_business_id AND document_id = p_document_id
      AND match_status <> 'REJECTED_MATCH'::public.match_record_status_enum
      AND split_payment_group_id IS NULL
    LIMIT 1;
    IF NOT FOUND AND v_only_group_id IS NOT NULL THEN
      SELECT status INTO v_group_status FROM public.split_payment_groups WHERE id = v_only_group_id;
      IF v_group_status IN ('PROPOSED','CONFIRMED') THEN
        RETURN jsonb_build_object(
          'detected', false,
          'reason', 'EXCLUDED_BY_SPLIT_PAYMENT_GROUP',
          'document_id', p_document_id,
          'split_payment_group_id', v_only_group_id,
          'group_status', v_group_status
        );
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'detected', true,
    'document_id', p_document_id,
    'transaction_ids', to_jsonb(v_txn_ids),
    'match_record_ids', to_jsonb(v_mr_ids),
    'total_match_records', v_total
  );
END;
$$;


-- 2. detect_duplicate_pattern_b ----------------------------------------------
-- Pattern B: one transaction matched to multiple unrelated documents, NOT
-- in same PROPOSED/CONFIRMED split_payment_group.

CREATE OR REPLACE FUNCTION public.detect_duplicate_pattern_b(
  p_business_id    uuid,
  p_transaction_id uuid
)
RETURNS jsonb LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_total          int;
  v_distinct_doc   int;
  v_distinct_group int;
  v_only_group_id  uuid;
  v_group_status   public.split_payment_group_status_enum;
  v_doc_ids        uuid[];
  v_mr_ids         uuid[];
BEGIN
  SELECT
    count(*),
    count(DISTINCT document_id),
    count(DISTINCT split_payment_group_id) FILTER (WHERE split_payment_group_id IS NOT NULL),
    array_agg(DISTINCT document_id ORDER BY document_id),
    array_agg(id ORDER BY id)
  INTO v_total, v_distinct_doc, v_distinct_group, v_doc_ids, v_mr_ids
  FROM public.match_records
  WHERE business_id = p_business_id
    AND transaction_id = p_transaction_id
    AND match_status <> 'REJECTED_MATCH'::public.match_record_status_enum;

  IF v_total <= 1 OR v_distinct_doc <= 1 THEN
    RETURN jsonb_build_object(
      'detected', false, 'reason', 'SINGLE_DOCUMENT',
      'transaction_id', p_transaction_id, 'total_match_records', COALESCE(v_total,0)
    );
  END IF;

  IF v_distinct_group = 1 THEN
    SELECT DISTINCT split_payment_group_id INTO v_only_group_id
    FROM public.match_records
    WHERE business_id = p_business_id AND transaction_id = p_transaction_id
      AND match_status <> 'REJECTED_MATCH'::public.match_record_status_enum
      AND split_payment_group_id IS NOT NULL;
    PERFORM 1 FROM public.match_records
    WHERE business_id = p_business_id AND transaction_id = p_transaction_id
      AND match_status <> 'REJECTED_MATCH'::public.match_record_status_enum
      AND split_payment_group_id IS NULL
    LIMIT 1;
    IF NOT FOUND AND v_only_group_id IS NOT NULL THEN
      SELECT status INTO v_group_status FROM public.split_payment_groups WHERE id = v_only_group_id;
      IF v_group_status IN ('PROPOSED','CONFIRMED') THEN
        RETURN jsonb_build_object(
          'detected', false,
          'reason', 'EXCLUDED_BY_SPLIT_PAYMENT_GROUP',
          'transaction_id', p_transaction_id,
          'split_payment_group_id', v_only_group_id,
          'group_status', v_group_status
        );
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'detected', true,
    'transaction_id', p_transaction_id,
    'document_ids', to_jsonb(v_doc_ids),
    'match_record_ids', to_jsonb(v_mr_ids),
    'total_match_records', v_total
  );
END;
$$;


-- 3. raise_duplicate_pattern_detected ----------------------------------------

CREATE OR REPLACE FUNCTION public.raise_duplicate_pattern_detected(
  p_organization_id uuid,
  p_business_id     uuid,
  p_pattern_kind    text,
  p_primary_id      uuid,
  p_related_ids     uuid[],
  p_workflow_run_id uuid,
  p_actor_user_id   uuid    DEFAULT NULL,
  p_context         jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_issue_type        text;
  v_subject_type      audit.subject_type_enum;
  v_existing_issue_id uuid;
  v_review_issue_id   uuid;
  v_anchor_txn_id     uuid;
  v_anchor_doc_id     uuid;
BEGIN
  IF p_pattern_kind NOT IN ('document_used_multiple_times','transaction_multi_match') THEN
    RAISE EXCEPTION 'PATTERN_KIND_INVALID' USING errcode='check_violation';
  END IF;
  IF p_primary_id IS NULL THEN
    RAISE EXCEPTION 'PRIMARY_ID_REQUIRED' USING errcode='check_violation';
  END IF;
  IF p_related_ids IS NULL OR array_length(p_related_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'RELATED_IDS_REQUIRED' USING errcode='check_violation';
  END IF;

  IF p_pattern_kind = 'document_used_multiple_times' THEN
    v_issue_type   := 'matching.document_used_multiple_times';
    v_subject_type := 'DOCUMENT'::audit.subject_type_enum;
    v_anchor_doc_id := p_primary_id;
    v_anchor_txn_id := NULL;
  ELSE
    v_issue_type   := 'matching.transaction_multi_match';
    v_subject_type := 'TRANSACTION'::audit.subject_type_enum;
    v_anchor_txn_id := p_primary_id;
    v_anchor_doc_id := NULL;
  END IF;

  -- Idempotency: existing OPEN review_issue with matching issue_type +
  -- anchor on the primary entity → return existing without re-emitting.
  IF p_pattern_kind = 'document_used_multiple_times' THEN
    SELECT id INTO v_existing_issue_id FROM public.review_issues
    WHERE business_id = p_business_id
      AND issue_type = v_issue_type
      AND document_id = p_primary_id
      AND status = 'OPEN'::public.review_issue_status_enum
    LIMIT 1;
  ELSE
    SELECT id INTO v_existing_issue_id FROM public.review_issues
    WHERE business_id = p_business_id
      AND issue_type = v_issue_type
      AND transaction_id = p_primary_id
      AND status = 'OPEN'::public.review_issue_status_enum
    LIMIT 1;
  END IF;

  IF v_existing_issue_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'decision','ALREADY_RAISED',
      'review_issue_id', v_existing_issue_id,
      'pattern_kind', p_pattern_kind,
      'primary_id', p_primary_id
    );
  END IF;

  INSERT INTO public.review_issues (
    organization_id, business_id, workflow_run_id,
    transaction_id, document_id,
    issue_type, issue_group, severity,
    plain_language_title, plain_language_description, recommended_action,
    card_payload_json
  ) VALUES (
    p_organization_id, p_business_id, p_workflow_run_id,
    v_anchor_txn_id, v_anchor_doc_id,
    v_issue_type,
    'POSSIBLE_WRONG_MATCH'::public.review_issue_group_enum,
    'HIGH'::public.review_issue_severity_enum,
    CASE WHEN p_pattern_kind = 'document_used_multiple_times'
         THEN 'A document is attached to multiple transactions'
         ELSE 'A transaction has multiple unrelated matches' END,
    CASE WHEN p_pattern_kind = 'document_used_multiple_times'
         THEN 'The same document is matched to several transactions but none of them are part of a confirmed split-payment group. Confirm whether this is a legitimate split, reject one of the matches, or mark the document as a duplicate.'
         ELSE 'This transaction has more than one match record pointing at different documents, with no confirmed split-payment group tying them together. Pick the right match, mark as a legitimate multi-match, or edit the matches.' END,
    CASE WHEN p_pattern_kind = 'document_used_multiple_times'
         THEN 'Confirm as split-payment, reject a match, or mark as duplicate'
         ELSE 'Pick the right match, mark as legitimate multi-match, or edit' END,
    jsonb_build_object(
      'pattern_kind', p_pattern_kind,
      'primary_id', p_primary_id,
      'related_ids', to_jsonb(p_related_ids),
      'related_count', array_length(p_related_ids, 1)
    )
  ) RETURNING id INTO v_review_issue_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='MATCHING_DUPLICATE_PATTERN_DETECTED',
    p_subject_type:=v_subject_type,
    p_subject_id:=p_primary_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='matching_engine',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'pattern_kind', p_pattern_kind,
      'primary_id', p_primary_id,
      'related_ids', to_jsonb(p_related_ids),
      'review_issue_id', v_review_issue_id
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','RAISED',
    'review_issue_id', v_review_issue_id,
    'pattern_kind', p_pattern_kind,
    'primary_id', p_primary_id
  );
END;
$$;


-- 4. record_duplicate_pattern_resolved ---------------------------------------

CREATE OR REPLACE FUNCTION public.record_duplicate_pattern_resolved(
  p_review_issue_id uuid,
  p_actor_user_id   uuid,
  p_resolution_kind text,
  p_context         jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid; v_business_id uuid;
  v_transaction_id  uuid; v_document_id  uuid;
  v_issue_type      text;
  v_subject_type    audit.subject_type_enum;
  v_subject_id      uuid;
BEGIN
  IF p_resolution_kind NOT IN (
    'confirmed_as_split_payment','rejected_one_match','marked_as_duplicate',
    'picked_right_match','marked_legitimate_multi_match','edited_matches'
  ) THEN
    RAISE EXCEPTION 'RESOLUTION_KIND_INVALID' USING errcode='check_violation';
  END IF;

  SELECT organization_id, business_id, transaction_id, document_id, issue_type
    INTO v_organization_id, v_business_id, v_transaction_id, v_document_id, v_issue_type
  FROM public.review_issues WHERE id = p_review_issue_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','REVIEW_ISSUE_NOT_FOUND','review_issue_id',p_review_issue_id);
  END IF;

  -- Pick subject by pattern shape (anchor)
  IF v_document_id IS NOT NULL AND v_issue_type = 'matching.document_used_multiple_times' THEN
    v_subject_type := 'DOCUMENT'::audit.subject_type_enum;
    v_subject_id   := v_document_id;
  ELSIF v_transaction_id IS NOT NULL THEN
    v_subject_type := 'TRANSACTION'::audit.subject_type_enum;
    v_subject_id   := v_transaction_id;
  ELSE
    v_subject_type := 'TRANSACTION'::audit.subject_type_enum;
    v_subject_id   := NULL;
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='MATCHING_DUPLICATE_PATTERN_RESOLVED',
    p_subject_type:=v_subject_type,
    p_subject_id:=v_subject_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:=NULL,
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'review_issue_id', p_review_issue_id,
      'issue_type', v_issue_type,
      'resolution_kind', p_resolution_kind
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','RECORDED',
    'review_issue_id', p_review_issue_id,
    'resolution_kind', p_resolution_kind
  );
END;
$$;


-- 5. Privileges --------------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.raise_duplicate_pattern_detected(uuid, uuid, text, uuid, uuid[], uuid, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_duplicate_pattern_resolved(uuid, uuid, text, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.raise_duplicate_pattern_detected(uuid, uuid, text, uuid, uuid[], uuid, uuid, jsonb) TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.record_duplicate_pattern_resolved(uuid, uuid, text, jsonb) TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.detect_duplicate_pattern_a(uuid, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.detect_duplicate_pattern_b(uuid, uuid) TO authenticated, service_role;
