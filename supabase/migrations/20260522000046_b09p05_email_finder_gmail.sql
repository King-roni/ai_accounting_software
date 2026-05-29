-- B09·P05 — Email Finder (Gmail) — DB scaffold.
-- Lifecycle for transaction-scoped Gmail search runs + per-result records.
-- Python orchestrator owns Gmail API, query substitution, spam/allowlist
-- filtering, and attachment fetching. This phase delivers the registry of
-- query templates, the lifecycle tables, and the audit-coupled RPCs.
--
-- Audit family EMAIL_FINDER:
--   EMAIL_FINDER_QUERY_EXECUTED                  (subject_type=TRANSACTION)
--   EMAIL_FINDER_RESULT_FOUND                    (subject_type=DOCUMENT — new)
--   EMAIL_FINDER_RESULT_REJECTED_SPAM            (subject_type=TRANSACTION)
--   EMAIL_FINDER_RESULT_REJECTED_NOT_ALLOWLISTED (subject_type=TRANSACTION)
--   EMAIL_FINDER_RESULT_DUPLICATE_SOURCE         (subject_type=DOCUMENT — existing)

-- 1. Enums -------------------------------------------------------------------

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname='email_finder_run_status_enum' AND typnamespace='public'::regnamespace) THEN
    CREATE TYPE public.email_finder_run_status_enum AS ENUM ('STARTED','COMPLETED','FAILED');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname='email_finder_result_outcome_enum' AND typnamespace='public'::regnamespace) THEN
    CREATE TYPE public.email_finder_result_outcome_enum AS ENUM (
      'FOUND','REJECTED_SPAM','REJECTED_NOT_ALLOWLISTED','DUPLICATE_SOURCE'
    );
  END IF;
END$$;


-- 2. email_finder_runs -------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.email_finder_runs (
  id                              uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id                 uuid NOT NULL,
  business_id                     uuid NOT NULL,
  transaction_id                  uuid NOT NULL,
  status                          public.email_finder_run_status_enum NOT NULL,
  query_count                     integer NOT NULL DEFAULT 0,
  found_count                     integer NOT NULL DEFAULT 0,
  rejected_spam_count             integer NOT NULL DEFAULT 0,
  rejected_not_allowlisted_count  integer NOT NULL DEFAULT 0,
  duplicate_count                 integer NOT NULL DEFAULT 0,
  error_summary                   text,
  started_at                      timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at                    timestamptz,
  failed_at                       timestamptz,
  CONSTRAINT efr_counts_nonneg CHECK (
    query_count >= 0 AND found_count >= 0
    AND rejected_spam_count >= 0 AND rejected_not_allowlisted_count >= 0
    AND duplicate_count >= 0
  ),
  CONSTRAINT efr_completed_pairing CHECK (
    (status <> 'COMPLETED') OR completed_at IS NOT NULL
  ),
  CONSTRAINT efr_failed_pairing CHECK (
    (status <> 'FAILED')
    OR (failed_at IS NOT NULL AND error_summary IS NOT NULL AND length(trim(error_summary)) > 0)
  ),
  CONSTRAINT efr_org_fk      FOREIGN KEY (organization_id) REFERENCES public.organizations(id)    ON DELETE RESTRICT,
  CONSTRAINT efr_business_fk FOREIGN KEY (business_id)     REFERENCES public.business_entities(id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS efr_by_txn
  ON public.email_finder_runs (business_id, transaction_id, started_at DESC);

ALTER TABLE public.email_finder_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS efr_select ON public.email_finder_runs;
CREATE POLICY efr_select ON public.email_finder_runs FOR SELECT
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
DROP POLICY IF EXISTS efr_no_insert ON public.email_finder_runs;
CREATE POLICY efr_no_insert ON public.email_finder_runs FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS efr_no_update ON public.email_finder_runs;
CREATE POLICY efr_no_update ON public.email_finder_runs FOR UPDATE USING (false);
DROP POLICY IF EXISTS efr_no_delete ON public.email_finder_runs;
CREATE POLICY efr_no_delete ON public.email_finder_runs FOR DELETE USING (false);


-- 3. email_finder_results ----------------------------------------------------

CREATE TABLE IF NOT EXISTS public.email_finder_results (
  id                    uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id       uuid NOT NULL,
  business_id           uuid NOT NULL,
  run_id                uuid NOT NULL,
  template_name         text NOT NULL,
  gmail_message_id      text NOT NULL,
  sender_address        text,
  outcome               public.email_finder_result_outcome_enum NOT NULL,
  document_id           uuid,
  discovery_confidence  numeric,
  processed_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT efres_msgid_nonempty CHECK (length(trim(gmail_message_id)) > 0),
  CONSTRAINT efres_confidence_range CHECK (
    discovery_confidence IS NULL OR discovery_confidence BETWEEN 0 AND 1
  ),
  CONSTRAINT efres_found_requires CHECK (
    (outcome <> 'FOUND')
    OR (document_id IS NOT NULL AND discovery_confidence IS NOT NULL)
  ),
  CONSTRAINT efres_duplicate_requires_doc CHECK (
    (outcome <> 'DUPLICATE_SOURCE') OR (document_id IS NOT NULL)
  ),
  CONSTRAINT efres_run_fk       FOREIGN KEY (run_id)          REFERENCES public.email_finder_runs(id) ON DELETE RESTRICT,
  CONSTRAINT efres_org_fk       FOREIGN KEY (organization_id) REFERENCES public.organizations(id)     ON DELETE RESTRICT,
  CONSTRAINT efres_business_fk  FOREIGN KEY (business_id)     REFERENCES public.business_entities(id) ON DELETE RESTRICT,
  CONSTRAINT efres_document_fk  FOREIGN KEY (document_id)     REFERENCES public.documents(id)         ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS efres_unique_per_run
  ON public.email_finder_results (run_id, gmail_message_id);

CREATE INDEX IF NOT EXISTS efres_by_outcome
  ON public.email_finder_results (run_id, outcome);

ALTER TABLE public.email_finder_results ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS efres_select ON public.email_finder_results;
CREATE POLICY efres_select ON public.email_finder_results FOR SELECT
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
DROP POLICY IF EXISTS efres_no_insert ON public.email_finder_results;
CREATE POLICY efres_no_insert ON public.email_finder_results FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS efres_no_update ON public.email_finder_results;
CREATE POLICY efres_no_update ON public.email_finder_results FOR UPDATE USING (false);
DROP POLICY IF EXISTS efres_no_delete ON public.email_finder_results;
CREATE POLICY efres_no_delete ON public.email_finder_results FOR DELETE USING (false);


-- 4. documents.discovery_confidence ------------------------------------------

ALTER TABLE public.documents
  ADD COLUMN IF NOT EXISTS discovery_confidence numeric;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid
    WHERE t.relname='documents' AND c.conname='documents_discovery_confidence_range_chk'
  ) THEN
    ALTER TABLE public.documents
      ADD CONSTRAINT documents_discovery_confidence_range_chk
      CHECK (discovery_confidence IS NULL OR discovery_confidence BETWEEN 0 AND 1);
  END IF;
END$$;


-- 5. Seed 4 default global query templates -----------------------------------

INSERT INTO public.gmail_search_query_templates
  (organization_id, business_id, template_name, pattern_jsonb, enabled, priority)
VALUES
  (
    NULL, NULL, 'invoice_by_amount_and_supplier_domain',
    jsonb_build_object(
      'query_template', 'has:attachment from:{supplier_domain} subject:(invoice OR receipt) newer_than:{date_min} older_than:{date_max}',
      'parameter_slots', jsonb_build_array('supplier_domain','date_min','date_max'),
      'purpose', 'Find invoices from a known supplier domain within a date window'
    ),
    true, 100
  ),
  (
    NULL, NULL, 'invoice_by_amount_keyword',
    jsonb_build_object(
      'query_template', 'has:attachment subject:({supplier_name} OR invoice) "{amount}"',
      'parameter_slots', jsonb_build_array('supplier_name','amount'),
      'purpose', 'Find invoices by amount + supplier-name keyword'
    ),
    true, 200
  ),
  (
    NULL, NULL, 'recurring_supplier_recent',
    jsonb_build_object(
      'query_template', 'has:attachment from:{supplier_domain}',
      'parameter_slots', jsonb_build_array('supplier_domain'),
      'purpose', 'Catch-all for known recurring vendors when the amount may vary slightly'
    ),
    true, 300
  ),
  (
    NULL, NULL, 'receipt_by_merchant_short_window',
    jsonb_build_object(
      'query_template', 'has:attachment from:{merchant_email} newer_than:{txn_date_minus_2d} older_than:{txn_date_plus_2d}',
      'parameter_slots', jsonb_build_array('merchant_email','txn_date_minus_2d','txn_date_plus_2d'),
      'purpose', 'Find receipts within a tight date window around the transaction date'
    ),
    true, 400
  )
ON CONFLICT DO NOTHING;


-- 6. begin_email_finder_run --------------------------------------------------

CREATE OR REPLACE FUNCTION public.begin_email_finder_run(
  p_organization_id uuid,
  p_business_id     uuid,
  p_transaction_id  uuid,
  p_query_count     integer DEFAULT 0,
  p_context         jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_run_id uuid;
BEGIN
  INSERT INTO public.email_finder_runs (
    organization_id, business_id, transaction_id, status, query_count
  ) VALUES (
    p_organization_id, p_business_id, p_transaction_id, 'STARTED',
    GREATEST(COALESCE(p_query_count, 0), 0)
  )
  RETURNING id INTO v_run_id;

  RETURN jsonb_build_object(
    'decision','STARTED','run_id',v_run_id,
    'transaction_id',p_transaction_id
  );
END;
$$;


-- 7. record_email_finder_query_executed --------------------------------------

CREATE OR REPLACE FUNCTION public.record_email_finder_query_executed(
  p_run_id        uuid,
  p_template_name text,
  p_parameters    jsonb,
  p_result_count  integer,
  p_context       jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid;
  v_business_id     uuid;
  v_transaction_id  uuid;
BEGIN
  SELECT organization_id, business_id, transaction_id
    INTO v_organization_id, v_business_id, v_transaction_id
  FROM public.email_finder_runs WHERE id = p_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','RUN_NOT_FOUND','run_id',p_run_id);
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='EMAIL_FINDER_QUERY_EXECUTED',
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=v_transaction_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='email_finder',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'run_id',p_run_id,
      'template_name',p_template_name,
      'parameters',COALESCE(p_parameters,'{}'::jsonb),
      'result_count',p_result_count
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','RECORDED','run_id',p_run_id,
    'template_name',p_template_name,'result_count',p_result_count
  );
END;
$$;


-- 8. record_email_finder_result_found ----------------------------------------

CREATE OR REPLACE FUNCTION public.record_email_finder_result_found(
  p_run_id               uuid,
  p_template_name        text,
  p_gmail_message_id     text,
  p_sender_address       text,
  p_discovery_confidence numeric,
  p_attachment_filename  text,
  p_document_type        public.document_type_enum DEFAULT 'INVOICE',
  p_context              jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid;
  v_business_id     uuid;
  v_transaction_id  uuid;
  v_existing_doc    uuid;
  v_source_extid    text;
  v_new_doc_id      uuid;
BEGIN
  IF p_gmail_message_id IS NULL OR length(trim(p_gmail_message_id)) = 0 THEN
    RAISE EXCEPTION 'GMAIL_MESSAGE_ID_REQUIRED' USING errcode='check_violation';
  END IF;
  IF p_discovery_confidence IS NULL
     OR p_discovery_confidence < 0 OR p_discovery_confidence > 1 THEN
    RAISE EXCEPTION 'DISCOVERY_CONFIDENCE_OUT_OF_RANGE' USING errcode='check_violation';
  END IF;

  SELECT organization_id, business_id, transaction_id
    INTO v_organization_id, v_business_id, v_transaction_id
  FROM public.email_finder_runs WHERE id = p_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','RUN_NOT_FOUND','run_id',p_run_id);
  END IF;

  v_source_extid := 'gmail:' || p_gmail_message_id;

  -- Duplicate-source detection via document_source_links
  SELECT document_id INTO v_existing_doc
  FROM public.document_source_links
  WHERE business_id = v_business_id
    AND source_kind = 'EMAIL'
    AND source_external_id = v_source_extid
  LIMIT 1;

  IF FOUND THEN
    INSERT INTO public.email_finder_results (
      organization_id, business_id, run_id, template_name,
      gmail_message_id, sender_address, outcome, document_id
    ) VALUES (
      v_organization_id, v_business_id, p_run_id, p_template_name,
      p_gmail_message_id, p_sender_address, 'DUPLICATE_SOURCE', v_existing_doc
    );

    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='EMAIL_FINDER_RESULT_DUPLICATE_SOURCE',
      p_subject_type:='DOCUMENT'::audit.subject_type_enum,
      p_subject_id:=v_existing_doc,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='email_finder',
      p_organization_id:=v_organization_id, p_business_id:=v_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object(
        'run_id',p_run_id,'gmail_message_id',p_gmail_message_id,
        'existing_document_id',v_existing_doc
      ),
      p_reason:=NULL, p_request_context:=p_context
    );

    RETURN jsonb_build_object(
      'decision','DUPLICATE_SOURCE','run_id',p_run_id,
      'document_id',v_existing_doc,'gmail_message_id',p_gmail_message_id
    );
  END IF;

  -- New discovery: create document + dsl + result row
  INSERT INTO public.documents (
    organization_id, business_id, source, document_type,
    original_filename, discovery_reason, discovery_confidence
  ) VALUES (
    v_organization_id, v_business_id, 'EMAIL', p_document_type,
    p_attachment_filename, 'email_finder:' || p_template_name, p_discovery_confidence
  )
  RETURNING id INTO v_new_doc_id;

  INSERT INTO public.document_source_links (
    organization_id, business_id, document_id, source_kind,
    source_external_id, discovery_reason
  ) VALUES (
    v_organization_id, v_business_id, v_new_doc_id, 'EMAIL',
    v_source_extid, 'email_finder:' || p_template_name
  );

  INSERT INTO public.email_finder_results (
    organization_id, business_id, run_id, template_name,
    gmail_message_id, sender_address, outcome, document_id, discovery_confidence
  ) VALUES (
    v_organization_id, v_business_id, p_run_id, p_template_name,
    p_gmail_message_id, p_sender_address, 'FOUND', v_new_doc_id, p_discovery_confidence
  );

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='EMAIL_FINDER_RESULT_FOUND',
    p_subject_type:='DOCUMENT'::audit.subject_type_enum,
    p_subject_id:=v_new_doc_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='email_finder',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'run_id',p_run_id,
      'template_name',p_template_name,
      'gmail_message_id',p_gmail_message_id,
      'sender_address',p_sender_address,
      'discovery_confidence',p_discovery_confidence,
      'document_id',v_new_doc_id
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','FOUND','run_id',p_run_id,
    'document_id',v_new_doc_id,
    'gmail_message_id',p_gmail_message_id,
    'discovery_confidence',p_discovery_confidence
  );
END;
$$;


-- 9. record_email_finder_result_rejected -------------------------------------

CREATE OR REPLACE FUNCTION public.record_email_finder_result_rejected(
  p_run_id           uuid,
  p_template_name    text,
  p_gmail_message_id text,
  p_sender_address   text,
  p_outcome          public.email_finder_result_outcome_enum,
  p_context          jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid;
  v_business_id     uuid;
  v_transaction_id  uuid;
  v_action          text;
BEGIN
  IF p_outcome NOT IN ('REJECTED_SPAM','REJECTED_NOT_ALLOWLISTED') THEN
    RAISE EXCEPTION 'OUTCOME_MUST_BE_REJECTED_VARIANT' USING errcode='check_violation';
  END IF;
  IF p_gmail_message_id IS NULL OR length(trim(p_gmail_message_id)) = 0 THEN
    RAISE EXCEPTION 'GMAIL_MESSAGE_ID_REQUIRED' USING errcode='check_violation';
  END IF;

  SELECT organization_id, business_id, transaction_id
    INTO v_organization_id, v_business_id, v_transaction_id
  FROM public.email_finder_runs WHERE id = p_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','RUN_NOT_FOUND','run_id',p_run_id);
  END IF;

  INSERT INTO public.email_finder_results (
    organization_id, business_id, run_id, template_name,
    gmail_message_id, sender_address, outcome
  ) VALUES (
    v_organization_id, v_business_id, p_run_id, p_template_name,
    p_gmail_message_id, p_sender_address, p_outcome
  );

  IF p_outcome = 'REJECTED_SPAM' THEN
    v_action := 'EMAIL_FINDER_RESULT_REJECTED_SPAM';
  ELSE
    v_action := 'EMAIL_FINDER_RESULT_REJECTED_NOT_ALLOWLISTED';
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:=v_action,
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=v_transaction_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='email_finder',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'run_id',p_run_id,'template_name',p_template_name,
      'gmail_message_id',p_gmail_message_id,
      'sender_address',p_sender_address,'outcome',p_outcome
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','REJECTED','outcome',p_outcome,
    'run_id',p_run_id,'gmail_message_id',p_gmail_message_id
  );
END;
$$;


-- 10. complete_email_finder_run ----------------------------------------------

CREATE OR REPLACE FUNCTION public.complete_email_finder_run(
  p_run_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_status public.email_finder_run_status_enum;
  v_found  int := 0;
  v_spam   int := 0;
  v_notal  int := 0;
  v_dup    int := 0;
BEGIN
  SELECT status INTO v_status
  FROM public.email_finder_runs WHERE id = p_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','RUN_NOT_FOUND','run_id',p_run_id);
  END IF;
  IF v_status <> 'STARTED' THEN
    RETURN jsonb_build_object(
      'decision','REJECTED','reason','RUN_NOT_STARTED',
      'run_id',p_run_id,'current_status',v_status
    );
  END IF;

  SELECT
    count(*) FILTER (WHERE outcome='FOUND'),
    count(*) FILTER (WHERE outcome='REJECTED_SPAM'),
    count(*) FILTER (WHERE outcome='REJECTED_NOT_ALLOWLISTED'),
    count(*) FILTER (WHERE outcome='DUPLICATE_SOURCE')
  INTO v_found, v_spam, v_notal, v_dup
  FROM public.email_finder_results WHERE run_id = p_run_id;

  UPDATE public.email_finder_runs
    SET status                         = 'COMPLETED',
        found_count                    = v_found,
        rejected_spam_count            = v_spam,
        rejected_not_allowlisted_count = v_notal,
        duplicate_count                = v_dup,
        completed_at                   = clock_timestamp()
  WHERE id = p_run_id;

  RETURN jsonb_build_object(
    'decision','COMPLETED','run_id',p_run_id,
    'found_count',v_found,'rejected_spam_count',v_spam,
    'rejected_not_allowlisted_count',v_notal,'duplicate_count',v_dup
  );
END;
$$;


-- 11. fail_email_finder_run --------------------------------------------------

CREATE OR REPLACE FUNCTION public.fail_email_finder_run(
  p_run_id        uuid,
  p_error_summary text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_status public.email_finder_run_status_enum;
BEGIN
  IF p_error_summary IS NULL OR length(trim(p_error_summary)) = 0 THEN
    RAISE EXCEPTION 'ERROR_SUMMARY_REQUIRED' USING errcode='check_violation';
  END IF;

  SELECT status INTO v_status
  FROM public.email_finder_runs WHERE id = p_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','RUN_NOT_FOUND','run_id',p_run_id);
  END IF;
  IF v_status <> 'STARTED' THEN
    RETURN jsonb_build_object(
      'decision','REJECTED','reason','RUN_NOT_STARTED',
      'run_id',p_run_id,'current_status',v_status
    );
  END IF;

  UPDATE public.email_finder_runs
    SET status        = 'FAILED',
        error_summary = p_error_summary,
        failed_at     = clock_timestamp()
  WHERE id = p_run_id;

  RETURN jsonb_build_object(
    'decision','FAILED','run_id',p_run_id,'error_summary',p_error_summary
  );
END;
$$;


-- 12. Privilege grants -------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.begin_email_finder_run(uuid, uuid, uuid, integer, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_email_finder_query_executed(uuid, text, jsonb, integer, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_email_finder_result_found(uuid, text, text, text, numeric, text, public.document_type_enum, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_email_finder_result_rejected(uuid, text, text, text, public.email_finder_result_outcome_enum, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.complete_email_finder_run(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fail_email_finder_run(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.begin_email_finder_run(uuid, uuid, uuid, integer, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_email_finder_query_executed(uuid, text, jsonb, integer, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_email_finder_result_found(uuid, text, text, text, numeric, text, public.document_type_enum, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_email_finder_result_rejected(uuid, text, text, text, public.email_finder_result_outcome_enum, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.complete_email_finder_run(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fail_email_finder_run(uuid, text) TO authenticated, service_role;
