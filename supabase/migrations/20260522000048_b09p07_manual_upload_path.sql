-- B09·P07 — Manual Upload Path — DB scaffold.
-- Lifecycle for user-driven document uploads + 5 stub-reason variants that
-- close a transaction's missing-evidence requirement without a real file.
--
-- Audit family additions:
--   MANUAL_UPLOAD_INITIATED                (TRANSACTION subject)
--   MANUAL_UPLOAD_COMPLETED                (DOCUMENT subject — new doc)
--   DOCUMENT_MANUAL_LINKED_TO_TRANSACTION  (DOCUMENT subject; payload txn_id)
-- (DOCUMENT_STUB_CREATED is emitted by B09·P02's create_document_stub.)

-- 1. Enums -------------------------------------------------------------------

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname='stub_reason_enum' AND typnamespace='public'::regnamespace) THEN
    CREATE TYPE public.stub_reason_enum AS ENUM (
      'NO_INVOICE_AVAILABLE',
      'INTERNAL_TRANSFER',
      'NON_DEDUCTIBLE',
      'BANK_FEE',
      'AWAITING_ACCOUNTANT_REVIEW'
    );
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname='manual_upload_status_enum' AND typnamespace='public'::regnamespace) THEN
    CREATE TYPE public.manual_upload_status_enum AS ENUM ('REQUESTED','COMPLETED','FAILED');
  END IF;
END$$;


-- 2. documents.stub_reason ---------------------------------------------------

ALTER TABLE public.documents
  ADD COLUMN IF NOT EXISTS stub_reason public.stub_reason_enum;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid
    WHERE t.relname='documents' AND c.conname='documents_stub_reason_requires_stub_type_chk'
  ) THEN
    ALTER TABLE public.documents
      ADD CONSTRAINT documents_stub_reason_requires_stub_type_chk
      CHECK (stub_reason IS NULL OR document_type = 'STUB');
  END IF;
END$$;


-- 3. manual_uploads lifecycle table ------------------------------------------

CREATE TABLE IF NOT EXISTS public.manual_uploads (
  id                      uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id         uuid NOT NULL,
  business_id             uuid NOT NULL,
  transaction_id          uuid NOT NULL,
  document_type           public.document_type_enum NOT NULL,
  requested_by_user_id    uuid NOT NULL,
  status                  public.manual_upload_status_enum NOT NULL,
  file_hash               text,
  file_size               bigint,
  original_filename       text,
  document_id             uuid,
  error_summary           text,
  requested_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at            timestamptz,
  failed_at               timestamptz,
  CONSTRAINT mu_file_size_nonneg CHECK (file_size IS NULL OR file_size >= 0),
  CONSTRAINT mu_completed_pairing CHECK (
    (status <> 'COMPLETED')
    OR (
      completed_at IS NOT NULL
      AND document_id IS NOT NULL
      AND file_hash IS NOT NULL AND length(trim(file_hash)) > 0
    )
  ),
  CONSTRAINT mu_failed_pairing CHECK (
    (status <> 'FAILED')
    OR (failed_at IS NOT NULL AND error_summary IS NOT NULL AND length(trim(error_summary)) > 0)
  ),
  CONSTRAINT mu_org_fk      FOREIGN KEY (organization_id) REFERENCES public.organizations(id)    ON DELETE RESTRICT,
  CONSTRAINT mu_business_fk FOREIGN KEY (business_id)     REFERENCES public.business_entities(id) ON DELETE RESTRICT,
  CONSTRAINT mu_document_fk FOREIGN KEY (document_id)     REFERENCES public.documents(id)         ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS mu_by_txn
  ON public.manual_uploads (business_id, transaction_id, requested_at DESC);

ALTER TABLE public.manual_uploads ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mu_select ON public.manual_uploads;
CREATE POLICY mu_select ON public.manual_uploads FOR SELECT
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
DROP POLICY IF EXISTS mu_no_insert ON public.manual_uploads;
CREATE POLICY mu_no_insert ON public.manual_uploads FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS mu_no_update ON public.manual_uploads;
CREATE POLICY mu_no_update ON public.manual_uploads FOR UPDATE USING (false);
DROP POLICY IF EXISTS mu_no_delete ON public.manual_uploads;
CREATE POLICY mu_no_delete ON public.manual_uploads FOR DELETE USING (false);


-- 4. request_manual_upload ---------------------------------------------------

CREATE OR REPLACE FUNCTION public.request_manual_upload(
  p_organization_id      uuid,
  p_business_id          uuid,
  p_transaction_id       uuid,
  p_document_type        public.document_type_enum,
  p_requested_by_user_id uuid,
  p_context              jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_upload_id uuid;
BEGIN
  INSERT INTO public.manual_uploads (
    organization_id, business_id, transaction_id, document_type,
    requested_by_user_id, status
  ) VALUES (
    p_organization_id, p_business_id, p_transaction_id, p_document_type,
    p_requested_by_user_id, 'REQUESTED'
  ) RETURNING id INTO v_upload_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='MANUAL_UPLOAD_INITIATED',
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=p_transaction_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='manual_upload',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'upload_id',v_upload_id,
      'document_type',p_document_type,
      'requested_by_user_id',p_requested_by_user_id
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','REQUESTED','upload_id',v_upload_id,
    'transaction_id',p_transaction_id
  );
END;
$$;


-- 5. confirm_manual_upload ---------------------------------------------------

CREATE OR REPLACE FUNCTION public.confirm_manual_upload(
  p_upload_id         uuid,
  p_file_hash         text,
  p_file_size         bigint,
  p_original_filename text,
  p_context           jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid; v_business_id uuid; v_transaction_id uuid;
  v_document_type   public.document_type_enum;
  v_status          public.manual_upload_status_enum;
  v_new_doc_id      uuid;
  v_transition_env  jsonb;
BEGIN
  IF p_file_hash IS NULL OR length(trim(p_file_hash)) = 0 THEN
    RAISE EXCEPTION 'FILE_HASH_REQUIRED' USING errcode='check_violation';
  END IF;

  SELECT organization_id, business_id, transaction_id, document_type, status
    INTO v_organization_id, v_business_id, v_transaction_id, v_document_type, v_status
  FROM public.manual_uploads WHERE id = p_upload_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','UPLOAD_NOT_FOUND','upload_id',p_upload_id);
  END IF;
  IF v_status <> 'REQUESTED' THEN
    RETURN jsonb_build_object(
      'decision','REJECTED','reason','UPLOAD_NOT_REQUESTED',
      'upload_id',p_upload_id,'current_status',v_status
    );
  END IF;

  -- Create document at DISCOVERED (default)
  INSERT INTO public.documents (
    organization_id, business_id, source, document_type,
    source_location, original_filename, document_hash, discovery_reason
  ) VALUES (
    v_organization_id, v_business_id, 'MANUAL', v_document_type,
    'manual:' || p_upload_id::text, p_original_filename, p_file_hash,
    'manual_upload'
  ) RETURNING id INTO v_new_doc_id;

  -- Source link
  INSERT INTO public.document_source_links (
    organization_id, business_id, document_id, source_kind,
    source_external_id, discovery_reason
  ) VALUES (
    v_organization_id, v_business_id, v_new_doc_id, 'MANUAL',
    'manual:' || p_upload_id::text, 'manual_upload'
  );

  -- Transition through B09·P02 chokepoint: DISCOVERED → INGESTED
  v_transition_env := public.transition_document(
    p_document_id  => v_new_doc_id,
    p_target_state => 'INGESTED'::public.document_extraction_status_enum,
    p_reason       => 'manual_upload_confirmed',
    p_context      => jsonb_build_object('upload_id', p_upload_id) || COALESCE(p_context,'{}'::jsonb)
  );

  -- Mark upload COMPLETED
  UPDATE public.manual_uploads
    SET status='COMPLETED', document_id=v_new_doc_id,
        file_hash=p_file_hash, file_size=p_file_size,
        original_filename=p_original_filename, completed_at=clock_timestamp()
  WHERE id = p_upload_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='MANUAL_UPLOAD_COMPLETED',
    p_subject_type:='DOCUMENT'::audit.subject_type_enum,
    p_subject_id:=v_new_doc_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='manual_upload',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'upload_id',p_upload_id,'document_id',v_new_doc_id,
      'file_hash',p_file_hash,'file_size',p_file_size,
      'transition',v_transition_env
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='DOCUMENT_MANUAL_LINKED_TO_TRANSACTION',
    p_subject_type:='DOCUMENT'::audit.subject_type_enum,
    p_subject_id:=v_new_doc_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='manual_upload',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'document_id',v_new_doc_id,'transaction_id',v_transaction_id,
      'upload_id',p_upload_id,'origin','manual_upload'
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','COMPLETED','upload_id',p_upload_id,
    'document_id',v_new_doc_id,'transaction_id',v_transaction_id,
    'transition',v_transition_env
  );
END;
$$;


-- 6. fail_manual_upload ------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fail_manual_upload(
  p_upload_id     uuid,
  p_error_summary text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_status public.manual_upload_status_enum;
BEGIN
  IF p_error_summary IS NULL OR length(trim(p_error_summary)) = 0 THEN
    RAISE EXCEPTION 'ERROR_SUMMARY_REQUIRED' USING errcode='check_violation';
  END IF;
  SELECT status INTO v_status FROM public.manual_uploads WHERE id = p_upload_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','UPLOAD_NOT_FOUND','upload_id',p_upload_id);
  END IF;
  IF v_status <> 'REQUESTED' THEN
    RETURN jsonb_build_object(
      'decision','REJECTED','reason','UPLOAD_NOT_REQUESTED',
      'upload_id',p_upload_id,'current_status',v_status
    );
  END IF;
  UPDATE public.manual_uploads
    SET status='FAILED', error_summary=p_error_summary, failed_at=clock_timestamp()
  WHERE id = p_upload_id;
  RETURN jsonb_build_object(
    'decision','FAILED','upload_id',p_upload_id,'error_summary',p_error_summary
  );
END;
$$;


-- 7. create_transaction_stub -------------------------------------------------

CREATE OR REPLACE FUNCTION public.create_transaction_stub(
  p_organization_id   uuid,
  p_business_id       uuid,
  p_transaction_id    uuid,
  p_stub_reason       public.stub_reason_enum,
  p_reason_text       text,
  p_workflow_run_id   uuid,
  p_actor_user_id     uuid,
  p_step_up_token_id  uuid    DEFAULT NULL,
  p_context           jsonb   DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_requires_step_up  boolean;
  v_consumed          boolean;
  v_token_reason      text;
  v_stub_envelope     jsonb;
  v_doc_id            uuid;
  v_action_id         uuid := public.gen_uuid_v7();
BEGIN
  IF p_reason_text IS NULL OR length(trim(p_reason_text)) = 0 THEN
    RAISE EXCEPTION 'REASON_TEXT_REQUIRED' USING errcode='check_violation';
  END IF;

  -- Step-up enforcement: only NO_INVOICE_AVAILABLE and NON_DEDUCTIBLE require it
  v_requires_step_up := p_stub_reason IN ('NO_INVOICE_AVAILABLE','NON_DEDUCTIBLE');

  IF v_requires_step_up THEN
    IF p_step_up_token_id IS NULL THEN
      RETURN jsonb_build_object(
        'decision','REJECTED','reason','STEP_UP_REQUIRED',
        'stub_reason',p_stub_reason
      );
    END IF;
    SELECT consumed, reason
      INTO v_consumed, v_token_reason
    FROM public.consume_step_up_token(
      p_step_up_token_id, p_business_id,
      'b09p07.create_transaction_stub', v_action_id
    );
    IF NOT COALESCE(v_consumed, false) THEN
      RETURN jsonb_build_object(
        'decision','REJECTED','reason','STEP_UP_TOKEN_NOT_CONSUMED',
        'token_reason',v_token_reason,'stub_reason',p_stub_reason
      );
    END IF;
  END IF;

  -- Delegate to B09·P02 to create the stub doc + emit DOCUMENT_STUB_CREATED +
  -- transition DISCOVERED → DISMISSED via the is_stub_only registry row.
  v_stub_envelope := public.create_document_stub(
    p_organization_id => p_organization_id,
    p_business_id     => p_business_id,
    p_reason          => p_reason_text,
    p_context         => jsonb_build_object(
                           'transaction_id', p_transaction_id,
                           'stub_reason',    p_stub_reason,
                           'workflow_run_id',p_workflow_run_id
                         ) || COALESCE(p_context,'{}'::jsonb)
  );

  v_doc_id := (v_stub_envelope->>'document_id')::uuid;

  -- Tag the new stub document with the structured reason
  UPDATE public.documents
    SET stub_reason = p_stub_reason
  WHERE id = v_doc_id;

  -- Emit the manual-linkage audit (carries stub_reason + transaction_id)
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='DOCUMENT_MANUAL_LINKED_TO_TRANSACTION',
    p_subject_type:='DOCUMENT'::audit.subject_type_enum,
    p_subject_id:=v_doc_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='manual_upload',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'document_id',v_doc_id,
      'transaction_id',p_transaction_id,
      'stub_reason',p_stub_reason,
      'origin','transaction_stub',
      'workflow_run_id',p_workflow_run_id,
      'step_up_required',v_requires_step_up
    ),
    p_reason:=p_reason_text, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','STUB_CREATED',
    'document_id',v_doc_id,
    'transaction_id',p_transaction_id,
    'stub_reason',p_stub_reason,
    'step_up_required',v_requires_step_up,
    'stub_envelope',v_stub_envelope
  );
END;
$$;


-- 8. Privilege grants --------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.request_manual_upload(uuid, uuid, uuid, public.document_type_enum, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.confirm_manual_upload(uuid, text, bigint, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fail_manual_upload(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.create_transaction_stub(uuid, uuid, uuid, public.stub_reason_enum, text, uuid, uuid, uuid, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.request_manual_upload(uuid, uuid, uuid, public.document_type_enum, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.confirm_manual_upload(uuid, text, bigint, text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fail_manual_upload(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_transaction_stub(uuid, uuid, uuid, public.stub_reason_enum, text, uuid, uuid, uuid, jsonb) TO authenticated, service_role;
