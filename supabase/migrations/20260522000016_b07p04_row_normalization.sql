-- B07·P04 — Row Normalization
--
-- Spec-key constraint: Phase 04 does NOT insert into `transactions`. It returns
-- a NormalizedTransaction[] to the caller (Phase 05's dedup tool). The SQL
-- contract is a staging table that Phase 04 populates and Phase 05 reads.
--
-- The Python normalize() body (date parsing, description cleanup regex,
-- deterministic counterparty extraction, FX-pair detection, ISO-4217 currency
-- check, sha256 hash via sourceRowHash/transactionFingerprint, Tier-2 LLM
-- fallback through B06·P02 gateway, encrypt_field/mask_field for counterparty
-- identifiers via B05·P05) lives in the orchestrator. SQL ships:
--
--   1. statement_normalization_runs — lifecycle row per upload (STARTED →
--      COMPLETED/FAILED/CANCELLED) with summary counters
--   2. statement_normalized_rows — staging table mirroring NormalizedTransaction
--      shape; deliberately schema-aligned with transactions but NOT FK'd to it
--   3. 6 RPCs: start, record_normalized_transaction, record_normalization_failed,
--      record_fx_pair_resolved, record_ai_fallback_used, complete, fail
--   4. 4 spec-canonical audit events (TRANSACTION_NORMALIZED,
--      STATEMENT_NORMALIZATION_FAILED, _FX_PAIR_RESOLVED, _AI_FALLBACK_USED)
--
-- ============================================================================
-- 1. Enums
-- ============================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'statement_normalization_status_enum') THEN
    CREATE TYPE public.statement_normalization_status_enum AS ENUM (
      'STARTED','COMPLETED','FAILED','CANCELLED'
    );
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'normalization_failure_reason_enum') THEN
    CREATE TYPE public.normalization_failure_reason_enum AS ENUM (
      'ZERO_AMOUNT','INVALID_DATE','INVALID_CURRENCY','INVALID_AMOUNT_FORMAT',
      'MISSING_REQUIRED_FIELD','UNPAIRED_FX_LEG','INTERNAL_ERROR'
    );
  END IF;
END$$;

-- ============================================================================
-- 2. statement_normalization_runs
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.statement_normalization_runs (
  id                    uuid PRIMARY KEY,
  statement_upload_id   uuid NOT NULL REFERENCES public.statement_uploads(id),
  business_id           uuid NOT NULL REFERENCES public.business_entities(id),
  organization_id       uuid NOT NULL REFERENCES public.organizations(id),
  status                public.statement_normalization_status_enum NOT NULL DEFAULT 'STARTED',
  normalized_count      int NOT NULL DEFAULT 0,
  failed_count          int NOT NULL DEFAULT 0,
  fx_pair_count         int NOT NULL DEFAULT 0,
  ai_fallback_count     int NOT NULL DEFAULT 0,
  error_message         text,
  started_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at          timestamptz,
  created_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT statement_normalization_runs_counts_nonneg CHECK (
    normalized_count >= 0 AND failed_count >= 0
    AND fx_pair_count >= 0 AND ai_fallback_count >= 0
  ),
  CONSTRAINT statement_normalization_runs_terminal_chk CHECK (
    (status IN ('COMPLETED','FAILED','CANCELLED')) = (completed_at IS NOT NULL)
  ),
  CONSTRAINT statement_normalization_runs_failed_has_msg CHECK (
    (status = 'FAILED') = (error_message IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS statement_normalization_runs_upload_idx
  ON public.statement_normalization_runs (statement_upload_id, started_at DESC);

-- At most one STARTED run per upload (idempotency for start RPC).
CREATE UNIQUE INDEX IF NOT EXISTS statement_normalization_runs_one_started_per_upload
  ON public.statement_normalization_runs (statement_upload_id)
  WHERE status = 'STARTED';

REVOKE ALL ON public.statement_normalization_runs FROM PUBLIC, authenticated, anon;
GRANT  SELECT ON public.statement_normalization_runs TO service_role;

-- ============================================================================
-- 3. statement_normalized_rows  (staging — NOT inserted into transactions here)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.statement_normalized_rows (
  id                                  uuid PRIMARY KEY,
  normalization_run_id                uuid NOT NULL REFERENCES public.statement_normalization_runs(id) ON DELETE CASCADE,
  statement_upload_id                 uuid NOT NULL REFERENCES public.statement_uploads(id),
  business_id                         uuid NOT NULL REFERENCES public.business_entities(id),
  organization_id                     uuid NOT NULL REFERENCES public.organizations(id),
  parsed_row_ids                      uuid[] NOT NULL,
  transaction_date                    date NOT NULL,
  booking_date                        date,
  amount                              numeric(20,4) NOT NULL,
  currency                            text NOT NULL,
  direction                           public.transaction_direction_enum NOT NULL,
  transaction_type_candidate          public.transaction_type_enum,
  normalized_description              text NOT NULL,
  counterparty_name                   text,
  counterparty_identifier_masked      text,
  counterparty_identifier_encrypted   bytea,
  reference                           text,
  source_row_hash                     text NOT NULL,
  transaction_fingerprint             text NOT NULL,
  fx_paired_legs                      jsonb,
  normalization_confidence            text NOT NULL DEFAULT 'HIGH',
  extraction_method                   text NOT NULL DEFAULT 'DETERMINISTIC',
  created_at                          timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT statement_normalized_rows_amount_positive
    CHECK (amount > 0),
  CONSTRAINT statement_normalized_rows_currency_iso
    CHECK (currency ~ '^[A-Z]{3}$'),
  CONSTRAINT statement_normalized_rows_direction_in_or_out
    CHECK (direction IN ('IN','OUT')),
  CONSTRAINT statement_normalized_rows_source_hash_sha256
    CHECK (source_row_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT statement_normalized_rows_fingerprint_sha256
    CHECK (transaction_fingerprint ~ '^[0-9a-f]{64}$'),
  CONSTRAINT statement_normalized_rows_parsed_row_ids_card
    CHECK (array_length(parsed_row_ids, 1) BETWEEN 1 AND 2),
  CONSTRAINT statement_normalized_rows_fx_obj
    CHECK (fx_paired_legs IS NULL OR jsonb_typeof(fx_paired_legs) = 'object'),
  CONSTRAINT statement_normalized_rows_fx_legs_iff_fx_type
    CHECK ((transaction_type_candidate = 'FX_EXCHANGE'::public.transaction_type_enum) = (fx_paired_legs IS NOT NULL)),
  CONSTRAINT statement_normalized_rows_confidence_chk
    CHECK (normalization_confidence IN ('HIGH','LOW')),
  CONSTRAINT statement_normalized_rows_extraction_method_chk
    CHECK (extraction_method IN ('DETERMINISTIC','AI_FALLBACK')),
  CONSTRAINT statement_normalized_rows_fingerprint_uq
    UNIQUE (normalization_run_id, transaction_fingerprint)
);

CREATE INDEX IF NOT EXISTS statement_normalized_rows_run_idx
  ON public.statement_normalized_rows (normalization_run_id);
CREATE INDEX IF NOT EXISTS statement_normalized_rows_upload_idx
  ON public.statement_normalized_rows (statement_upload_id, transaction_date);

REVOKE ALL ON public.statement_normalized_rows FROM PUBLIC, authenticated, anon;
GRANT  SELECT ON public.statement_normalized_rows TO service_role;

-- ============================================================================
-- 4. RPC: start_statement_normalization
-- ============================================================================
CREATE OR REPLACE FUNCTION public.start_statement_normalization(
  p_statement_upload_id uuid,
  p_actor_user_id       uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_upload public.statement_uploads%ROWTYPE;
  v_run_id uuid := public.gen_uuid_v7();
BEGIN
  IF p_statement_upload_id IS NULL THEN
    RAISE EXCEPTION 'start_statement_normalization: p_statement_upload_id is required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_upload FROM public.statement_uploads WHERE id = p_statement_upload_id FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'start_statement_normalization: upload % not found', p_statement_upload_id USING ERRCODE='02000';
  END IF;
  IF v_upload.upload_status <> 'PARSED'::public.statement_upload_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'UPLOAD_NOT_IN_PARSED_STATE',
      'current_status', v_upload.upload_status::text);
  END IF;

  BEGIN
    INSERT INTO public.statement_normalization_runs
      (id, statement_upload_id, business_id, organization_id, status,
       started_at, created_at, updated_at)
    VALUES
      (v_run_id, v_upload.id, v_upload.business_id, v_upload.organization_id, 'STARTED',
       clock_timestamp(), clock_timestamp(), clock_timestamp());
  EXCEPTION WHEN unique_violation THEN
    -- A STARTED run already exists (partial unique index)
    RETURN jsonb_build_object('ok', false, 'reason', 'NORMALIZATION_ALREADY_IN_PROGRESS',
      'statement_upload_id', v_upload.id);
  END;

  RETURN jsonb_build_object('ok', true,
    'normalization_run_id', v_run_id,
    'statement_upload_id',  v_upload.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.start_statement_normalization(uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.start_statement_normalization(uuid, uuid) TO service_role;

-- ============================================================================
-- 5. RPC: record_normalized_transaction
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_normalized_transaction(
  p_normalization_run_id              uuid,
  p_parsed_row_ids                    uuid[],
  p_transaction_date                  date,
  p_amount                            numeric,
  p_currency                          text,
  p_direction                         public.transaction_direction_enum,
  p_normalized_description            text,
  p_source_row_hash                   text,
  p_transaction_fingerprint           text,
  p_booking_date                      date     DEFAULT NULL,
  p_counterparty_name                 text     DEFAULT NULL,
  p_counterparty_identifier_masked    text     DEFAULT NULL,
  p_counterparty_identifier_encrypted bytea    DEFAULT NULL,
  p_reference                         text     DEFAULT NULL,
  p_transaction_type_candidate        public.transaction_type_enum DEFAULT NULL,
  p_fx_paired_legs                    jsonb    DEFAULT NULL,
  p_normalization_confidence          text     DEFAULT 'HIGH',
  p_extraction_method                 text     DEFAULT 'DETERMINISTIC',
  p_actor_user_id                     uuid     DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run        public.statement_normalization_runs%ROWTYPE;
  v_row_id     uuid := public.gen_uuid_v7();
  v_audit_row  audit.audit_events;
  v_kind       audit.actor_kind_enum;
  v_system     text;
BEGIN
  IF p_normalization_run_id IS NULL OR p_parsed_row_ids IS NULL
     OR p_transaction_date IS NULL OR p_amount IS NULL OR p_currency IS NULL
     OR p_direction IS NULL OR p_normalized_description IS NULL
     OR p_source_row_hash IS NULL OR p_transaction_fingerprint IS NULL THEN
    RAISE EXCEPTION 'record_normalized_transaction: required params missing' USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_run FROM public.statement_normalization_runs WHERE id = p_normalization_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_normalized_transaction: run % not found', p_normalization_run_id USING ERRCODE='02000';
  END IF;
  IF v_run.status <> 'STARTED'::public.statement_normalization_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NORMALIZATION_NOT_STARTED',
      'current_status', v_run.status::text);
  END IF;

  BEGIN
    INSERT INTO public.statement_normalized_rows
      (id, normalization_run_id, statement_upload_id, business_id, organization_id,
       parsed_row_ids, transaction_date, booking_date, amount, currency, direction,
       transaction_type_candidate, normalized_description, counterparty_name,
       counterparty_identifier_masked, counterparty_identifier_encrypted, reference,
       source_row_hash, transaction_fingerprint, fx_paired_legs,
       normalization_confidence, extraction_method, created_at)
    VALUES
      (v_row_id, p_normalization_run_id, v_run.statement_upload_id, v_run.business_id, v_run.organization_id,
       p_parsed_row_ids, p_transaction_date, p_booking_date, p_amount, p_currency, p_direction,
       p_transaction_type_candidate, p_normalized_description, p_counterparty_name,
       p_counterparty_identifier_masked, p_counterparty_identifier_encrypted, p_reference,
       p_source_row_hash, p_transaction_fingerprint, p_fx_paired_legs,
       p_normalization_confidence, p_extraction_method, clock_timestamp());
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'DUPLICATE_FINGERPRINT_IN_RUN',
      'transaction_fingerprint', p_transaction_fingerprint);
  END;

  UPDATE public.statement_normalization_runs
    SET normalized_count = normalized_count + 1, updated_at = clock_timestamp()
    WHERE id = p_normalization_run_id;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_normalizer';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'TRANSACTION_NORMALIZED',
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id   => v_run.statement_upload_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_run.organization_id, p_business_id => v_run.business_id,
    p_after_state => jsonb_build_object(
      'normalized_row_id',           v_row_id,
      'normalization_run_id',        v_run.id,
      'parsed_row_ids',              to_jsonb(p_parsed_row_ids),
      'transaction_date',            p_transaction_date,
      'amount',                      p_amount,
      'currency',                    p_currency,
      'direction',                   p_direction::text,
      'transaction_type_candidate',  p_transaction_type_candidate::text,
      'source_row_hash',             p_source_row_hash,
      'transaction_fingerprint',     p_transaction_fingerprint,
      'normalization_confidence',    p_normalization_confidence,
      'extraction_method',           p_extraction_method),
    p_reason => format('normalized %s %s -> %s (fingerprint %s)',
                       p_direction::text, p_amount, p_currency,
                       left(p_transaction_fingerprint, 12)));

  RETURN jsonb_build_object('ok', true,
    'normalized_row_id', v_row_id,
    'audit_event_id',    v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_normalized_transaction(uuid, uuid[], date, numeric, text, public.transaction_direction_enum, text, text, text, date, text, text, bytea, text, public.transaction_type_enum, jsonb, text, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_normalized_transaction(uuid, uuid[], date, numeric, text, public.transaction_direction_enum, text, text, text, date, text, text, bytea, text, public.transaction_type_enum, jsonb, text, text, uuid) TO service_role;

-- ============================================================================
-- 6. RPC: record_normalization_failed
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_normalization_failed(
  p_normalization_run_id uuid,
  p_parsed_row_id        uuid,
  p_source_row_index     int,
  p_reason               public.normalization_failure_reason_enum,
  p_error_message        text,
  p_actor_user_id        uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run        public.statement_normalization_runs%ROWTYPE;
  v_audit_row  audit.audit_events;
  v_kind       audit.actor_kind_enum;
  v_system     text;
BEGIN
  IF p_normalization_run_id IS NULL OR p_reason IS NULL
     OR p_source_row_index IS NULL OR p_error_message IS NULL THEN
    RAISE EXCEPTION 'record_normalization_failed: required params missing' USING ERRCODE='22000';
  END IF;
  IF length(p_error_message) = 0 OR length(p_error_message) > 2000 THEN
    RAISE EXCEPTION 'record_normalization_failed: error_message length must be 1..2000 (got %)',
      length(p_error_message) USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_run FROM public.statement_normalization_runs WHERE id = p_normalization_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_normalization_failed: run % not found', p_normalization_run_id USING ERRCODE='02000';
  END IF;
  IF v_run.status <> 'STARTED'::public.statement_normalization_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NORMALIZATION_NOT_STARTED',
      'current_status', v_run.status::text);
  END IF;

  UPDATE public.statement_normalization_runs
    SET failed_count = failed_count + 1, updated_at = clock_timestamp()
    WHERE id = p_normalization_run_id;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_normalizer';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'STATEMENT_NORMALIZATION_FAILED',
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id   => v_run.statement_upload_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_run.organization_id, p_business_id => v_run.business_id,
    p_after_state => jsonb_build_object(
      'normalization_run_id', v_run.id,
      'parsed_row_id',        p_parsed_row_id,
      'source_row_index',     p_source_row_index,
      'reason',               p_reason::text,
      'error_message',        p_error_message),
    p_reason => format('normalization failed on row %s: %s — %s',
                       p_source_row_index, p_reason::text, left(p_error_message, 200)));

  RETURN jsonb_build_object('ok', true,
    'audit_event_id', v_audit_row.id,
    'reason',         p_reason::text);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_normalization_failed(uuid, uuid, int, public.normalization_failure_reason_enum, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_normalization_failed(uuid, uuid, int, public.normalization_failure_reason_enum, text, uuid) TO service_role;

-- ============================================================================
-- 7. RPC: record_fx_pair_resolved
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_fx_pair_resolved(
  p_normalization_run_id uuid,
  p_normalized_row_id    uuid,
  p_parsed_row_id_out    uuid,
  p_parsed_row_id_in     uuid,
  p_fx_paired_legs       jsonb,
  p_actor_user_id        uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run        public.statement_normalization_runs%ROWTYPE;
  v_row        public.statement_normalized_rows%ROWTYPE;
  v_audit_row  audit.audit_events;
  v_kind       audit.actor_kind_enum;
  v_system     text;
BEGIN
  IF p_normalization_run_id IS NULL OR p_normalized_row_id IS NULL
     OR p_parsed_row_id_out IS NULL OR p_parsed_row_id_in IS NULL
     OR p_fx_paired_legs IS NULL THEN
    RAISE EXCEPTION 'record_fx_pair_resolved: required params missing' USING ERRCODE='22000';
  END IF;
  IF jsonb_typeof(p_fx_paired_legs) <> 'object' THEN
    RAISE EXCEPTION 'record_fx_pair_resolved: fx_paired_legs must be an object' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_run FROM public.statement_normalization_runs WHERE id = p_normalization_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_fx_pair_resolved: run % not found', p_normalization_run_id USING ERRCODE='02000';
  END IF;
  IF v_run.status <> 'STARTED'::public.statement_normalization_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NORMALIZATION_NOT_STARTED',
      'current_status', v_run.status::text);
  END IF;
  SELECT * INTO v_row FROM public.statement_normalized_rows WHERE id = p_normalized_row_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_fx_pair_resolved: normalized_row % not found', p_normalized_row_id USING ERRCODE='02000';
  END IF;
  IF v_row.transaction_type_candidate IS DISTINCT FROM 'FX_EXCHANGE'::public.transaction_type_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'ROW_NOT_FX_EXCHANGE',
      'transaction_type_candidate', v_row.transaction_type_candidate::text);
  END IF;
  IF NOT (p_parsed_row_id_out = ANY (v_row.parsed_row_ids))
     OR NOT (p_parsed_row_id_in = ANY (v_row.parsed_row_ids)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'PARSED_ROWS_DO_NOT_MATCH_NORMALIZED_ROW',
      'normalized_parsed_row_ids', to_jsonb(v_row.parsed_row_ids),
      'requested_out', p_parsed_row_id_out, 'requested_in', p_parsed_row_id_in);
  END IF;

  UPDATE public.statement_normalization_runs
    SET fx_pair_count = fx_pair_count + 1, updated_at = clock_timestamp()
    WHERE id = p_normalization_run_id;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_normalizer';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'STATEMENT_NORMALIZATION_FX_PAIR_RESOLVED',
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id   => v_run.statement_upload_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_run.organization_id, p_business_id => v_run.business_id,
    p_after_state => jsonb_build_object(
      'normalization_run_id', v_run.id,
      'normalized_row_id',    p_normalized_row_id,
      'parsed_row_id_out',    p_parsed_row_id_out,
      'parsed_row_id_in',     p_parsed_row_id_in,
      'fx_paired_legs',       p_fx_paired_legs),
    p_reason => format('FX pair resolved: out=%s in=%s rate=%s',
                       p_fx_paired_legs->'leg_out'->>'currency',
                       p_fx_paired_legs->'leg_in'->>'currency',
                       p_fx_paired_legs->>'rate'));

  RETURN jsonb_build_object('ok', true, 'audit_event_id', v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_fx_pair_resolved(uuid, uuid, uuid, uuid, jsonb, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_fx_pair_resolved(uuid, uuid, uuid, uuid, jsonb, uuid) TO service_role;

-- ============================================================================
-- 8. RPC: record_ai_fallback_used
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_ai_fallback_used(
  p_normalization_run_id uuid,
  p_parsed_row_id        uuid,
  p_fallback_kind        text,
  p_model_ref            text DEFAULT NULL,
  p_actor_user_id        uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run        public.statement_normalization_runs%ROWTYPE;
  v_audit_row  audit.audit_events;
  v_kind       audit.actor_kind_enum;
  v_system     text;
BEGIN
  IF p_normalization_run_id IS NULL OR p_parsed_row_id IS NULL OR p_fallback_kind IS NULL THEN
    RAISE EXCEPTION 'record_ai_fallback_used: required params missing' USING ERRCODE='22000';
  END IF;
  IF p_fallback_kind NOT IN ('COUNTERPARTY_EXTRACTION') THEN
    RAISE EXCEPTION 'record_ai_fallback_used: unknown fallback_kind %', p_fallback_kind USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_run FROM public.statement_normalization_runs WHERE id = p_normalization_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_ai_fallback_used: run % not found', p_normalization_run_id USING ERRCODE='02000';
  END IF;
  IF v_run.status <> 'STARTED'::public.statement_normalization_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NORMALIZATION_NOT_STARTED',
      'current_status', v_run.status::text);
  END IF;

  UPDATE public.statement_normalization_runs
    SET ai_fallback_count = ai_fallback_count + 1, updated_at = clock_timestamp()
    WHERE id = p_normalization_run_id;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_normalizer';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'STATEMENT_NORMALIZATION_AI_FALLBACK_USED',
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id   => v_run.statement_upload_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_run.organization_id, p_business_id => v_run.business_id,
    p_after_state => jsonb_build_object(
      'normalization_run_id', v_run.id,
      'parsed_row_id',        p_parsed_row_id,
      'fallback_kind',        p_fallback_kind,
      'model_ref',            p_model_ref),
    p_reason => format('AI fallback used (%s) on parsed_row %s', p_fallback_kind, p_parsed_row_id));

  RETURN jsonb_build_object('ok', true, 'audit_event_id', v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_ai_fallback_used(uuid, uuid, text, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_ai_fallback_used(uuid, uuid, text, text, uuid) TO service_role;

-- ============================================================================
-- 9. RPC: complete_statement_normalization
-- ============================================================================
CREATE OR REPLACE FUNCTION public.complete_statement_normalization(
  p_normalization_run_id uuid,
  p_actor_user_id        uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run public.statement_normalization_runs%ROWTYPE;
BEGIN
  IF p_normalization_run_id IS NULL THEN
    RAISE EXCEPTION 'complete_statement_normalization: p_normalization_run_id is required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_run FROM public.statement_normalization_runs WHERE id = p_normalization_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'complete_statement_normalization: run % not found', p_normalization_run_id USING ERRCODE='02000';
  END IF;
  IF v_run.status <> 'STARTED'::public.statement_normalization_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NORMALIZATION_NOT_STARTED',
      'current_status', v_run.status::text);
  END IF;

  UPDATE public.statement_normalization_runs
    SET status       = 'COMPLETED'::public.statement_normalization_status_enum,
        completed_at = clock_timestamp(),
        updated_at   = clock_timestamp()
    WHERE id = p_normalization_run_id
    RETURNING * INTO v_run;

  RETURN jsonb_build_object('ok', true,
    'normalization_run_id', v_run.id,
    'normalized_count',     v_run.normalized_count,
    'failed_count',         v_run.failed_count,
    'fx_pair_count',        v_run.fx_pair_count,
    'ai_fallback_count',    v_run.ai_fallback_count);
END;
$function$;

REVOKE ALL ON FUNCTION public.complete_statement_normalization(uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.complete_statement_normalization(uuid, uuid) TO service_role;

-- ============================================================================
-- 10. RPC: fail_statement_normalization
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fail_statement_normalization(
  p_normalization_run_id uuid,
  p_error_message        text,
  p_actor_user_id        uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run public.statement_normalization_runs%ROWTYPE;
BEGIN
  IF p_normalization_run_id IS NULL OR p_error_message IS NULL THEN
    RAISE EXCEPTION 'fail_statement_normalization: required params missing' USING ERRCODE='22000';
  END IF;
  IF length(p_error_message) = 0 OR length(p_error_message) > 2000 THEN
    RAISE EXCEPTION 'fail_statement_normalization: error_message length must be 1..2000 (got %)',
      length(p_error_message) USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_run FROM public.statement_normalization_runs WHERE id = p_normalization_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fail_statement_normalization: run % not found', p_normalization_run_id USING ERRCODE='02000';
  END IF;
  IF v_run.status <> 'STARTED'::public.statement_normalization_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NORMALIZATION_NOT_STARTED',
      'current_status', v_run.status::text);
  END IF;

  UPDATE public.statement_normalization_runs
    SET status        = 'FAILED'::public.statement_normalization_status_enum,
        error_message = p_error_message,
        completed_at  = clock_timestamp(),
        updated_at    = clock_timestamp()
    WHERE id = p_normalization_run_id;

  RETURN jsonb_build_object('ok', true, 'normalization_run_id', v_run.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.fail_statement_normalization(uuid, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.fail_statement_normalization(uuid, text, uuid) TO service_role;
