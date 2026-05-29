-- B11·P04 — Counterparty Country & VAT-Number Resolution
-- =====================================================================
-- Deterministic 4-step resolver:
--   1. DOCUMENT        (extracted_fields passed as RPC params)
--   1.5 CLIENTS_REGISTRY — deferred (Block 13 P02 owns)
--   2. VENDOR_MEMORY   (recurring_vendor_memory by counterparty_signature)
--   3. TRANSACTION_METADATA (IBAN country candidate)
--   4. UNRESOLVED
--
-- Stage-1 notes:
--   * documents.extracted_fields_json doesn't exist (Block 09 stores extraction
--     differently); resolver accepts country / vat_number / layer as RPC params
--     so the orchestrator passes pre-extracted values. Decouples from the
--     final Block 09 storage shape (sub-doc territory).
--   * Vendor-memory signature uses lower(trim(counterparty_name)) as the
--     Stage-1 placeholder; Block 08 P03's signature convention finalizes the
--     normalisation contract.
--   * Disagreement detection: if DOCUMENT and VENDOR_MEMORY both return a
--     country and they differ, doc wins (highest confidence). Emits
--     LEDGER_COUNTERPARTY_DISAGREEMENT_DETECTED + counterparty.country_disagreement
--     review_issue.
--   * VAT format-only validation here; VIES online check is Phase 06.
--   * Write-back to recurring_vendor_memory only on DOC + HIGH + MATCHED.
--
-- Audit family (subject_type=TRANSACTION, actor_kind=SYSTEM):
--   * LEDGER_COUNTERPARTY_RESOLVED
--   * LEDGER_COUNTERPARTY_UNRESOLVED
--   * LEDGER_COUNTERPARTY_DISAGREEMENT_DETECTED
-- =====================================================================

BEGIN;

-- 1. recurring_vendor_memory additions (for write-back) -------------------
ALTER TABLE public.recurring_vendor_memory
  ADD COLUMN counterparty_country char(2),
  ADD COLUMN counterparty_vat_number text,
  ADD COLUMN counterparty_resolution_tier text
    CHECK (counterparty_resolution_tier IS NULL
        OR counterparty_resolution_tier IN ('HIGH','MEDIUM','LOW'));

COMMENT ON COLUMN public.recurring_vendor_memory.counterparty_country IS
  'B11·P04 write-back: last confirmed counterparty country (ISO 3166 alpha-2). Updated by resolve_counterparty on DOC/HIGH path.';
COMMENT ON COLUMN public.recurring_vendor_memory.counterparty_vat_number IS
  'B11·P04 write-back: last confirmed counterparty VAT number (canonical form).';


-- 2. IMMUTABLE helpers ----------------------------------------------------
CREATE OR REPLACE FUNCTION public.canonicalize_vat_number(p_country char(2), p_raw text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_raw IS NULL OR length(trim(p_raw)) = 0 THEN NULL
    ELSE upper(regexp_replace(trim(p_raw), '[[:space:]\-]', '', 'g'))
  END;
$$;

CREATE OR REPLACE FUNCTION public.validate_vat_number_format(p_country char(2), p_canonical_vat text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_canonical_vat IS NULL THEN false
    WHEN p_country IS NULL THEN length(p_canonical_vat) >= 4
    WHEN p_country = 'CY' THEN p_canonical_vat ~ '^CY[0-9]{8}[A-Z]$'
    WHEN p_country = 'GR' THEN p_canonical_vat ~ '^(EL|GR)[0-9]{9}$'
    WHEN p_country = 'DE' THEN p_canonical_vat ~ '^DE[0-9]{9}$'
    WHEN p_country = 'IE' THEN p_canonical_vat ~ '^IE[0-9]{7}[A-Z]{1,2}$'
    WHEN p_country IN ('GB','XI') THEN p_canonical_vat ~ '^(GB|XI)[0-9]{9}([0-9]{3})?$'
    ELSE p_canonical_vat ~ ('^' || p_country || '[A-Z0-9]{4,}$')
  END;
$$;

CREATE OR REPLACE FUNCTION public.canonicalize_country_alpha2(p_raw text)
RETURNS char(2) LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_raw IS NULL OR length(trim(p_raw)) = 0 THEN NULL
    WHEN length(trim(p_raw)) = 2 THEN upper(trim(p_raw))::char(2)
    ELSE CASE upper(trim(p_raw))
      WHEN 'CYPRUS' THEN 'CY'::char(2)
      WHEN 'GERMANY' THEN 'DE'::char(2)
      WHEN 'GREECE' THEN 'GR'::char(2)
      WHEN 'IRELAND' THEN 'IE'::char(2)
      WHEN 'UNITED KINGDOM' THEN 'GB'::char(2)
      WHEN 'NORTHERN IRELAND' THEN 'XI'::char(2)
      WHEN 'NETHERLANDS' THEN 'NL'::char(2)
      WHEN 'FRANCE' THEN 'FR'::char(2)
      WHEN 'ITALY' THEN 'IT'::char(2)
      WHEN 'SPAIN' THEN 'ES'::char(2)
      WHEN 'UNITED STATES' THEN 'US'::char(2)
      ELSE NULL
    END
  END;
$$;


-- 3. Private write-back helper --------------------------------------------
CREATE OR REPLACE FUNCTION public._writeback_counterparty_to_vendor_memory(
  p_business_id uuid, p_signature text, p_country char(2), p_vat_number text, p_tier text
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_updated int;
BEGIN
  UPDATE public.recurring_vendor_memory
    SET counterparty_country = p_country,
        counterparty_vat_number = p_vat_number,
        counterparty_resolution_tier = p_tier,
        updated_at = clock_timestamp()
   WHERE business_id = p_business_id
     AND counterparty_signature = p_signature
     AND confirmations_count >= 1;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated > 0;
END;
$$;


-- 4. Main resolver --------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_counterparty(
  p_organization_id uuid, p_business_id uuid,
  p_transaction_id uuid,
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

  -- Step 1: DOCUMENT
  IF p_match_record_id IS NOT NULL AND (p_doc_country IS NOT NULL OR p_doc_vat_number IS NOT NULL) THEN
    v_doc_country_canon := public.canonicalize_country_alpha2(p_doc_country);
    IF p_doc_vat_number IS NOT NULL THEN
      v_doc_vat_canon := public.canonicalize_vat_number(v_doc_country_canon, p_doc_vat_number);
      v_doc_vat_valid := public.validate_vat_number_format(v_doc_country_canon, v_doc_vat_canon);
      IF v_doc_vat_canon IS NOT NULL AND NOT v_doc_vat_valid THEN
        INSERT INTO public.review_issues (
          organization_id, business_id, transaction_id,
          issue_type, issue_group, severity,
          plain_language_title, plain_language_description, recommended_action,
          card_payload_json
        ) VALUES (
          p_organization_id, p_business_id, p_transaction_id,
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

  -- Step 2: VENDOR_MEMORY (+ disagreement detection)
  IF v_signature IS NOT NULL AND length(v_signature) > 0 THEN
    SELECT counterparty_country, counterparty_vat_number, confirmations_count
      INTO v_vm
      FROM public.recurring_vendor_memory
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
        p_after_state:=jsonb_build_object(
          'doc_country', v_resolved_country,
          'vendor_memory_country', v_vm.counterparty_country,
          'winner', 'DOCUMENT'),
        p_reason:=NULL, p_request_context:=p_context
      );
      INSERT INTO public.review_issues (
        organization_id, business_id, transaction_id,
        issue_type, issue_group, severity,
        plain_language_title, plain_language_description, recommended_action,
        card_payload_json
      ) VALUES (
        p_organization_id, p_business_id, p_transaction_id,
        'counterparty.country_disagreement',
        'POSSIBLE_TAX_VAT_ISSUE'::public.review_issue_group_enum,
        'MEDIUM'::public.review_issue_severity_enum,
        'Counterparty country sources disagree',
        'The document and the vendor memory suggest different counterparty countries. The higher-confidence source was used; please confirm.',
        'Confirm the correct counterparty country',
        jsonb_build_object(
          'doc_country', v_resolved_country,
          'vendor_memory_country', v_vm.counterparty_country)
      ) RETURNING id INTO v_review_id;
      v_review_ids := array_append(v_review_ids, v_review_id);
    END IF;
  END IF;

  -- Step 3: TRANSACTION_METADATA
  IF v_resolved_source IS NULL AND p_iban_country_candidate IS NOT NULL THEN
    v_resolved_country := p_iban_country_candidate;
    v_resolved_vat := NULL;
    v_resolved_source := 'TRANSACTION_METADATA';
    v_resolved_confidence := 'LOW';
  END IF;

  -- Step 4: UNRESOLVED / RESOLVED audit
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
      p_after_state:=jsonb_build_object('signature', v_signature),
      p_reason:=NULL, p_request_context:=p_context
    );
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
      p_after_state:=jsonb_build_object(
        'country', v_resolved_country, 'vat_number', v_resolved_vat,
        'source', v_resolved_source, 'confidence', v_resolved_confidence),
      p_reason:=NULL, p_request_context:=p_context
    );
  END IF;

  -- Write-back: DOC + HIGH + matched
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


-- 5. Privileges -----------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public._writeback_counterparty_to_vendor_memory(uuid, text, char(2), text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.resolve_counterparty(uuid, uuid, uuid, uuid, text, text, text, char(2), uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_counterparty(uuid, uuid, uuid, uuid, text, text, text, char(2), uuid, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.canonicalize_vat_number(char(2), text) TO authenticated, service_role, anon;
GRANT EXECUTE ON FUNCTION public.validate_vat_number_format(char(2), text) TO authenticated, service_role, anon;
GRANT EXECUTE ON FUNCTION public.canonicalize_country_alpha2(text) TO authenticated, service_role, anon;

COMMIT;
