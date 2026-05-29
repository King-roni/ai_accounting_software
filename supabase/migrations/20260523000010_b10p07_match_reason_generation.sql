-- B10·P07 — Match Reason Generation — DB scaffold.
-- 2 prompt seeds + IMMUTABLE fallback helper + 3 RPCs to apply/regenerate/
-- fallback the plain-language reason. Python orchestrator owns the actual
-- B06 plain-language AI call + cache; this phase just records results,
-- emits audits, and provides the deterministic fallback when AI fails.
--
-- Audit family additions (4):
--   MATCHING_REASON_GENERATED       (MATCH_RECORD subject; SYSTEM actor)
--   MATCHING_REASON_CACHE_HIT       (MATCH_RECORD subject; SYSTEM actor)
--   MATCHING_REASON_REGENERATED     (MATCH_RECORD subject; USER actor)
--   MATCHING_REASON_FALLBACK_APPLIED (MATCH_RECORD subject; SYSTEM actor)

-- 1. Prompt seeds ------------------------------------------------------------

INSERT INTO public.prompt_registry (
  prompt_id, version, purpose, input_schema, output_schema, ai_tier,
  prompt_template_text, content_hash, registered_by_user_id
) VALUES
  (
    'matching.generate_reason.tier2',
    '0.1.0-placeholder',
    'Generate a plain-language explanation of why a transaction and a document were matched (Tier 2 default path).',
    jsonb_build_object('match_level','string','score_breakdown','object','decision_factors','array','transaction_summary','object','document_summary','object'),
    jsonb_build_object('reason_text','string(max 300 chars)'),
    'LOCAL_LLM',
    '/* placeholder - filled in Stage-6 */',
    encode(sha256('matching.generate_reason.tier2:0.1.0-placeholder'::bytea), 'hex'),
    NULL
  ),
  (
    'matching.generate_reason.tier3',
    '0.1.0-placeholder',
    'Generate a plain-language explanation for ambiguous or complex matches (Tier 3 escalation: cross-currency / cross-period / 2+ ambiguous signals).',
    jsonb_build_object('match_level','string','score_breakdown','object','decision_factors','array','cross_currency','object?','cross_period','object?','transaction_summary','object','document_summary','object'),
    jsonb_build_object('reason_text','string(max 300 chars)'),
    'EXTERNAL_LLM',
    '/* placeholder - filled in Stage-6 */',
    encode(sha256('matching.generate_reason.tier3:0.1.0-placeholder'::bytea), 'hex'),
    NULL
  )
ON CONFLICT DO NOTHING;


-- 2. build_match_reason_fallback (deterministic) ----------------------------

CREATE OR REPLACE FUNCTION public.build_match_reason_fallback(
  p_match_level       public.match_level_enum,
  p_decision_factors  text[]
)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
  SELECT
    CASE p_match_level
      WHEN 'EXACT'           THEN 'Exact match. '
      WHEN 'STRONG_PROBABLE' THEN 'Strong probable match. '
      WHEN 'WEAK_POSSIBLE'   THEN 'Possible match. '
    END
    || 'Decision factors: '
    || CASE
         WHEN p_decision_factors IS NULL OR array_length(p_decision_factors, 1) IS NULL
         THEN 'none recorded'
         ELSE array_to_string(p_decision_factors, ', ')
       END
    || '. Plain-language summary unavailable; structured signals only.';
$$;


-- 3. apply_match_reason ------------------------------------------------------

CREATE OR REPLACE FUNCTION public.apply_match_reason(
  p_match_record_id        uuid,
  p_signal_breakdown_full  jsonb,
  p_plain_language_reason  text,
  p_tier                   text,
  p_was_cache_hit          boolean DEFAULT false,
  p_context                jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid; v_business_id uuid;
BEGIN
  IF p_tier NOT IN ('tier2','tier3','deterministic_fallback') THEN
    RAISE EXCEPTION 'TIER_INVALID' USING errcode='check_violation';
  END IF;
  IF p_signal_breakdown_full IS NULL OR jsonb_typeof(p_signal_breakdown_full) <> 'object' THEN
    RAISE EXCEPTION 'SIGNAL_BREAKDOWN_MUST_BE_OBJECT' USING errcode='check_violation';
  END IF;

  SELECT organization_id, business_id INTO v_organization_id, v_business_id
  FROM public.match_records WHERE id = p_match_record_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','MATCH_RECORD_NOT_FOUND','match_record_id',p_match_record_id);
  END IF;

  UPDATE public.match_records
    SET match_signals = p_signal_breakdown_full,
        match_reason_plain_language = p_plain_language_reason,
        updated_at = clock_timestamp()
  WHERE id = p_match_record_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='MATCHING_REASON_GENERATED',
    p_subject_type:='MATCH_RECORD'::audit.subject_type_enum,
    p_subject_id:=p_match_record_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='matching_engine',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'tier', p_tier,
      'was_cache_hit', p_was_cache_hit,
      'reason_length', length(COALESCE(p_plain_language_reason, ''))
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  IF p_was_cache_hit THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='MATCHING_REASON_CACHE_HIT',
      p_subject_type:='MATCH_RECORD'::audit.subject_type_enum,
      p_subject_id:=p_match_record_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='matching_engine',
      p_organization_id:=v_organization_id, p_business_id:=v_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('tier', p_tier),
      p_reason:=NULL, p_request_context:=p_context
    );
  END IF;

  RETURN jsonb_build_object(
    'decision','APPLIED', 'match_record_id', p_match_record_id,
    'tier', p_tier, 'was_cache_hit', p_was_cache_hit
  );
END;
$$;


-- 4. regenerate_match_reason -------------------------------------------------

CREATE OR REPLACE FUNCTION public.regenerate_match_reason(
  p_match_record_id          uuid,
  p_new_signal_breakdown     jsonb,
  p_new_plain_language_reason text,
  p_tier                     text,
  p_actor_user_id            uuid,
  p_context                  jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid; v_business_id uuid;
  v_old_signals jsonb; v_old_reason text;
BEGIN
  IF p_tier NOT IN ('tier2','tier3','deterministic_fallback') THEN
    RAISE EXCEPTION 'TIER_INVALID' USING errcode='check_violation';
  END IF;
  IF p_new_signal_breakdown IS NULL OR jsonb_typeof(p_new_signal_breakdown) <> 'object' THEN
    RAISE EXCEPTION 'SIGNAL_BREAKDOWN_MUST_BE_OBJECT' USING errcode='check_violation';
  END IF;

  SELECT organization_id, business_id, match_signals, match_reason_plain_language
    INTO v_organization_id, v_business_id, v_old_signals, v_old_reason
  FROM public.match_records WHERE id = p_match_record_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','MATCH_RECORD_NOT_FOUND','match_record_id',p_match_record_id);
  END IF;

  UPDATE public.match_records
    SET match_signals = p_new_signal_breakdown,
        match_reason_plain_language = p_new_plain_language_reason,
        updated_at = clock_timestamp()
  WHERE id = p_match_record_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='MATCHING_REASON_REGENERATED',
    p_subject_type:='MATCH_RECORD'::audit.subject_type_enum,
    p_subject_id:=p_match_record_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:=NULL,
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=jsonb_build_object(
      'old_signals', v_old_signals,
      'old_plain_language_reason', v_old_reason
    ),
    p_after_state:=jsonb_build_object(
      'tier', p_tier,
      'new_plain_language_reason', p_new_plain_language_reason,
      'reason_length', length(COALESCE(p_new_plain_language_reason, ''))
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','REGENERATED','match_record_id', p_match_record_id,
    'old_plain_language_reason', v_old_reason,
    'new_plain_language_reason', p_new_plain_language_reason
  );
END;
$$;


-- 5. apply_match_reason_fallback ---------------------------------------------

CREATE OR REPLACE FUNCTION public.apply_match_reason_fallback(
  p_match_record_id   uuid,
  p_failure_category  text,
  p_workflow_run_id   uuid,
  p_actor_user_id     uuid    DEFAULT NULL,
  p_context           jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid; v_business_id uuid;
  v_transaction_id  uuid; v_match_level public.match_level_enum;
  v_existing_signals jsonb;
  v_decision_factors text[];
  v_fallback_text   text;
  v_review_issue_id uuid;
BEGIN
  IF p_failure_category NOT IN ('AI_TIMEOUT','AI_SCHEMA_VALIDATION_FAILED','AI_RATE_LIMITED','AI_OTHER') THEN
    RAISE EXCEPTION 'FAILURE_CATEGORY_INVALID' USING errcode='check_violation';
  END IF;

  SELECT organization_id, business_id, transaction_id, match_level, match_signals
    INTO v_organization_id, v_business_id, v_transaction_id, v_match_level, v_existing_signals
  FROM public.match_records WHERE id = p_match_record_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','MATCH_RECORD_NOT_FOUND','match_record_id',p_match_record_id);
  END IF;

  -- Pull decision_factors from existing match_signals if present
  IF v_existing_signals ? 'decision_factors'
     AND jsonb_typeof(v_existing_signals->'decision_factors') = 'array' THEN
    SELECT array_agg(value::text) INTO v_decision_factors
    FROM jsonb_array_elements_text(v_existing_signals->'decision_factors');
  END IF;

  v_fallback_text := public.build_match_reason_fallback(v_match_level, v_decision_factors);

  UPDATE public.match_records
    SET match_reason_plain_language = v_fallback_text,
        updated_at = clock_timestamp()
  WHERE id = p_match_record_id;

  -- LOW-severity review_issue with a "Regenerate" recommended action
  INSERT INTO public.review_issues (
    organization_id, business_id, workflow_run_id,
    transaction_id, match_record_id,
    issue_type, issue_group, severity,
    plain_language_title, plain_language_description, recommended_action,
    card_payload_json
  ) VALUES (
    v_organization_id, v_business_id, p_workflow_run_id,
    v_transaction_id, p_match_record_id,
    'matching.reason_fallback_applied',
    'POSSIBLE_WRONG_MATCH'::public.review_issue_group_enum,
    'LOW'::public.review_issue_severity_enum,
    'Plain-language match reason fallback used',
    'The AI explanation step failed; the match details are still recorded but the user-friendly summary is a placeholder. You can ask the system to re-try the explanation.',
    'Regenerate the plain-language reason',
    jsonb_build_object(
      'failure_category', p_failure_category,
      'match_record_id', p_match_record_id,
      'fallback_text', v_fallback_text
    )
  ) RETURNING id INTO v_review_issue_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='MATCHING_REASON_FALLBACK_APPLIED',
    p_subject_type:='MATCH_RECORD'::audit.subject_type_enum,
    p_subject_id:=p_match_record_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='matching_engine',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'failure_category', p_failure_category,
      'fallback_text', v_fallback_text,
      'review_issue_id', v_review_issue_id,
      'decision_factors', to_jsonb(v_decision_factors)
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','FALLBACK_APPLIED',
    'match_record_id', p_match_record_id,
    'failure_category', p_failure_category,
    'review_issue_id', v_review_issue_id,
    'fallback_text', v_fallback_text
  );
END;
$$;


-- 6. Privileges --------------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.apply_match_reason(uuid, jsonb, text, text, boolean, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.regenerate_match_reason(uuid, jsonb, text, text, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.apply_match_reason_fallback(uuid, text, uuid, uuid, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.apply_match_reason(uuid, jsonb, text, text, boolean, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.regenerate_match_reason(uuid, jsonb, text, text, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.apply_match_reason_fallback(uuid, text, uuid, uuid, jsonb) TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.build_match_reason_fallback(public.match_level_enum, text[]) TO authenticated, service_role, anon;
