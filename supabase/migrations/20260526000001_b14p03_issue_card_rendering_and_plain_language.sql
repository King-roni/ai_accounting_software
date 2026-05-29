-- B14·P03 — Issue Card Rendering & Plain-Language Consumption
-- =====================================================================
-- Block 14-internal helpers that producing blocks invoke at issue-creation
-- time to populate the card-content columns. Real AI calls live app-layer;
-- DB-side stub writes deterministic text capturing structured signals.
-- =====================================================================

-- 1. Length CHECKs (review_issues is empty → validates immediately) -----

ALTER TABLE public.review_issues
  ADD CONSTRAINT review_issues_plain_lang_title_chk
    CHECK (plain_language_title IS NULL OR length(plain_language_title) <= 80);
ALTER TABLE public.review_issues
  ADD CONSTRAINT review_issues_plain_lang_description_chk
    CHECK (plain_language_description IS NULL OR length(plain_language_description) <= 300);
ALTER TABLE public.review_issues
  ADD CONSTRAINT review_issues_recommended_action_chk
    CHECK (recommended_action IS NULL OR length(recommended_action) <= 120);


-- 2. Register review_queue.card_content_default prompt -----------------

INSERT INTO public.prompt_registry (
  prompt_id, version, purpose,
  input_schema, output_schema, ai_tier,
  prompt_template_text, content_hash,
  registered_at, registered_by_user_id
) VALUES (
  'review_queue.card_content_default', '0.1.0-stage1',
  'B14·P03 canonical card-content prompt — generates title/description/recommended_action for any review_issue from structured signals.',
  jsonb_build_object(
    'type','object',
    'required', ARRAY['issue_type','issue_group','severity','allowed_resolution_actions','structured_signals'],
    'properties', jsonb_build_object(
      'issue_type', jsonb_build_object('type','string'),
      'issue_group', jsonb_build_object('type','string'),
      'severity', jsonb_build_object('type','string'),
      'allowed_resolution_actions', jsonb_build_object('type','array'),
      'structured_signals', jsonb_build_object('type','object'))),
  jsonb_build_object(
    'type','object',
    'required', ARRAY['plain_language_title','plain_language_description','recommended_action'],
    'properties', jsonb_build_object(
      'plain_language_title', jsonb_build_object('type','string','maxLength',80),
      'plain_language_description', jsonb_build_object('type','string','maxLength',300),
      'recommended_action', jsonb_build_object('type','string','maxLength',120))),
  'LOCAL_LLM'::public.ai_tier_enum,
  'B14·P03 card-content prompt — Stage-4 refines template; pipeline lives app-layer (Block 06 P10).',
  encode(extensions.digest('b14p03_card_content_default_v1_2026-05-26', 'sha256'), 'hex'),
  clock_timestamp(), NULL
);

UPDATE public.issue_type_registry
   SET plain_language_template_ref = 'review_queue.card_content_default'
 WHERE plain_language_template_ref IS NULL;

SELECT public.register_issue_type(
  'review_queue.card_content_unavailable',
  'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
  'LOW'::public.review_issue_severity_enum,
  ARRAY['REGENERATE_CARD_CONTENT','ACKNOWLEDGE'],
  'review_queue',
  'review_queue.card_content_default'
);


-- 3. _compute_card_content_tier ----------------------------------------

CREATE OR REPLACE FUNCTION public._compute_card_content_tier(p_issue_id uuid)
RETURNS public.review_issue_card_content_tier_enum
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_issue record;
  v_open_count int;
  v_biz_currency text;
  v_txn_currency text;
BEGIN
  SELECT id, severity, transaction_id, business_id, status
    INTO v_issue
    FROM public.review_issues
   WHERE id = p_issue_id;
  IF NOT FOUND THEN RETURN 'TIER_2_LOCAL_LLM'::public.review_issue_card_content_tier_enum; END IF;

  IF v_issue.severity = 'BLOCKING'::public.review_issue_severity_enum THEN
    RETURN 'TIER_3_EXTERNAL_LLM'::public.review_issue_card_content_tier_enum;
  END IF;

  IF v_issue.transaction_id IS NOT NULL THEN
    SELECT count(*) INTO v_open_count FROM public.review_issues
     WHERE transaction_id = v_issue.transaction_id
       AND status = 'OPEN'::public.review_issue_status_enum;
    IF v_open_count >= 2 THEN
      RETURN 'TIER_3_EXTERNAL_LLM'::public.review_issue_card_content_tier_enum;
    END IF;
  END IF;

  IF v_issue.transaction_id IS NOT NULL THEN
    SELECT t.currency INTO v_txn_currency FROM public.transactions t WHERE t.id = v_issue.transaction_id;
    BEGIN
      EXECUTE 'SELECT default_currency FROM public.business_entities WHERE id = $1'
        INTO v_biz_currency USING v_issue.business_id;
    EXCEPTION WHEN undefined_column THEN v_biz_currency := NULL;
    END;
    IF v_biz_currency IS NOT NULL AND v_txn_currency IS NOT NULL AND v_txn_currency <> v_biz_currency THEN
      RETURN 'TIER_3_EXTERNAL_LLM'::public.review_issue_card_content_tier_enum;
    END IF;
  END IF;

  RETURN 'TIER_2_LOCAL_LLM'::public.review_issue_card_content_tier_enum;
END;
$$;


-- 4. generate_and_persist_card_content ---------------------------------

CREATE OR REPLACE FUNCTION public.generate_and_persist_card_content(
  p_issue_id            uuid,
  p_simulate_ai_failure boolean DEFAULT false,
  p_actor_system        text    DEFAULT 'review_queue',
  p_context             jsonb   DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_issue   record;
  v_reg     record;
  v_tier    public.review_issue_card_content_tier_enum;
  v_title   text;
  v_desc    text;
  v_action  text;
BEGIN
  SELECT id, organization_id, business_id, transaction_id, document_id, match_record_id,
         draft_ledger_entry_id, invoice_id, client_id, issue_type, issue_group, severity,
         card_payload_json, status
    INTO v_issue
    FROM public.review_issues WHERE id = p_issue_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'generate_and_persist_card_content: issue % not found', p_issue_id USING ERRCODE='02000';
  END IF;

  SELECT issue_type, default_group, default_severity, allowed_resolution_actions,
         producing_block, plain_language_template_ref
    INTO v_reg
    FROM public.issue_type_registry WHERE issue_type = v_issue.issue_type;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'generate_and_persist_card_content: issue_type % not in registry', v_issue.issue_type USING ERRCODE='23503';
  END IF;

  IF p_simulate_ai_failure THEN
    RETURN public.handle_card_content_failure(p_issue_id, 'simulated', p_context);
  END IF;

  v_tier := public._compute_card_content_tier(p_issue_id);

  v_title  := left(format('%s on %s', v_issue.issue_group::text, v_reg.producing_block), 80);
  v_desc   := left(format(
    'Issue %s (%s). Severity %s. Bucket: %s. Producing block: %s. Generated by %s pipeline.',
    v_issue.issue_type, v_reg.plain_language_template_ref, v_issue.severity::text,
    v_issue.issue_group::text, v_reg.producing_block, v_tier::text), 300);
  v_action := left(
    COALESCE(v_reg.allowed_resolution_actions[1], 'ACKNOWLEDGE') ||
    CASE WHEN v_issue.transaction_id IS NOT NULL
         THEN ' for transaction ' || substr(v_issue.transaction_id::text, 1, 8)
         ELSE '' END, 120);

  UPDATE public.review_issues
     SET plain_language_title         = v_title,
         plain_language_description   = v_desc,
         recommended_action           = v_action,
         card_content_generated_at    = clock_timestamp(),
         card_content_tier_used       = v_tier,
         card_content_fallback_applied = false,
         updated_at                   = clock_timestamp()
   WHERE id = p_issue_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='REVIEW_CARD_CONTENT_GENERATED',
    p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
    p_subject_id:=p_issue_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:=p_actor_system,
    p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'tier_used', v_tier::text,
      'fallback_applied', false,
      'title_len', length(v_title),
      'description_len', length(v_desc),
      'recommended_action_len', length(v_action)),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'decision','ALLOW',
    'tier_used', v_tier::text,
    'was_fallback', false,
    'issue_id', p_issue_id);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.generate_and_persist_card_content(uuid, boolean, text, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.generate_and_persist_card_content(uuid, boolean, text, jsonb) TO service_role;


-- 5. handle_card_content_failure ---------------------------------------

CREATE OR REPLACE FUNCTION public.handle_card_content_failure(
  p_issue_id         uuid,
  p_failure_category text,
  p_context          jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_issue        record;
  v_reg          record;
  v_title        text;
  v_desc         text;
  v_action       text;
  v_followup_id  uuid;
  v_existing_followup_id uuid;
BEGIN
  IF p_failure_category IS NULL OR length(trim(p_failure_category)) = 0 THEN
    RAISE EXCEPTION 'handle_card_content_failure: failure_category required' USING ERRCODE='22023';
  END IF;

  SELECT id, organization_id, business_id, transaction_id, document_id, match_record_id,
         draft_ledger_entry_id, invoice_id, client_id, issue_type, issue_group, severity
    INTO v_issue FROM public.review_issues WHERE id = p_issue_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'handle_card_content_failure: issue % not found', p_issue_id USING ERRCODE='02000';
  END IF;

  SELECT issue_type, allowed_resolution_actions, producing_block
    INTO v_reg FROM public.issue_type_registry WHERE issue_type = v_issue.issue_type;

  v_title  := left(format('%s on issue %s', v_issue.issue_group::text,
                          substr(p_issue_id::text, 1, 8)), 80);
  v_desc   := left(format(
    'Structured signals: issue_type=%s severity=%s. Plain-language summary unavailable; see expand for details.',
    v_issue.issue_type, v_issue.severity::text), 300);
  v_action := left(
    COALESCE((v_reg.allowed_resolution_actions)[1], 'ACKNOWLEDGE'), 120);

  UPDATE public.review_issues
     SET plain_language_title         = v_title,
         plain_language_description   = v_desc,
         recommended_action           = v_action,
         card_content_generated_at    = clock_timestamp(),
         card_content_tier_used       = 'NONE'::public.review_issue_card_content_tier_enum,
         card_content_fallback_applied = true,
         updated_at                   = clock_timestamp()
   WHERE id = p_issue_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='REVIEW_CARD_CONTENT_FALLBACK_APPLIED',
    p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
    p_subject_id:=p_issue_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='review_queue_fallback',
    p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'failure_category', p_failure_category,
      'tier_used', 'NONE',
      'fallback_applied', true),
    p_reason:=NULL, p_request_context:=p_context);

  SELECT id INTO v_existing_followup_id
    FROM public.review_issues
   WHERE auto_resolution_trigger_issue_id = p_issue_id
     AND issue_type = 'review_queue.card_content_unavailable'
     AND status = 'OPEN'::public.review_issue_status_enum
   LIMIT 1;

  IF v_existing_followup_id IS NOT NULL THEN
    UPDATE public.review_issues
       SET card_payload_json = jsonb_set(
             COALESCE(card_payload_json, '{}'::jsonb),
             '{failure_category}', to_jsonb(p_failure_category)),
           card_content_generated_at = clock_timestamp(),
           updated_at = clock_timestamp()
     WHERE id = v_existing_followup_id;
    v_followup_id := v_existing_followup_id;
  ELSE
    INSERT INTO public.review_issues (
      organization_id, business_id, workflow_run_id,
      transaction_id, document_id, match_record_id, draft_ledger_entry_id,
      invoice_id, client_id,
      issue_type, issue_group, severity,
      plain_language_title, plain_language_description, recommended_action,
      card_payload_json, card_content_generated_at,
      card_content_tier_used, card_content_fallback_applied,
      status, auto_resolution_trigger_issue_id
    ) VALUES (
      v_issue.organization_id, v_issue.business_id,
      (SELECT workflow_run_id FROM public.review_issues WHERE id = p_issue_id),
      v_issue.transaction_id, v_issue.document_id, v_issue.match_record_id, v_issue.draft_ledger_entry_id,
      v_issue.invoice_id, v_issue.client_id,
      'review_queue.card_content_unavailable',
      'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
      'LOW'::public.review_issue_severity_enum,
      'Card content unavailable',
      'Plain-language summary could not be generated. Click Regenerate to retry.',
      'REGENERATE_CARD_CONTENT',
      jsonb_build_object('failure_category', p_failure_category, 'primary_issue_id', p_issue_id),
      clock_timestamp(),
      'NONE'::public.review_issue_card_content_tier_enum,
      true,
      'OPEN'::public.review_issue_status_enum,
      p_issue_id
    ) RETURNING id INTO v_followup_id;
  END IF;

  RETURN jsonb_build_object(
    'decision','ALLOW',
    'tier_used','NONE',
    'was_fallback', true,
    'failure_category', p_failure_category,
    'issue_id', p_issue_id,
    'followup_issue_id', v_followup_id,
    'followup_was_new', v_existing_followup_id IS NULL);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.handle_card_content_failure(uuid, text, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.handle_card_content_failure(uuid, text, jsonb) TO service_role;


-- 6. regenerate_card_content (user-facing) -----------------------------

CREATE OR REPLACE FUNCTION public.regenerate_card_content(
  p_actor_user_id uuid,
  p_issue_id      uuid,
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_issue   record;
  v_perm    jsonb;
  v_before  record;
  v_gen     jsonb;
BEGIN
  SELECT id, organization_id, business_id, plain_language_title,
         plain_language_description, recommended_action,
         card_content_tier_used, card_content_fallback_applied, status
    INTO v_issue FROM public.review_issues WHERE id = p_issue_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','ISSUE_NOT_FOUND');
  END IF;

  v_perm := public.can_perform(p_actor_user_id, 'REVIEW_REGENERATE', 'EXECUTE',
                               '{}'::jsonb, v_issue.business_id, v_issue.organization_id);
  IF (v_perm->>'decision') <> 'ALLOW' THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum,
      p_action:='REVIEW_CARD_CONTENT_REGENERATE_DENIED',
      p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
      p_subject_id:=p_issue_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('reason_code', v_perm->>'reason_code'),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code', v_perm->>'reason_code');
  END IF;

  v_before := v_issue;
  v_gen := public.generate_and_persist_card_content(p_issue_id, false, 'review_queue_regenerate', p_context);

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='REVIEW_CARD_CONTENT_REGENERATED',
    p_subject_type:='REVIEW_ISSUE'::audit.subject_type_enum,
    p_subject_id:=p_issue_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_issue.organization_id, p_business_id:=v_issue.business_id,
    p_before_state:=jsonb_build_object(
      'plain_language_title', v_before.plain_language_title,
      'plain_language_description', v_before.plain_language_description,
      'recommended_action', v_before.recommended_action,
      'card_content_tier_used', v_before.card_content_tier_used::text,
      'card_content_fallback_applied', v_before.card_content_fallback_applied),
    p_after_state:=jsonb_build_object(
      'tier_used', v_gen->>'tier_used',
      'was_fallback', (v_gen->>'was_fallback')::boolean),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'decision','ALLOW',
    'tier_used', v_gen->>'tier_used',
    'was_fallback', (v_gen->>'was_fallback')::boolean,
    'issue_id', p_issue_id);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.regenerate_card_content(uuid, uuid, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.regenerate_card_content(uuid, uuid, jsonb) TO service_role, authenticated;


-- 7. v_review_issue_card view ------------------------------------------

CREATE OR REPLACE VIEW public.v_review_issue_card AS
  SELECT
    ri.id,
    ri.organization_id, ri.business_id, ri.workflow_run_id,
    ri.transaction_id, ri.document_id, ri.match_record_id,
    ri.draft_ledger_entry_id, ri.invoice_id, ri.client_id,
    ri.issue_type, ri.issue_group, ri.severity, ri.status,
    ri.plain_language_title, ri.plain_language_description, ri.recommended_action,
    ri.card_payload_json,
    ri.card_content_generated_at, ri.card_content_tier_used, ri.card_content_fallback_applied,
    ri.assigned_to, ri.assigned_at, ri.assigned_by,
    ri.snoozed_at, ri.snoozed_until, ri.snooze_reason,
    ri.created_at, ri.updated_at,
    ri.resolved_at, ri.resolved_by, ri.resolution_action, ri.resolution_note,
    ri.auto_resolution_trigger_issue_id,
    itr.producing_block,
    itr.plain_language_template_ref,
    itr.allowed_resolution_actions,
    itr.default_severity,
    itr.default_group
  FROM public.review_issues ri
  LEFT JOIN public.issue_type_registry itr ON itr.issue_type = ri.issue_type;

COMMENT ON VIEW public.v_review_issue_card IS
  'B14·P03 denormalized read model: review_issues joined to issue_type_registry. UI reads card content + producing block + allowed_resolution_actions from this view.';
