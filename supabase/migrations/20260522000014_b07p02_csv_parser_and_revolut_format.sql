-- B07·P02 — CSV Parser & Revolut Format
--
-- Ships the SQL contract for an extensible (provider, file_format) parser
-- framework with Revolut CSV as the seeded first format. SQL provides:
--   1. statement_parser_registry — (provider, file_format, version) registry
--      pointing at a Python parser module reference
--   2. statement_parse_runs — per-attempt lifecycle row (STARTED/COMPLETED/
--      FAILED/CANCELLED) recording which parser version ran
--   3. statement_parsed_rows — ParsedRow[] storage: provider_native verbatim
--      jsonb + normalized candidate fields ready for Phase 04 normalization
--   4. RPCs:
--      - register_statement_parser (Owner-only via can_perform, Mitigation A)
--      - start_statement_parse  (UPLOADED -> PARSING, emits STATEMENT_PARSE_STARTED)
--      - record_parsed_row      (per-row INSERT; no audit per row — would flood)
--      - complete_statement_parse (PARSING -> PARSED, emits STATEMENT_PARSE_COMPLETED with row_count)
--      - fail_statement_parse   (PARSING -> FAILED, emits STATEMENT_PARSE_FAILED with error_category)
--
-- Orchestrator-deferral: the Python CSV-reading body (split rows, decode
-- encoding, recognize Revolut columns, FX-pair detection) lives in api/ and
-- arrives with the dispatch orchestrator. The orchestrator calls
-- start_statement_parse -> N record_parsed_row -> complete_statement_parse,
-- or fail_statement_parse on any unrecoverable parser error. The Revolut
-- column-layout details are owned by the Stage-4 sub-doc.
--
-- Review-issue creation on parse failure is owned by B07·P08 (failure-mode
-- mapping). This phase only records the FAILED transition.
--
-- ============================================================================
-- 1. Enums
-- ============================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'statement_parse_status_enum') THEN
    CREATE TYPE public.statement_parse_status_enum AS ENUM (
      'STARTED', 'COMPLETED', 'FAILED', 'CANCELLED'
    );
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'parsed_row_direction_hint_enum') THEN
    CREATE TYPE public.parsed_row_direction_hint_enum AS ENUM (
      'IN', 'OUT', 'UNKNOWN'
    );
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'statement_parse_error_category_enum') THEN
    CREATE TYPE public.statement_parse_error_category_enum AS ENUM (
      'MALFORMED_CSV',
      'EMPTY_FILE',
      'MISSING_HEADERS',
      'WRONG_COLUMN_COUNT',
      'UNREADABLE_ENCODING',
      'UNKNOWN_PROVIDER_FORMAT',
      'INTERNAL_ERROR'
    );
  END IF;
END$$;

-- ============================================================================
-- 2. statement_parser_registry
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.statement_parser_registry (
  provider           text NOT NULL,
  file_format        public.statement_file_format_enum NOT NULL,
  version            text NOT NULL,
  parser_module_ref  text NOT NULL,
  is_active          boolean NOT NULL DEFAULT true,
  notes              text,
  registered_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
  registered_by_user_id uuid REFERENCES public.users(id),
  updated_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT statement_parser_registry_pkey PRIMARY KEY (provider, file_format, version),
  CONSTRAINT statement_parser_registry_provider_upper CHECK (provider ~ '^[A-Z][A-Z0-9_]{1,49}$'),
  CONSTRAINT statement_parser_registry_version_semver  CHECK (version ~ '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$'),
  CONSTRAINT statement_parser_registry_module_ref_dotted CHECK (parser_module_ref ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+:[a-z][a-z0-9_]*$')
);

-- At most one active version per (provider, file_format).
CREATE UNIQUE INDEX IF NOT EXISTS statement_parser_registry_active_uq
  ON public.statement_parser_registry (provider, file_format)
  WHERE is_active;

REVOKE ALL ON public.statement_parser_registry FROM PUBLIC, authenticated, anon;
GRANT  SELECT ON public.statement_parser_registry TO service_role;

-- ============================================================================
-- 3. statement_parse_runs
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.statement_parse_runs (
  id                      uuid PRIMARY KEY,
  statement_upload_id     uuid NOT NULL REFERENCES public.statement_uploads(id),
  business_id             uuid NOT NULL REFERENCES public.business_entities(id),
  organization_id         uuid NOT NULL REFERENCES public.organizations(id),
  status                  public.statement_parse_status_enum NOT NULL DEFAULT 'STARTED',
  parser_provider         text NOT NULL,
  parser_file_format      public.statement_file_format_enum NOT NULL,
  parser_version          text NOT NULL,
  row_count               int  NOT NULL DEFAULT 0,
  error_category          public.statement_parse_error_category_enum,
  error_message           text,
  started_at              timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at            timestamptz,
  created_at              timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at              timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT statement_parse_runs_row_count_nonneg CHECK (row_count >= 0),
  CONSTRAINT statement_parse_runs_failed_has_error CHECK (
    (status = 'FAILED') = (error_category IS NOT NULL AND error_message IS NOT NULL)
  ),
  CONSTRAINT statement_parse_runs_terminal_has_completed_at CHECK (
    (status IN ('COMPLETED','FAILED','CANCELLED')) = (completed_at IS NOT NULL)
  ),
  CONSTRAINT statement_parse_runs_parser_fk FOREIGN KEY
    (parser_provider, parser_file_format, parser_version)
    REFERENCES public.statement_parser_registry (provider, file_format, version)
);

CREATE INDEX IF NOT EXISTS statement_parse_runs_upload_idx
  ON public.statement_parse_runs (statement_upload_id, started_at DESC);

CREATE INDEX IF NOT EXISTS statement_parse_runs_business_idx
  ON public.statement_parse_runs (business_id, started_at DESC);

REVOKE ALL ON public.statement_parse_runs FROM PUBLIC, authenticated, anon;
GRANT  SELECT ON public.statement_parse_runs TO service_role;

-- ============================================================================
-- 4. statement_parsed_rows
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.statement_parsed_rows (
  id                    uuid PRIMARY KEY,
  parse_run_id          uuid NOT NULL REFERENCES public.statement_parse_runs(id) ON DELETE CASCADE,
  statement_upload_id   uuid NOT NULL REFERENCES public.statement_uploads(id),
  source_row_index      int  NOT NULL,
  provider_native       jsonb NOT NULL,
  date_text             text NOT NULL,
  amount_text           text NOT NULL,
  currency              text NOT NULL,
  description_text      text,
  reference_text        text,
  counterparty_text     text,
  direction_hint        public.parsed_row_direction_hint_enum NOT NULL DEFAULT 'UNKNOWN',
  created_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT statement_parsed_rows_source_row_index_nonneg CHECK (source_row_index >= 0),
  CONSTRAINT statement_parsed_rows_currency_iso CHECK (currency ~ '^[A-Z]{3}$'),
  CONSTRAINT statement_parsed_rows_provider_native_obj CHECK (jsonb_typeof(provider_native) = 'object'),
  CONSTRAINT statement_parsed_rows_run_index_uq UNIQUE (parse_run_id, source_row_index)
);

CREATE INDEX IF NOT EXISTS statement_parsed_rows_upload_idx
  ON public.statement_parsed_rows (statement_upload_id, source_row_index);

REVOKE ALL ON public.statement_parsed_rows FROM PUBLIC, authenticated, anon;
GRANT  SELECT ON public.statement_parsed_rows TO service_role;

-- ============================================================================
-- 5. RPC: register_statement_parser  (Owner-only, Mitigation A)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.register_statement_parser(
  p_actor_user_id    uuid,
  p_provider         text,
  p_file_format      public.statement_file_format_enum,
  p_version          text,
  p_parser_module_ref text,
  p_business_id      uuid DEFAULT NULL,
  p_organization_id  uuid DEFAULT NULL,
  p_notes            text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_decision   text;
  v_can        jsonb;
  v_inserted   boolean;
  v_audit_row  audit.audit_events;
BEGIN
  IF p_provider IS NULL OR p_file_format IS NULL OR p_version IS NULL
     OR p_parser_module_ref IS NULL THEN
    RAISE EXCEPTION 'register_statement_parser: required params missing'
      USING ERRCODE='22000';
  END IF;
  IF p_provider !~ '^[A-Z][A-Z0-9_]{1,49}$' THEN
    RAISE EXCEPTION 'register_statement_parser: provider must match ^[A-Z][A-Z0-9_]{1,49}$ (got %)', p_provider
      USING ERRCODE='22023';
  END IF;
  IF p_version !~ '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$' THEN
    RAISE EXCEPTION 'register_statement_parser: version must be semver (got %)', p_version
      USING ERRCODE='22023';
  END IF;
  IF p_parser_module_ref !~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+:[a-z][a-z0-9_]*$' THEN
    RAISE EXCEPTION 'register_statement_parser: parser_module_ref must be dotted.path:callable (got %)', p_parser_module_ref
      USING ERRCODE='22023';
  END IF;

  v_can := public.can_perform(
    p_actor_user_id, 'statement_parser_registry', 'REGISTER',
    jsonb_build_object('provider', p_provider, 'file_format', p_file_format::text, 'version', p_version),
    p_business_id, p_organization_id);
  v_decision := v_can->>'decision';
  IF v_decision <> 'ALLOW' THEN
    v_audit_row := audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum,
      p_action     => 'STATEMENT_PARSER_REGISTRATION_DENIED',
      p_subject_type => 'STATEMENT_PARSER'::audit.subject_type_enum,
      p_subject_id   => NULL,
      p_actor_user_id => p_actor_user_id,
      p_organization_id => p_organization_id, p_business_id => p_business_id,
      p_reason => format('policy decision %s for parser registration %s/%s/%s',
                         v_decision, p_provider, p_file_format::text, p_version),
      p_after_state => jsonb_build_object('decision', v_decision,
        'provider', p_provider, 'file_format', p_file_format::text, 'version', p_version));
    RETURN jsonb_build_object('ok', false, 'reason', 'POLICY_DENIED',
                              'decision', v_decision, 'audit_event_id', v_audit_row.id);
  END IF;

  INSERT INTO public.statement_parser_registry
    (provider, file_format, version, parser_module_ref, is_active,
     notes, registered_by_user_id, registered_at, updated_at)
  VALUES
    (p_provider, p_file_format, p_version, p_parser_module_ref, true,
     p_notes, p_actor_user_id, clock_timestamp(), clock_timestamp())
  ON CONFLICT (provider, file_format, version) DO UPDATE
    SET parser_module_ref = EXCLUDED.parser_module_ref,
        notes             = EXCLUDED.notes,
        is_active         = true,
        updated_at        = clock_timestamp();

  v_inserted := true;  -- UPSERT — caller cares about the resulting row, not which path

  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action     => 'STATEMENT_PARSER_REGISTERED',
    p_subject_type => 'STATEMENT_PARSER'::audit.subject_type_enum,
    p_subject_id   => NULL,
    p_actor_user_id => p_actor_user_id,
    p_organization_id => p_organization_id, p_business_id => p_business_id,
    p_reason => format('parser %s/%s/%s registered -> %s',
                       p_provider, p_file_format::text, p_version, p_parser_module_ref),
    p_after_state => jsonb_build_object(
      'provider',          p_provider,
      'file_format',       p_file_format::text,
      'version',           p_version,
      'parser_module_ref', p_parser_module_ref,
      'is_active',         true));

  RETURN jsonb_build_object('ok', true,
    'provider', p_provider, 'file_format', p_file_format::text, 'version', p_version,
    'audit_event_id', v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.register_statement_parser(uuid, text, public.statement_file_format_enum, text, text, uuid, uuid, text) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.register_statement_parser(uuid, text, public.statement_file_format_enum, text, text, uuid, uuid, text) TO service_role;

-- ============================================================================
-- 6. RPC: start_statement_parse
-- ============================================================================
CREATE OR REPLACE FUNCTION public.start_statement_parse(
  p_statement_upload_id uuid,
  p_actor_user_id       uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_upload     public.statement_uploads%ROWTYPE;
  v_parser     public.statement_parser_registry%ROWTYPE;
  v_run_id     uuid := public.gen_uuid_v7();
  v_audit_row  audit.audit_events;
  v_kind       audit.actor_kind_enum;
  v_system     text;
BEGIN
  IF p_statement_upload_id IS NULL THEN
    RAISE EXCEPTION 'start_statement_parse: p_statement_upload_id is required'
      USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_upload FROM public.statement_uploads
    WHERE id = p_statement_upload_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'start_statement_parse: statement_upload % not found', p_statement_upload_id
      USING ERRCODE='02000';
  END IF;
  IF v_upload.upload_status <> 'UPLOADED'::public.statement_upload_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'UPLOAD_NOT_IN_UPLOADED_STATE',
      'current_status', v_upload.upload_status::text);
  END IF;

  SELECT * INTO v_parser FROM public.statement_parser_registry
    WHERE provider = v_upload.provider AND file_format = v_upload.file_format
      AND is_active = true
    LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NO_ACTIVE_PARSER',
      'provider', v_upload.provider, 'file_format', v_upload.file_format::text);
  END IF;

  INSERT INTO public.statement_parse_runs
    (id, statement_upload_id, business_id, organization_id, status,
     parser_provider, parser_file_format, parser_version,
     row_count, started_at, created_at, updated_at)
  VALUES
    (v_run_id, v_upload.id, v_upload.business_id, v_upload.organization_id, 'STARTED',
     v_parser.provider, v_parser.file_format, v_parser.version,
     0, clock_timestamp(), clock_timestamp(), clock_timestamp());

  UPDATE public.statement_uploads
    SET upload_status = 'PARSING'::public.statement_upload_status_enum,
        updated_at    = clock_timestamp()
    WHERE id = v_upload.id;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_parser';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'STATEMENT_PARSE_STARTED',
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id   => v_upload.id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_upload.organization_id, p_business_id => v_upload.business_id,
    p_before_state => jsonb_build_object('upload_status', 'UPLOADED'),
    p_after_state  => jsonb_build_object(
      'upload_status',      'PARSING',
      'parse_run_id',       v_run_id,
      'parser_provider',    v_parser.provider,
      'parser_file_format', v_parser.file_format::text,
      'parser_version',     v_parser.version),
    p_reason => format('parse started by %s/%s/%s',
                       v_parser.provider, v_parser.file_format::text, v_parser.version));

  RETURN jsonb_build_object('ok', true,
    'parse_run_id',     v_run_id,
    'parser_provider',  v_parser.provider,
    'parser_file_format', v_parser.file_format::text,
    'parser_version',   v_parser.version,
    'parser_module_ref', v_parser.parser_module_ref,
    'audit_event_id',   v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.start_statement_parse(uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.start_statement_parse(uuid, uuid) TO service_role;

-- ============================================================================
-- 7. RPC: record_parsed_row
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_parsed_row(
  p_parse_run_id      uuid,
  p_source_row_index  int,
  p_provider_native   jsonb,
  p_date_text         text,
  p_amount_text       text,
  p_currency          text,
  p_direction_hint    public.parsed_row_direction_hint_enum DEFAULT 'UNKNOWN',
  p_description_text  text DEFAULT NULL,
  p_reference_text    text DEFAULT NULL,
  p_counterparty_text text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run    public.statement_parse_runs%ROWTYPE;
  v_row_id uuid := public.gen_uuid_v7();
BEGIN
  IF p_parse_run_id IS NULL OR p_source_row_index IS NULL
     OR p_provider_native IS NULL OR p_date_text IS NULL
     OR p_amount_text IS NULL OR p_currency IS NULL THEN
    RAISE EXCEPTION 'record_parsed_row: required params missing'
      USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_run FROM public.statement_parse_runs
    WHERE id = p_parse_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_parsed_row: parse_run % not found', p_parse_run_id
      USING ERRCODE='02000';
  END IF;
  IF v_run.status <> 'STARTED'::public.statement_parse_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'PARSE_RUN_NOT_STARTED',
      'current_status', v_run.status::text);
  END IF;

  BEGIN
    INSERT INTO public.statement_parsed_rows
      (id, parse_run_id, statement_upload_id, source_row_index, provider_native,
       date_text, amount_text, currency, description_text, reference_text,
       counterparty_text, direction_hint, created_at)
    VALUES
      (v_row_id, p_parse_run_id, v_run.statement_upload_id, p_source_row_index,
       p_provider_native, p_date_text, p_amount_text, p_currency,
       p_description_text, p_reference_text, p_counterparty_text,
       p_direction_hint, clock_timestamp());
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'DUPLICATE_ROW_INDEX',
      'parse_run_id', p_parse_run_id, 'source_row_index', p_source_row_index);
  END;

  UPDATE public.statement_parse_runs
    SET row_count  = row_count + 1,
        updated_at = clock_timestamp()
    WHERE id = p_parse_run_id;

  RETURN jsonb_build_object('ok', true, 'parsed_row_id', v_row_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_parsed_row(uuid, int, jsonb, text, text, text, public.parsed_row_direction_hint_enum, text, text, text) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_parsed_row(uuid, int, jsonb, text, text, text, public.parsed_row_direction_hint_enum, text, text, text) TO service_role;

-- ============================================================================
-- 8. RPC: complete_statement_parse
-- ============================================================================
CREATE OR REPLACE FUNCTION public.complete_statement_parse(
  p_parse_run_id  uuid,
  p_actor_user_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run        public.statement_parse_runs%ROWTYPE;
  v_audit_row  audit.audit_events;
  v_kind       audit.actor_kind_enum;
  v_system     text;
BEGIN
  IF p_parse_run_id IS NULL THEN
    RAISE EXCEPTION 'complete_statement_parse: p_parse_run_id is required'
      USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_run FROM public.statement_parse_runs
    WHERE id = p_parse_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'complete_statement_parse: parse_run % not found', p_parse_run_id
      USING ERRCODE='02000';
  END IF;
  IF v_run.status <> 'STARTED'::public.statement_parse_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'PARSE_RUN_NOT_STARTED',
      'current_status', v_run.status::text);
  END IF;

  UPDATE public.statement_parse_runs
    SET status       = 'COMPLETED'::public.statement_parse_status_enum,
        completed_at = clock_timestamp(),
        updated_at   = clock_timestamp()
    WHERE id = p_parse_run_id;

  UPDATE public.statement_uploads
    SET upload_status = 'PARSED'::public.statement_upload_status_enum,
        updated_at    = clock_timestamp()
    WHERE id = v_run.statement_upload_id;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_parser';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'STATEMENT_PARSE_COMPLETED',
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id   => v_run.statement_upload_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_run.organization_id, p_business_id => v_run.business_id,
    p_before_state => jsonb_build_object('upload_status', 'PARSING'),
    p_after_state  => jsonb_build_object(
      'upload_status',      'PARSED',
      'parse_run_id',       v_run.id,
      'row_count',          v_run.row_count,
      'parser_provider',    v_run.parser_provider,
      'parser_file_format', v_run.parser_file_format::text,
      'parser_version',     v_run.parser_version),
    p_reason => format('parsed %s row(s) via %s/%s/%s',
                       v_run.row_count, v_run.parser_provider,
                       v_run.parser_file_format::text, v_run.parser_version));

  RETURN jsonb_build_object('ok', true,
    'parse_run_id',  v_run.id,
    'row_count',     v_run.row_count,
    'audit_event_id', v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.complete_statement_parse(uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.complete_statement_parse(uuid, uuid) TO service_role;

-- ============================================================================
-- 9. RPC: fail_statement_parse
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fail_statement_parse(
  p_parse_run_id   uuid,
  p_error_category public.statement_parse_error_category_enum,
  p_error_message  text,
  p_actor_user_id  uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run        public.statement_parse_runs%ROWTYPE;
  v_audit_row  audit.audit_events;
  v_kind       audit.actor_kind_enum;
  v_system     text;
BEGIN
  IF p_parse_run_id IS NULL OR p_error_category IS NULL OR p_error_message IS NULL THEN
    RAISE EXCEPTION 'fail_statement_parse: required params missing'
      USING ERRCODE='22000';
  END IF;
  IF length(p_error_message) = 0 OR length(p_error_message) > 2000 THEN
    RAISE EXCEPTION 'fail_statement_parse: error_message length must be 1..2000 (got %)', length(p_error_message)
      USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_run FROM public.statement_parse_runs
    WHERE id = p_parse_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fail_statement_parse: parse_run % not found', p_parse_run_id
      USING ERRCODE='02000';
  END IF;
  IF v_run.status <> 'STARTED'::public.statement_parse_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'PARSE_RUN_NOT_STARTED',
      'current_status', v_run.status::text);
  END IF;

  UPDATE public.statement_parse_runs
    SET status         = 'FAILED'::public.statement_parse_status_enum,
        error_category = p_error_category,
        error_message  = p_error_message,
        completed_at   = clock_timestamp(),
        updated_at     = clock_timestamp()
    WHERE id = p_parse_run_id;

  UPDATE public.statement_uploads
    SET upload_status = 'FAILED'::public.statement_upload_status_enum,
        updated_at    = clock_timestamp()
    WHERE id = v_run.statement_upload_id;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_parser';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'STATEMENT_PARSE_FAILED',
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id   => v_run.statement_upload_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_run.organization_id, p_business_id => v_run.business_id,
    p_before_state => jsonb_build_object('upload_status', 'PARSING'),
    p_after_state  => jsonb_build_object(
      'upload_status',      'FAILED',
      'parse_run_id',       v_run.id,
      'error_category',     p_error_category::text,
      'error_message',      p_error_message,
      'rows_recorded_before_failure', v_run.row_count,
      'parser_provider',    v_run.parser_provider,
      'parser_file_format', v_run.parser_file_format::text,
      'parser_version',     v_run.parser_version),
    p_reason => format('parse failed: %s — %s',
                       p_error_category::text, left(p_error_message, 240)));

  RETURN jsonb_build_object('ok', true,
    'parse_run_id',  v_run.id,
    'error_category', p_error_category::text,
    'audit_event_id', v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.fail_statement_parse(uuid, public.statement_parse_error_category_enum, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.fail_statement_parse(uuid, public.statement_parse_error_category_enum, text, uuid) TO service_role;

-- ============================================================================
-- 10. Seed Revolut CSV parser
-- ============================================================================
-- Seeded directly (not via the RPC) because the RPC requires an actor_user_id
-- with Owner privileges; the seed is a deployment artifact, not a user action.
INSERT INTO public.statement_parser_registry
  (provider, file_format, version, parser_module_ref, is_active, notes,
   registered_by_user_id, registered_at, updated_at)
VALUES
  ('REVOLUT', 'CSV'::public.statement_file_format_enum, '1.0.0',
   'cyprus_bookkeeping_api.parsers.revolut_csv:parse',
   true,
   'Initial Revolut CSV parser. Handles multi-currency rows, FX-paired exchange legs, and fee lines. Column layout per Stage-4 Revolut CSV format sub-doc.',
   NULL, clock_timestamp(), clock_timestamp())
ON CONFLICT (provider, file_format, version) DO NOTHING;
