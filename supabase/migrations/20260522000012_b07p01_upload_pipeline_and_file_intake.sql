-- B07·P01 — Upload Pipeline & File Intake
--
-- Two SECURITY DEFINER RPCs that bookend the Storage signed-URL flow:
--   * request_statement_upload  — pre-sign audit + path generation
--   * complete_statement_upload — post-upload INSERT into statement_uploads
--
-- Plus the duplicate-hash policy: UNIQUE (bank_account_id, file_hash). Per
-- spec, re-uploading the same file under the same bank account is rejected,
-- not silently ignored.
--
-- Spec: Docs/phases/07_bank_statement_pipeline/01_upload_pipeline_and_file_intake.md
--
-- Status lifecycle ownership boundary: P01 only writes status=UPLOADED.
-- Subsequent transitions (UPLOADED → PARSING → PARSED → ACCEPTED, → FAILED)
-- ship in P02 / P09. Spec is explicit: "Phase 01 ends here at status
-- UPLOADED — it never invokes the parser directly."

-- ============================================================================
-- 1. Duplicate-hash UNIQUE
-- ============================================================================
ALTER TABLE public.statement_uploads
  ADD CONSTRAINT statement_uploads_bank_account_hash_uq
  UNIQUE (bank_account_id, file_hash);
COMMENT ON CONSTRAINT statement_uploads_bank_account_hash_uq ON public.statement_uploads IS
  'Spec §Upload-completion handler: re-uploading the same file under the same bank account is rejected, not silently ignored. Cross-account duplicate rule is post-MVP per the duplicate-hash policy sub-doc.';

-- ============================================================================
-- 2. request_statement_upload — pre-sign audit + path
-- ============================================================================
CREATE OR REPLACE FUNCTION public.request_statement_upload(
  p_actor_user_id           uuid,
  p_business_id             uuid,
  p_bank_account_id         uuid,
  p_declared_period_start   date,
  p_declared_period_end     date,
  p_file_format             public.statement_file_format_enum,
  p_original_filename       text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_biz         public.business_entities%ROWTYPE;
  v_ba          public.bank_accounts%ROWTYPE;
  v_perm        jsonb;
  v_perm_dec    text;
  v_reject_code text;
  v_reject_msg  text;
  v_audit_row   audit.audit_events;
  v_raw_path    text;
  v_file_uuid   uuid := public.gen_uuid_v7();
BEGIN
  IF p_actor_user_id IS NULL OR p_business_id IS NULL OR p_bank_account_id IS NULL
     OR p_declared_period_start IS NULL OR p_declared_period_end IS NULL
     OR p_file_format IS NULL OR p_original_filename IS NULL
     OR length(trim(p_original_filename)) = 0 THEN
    RAISE EXCEPTION 'request_statement_upload: required params missing' USING ERRCODE = '22000';
  END IF;
  IF p_declared_period_end < p_declared_period_start THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'INVALID_PERIOD',
      'message', 'declared_period_end must be >= declared_period_start');
  END IF;

  SELECT * INTO v_biz FROM public.business_entities WHERE id = p_business_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'BUSINESS_NOT_FOUND',
      'message', format('business %s not found', p_business_id));
  END IF;

  SELECT * INTO v_ba FROM public.bank_accounts WHERE id = p_bank_account_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'BANK_ACCOUNT_NOT_FOUND',
      'message', format('bank_account %s not found', p_bank_account_id));
  END IF;
  IF v_ba.business_id <> p_business_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'BANK_ACCOUNT_TENANT_MISMATCH',
      'message', format('bank_account %s belongs to business %s, not %s',
                         p_bank_account_id, v_ba.business_id, p_business_id));
  END IF;

  v_perm := public.can_perform(
    p_actor_user_id   => p_actor_user_id,
    p_surface         => 'workflow_run',
    p_action          => 'execute',
    p_resource        => jsonb_build_object('action', 'statement_upload',
                                             'bank_account_id', p_bank_account_id),
    p_business_id     => p_business_id,
    p_organization_id => v_biz.organization_id);
  v_perm_dec := v_perm->>'decision';
  IF v_perm_dec = 'DENY' THEN
    v_reject_code := 'PERMISSION_DENIED';
    v_reject_msg  := format('actor lacks permission workflow_run:execute (reason=%s)',
                             v_perm->>'reason_code');
  ELSIF v_perm_dec NOT IN ('ALLOW','STEP_UP') THEN
    v_reject_code := 'PERMISSION_DENIED';
    v_reject_msg  := format('unexpected can_perform decision: %s', v_perm_dec);
  END IF;

  IF v_reject_code IS NOT NULL THEN
    v_audit_row := audit.emit_audit(
      p_actor_kind      => 'USER'::audit.actor_kind_enum,
      p_action          => 'STATEMENT_UPLOAD_REJECTED_PERMISSION',
      p_subject_type    => 'WORKFLOW_RUN'::audit.subject_type_enum,
      p_subject_id      => NULL,
      p_actor_user_id   => p_actor_user_id,
      p_business_id     => p_business_id,
      p_organization_id => v_biz.organization_id,
      p_reason          => v_reject_msg,
      p_after_state     => jsonb_build_object(
        'rejection_code', v_reject_code,
        'bank_account_id', p_bank_account_id,
        'declared_period_start', p_declared_period_start,
        'declared_period_end', p_declared_period_end,
        'file_format', p_file_format::text,
        'original_filename', p_original_filename));
    RETURN jsonb_build_object('ok', false, 'reason', v_reject_code,
      'message', v_reject_msg, 'audit_event_id', v_audit_row.id);
  END IF;

  v_raw_path := format('raw-uploads/%s/%s/%s.%s',
                        p_business_id, p_bank_account_id, v_file_uuid,
                        lower(p_file_format::text));

  v_audit_row := audit.emit_audit(
    p_actor_kind      => 'USER'::audit.actor_kind_enum,
    p_action          => 'STATEMENT_UPLOAD_REQUESTED',
    p_subject_type    => 'BANK_ACCOUNT'::audit.subject_type_enum,
    p_subject_id      => p_bank_account_id,
    p_actor_user_id   => p_actor_user_id,
    p_business_id     => p_business_id,
    p_organization_id => v_biz.organization_id,
    p_reason          => format('signed-upload request for bank account %s (%s file)',
                                 p_bank_account_id, p_file_format),
    p_after_state     => jsonb_build_object(
      'bank_account_id',       p_bank_account_id,
      'file_id',               v_file_uuid,
      'raw_path',              v_raw_path,
      'declared_period_start', p_declared_period_start,
      'declared_period_end',   p_declared_period_end,
      'file_format',           p_file_format::text,
      'original_filename',     p_original_filename));

  RETURN jsonb_build_object('ok', true,
    'file_id', v_file_uuid,
    'raw_path', v_raw_path,
    'declared_period_start', p_declared_period_start,
    'declared_period_end', p_declared_period_end,
    'file_format', p_file_format::text,
    'audit_event_id', v_audit_row.id);
END;
$function$;
COMMENT ON FUNCTION public.request_statement_upload(uuid, uuid, uuid, date, date, public.statement_file_format_enum, text) IS
  'Pre-sign step. Validates can_perform + bank-account tenancy + period shape; emits STATEMENT_UPLOAD_REQUESTED. Returns the raw_path the API layer feeds to Supabase Storage''s createSignedUploadUrl. On policy failure: emits STATEMENT_UPLOAD_REJECTED_PERMISSION (Mitigation A). On caller bugs (NOT_FOUND / period inversion): returns an ERROR envelope without audit.';

REVOKE EXECUTE ON FUNCTION public.request_statement_upload(uuid, uuid, uuid, date, date, public.statement_file_format_enum, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.request_statement_upload(uuid, uuid, uuid, date, date, public.statement_file_format_enum, text) TO service_role;

-- ============================================================================
-- 3. complete_statement_upload — post-Storage insert
-- ============================================================================
CREATE OR REPLACE FUNCTION public.complete_statement_upload(
  p_actor_user_id         uuid,
  p_business_id           uuid,
  p_bank_account_id       uuid,
  p_file_id               text,
  p_file_hash             text,
  p_file_format           public.statement_file_format_enum,
  p_provider              text,
  p_declared_period_start date,
  p_declared_period_end   date,
  p_original_filename     text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_biz         public.business_entities%ROWTYPE;
  v_ba          public.bank_accounts%ROWTYPE;
  v_perm        jsonb;
  v_perm_dec    text;
  v_reject_code text;
  v_reject_msg  text;
  v_audit_row   audit.audit_events;
  v_upload_id   uuid;
  v_existing    public.statement_uploads%ROWTYPE;
BEGIN
  IF p_actor_user_id IS NULL OR p_business_id IS NULL OR p_bank_account_id IS NULL
     OR p_file_id IS NULL OR p_file_hash IS NULL OR p_file_format IS NULL
     OR p_provider IS NULL OR p_declared_period_start IS NULL
     OR p_declared_period_end IS NULL OR p_original_filename IS NULL THEN
    RAISE EXCEPTION 'complete_statement_upload: required params missing' USING ERRCODE = '22000';
  END IF;
  IF p_file_hash !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'INVALID_HASH_FORMAT',
      'message', 'file_hash must be 64-char lowercase SHA-256 hex');
  END IF;
  IF p_provider NOT IN ('REVOLUT') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'UNKNOWN_PROVIDER',
      'message', format('provider %s not supported in MVP', p_provider));
  END IF;
  IF p_declared_period_end < p_declared_period_start THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'INVALID_PERIOD',
      'message', 'declared_period_end must be >= declared_period_start');
  END IF;

  SELECT * INTO v_biz FROM public.business_entities WHERE id = p_business_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'BUSINESS_NOT_FOUND');
  END IF;
  SELECT * INTO v_ba FROM public.bank_accounts WHERE id = p_bank_account_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'BANK_ACCOUNT_NOT_FOUND');
  END IF;
  IF v_ba.business_id <> p_business_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'BANK_ACCOUNT_TENANT_MISMATCH');
  END IF;

  v_perm := public.can_perform(
    p_actor_user_id   => p_actor_user_id,
    p_surface         => 'workflow_run',
    p_action          => 'execute',
    p_resource        => jsonb_build_object('action', 'statement_upload',
                                             'bank_account_id', p_bank_account_id),
    p_business_id     => p_business_id,
    p_organization_id => v_biz.organization_id);
  v_perm_dec := v_perm->>'decision';
  IF v_perm_dec = 'DENY' THEN
    v_reject_code := 'PERMISSION_DENIED';
    v_reject_msg  := format('actor lacks permission workflow_run:execute (reason=%s)',
                             v_perm->>'reason_code');
  ELSIF v_perm_dec NOT IN ('ALLOW','STEP_UP') THEN
    v_reject_code := 'PERMISSION_DENIED';
    v_reject_msg  := format('unexpected can_perform decision: %s', v_perm_dec);
  END IF;
  IF v_reject_code IS NOT NULL THEN
    v_audit_row := audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum,
      p_action => 'STATEMENT_UPLOAD_REJECTED_PERMISSION',
      p_subject_type => 'BANK_ACCOUNT'::audit.subject_type_enum,
      p_subject_id => p_bank_account_id,
      p_actor_user_id => p_actor_user_id,
      p_business_id => p_business_id, p_organization_id => v_biz.organization_id,
      p_reason => v_reject_msg,
      p_after_state => jsonb_build_object('rejection_code', v_reject_code,
        'bank_account_id', p_bank_account_id, 'file_hash', p_file_hash,
        'file_format', p_file_format::text));
    RETURN jsonb_build_object('ok', false, 'reason', v_reject_code,
      'message', v_reject_msg, 'audit_event_id', v_audit_row.id);
  END IF;

  -- Try INSERT first; rely on UNIQUE(bank_account_id, file_hash) for race
  -- safety. Catch the unique_violation, look up the existing row, and emit
  -- the duplicate-hash reject (Mitigation A).
  BEGIN
    INSERT INTO public.statement_uploads (
      organization_id, business_id, bank_account_id,
      file_id, file_hash, file_format, provider, original_filename,
      declared_period_start, declared_period_end,
      upload_status, uploaded_by
    ) VALUES (
      v_biz.organization_id, p_business_id, p_bank_account_id,
      p_file_id, p_file_hash, p_file_format, p_provider, p_original_filename,
      p_declared_period_start, p_declared_period_end,
      'UPLOADED'::public.statement_upload_status_enum, p_actor_user_id
    )
    RETURNING id INTO v_upload_id;
  EXCEPTION
    WHEN unique_violation THEN
      SELECT * INTO v_existing FROM public.statement_uploads
        WHERE bank_account_id = p_bank_account_id AND file_hash = p_file_hash;
      v_audit_row := audit.emit_audit(
        p_actor_kind => 'USER'::audit.actor_kind_enum,
        p_action => 'STATEMENT_UPLOAD_REJECTED_DUPLICATE_HASH',
        p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
        p_subject_id => v_existing.id,
        p_actor_user_id => p_actor_user_id,
        p_business_id => p_business_id, p_organization_id => v_biz.organization_id,
        p_reason => format('duplicate file_hash on bank_account %s (existing upload %s)',
                            p_bank_account_id, v_existing.id),
        p_after_state => jsonb_build_object(
          'rejection_code', 'DUPLICATE_HASH',
          'bank_account_id', p_bank_account_id,
          'file_hash', p_file_hash,
          'existing_upload_id', v_existing.id,
          'existing_uploaded_at', v_existing.uploaded_at,
          'attempted_filename', p_original_filename));
      RETURN jsonb_build_object('ok', false, 'reason', 'DUPLICATE_HASH',
        'existing_upload_id', v_existing.id,
        'message', format('file with this hash already uploaded for bank_account %s',
                           p_bank_account_id),
        'audit_event_id', v_audit_row.id);
  END;

  v_audit_row := audit.emit_audit(
    p_actor_kind      => 'USER'::audit.actor_kind_enum,
    p_action          => 'STATEMENT_UPLOAD_COMPLETED',
    p_subject_type    => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id      => v_upload_id,
    p_actor_user_id   => p_actor_user_id,
    p_business_id     => p_business_id,
    p_organization_id => v_biz.organization_id,
    p_reason          => format('statement upload %s landed for bank_account %s (%s file)',
                                 v_upload_id, p_bank_account_id, p_file_format),
    p_after_state     => jsonb_build_object(
      'upload_id',             v_upload_id,
      'bank_account_id',       p_bank_account_id,
      'file_id',               p_file_id,
      'file_hash',             p_file_hash,
      'file_format',           p_file_format::text,
      'provider',              p_provider,
      'declared_period_start', p_declared_period_start,
      'declared_period_end',   p_declared_period_end,
      'original_filename',     p_original_filename,
      'upload_status',         'UPLOADED'));

  RETURN jsonb_build_object('ok', true,
    'upload_id', v_upload_id,
    'upload_status', 'UPLOADED',
    'audit_event_id', v_audit_row.id);
END;
$function$;
COMMENT ON FUNCTION public.complete_statement_upload(uuid, uuid, uuid, text, text, public.statement_file_format_enum, text, date, date, text) IS
  'Post-upload completion handler. Validates can_perform + bank-account tenancy + provider allowlist + file_hash shape, then INSERTs the statement_uploads row at status=UPLOADED. UNIQUE(bank_account_id, file_hash) violation → STATEMENT_UPLOAD_REJECTED_DUPLICATE_HASH (Mitigation A). Status lifecycle past UPLOADED is owned by B07·P02 / B03·P09.';

REVOKE EXECUTE ON FUNCTION public.complete_statement_upload(uuid, uuid, uuid, text, text, public.statement_file_format_enum, text, date, date, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_statement_upload(uuid, uuid, uuid, text, text, public.statement_file_format_enum, text, date, date, text) TO service_role;
