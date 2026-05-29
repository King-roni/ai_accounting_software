-- B08·P02 — Layer 1 Rule Engine
--
-- Most of Layer 1 is Python predicate-matching logic. SQL ships:
--   1. Rule management RPCs (Owner-only via can_perform, Mitigation A)
--   2. Match-recording audit RPCs (no state mutation; B08·P09 writes transactions)
--   3. get_classification_rules_for_business helper (priority-ordered)
--   4. 6 default global rule seeds
--
-- Audit subject types: BUSINESS for rule-management events (business_id is the
-- subject; global rules use subject_id=NULL); TRANSACTION for match events.

-- ============================================================================
-- 1. upsert_classification_rule
-- ============================================================================
CREATE OR REPLACE FUNCTION public.upsert_classification_rule(
  p_actor_user_id    uuid,
  p_business_id      uuid,                              -- NULL for global rules
  p_rule_kind        public.classification_rule_kind_enum,
  p_rule_predicate   jsonb,
  p_assigned_type    public.transaction_type_enum,
  p_assigned_tag     text DEFAULT NULL,
  p_priority         int DEFAULT 100,
  p_rule_id          uuid DEFAULT NULL,                 -- if set, UPDATE; else INSERT
  p_organization_id  uuid DEFAULT NULL                  -- required when business_id NOT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_decision   text;
  v_can        jsonb;
  v_rule_id    uuid;
  v_action_audit text;
  v_audit_row  audit.audit_events;
  v_existing   public.classification_rules%ROWTYPE;
  v_business_resolved uuid;
  v_org_resolved uuid;
BEGIN
  IF p_rule_kind IS NULL OR p_rule_predicate IS NULL OR p_assigned_type IS NULL THEN
    RAISE EXCEPTION 'upsert_classification_rule: required params missing' USING ERRCODE='22000';
  END IF;
  IF jsonb_typeof(p_rule_predicate) <> 'object' THEN
    RAISE EXCEPTION 'upsert_classification_rule: rule_predicate must be an object' USING ERRCODE='22023';
  END IF;
  IF p_priority < 0 THEN
    RAISE EXCEPTION 'upsert_classification_rule: priority must be >= 0' USING ERRCODE='22023';
  END IF;
  IF (p_business_id IS NULL) <> (p_organization_id IS NULL) THEN
    RAISE EXCEPTION 'upsert_classification_rule: business_id and organization_id must both be set or both NULL'
      USING ERRCODE='22023';
  END IF;

  v_can := public.can_perform(
    p_actor_user_id, 'classification_rule',
    CASE WHEN p_rule_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
    jsonb_build_object(
      'business_id',  p_business_id,
      'rule_kind',    p_rule_kind::text,
      'assigned_type', p_assigned_type::text,
      'scope',        CASE WHEN p_business_id IS NULL THEN 'GLOBAL' ELSE 'BUSINESS' END),
    p_business_id, p_organization_id);
  v_decision := v_can->>'decision';
  IF v_decision <> 'ALLOW' THEN
    v_audit_row := audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum,
      p_action     => 'CLASSIFICATION_RULE_MUTATION_DENIED',
      p_subject_type => 'BUSINESS'::audit.subject_type_enum,
      p_subject_id   => p_business_id,
      p_actor_user_id => p_actor_user_id,
      p_organization_id => p_organization_id, p_business_id => p_business_id,
      p_reason => format('policy %s for %s classification rule', v_decision,
                         CASE WHEN p_rule_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END),
      p_after_state => jsonb_build_object('decision', v_decision,
        'rule_kind', p_rule_kind::text, 'rule_id', p_rule_id));
    RETURN jsonb_build_object('ok', false, 'reason', 'POLICY_DENIED',
      'decision', v_decision, 'audit_event_id', v_audit_row.id);
  END IF;

  IF p_rule_id IS NULL THEN
    v_rule_id := public.gen_uuid_v7();
    INSERT INTO public.classification_rules
      (id, organization_id, business_id, rule_kind, rule_predicate,
       assigned_type, assigned_tag, priority, enabled, created_at, updated_at, created_by_user_id)
    VALUES
      (v_rule_id, p_organization_id, p_business_id, p_rule_kind, p_rule_predicate,
       p_assigned_type, p_assigned_tag, p_priority, true,
       clock_timestamp(), clock_timestamp(), p_actor_user_id);
    v_action_audit := 'CLASSIFICATION_RULE_CREATED';
    v_business_resolved := p_business_id;
    v_org_resolved := p_organization_id;
  ELSE
    SELECT * INTO v_existing FROM public.classification_rules WHERE id = p_rule_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'upsert_classification_rule: rule % not found', p_rule_id USING ERRCODE='02000';
    END IF;
    UPDATE public.classification_rules
      SET rule_kind = p_rule_kind, rule_predicate = p_rule_predicate,
          assigned_type = p_assigned_type, assigned_tag = p_assigned_tag,
          priority = p_priority,
          updated_at = clock_timestamp()
      WHERE id = p_rule_id;
    v_rule_id := p_rule_id;
    v_action_audit := 'CLASSIFICATION_RULE_UPDATED';
    v_business_resolved := v_existing.business_id;
    v_org_resolved := v_existing.organization_id;
  END IF;

  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action     => v_action_audit,
    p_subject_type => 'BUSINESS'::audit.subject_type_enum,
    p_subject_id   => v_business_resolved,
    p_actor_user_id => p_actor_user_id,
    p_organization_id => v_org_resolved, p_business_id => v_business_resolved,
    p_after_state => jsonb_build_object(
      'rule_id',        v_rule_id,
      'business_id',    v_business_resolved,
      'scope',          CASE WHEN v_business_resolved IS NULL THEN 'GLOBAL' ELSE 'BUSINESS' END,
      'rule_kind',      p_rule_kind::text,
      'assigned_type',  p_assigned_type::text,
      'assigned_tag',   p_assigned_tag,
      'priority',       p_priority,
      'rule_predicate', p_rule_predicate),
    p_reason => format('classification rule %s: kind=%s type=%s priority=%s',
                       CASE WHEN p_rule_id IS NULL THEN 'created' ELSE 'updated' END,
                       p_rule_kind::text, p_assigned_type::text, p_priority));

  RETURN jsonb_build_object('ok', true,
    'rule_id', v_rule_id, 'audit_event_id', v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.upsert_classification_rule(uuid, uuid, public.classification_rule_kind_enum, jsonb, public.transaction_type_enum, text, int, uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.upsert_classification_rule(uuid, uuid, public.classification_rule_kind_enum, jsonb, public.transaction_type_enum, text, int, uuid, uuid) TO service_role;

-- ============================================================================
-- 2. disable_classification_rule
-- ============================================================================
CREATE OR REPLACE FUNCTION public.disable_classification_rule(
  p_actor_user_id uuid,
  p_rule_id       uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_rule public.classification_rules%ROWTYPE;
  v_can jsonb;
  v_decision text;
  v_audit_row audit.audit_events;
BEGIN
  IF p_rule_id IS NULL THEN
    RAISE EXCEPTION 'disable_classification_rule: p_rule_id is required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_rule FROM public.classification_rules WHERE id = p_rule_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'disable_classification_rule: rule % not found', p_rule_id USING ERRCODE='02000';
  END IF;
  IF NOT v_rule.enabled THEN
    RETURN jsonb_build_object('ok', true, 'idempotent_replay', true, 'rule_id', p_rule_id);
  END IF;

  v_can := public.can_perform(
    p_actor_user_id, 'classification_rule', 'DISABLE',
    jsonb_build_object('rule_id', p_rule_id, 'business_id', v_rule.business_id,
                       'scope', CASE WHEN v_rule.business_id IS NULL THEN 'GLOBAL' ELSE 'BUSINESS' END),
    v_rule.business_id, v_rule.organization_id);
  v_decision := v_can->>'decision';
  IF v_decision <> 'ALLOW' THEN
    v_audit_row := audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum,
      p_action     => 'CLASSIFICATION_RULE_MUTATION_DENIED',
      p_subject_type => 'BUSINESS'::audit.subject_type_enum,
      p_subject_id   => v_rule.business_id,
      p_actor_user_id => p_actor_user_id,
      p_organization_id => v_rule.organization_id, p_business_id => v_rule.business_id,
      p_reason => format('policy %s for DISABLE classification rule %s', v_decision, p_rule_id),
      p_after_state => jsonb_build_object('decision', v_decision, 'rule_id', p_rule_id));
    RETURN jsonb_build_object('ok', false, 'reason', 'POLICY_DENIED',
      'decision', v_decision, 'audit_event_id', v_audit_row.id);
  END IF;

  UPDATE public.classification_rules
    SET enabled = false, updated_at = clock_timestamp()
    WHERE id = p_rule_id;

  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action     => 'CLASSIFICATION_RULE_DISABLED',
    p_subject_type => 'BUSINESS'::audit.subject_type_enum,
    p_subject_id   => v_rule.business_id,
    p_actor_user_id => p_actor_user_id,
    p_organization_id => v_rule.organization_id, p_business_id => v_rule.business_id,
    p_after_state => jsonb_build_object(
      'rule_id', p_rule_id, 'business_id', v_rule.business_id,
      'rule_kind', v_rule.rule_kind::text,
      'scope', CASE WHEN v_rule.business_id IS NULL THEN 'GLOBAL' ELSE 'BUSINESS' END),
    p_reason => format('classification rule %s disabled', p_rule_id));

  RETURN jsonb_build_object('ok', true, 'rule_id', p_rule_id, 'audit_event_id', v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.disable_classification_rule(uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.disable_classification_rule(uuid, uuid) TO service_role;

-- ============================================================================
-- 3. record_classification_rule_matched
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_classification_rule_matched(
  p_transaction_id uuid,
  p_rule_id        uuid,
  p_confidence     numeric,
  p_actor_user_id  uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_rule public.classification_rules%ROWTYPE;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_transaction_id IS NULL OR p_rule_id IS NULL OR p_confidence IS NULL THEN
    RAISE EXCEPTION 'record_classification_rule_matched: required params missing' USING ERRCODE='22000';
  END IF;
  IF p_confidence < 0 OR p_confidence > 1 THEN
    RAISE EXCEPTION 'record_classification_rule_matched: confidence must be in [0,1] (got %)', p_confidence USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_classification_rule_matched: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;
  SELECT * INTO v_rule FROM public.classification_rules WHERE id = p_rule_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_classification_rule_matched: rule % not found', p_rule_id USING ERRCODE='02000';
  END IF;

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'classification_layer1';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'CLASSIFICATION_RULE_MATCHED',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id', p_transaction_id, 'rule_id', p_rule_id,
      'confidence', p_confidence,
      'rule_kind', v_rule.rule_kind::text,
      'assigned_type', v_rule.assigned_type::text,
      'assigned_tag', v_rule.assigned_tag,
      'rule_scope', CASE WHEN v_rule.business_id IS NULL THEN 'GLOBAL' ELSE 'BUSINESS' END),
    p_reason => format('classification rule matched: tx=%s rule=%s confidence=%s',
                       p_transaction_id, p_rule_id, p_confidence));
  RETURN jsonb_build_object('ok', true,
    'transaction_id', p_transaction_id, 'rule_id', p_rule_id,
    'assigned_type', v_rule.assigned_type::text,
    'audit_event_id', v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_classification_rule_matched(uuid, uuid, numeric, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_classification_rule_matched(uuid, uuid, numeric, uuid) TO service_role;

-- ============================================================================
-- 4. record_classification_rule_conflict
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_classification_rule_conflict(
  p_transaction_id        uuid,
  p_workflow_run_id       uuid,
  p_conflicting_rule_ids  uuid[],
  p_actor_user_id         uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_review_id uuid := public.gen_uuid_v7();
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_transaction_id IS NULL OR p_workflow_run_id IS NULL OR p_conflicting_rule_ids IS NULL THEN
    RAISE EXCEPTION 'record_classification_rule_conflict: required params missing' USING ERRCODE='22000';
  END IF;
  IF COALESCE(array_length(p_conflicting_rule_ids, 1), 0) < 2 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'INSUFFICIENT_CONFLICTING_RULES',
      'conflicting_count', COALESCE(array_length(p_conflicting_rule_ids, 1), 0));
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_classification_rule_conflict: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;

  INSERT INTO public.review_issues
    (id, organization_id, business_id, workflow_run_id, transaction_id,
     issue_type, issue_group, severity,
     plain_language_title, plain_language_description,
     card_payload_json, card_content_tier_used, card_content_fallback_applied,
     status, created_at, updated_at)
  VALUES
    (v_review_id, v_tx.organization_id, v_tx.business_id, p_workflow_run_id, p_transaction_id,
     'classification.rule_conflict',
     'POSSIBLE_WRONG_MATCH'::public.review_issue_group_enum,
     'MEDIUM'::public.review_issue_severity_enum,
     'Conflicting classification rules matched this transaction',
     format('Multiple classification rules matched this transaction with different assigned types. The transaction will not be auto-classified until you resolve the conflict — review the matched rules and choose which one applies.'),
     jsonb_build_object(
       'transaction_id',         p_transaction_id,
       'conflicting_rule_ids',   to_jsonb(p_conflicting_rule_ids),
       'conflicting_rule_count', array_length(p_conflicting_rule_ids, 1)),
     'NONE'::public.review_issue_card_content_tier_enum, false,
     'OPEN'::public.review_issue_status_enum,
     clock_timestamp(), clock_timestamp());

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'classification_layer1';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'CLASSIFICATION_RULE_CONFLICT',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object(
      'transaction_id',       p_transaction_id,
      'review_issue_id',      v_review_id,
      'conflicting_rule_ids', to_jsonb(p_conflicting_rule_ids)),
    p_reason => format('classification rule conflict on tx %s: %s rules',
                       p_transaction_id, array_length(p_conflicting_rule_ids, 1)));

  RETURN jsonb_build_object('ok', true,
    'transaction_id', p_transaction_id,
    'review_issue_id', v_review_id,
    'audit_event_id', v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_classification_rule_conflict(uuid, uuid, uuid[], uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_classification_rule_conflict(uuid, uuid, uuid[], uuid) TO service_role;

-- ============================================================================
-- 5. record_classification_rule_no_match  (silent telemetry)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_classification_rule_no_match(
  p_transaction_id uuid,
  p_actor_user_id  uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_transaction_id IS NULL THEN
    RAISE EXCEPTION 'record_classification_rule_no_match: p_transaction_id is required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_transaction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_classification_rule_no_match: transaction % not found', p_transaction_id USING ERRCODE='02000';
  END IF;
  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'classification_layer1';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'CLASSIFICATION_RULE_NO_MATCH',
    p_subject_type => 'TRANSACTION'::audit.subject_type_enum,
    p_subject_id => p_transaction_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_tx.organization_id, p_business_id => v_tx.business_id,
    p_after_state => jsonb_build_object('transaction_id', p_transaction_id),
    p_reason => format('classification layer 1 found no matching rule for tx %s', p_transaction_id));
  RETURN jsonb_build_object('ok', true,
    'transaction_id', p_transaction_id, 'audit_event_id', v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_classification_rule_no_match(uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_classification_rule_no_match(uuid, uuid) TO service_role;

-- ============================================================================
-- 6. get_classification_rules_for_business  (priority-ordered)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_classification_rules_for_business(
  p_business_id uuid
) RETURNS SETOF public.classification_rules
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT *
  FROM public.classification_rules
  WHERE enabled = true
    AND (business_id IS NULL OR business_id = p_business_id)
  ORDER BY priority ASC, created_at ASC;
$function$;

REVOKE ALL ON FUNCTION public.get_classification_rules_for_business(uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.get_classification_rules_for_business(uuid) TO service_role;

-- ============================================================================
-- 7. Default global rule seeds
-- ============================================================================
INSERT INTO public.classification_rules
  (organization_id, business_id, rule_kind, rule_predicate, assigned_type, assigned_tag, priority, enabled)
VALUES
  -- Same-business own-account transfers (detected when both sides are same-biz bank_accounts)
  (NULL, NULL, 'OWN_ACCOUNT_TRANSFER'::public.classification_rule_kind_enum,
   jsonb_build_object('detection','same_business_bank_account',
                      'description','Both bank accounts owned by the same business → internal transfer'),
   'INTERNAL_TRANSFER'::public.transaction_type_enum, 'Internal transfer', 5, true),

  -- Revolut fee descriptions
  (NULL, NULL, 'REGEX_DESCRIPTION'::public.classification_rule_kind_enum,
   jsonb_build_object('pattern','^(Fee|Revolut Fee|Card replacement)',
                      'flags','i',
                      'description','Revolut fee-line descriptions'),
   'BANK_FEE'::public.transaction_type_enum, 'Bank fee', 10, true),

  -- FX exchange — corroborates the normalizer's transaction_type_candidate=FX_EXCHANGE
  (NULL, NULL, 'REGEX_DESCRIPTION'::public.classification_rule_kind_enum,
   jsonb_build_object('pattern','EXCHANGE|Exchanged to',
                      'requires','fx_paired_legs_not_null',
                      'description','FX exchange paired-leg markers'),
   'FX_EXCHANGE'::public.transaction_type_enum, 'Currency exchange', 10, true),

  -- Known supplier domain → outgoing expense
  (NULL, NULL, 'COUNTERPARTY_DOMAIN'::public.classification_rule_kind_enum,
   jsonb_build_object('registry','known_suppliers',
                      'amount_sign','negative',
                      'description','Counterparty domain in the curated supplier registry'),
   'OUT_EXPENSE'::public.transaction_type_enum, NULL, 20, true),

  -- Known client domain → incoming income
  (NULL, NULL, 'COUNTERPARTY_DOMAIN'::public.classification_rule_kind_enum,
   jsonb_build_object('registry','known_clients',
                      'amount_sign','positive',
                      'description','Counterparty domain in the curated client registry'),
   'IN_INCOME'::public.transaction_type_enum, NULL, 20, true),

  -- Tax authority counterparties (curated list per country; Cyprus first)
  (NULL, NULL, 'COUNTERPARTY_NAME'::public.classification_rule_kind_enum,
   jsonb_build_object('registry','tax_authorities',
                      'countries', jsonb_build_array('CY'),
                      'description','Tax authority name matches (Cyprus + future jurisdictions)'),
   'TAX_PAYMENT'::public.transaction_type_enum, 'Tax payment', 8, true)
ON CONFLICT DO NOTHING;
