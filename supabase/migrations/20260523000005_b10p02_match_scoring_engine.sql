-- B10·P02 — Match Scoring Engine — DB scaffold.
-- Deterministic SQL helpers for pure-DB signals + signal-weight config
-- registry + chokepoint RPC that records match_records with rejection-memory
-- suppression + audit emission. Orchestrator (Python) computes the app-layer
-- signals (fuzzy match, ECB FX, etc.) and assembles the full breakdown.
--
-- Audit family MATCHING:
--   MATCHING_SCORE_COMPUTED           (TRANSACTION subject)
--   MATCHING_LEVEL_ASSIGNED           (MATCH_RECORD subject)
--   MATCHING_REJECTION_SUPPRESSED     (TRANSACTION subject)
--   MATCHING_CROSS_CURRENCY_FX_RESOLVED (TRANSACTION subject)
--   MATCHING_CROSS_PERIOD_CANDIDATE_FOUND (TRANSACTION subject)

-- 1. match_signal_weights registry --------------------------------------------

CREATE TABLE IF NOT EXISTS public.match_signal_weights (
  id                  uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  business_id         uuid,
  signal_name         text NOT NULL,
  weight              numeric NOT NULL,
  enabled             boolean NOT NULL DEFAULT true,
  version             text NOT NULL DEFAULT '1.0.0',
  created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_by_user_id  uuid,
  CONSTRAINT msw_signal_name_format CHECK (signal_name ~ '^[a-z][a-z0-9_]+$'),
  CONSTRAINT msw_weight_range CHECK (weight >= 0 AND weight <= 1),
  CONSTRAINT msw_version_nonempty CHECK (length(trim(version)) > 0),
  CONSTRAINT msw_business_fk FOREIGN KEY (business_id) REFERENCES public.business_entities(id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS msw_unique_per_business
  ON public.match_signal_weights (business_id, signal_name) WHERE business_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS msw_unique_global
  ON public.match_signal_weights (signal_name) WHERE business_id IS NULL;

ALTER TABLE public.match_signal_weights ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS msw_select ON public.match_signal_weights;
CREATE POLICY msw_select ON public.match_signal_weights FOR SELECT
  USING (business_id IS NULL OR business_id = ANY (public.current_user_businesses()));
DROP POLICY IF EXISTS msw_no_insert ON public.match_signal_weights;
CREATE POLICY msw_no_insert ON public.match_signal_weights FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS msw_no_update ON public.match_signal_weights;
CREATE POLICY msw_no_update ON public.match_signal_weights FOR UPDATE USING (false);
DROP POLICY IF EXISTS msw_no_delete ON public.match_signal_weights;
CREATE POLICY msw_no_delete ON public.match_signal_weights FOR DELETE USING (false);

-- Default global weights (sum = 1.00; sub-doc tunes)
INSERT INTO public.match_signal_weights (business_id, signal_name, weight) VALUES
  (NULL, 'amount_exact_match',          0.20),
  (NULL, 'currency_match',              0.10),
  (NULL, 'supplier_exact_match',        0.20),
  (NULL, 'supplier_fuzzy_match',        0.10),
  (NULL, 'date_proximity',              0.15),
  (NULL, 'invoice_number_match',        0.10),
  (NULL, 'recurring_vendor_signal',     0.05),
  (NULL, 'email_sender_domain_match',   0.05),
  (NULL, 'drive_folder_relevance',      0.02),
  (NULL, 'business_name_on_invoice',    0.02),
  (NULL, 'vat_number_relevance',        0.01)
ON CONFLICT DO NOTHING;


-- 2. Helper functions --------------------------------------------------------

CREATE OR REPLACE FUNCTION public.compute_amount_exact_match(
  p_txn_amount numeric,
  p_doc_amount numeric,
  p_tolerance  numeric DEFAULT 0.01
)
RETURNS numeric LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
  SELECT CASE
    WHEN p_txn_amount IS NULL OR p_doc_amount IS NULL THEN 0.0::numeric
    WHEN abs(abs(p_txn_amount) - abs(p_doc_amount)) <= COALESCE(p_tolerance, 0.01) THEN 1.0::numeric
    ELSE 0.0::numeric
  END;
$$;

CREATE OR REPLACE FUNCTION public.compute_date_proximity(
  p_txn_date date,
  p_doc_date date
)
RETURNS numeric LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
  SELECT CASE
    WHEN p_txn_date IS NULL OR p_doc_date IS NULL THEN 0.0::numeric
    WHEN abs(p_txn_date - p_doc_date) <= 3  THEN 1.0::numeric
    WHEN abs(p_txn_date - p_doc_date) <= 10 THEN 0.7::numeric
    WHEN abs(p_txn_date - p_doc_date) <= 30 THEN 0.4::numeric
    ELSE 0.0::numeric
  END;
$$;

CREATE OR REPLACE FUNCTION public.compute_invoice_number_match(
  p_txn_ref            text,
  p_doc_invoice_number text
)
RETURNS numeric LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
  SELECT CASE
    WHEN p_txn_ref IS NULL AND p_doc_invoice_number IS NULL THEN 0.0::numeric
    WHEN p_txn_ref IS NULL OR  p_doc_invoice_number IS NULL THEN 0.5::numeric
    WHEN trim(p_txn_ref) = trim(p_doc_invoice_number) THEN 1.0::numeric
    ELSE 0.0::numeric
  END;
$$;

CREATE OR REPLACE FUNCTION public.lookup_recurring_vendor_signal(
  p_business_id            uuid,
  p_counterparty_signature text
)
RETURNS numeric LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE v_confirmations int;
BEGIN
  IF p_business_id IS NULL OR p_counterparty_signature IS NULL THEN
    RETURN 0.0::numeric;
  END IF;
  SELECT confirmations_count INTO v_confirmations
  FROM public.recurring_vendor_memory
  WHERE business_id = p_business_id
    AND counterparty_signature = p_counterparty_signature
  LIMIT 1;
  IF v_confirmations IS NULL THEN RETURN 0.0::numeric; END IF;
  IF v_confirmations >= 3 THEN RETURN 0.88::numeric; END IF;
  IF v_confirmations = 2 THEN RETURN 0.72::numeric; END IF;
  IF v_confirmations = 1 THEN RETURN 0.60::numeric; END IF;
  RETURN 0.0::numeric;
END;
$$;


-- 3. apply_match_score chokepoint -------------------------------------------

CREATE OR REPLACE FUNCTION public.apply_match_score(
  p_organization_id            uuid,
  p_business_id                uuid,
  p_transaction_id             uuid,
  p_document_id                uuid,
  p_signal_breakdown           jsonb,
  p_match_score                numeric,
  p_match_level                public.match_level_enum,
  p_match_method               public.match_method_enum DEFAULT 'DETERMINISTIC_RULE',
  p_match_reason_plain_language text DEFAULT NULL,
  p_matched_by_system          text DEFAULT 'matching_engine',
  p_context                    jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_existing_rejection_id uuid;
  v_match_record_id       uuid;
  v_requires_confirm      boolean;
BEGIN
  IF p_match_score IS NULL OR p_match_score < 0 OR p_match_score > 1 THEN
    RAISE EXCEPTION 'MATCH_SCORE_OUT_OF_RANGE' USING errcode='check_violation';
  END IF;
  IF jsonb_typeof(COALESCE(p_signal_breakdown,'{}'::jsonb)) <> 'object' THEN
    RAISE EXCEPTION 'SIGNAL_BREAKDOWN_MUST_BE_OBJECT' USING errcode='check_violation';
  END IF;

  -- Suppression check: rejected pair → emit audit + return SUPPRESSED envelope
  SELECT id INTO v_existing_rejection_id
  FROM public.match_rejection_memory
  WHERE business_id = p_business_id
    AND transaction_id = p_transaction_id
    AND document_id = p_document_id
  LIMIT 1;

  IF FOUND THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='MATCHING_REJECTION_SUPPRESSED',
      p_subject_type:='TRANSACTION'::audit.subject_type_enum,
      p_subject_id:=p_transaction_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='matching_engine',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object(
        'transaction_id', p_transaction_id,
        'document_id', p_document_id,
        'rejection_record_id', v_existing_rejection_id
      ),
      p_reason:=NULL, p_request_context:=p_context
    );
    RETURN jsonb_build_object(
      'decision','SUPPRESSED',
      'reason','PAIR_IN_REJECTION_MEMORY',
      'transaction_id', p_transaction_id,
      'document_id', p_document_id,
      'rejection_record_id', v_existing_rejection_id
    );
  END IF;

  -- Default requires_user_confirmation by level
  v_requires_confirm := (p_match_level <> 'EXACT');

  INSERT INTO public.match_records (
    organization_id, business_id, transaction_id, document_id,
    match_level, match_method, match_score, match_signals,
    match_status, requires_user_confirmation,
    match_reason_plain_language, matched_by_system
  ) VALUES (
    p_organization_id, p_business_id, p_transaction_id, p_document_id,
    p_match_level, p_match_method, p_match_score,
    COALESCE(p_signal_breakdown,'{}'::jsonb),
    CASE p_match_level
      WHEN 'EXACT'          THEN 'MATCHED_AUTO_HIGH_CONFIDENCE'::public.match_record_status_enum
      WHEN 'STRONG_PROBABLE' THEN 'MATCHED_NEEDS_CONFIRMATION'::public.match_record_status_enum
      ELSE                       'POSSIBLE_MATCH'::public.match_record_status_enum
    END,
    v_requires_confirm,
    p_match_reason_plain_language,
    p_matched_by_system
  )
  RETURNING id INTO v_match_record_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='MATCHING_SCORE_COMPUTED',
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=p_transaction_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='matching_engine',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'match_record_id', v_match_record_id,
      'document_id', p_document_id,
      'signal_breakdown', COALESCE(p_signal_breakdown,'{}'::jsonb),
      'match_score', p_match_score
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='MATCHING_LEVEL_ASSIGNED',
    p_subject_type:='MATCH_RECORD'::audit.subject_type_enum,
    p_subject_id:=v_match_record_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='matching_engine',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'match_level', p_match_level,
      'match_method', p_match_method,
      'transaction_id', p_transaction_id,
      'document_id', p_document_id,
      'requires_user_confirmation', v_requires_confirm
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','RECORDED',
    'match_record_id', v_match_record_id,
    'match_level', p_match_level,
    'match_score', p_match_score,
    'requires_user_confirmation', v_requires_confirm
  );
END;
$$;


-- 4. record_matching_cross_currency_fx_resolved ------------------------------

CREATE OR REPLACE FUNCTION public.record_matching_cross_currency_fx_resolved(
  p_organization_id uuid,
  p_business_id     uuid,
  p_transaction_id  uuid,
  p_document_id     uuid,
  p_rate_source     text,
  p_rate            numeric,
  p_context         jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
BEGIN
  IF p_rate_source NOT IN ('fx_paired_legs','ecb_fallback') THEN
    RAISE EXCEPTION 'RATE_SOURCE_MUST_BE_FX_PAIRED_LEGS_OR_ECB_FALLBACK' USING errcode='check_violation';
  END IF;
  IF p_rate IS NULL OR p_rate <= 0 THEN
    RAISE EXCEPTION 'RATE_MUST_BE_POSITIVE' USING errcode='check_violation';
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='MATCHING_CROSS_CURRENCY_FX_RESOLVED',
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=p_transaction_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='matching_engine',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'transaction_id', p_transaction_id,
      'document_id', p_document_id,
      'rate_source', p_rate_source,
      'rate', p_rate
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','RECORDED','transaction_id',p_transaction_id,
    'document_id',p_document_id,'rate_source',p_rate_source,'rate',p_rate
  );
END;
$$;


-- 5. record_matching_cross_period_candidate_found ----------------------------

CREATE OR REPLACE FUNCTION public.record_matching_cross_period_candidate_found(
  p_organization_id uuid,
  p_business_id     uuid,
  p_transaction_id  uuid,
  p_document_id     uuid,
  p_days_offset     integer,
  p_context         jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
BEGIN
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='MATCHING_CROSS_PERIOD_CANDIDATE_FOUND',
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=p_transaction_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='matching_engine',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'transaction_id', p_transaction_id,
      'document_id', p_document_id,
      'days_offset', p_days_offset
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','RECORDED','transaction_id',p_transaction_id,
    'document_id',p_document_id,'days_offset',p_days_offset
  );
END;
$$;


-- 6. Privilege grants --------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.apply_match_score(uuid, uuid, uuid, uuid, jsonb, numeric, public.match_level_enum, public.match_method_enum, text, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_matching_cross_currency_fx_resolved(uuid, uuid, uuid, uuid, text, numeric, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_matching_cross_period_candidate_found(uuid, uuid, uuid, uuid, integer, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.apply_match_score(uuid, uuid, uuid, uuid, jsonb, numeric, public.match_level_enum, public.match_method_enum, text, text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_matching_cross_currency_fx_resolved(uuid, uuid, uuid, uuid, text, numeric, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_matching_cross_period_candidate_found(uuid, uuid, uuid, uuid, integer, jsonb) TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.compute_amount_exact_match(numeric, numeric, numeric) TO authenticated, service_role, anon;
GRANT EXECUTE ON FUNCTION public.compute_date_proximity(date, date) TO authenticated, service_role, anon;
GRANT EXECUTE ON FUNCTION public.compute_invoice_number_match(text, text) TO authenticated, service_role, anon;
GRANT EXECUTE ON FUNCTION public.lookup_recurring_vendor_signal(uuid, text) TO authenticated, service_role;

GRANT SELECT ON public.match_signal_weights TO authenticated, anon;
