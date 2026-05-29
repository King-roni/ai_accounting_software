-- B11·P04 follow-up — review_issues.workflow_run_id is NOT NULL; the resolver
-- needs workflow_run_id to create review issues. Re-creates resolve_counterparty
-- with workflow_run_id as a required param.

BEGIN;

DROP FUNCTION IF EXISTS public.resolve_counterparty(uuid, uuid, uuid, uuid, text, text, text, char(2), uuid, jsonb);

CREATE OR REPLACE FUNCTION public.resolve_counterparty(
  p_organization_id uuid, p_business_id uuid,
  p_transaction_id uuid,
  p_workflow_run_id uuid,
  p_match_record_id uuid DEFAULT NULL,
  p_doc_country text DEFAULT NULL,
  p_doc_vat_number text DEFAULT NULL,
  p_doc_extraction_layer text DEFAULT NULL,
  p_iban_country_candidate char(2) DEFAULT NULL,
  p_actor_user_id uuid DEFAULT NULL,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp AS $$
DECLARE
  v_signature text;
  v_match_status public.transaction_match_status_enum;
  v_doc_country_canon char(2);
  v_doc_vat_canon text;
  v_doc_vat_valid boolean;
  v_vm record;
  v_resolved_country char(2);
  v_resolved_vat text;
  v_resolved_source text;
  v_resolved_confidence text;
  v_review_ids uuid[] := ARRAY[]::uuid[];
  v_review_id uuid;
  v_writeback boolean := false;
BEGIN
  SELECT lower(trim(coalesce(counterparty_name, ''))) INTO v_signature
    FROM public.transactions WHERE id = p_transaction_id;
  IF p_match_record_id IS NOT NULL THEN
    SELECT match_status INTO v_match_status FROM public.transactions WHERE id = p_transaction_id;
  END IF;

  IF p_match_record_id IS NOT NULL AND (p_doc_country IS NOT NULL OR p_doc_vat_number IS NOT NULL) THEN
    v_doc_country_canon := public.canonicalize_country_alpha2(p_doc_country);
    IF p_doc_vat_number IS NOT NULL THEN
      v_doc_vat_canon := public.canonicalize_vat_number(v_doc_country_canon, p_doc_vat_number);
      v_doc_vat_valid := public.validate_vat_number_format(v_doc_country_canon, v_doc_vat_canon);
      IF v_doc_vat_canon IS NOT NULL AND NOT v_doc_vat_valid THEN
        INSERT INTO public.review_issues (
          organization_id, business_id, workflow_run_id, transaction_id,
          issue_type, issue_group, severity,
          plain_language_title, plain_language_description, recommended_action,
          card_payload_json
        ) VALUES (
          p_organization_id, p_business_id, p_workflow_run_id, p_transaction_id,
          'counterparty.vat_number_invalid',
          'POSSIBLE_TAX_VAT_ISSUE'::public.review_issue_group_enum,
          'MEDIUM'::public.review_issue_severity_enum,
          'Counterparty VAT number format invalid',
          'The extracted VAT number does not match the expected format for the counterparty country. The value is stored but needs review.',
          'Verify and correct the VAT number',
          jsonb_build_object('country', v_doc_country_canon, 'raw_vat', p_doc_vat_number, 'canonical_vat', v_doc_vat_canon)
        ) RETURNING id INTO v_review_id;
        v_review_ids := array_append(v_review_ids, v_review_id);
      END IF;
    END IF;
    IF v_doc_country_canon IS NOT NULL OR v_doc_vat_canon IS NOT NULL THEN
      v_resolved_country := v_doc_country_canon;
      v_resolved_vat := v_doc_vat_canon;
      v_resolved_source := 'DOCUMENT';
      v_resolved_confidence := CASE
        WHEN p_doc_extraction_layer IN ('TIER3_AI','DETERMINISTIC') THEN 'HIGH'
        WHEN p_doc_extraction_layer = 'TIER2_AI' THEN 'MEDIUM'
        ELSE 'MEDIUM' END;
    END IF;
  END IF;

  IF v_signature IS NOT NULL AND length(v_signature) > 0 THEN
    SELECT counterparty_country, counterparty_vat_number, confirmations_count
      INTO v_vm FROM public.recurring_vendor_memory
     WHERE business_id = p_business_id AND counterparty_signature = v_signature
     ORDER BY last_confirmation_at DESC NULLS LAST LIMIT 1;

    IF v_resolved_source IS NULL AND v_vm.counterparty_country IS NOT NULL THEN
      v_resolved_country := v_vm.counterparty_country;
      v_resolved_vat := v_vm.counterparty_vat_number;
      v_resolved_source := 'VENDOR_MEMORY';
      v_resolved_confidence := CASE
        WHEN v_vm.confirmations_count >= 3 THEN 'HIGH'
        WHEN v_vm.confirmations_count >= 2 THEN 'MEDIUM'
        ELSE 'LOW' END;
    ELSIF v_resolved_country IS NOT NULL AND v_vm.counterparty_country IS NOT NULL
          AND v_resolved_country <> v_vm.counterparty_country THEN
      PERFORM audit.emit_audit(
        p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
        p_action:='LEDGER_COUNTERPARTY_DISAGREEMENT_DETECTED',
        p_subject_type:='TRANSACTION'::audit.subject_type_enum,
        p_subject_id:=p_transaction_id,
        p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
        p_actor_system:='counterparty_resolver',
        p_organization_id:=p_organization_id, p_business_id:=p_business_id,
        p_before_state:=NULL,
        p_after_state:=jsonb_build_object('doc_country', v_resolved_country, 'vendor_memory_country', v_vm.counterparty_country, 'winner', 'DOCUMENT'),
        p_reason:=NULL, p_request_context:=p_context
      );
      INSERT INTO public.review_issues (
        organization_id, business_id, workflow_run_id, transaction_id,
        issue_type, issue_group, severity,
        plain_language_title, plain_language_description, recommended_action,
        card_payload_json
      ) VALUES (
        p_organization_id, p_business_id, p_workflow_run_id, p_transaction_id,
        'counterparty.country_disagreement',
        'POSSIBLE_TAX_VAT_ISSUE'::public.review_issue_group_enum,
        'MEDIUM'::public.review_issue_severity_enum,
        'Counterparty country sources disagree',
        'The document and the vendor memory suggest different counterparty countries. The higher-confidence source was used; please confirm.',
        'Confirm the correct counterparty country',
        jsonb_build_object('doc_country', v_resolved_country, 'vendor_memory_country', v_vm.counterparty_country)
      ) RETURNING id INTO v_review_id;
      v_review_ids := array_append(v_review_ids, v_review_id);
    END IF;
  END IF;

  IF v_resolved_source IS NULL AND p_iban_country_candidate IS NOT NULL THEN
    v_resolved_country := p_iban_country_candidate;
    v_resolved_vat := NULL;
    v_resolved_source := 'TRANSACTION_METADATA';
    v_resolved_confidence := 'LOW';
  END IF;

  IF v_resolved_source IS NULL THEN
    v_resolved_source := 'UNRESOLVED';
    v_resolved_confidence := 'LOW';
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='LEDGER_COUNTERPARTY_UNRESOLVED',
      p_subject_type:='TRANSACTION'::audit.subject_type_enum,
      p_subject_id:=p_transaction_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='counterparty_resolver',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('signature', v_signature, 'workflow_run_id', p_workflow_run_id),
      p_reason:=NULL, p_request_context:=p_context);
  ELSE
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='LEDGER_COUNTERPARTY_RESOLVED',
      p_subject_type:='TRANSACTION'::audit.subject_type_enum,
      p_subject_id:=p_transaction_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='counterparty_resolver',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('country', v_resolved_country, 'vat_number', v_resolved_vat, 'source', v_resolved_source, 'confidence', v_resolved_confidence, 'workflow_run_id', p_workflow_run_id),
      p_reason:=NULL, p_request_context:=p_context);
  END IF;

  IF v_resolved_source = 'DOCUMENT' AND v_resolved_confidence = 'HIGH'
     AND v_match_status IN ('MATCHED_AUTO_CONFIRMED','MATCHED_CONFIRMED') THEN
    v_writeback := public._writeback_counterparty_to_vendor_memory(
      p_business_id, v_signature, v_resolved_country, v_resolved_vat, 'HIGH');
  END IF;

  RETURN jsonb_build_object(
    'counterparty_country', v_resolved_country,
    'counterparty_vat_number', v_resolved_vat,
    'source', v_resolved_source,
    'confidence', v_resolved_confidence,
    'evidence_pointer', jsonb_build_object(
      'transaction_id', p_transaction_id,
      'match_record_id', p_match_record_id,
      'doc_extraction_layer', p_doc_extraction_layer),
    'review_issue_ids', to_jsonb(v_review_ids),
    'writeback_applied', v_writeback
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.resolve_counterparty(uuid, uuid, uuid, uuid, uuid, text, text, text, char(2), uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_counterparty(uuid, uuid, uuid, uuid, uuid, text, text, text, char(2), uuid, jsonb) TO service_role;

COMMIT;
