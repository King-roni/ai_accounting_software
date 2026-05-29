-- B07·P05 — Deduplication Engine
--
-- This is the phase that finally inserts into `transactions`. It runs over the
-- staged statement_normalized_rows from B07·P04 and classifies each one:
--   - NEW                → INSERT into transactions, dedup_status='NEW'
--   - DUPLICATE_EXACT    → silent reject (already in transactions OR within-batch)
--   - DUPLICATE_PROBABLE → review_issue (issue_type='bank_pipeline.duplicate_probable')
--   - NEEDS_REVIEW       → review_issue (issue_type='bank_pipeline.duplicate_needs_review')
--
-- Spec naming reconciliation: the spec uses DUPLICATE_POSSIBLE but the
-- transaction_dedup_status_enum standardised on DUPLICATE_PROBABLE. We use
-- the enum value consistently. Reservation note added to the taxonomy.
--
-- review_issues CHECK enforcement: at_least_one_entity_chk requires one of
-- (transaction_id, document_id, match_record_id, draft_ledger_entry_id) to be
-- NOT NULL. For dedup issues we point review_issue.transaction_id at the
-- *matched* existing transaction (the one whose fingerprint matched) — the
-- review question is "is this candidate row a duplicate of transaction X",
-- so pointing at X is semantically right; the candidate row info lives in
-- card_payload_json (normalized_row_id, statement_upload_id, source_row_index).

-- ============================================================================
-- 1. Enum
-- ============================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'statement_dedup_status_enum') THEN
    CREATE TYPE public.statement_dedup_status_enum AS ENUM (
      'STARTED','COMPLETED','FAILED','CANCELLED'
    );
  END IF;
END$$;

-- ============================================================================
-- 2. statement_dedup_runs
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.statement_dedup_runs (
  id                        uuid PRIMARY KEY,
  statement_upload_id       uuid NOT NULL REFERENCES public.statement_uploads(id),
  business_id               uuid NOT NULL REFERENCES public.business_entities(id),
  bank_account_id           uuid NOT NULL REFERENCES public.bank_accounts(id),
  organization_id           uuid NOT NULL REFERENCES public.organizations(id),
  workflow_run_id           uuid NOT NULL REFERENCES public.workflow_runs(id),
  status                    public.statement_dedup_status_enum NOT NULL DEFAULT 'STARTED',
  new_count                 int NOT NULL DEFAULT 0,
  exact_duplicate_count     int NOT NULL DEFAULT 0,
  probable_duplicate_count  int NOT NULL DEFAULT 0,
  needs_review_count        int NOT NULL DEFAULT 0,
  error_message             text,
  started_at                timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at              timestamptz,
  created_at                timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at                timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT statement_dedup_runs_counts_nonneg CHECK (
    new_count >= 0 AND exact_duplicate_count >= 0
    AND probable_duplicate_count >= 0 AND needs_review_count >= 0
  ),
  CONSTRAINT statement_dedup_runs_terminal_chk CHECK (
    (status IN ('COMPLETED','FAILED','CANCELLED')) = (completed_at IS NOT NULL)
  ),
  CONSTRAINT statement_dedup_runs_failed_has_msg CHECK (
    (status = 'FAILED') = (error_message IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS statement_dedup_runs_upload_idx
  ON public.statement_dedup_runs (statement_upload_id, started_at DESC);

-- At most one STARTED run per upload (idempotency).
CREATE UNIQUE INDEX IF NOT EXISTS statement_dedup_runs_one_started_per_upload
  ON public.statement_dedup_runs (statement_upload_id) WHERE status = 'STARTED';

REVOKE ALL ON public.statement_dedup_runs FROM PUBLIC, authenticated, anon;
GRANT  SELECT ON public.statement_dedup_runs TO service_role;

-- ============================================================================
-- 3. statement_dedup_row_classifications  (idempotency linking table)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.statement_dedup_row_classifications (
  id                      uuid PRIMARY KEY,
  dedup_run_id            uuid NOT NULL REFERENCES public.statement_dedup_runs(id) ON DELETE CASCADE,
  normalized_row_id       uuid NOT NULL REFERENCES public.statement_normalized_rows(id),
  dedup_status            public.transaction_dedup_status_enum NOT NULL,
  transaction_id          uuid REFERENCES public.transactions(id),
  review_issue_id         uuid REFERENCES public.review_issues(id),
  matched_transaction_id  uuid REFERENCES public.transactions(id),
  matched_within_batch    boolean NOT NULL DEFAULT false,
  classified_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT statement_dedup_row_classifications_run_row_uq
    UNIQUE (dedup_run_id, normalized_row_id),
  CONSTRAINT statement_dedup_row_classifications_new_has_tx CHECK (
    (dedup_status = 'NEW') = (transaction_id IS NOT NULL)
  ),
  CONSTRAINT statement_dedup_row_classifications_review_has_issue CHECK (
    (dedup_status IN ('DUPLICATE_PROBABLE','NEEDS_REVIEW')) = (review_issue_id IS NOT NULL)
  ),
  CONSTRAINT statement_dedup_row_classifications_duplicate_has_match CHECK (
    (dedup_status IN ('DUPLICATE_EXACT','DUPLICATE_PROBABLE','NEEDS_REVIEW')) = (matched_transaction_id IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS statement_dedup_row_classifications_run_idx
  ON public.statement_dedup_row_classifications (dedup_run_id);

REVOKE ALL ON public.statement_dedup_row_classifications FROM PUBLIC, authenticated, anon;
GRANT  SELECT ON public.statement_dedup_row_classifications TO service_role;

-- ============================================================================
-- 4. RPC: start_statement_dedup
-- ============================================================================
CREATE OR REPLACE FUNCTION public.start_statement_dedup(
  p_statement_upload_id uuid,
  p_workflow_run_id     uuid,
  p_actor_user_id       uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_upload    public.statement_uploads%ROWTYPE;
  v_norm_done boolean;
  v_run_id    uuid := public.gen_uuid_v7();
BEGIN
  IF p_statement_upload_id IS NULL OR p_workflow_run_id IS NULL THEN
    RAISE EXCEPTION 'start_statement_dedup: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_upload FROM public.statement_uploads WHERE id = p_statement_upload_id FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'start_statement_dedup: upload % not found', p_statement_upload_id USING ERRCODE='02000';
  END IF;
  SELECT EXISTS (
    SELECT 1 FROM public.statement_normalization_runs
    WHERE statement_upload_id = v_upload.id
      AND status = 'COMPLETED'::public.statement_normalization_status_enum
  ) INTO v_norm_done;
  IF NOT v_norm_done THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NORMALIZATION_NOT_COMPLETED');
  END IF;

  BEGIN
    INSERT INTO public.statement_dedup_runs
      (id, statement_upload_id, business_id, bank_account_id, organization_id,
       workflow_run_id, status, started_at, created_at, updated_at)
    VALUES
      (v_run_id, v_upload.id, v_upload.business_id, v_upload.bank_account_id,
       v_upload.organization_id, p_workflow_run_id, 'STARTED',
       clock_timestamp(), clock_timestamp(), clock_timestamp());
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'DEDUP_ALREADY_IN_PROGRESS',
      'statement_upload_id', v_upload.id);
  END;

  RETURN jsonb_build_object('ok', true,
    'dedup_run_id', v_run_id, 'statement_upload_id', v_upload.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.start_statement_dedup(uuid, uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.start_statement_dedup(uuid, uuid, uuid) TO service_role;

-- ============================================================================
-- 5. RPC: classify_and_record_dedup_row
-- ============================================================================
CREATE OR REPLACE FUNCTION public.classify_and_record_dedup_row(
  p_dedup_run_id         uuid,
  p_normalized_row_id    uuid,
  p_soft_window_days     int DEFAULT 30,
  p_amount_tolerance_cents int DEFAULT 1,
  p_actor_user_id        uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run                public.statement_dedup_runs%ROWTYPE;
  v_norm               public.statement_normalized_rows%ROWTYPE;
  v_existing_class     public.statement_dedup_row_classifications%ROWTYPE;
  v_match_exact        public.transactions%ROWTYPE;
  v_match_within       public.statement_dedup_row_classifications%ROWTYPE;
  v_match_soft         public.transactions%ROWTYPE;
  v_classification_id  uuid := public.gen_uuid_v7();
  v_transaction_id     uuid;
  v_review_issue_id    uuid;
  v_matched_tx_id      uuid;
  v_within_batch       boolean := false;
  v_dedup_status       public.transaction_dedup_status_enum;
  v_audit_action       text;
  v_source_row_index   int;
  v_audit_row          audit.audit_events;
  v_kind               audit.actor_kind_enum;
  v_system             text;
  v_card_payload       jsonb;
  v_issue_type         text;
  v_title              text;
  v_description        text;
BEGIN
  IF p_dedup_run_id IS NULL OR p_normalized_row_id IS NULL THEN
    RAISE EXCEPTION 'classify_and_record_dedup_row: required params missing' USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_run FROM public.statement_dedup_runs WHERE id = p_dedup_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'classify_and_record_dedup_row: dedup_run % not found', p_dedup_run_id USING ERRCODE='02000';
  END IF;
  IF v_run.status <> 'STARTED'::public.statement_dedup_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'DEDUP_NOT_STARTED',
      'current_status', v_run.status::text);
  END IF;

  -- Idempotency: prior classification?
  SELECT * INTO v_existing_class
    FROM public.statement_dedup_row_classifications
    WHERE dedup_run_id = p_dedup_run_id AND normalized_row_id = p_normalized_row_id;
  IF FOUND THEN
    RETURN jsonb_build_object('ok', true,
      'idempotent_replay',   true,
      'dedup_status',        v_existing_class.dedup_status::text,
      'transaction_id',      v_existing_class.transaction_id,
      'review_issue_id',     v_existing_class.review_issue_id,
      'matched_transaction_id', v_existing_class.matched_transaction_id);
  END IF;

  SELECT * INTO v_norm FROM public.statement_normalized_rows WHERE id = p_normalized_row_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'classify_and_record_dedup_row: normalized_row % not found', p_normalized_row_id USING ERRCODE='02000';
  END IF;
  IF v_norm.statement_upload_id <> v_run.statement_upload_id THEN
    RAISE EXCEPTION 'classify_and_record_dedup_row: normalized_row belongs to a different upload (% vs %)',
      v_norm.statement_upload_id, v_run.statement_upload_id USING ERRCODE='22023';
  END IF;

  -- ====================================================================
  -- Strict pass (a): same source_row_hash for (business, bank_account)
  -- ====================================================================
  SELECT * INTO v_match_exact FROM public.transactions
    WHERE business_id = v_run.business_id
      AND bank_account_id = v_run.bank_account_id
      AND source_row_hash = v_norm.source_row_hash
    LIMIT 1;
  IF FOUND THEN
    v_dedup_status := 'DUPLICATE_EXACT';
    v_matched_tx_id := v_match_exact.id;
    v_audit_action := 'TRANSACTION_DEDUP_EXACT_DUPLICATE';
  ELSE
    -- Strict pass (b): within-batch dedup -- prior NEW classification in this run with same hash
    SELECT c.* INTO v_match_within
      FROM public.statement_dedup_row_classifications c
      JOIN public.statement_normalized_rows n ON n.id = c.normalized_row_id
      WHERE c.dedup_run_id = p_dedup_run_id
        AND c.dedup_status = 'NEW'
        AND n.source_row_hash = v_norm.source_row_hash
      LIMIT 1;
    IF FOUND THEN
      v_dedup_status := 'DUPLICATE_EXACT';
      v_matched_tx_id := v_match_within.transaction_id;
      v_within_batch := true;
      v_audit_action := 'TRANSACTION_DEDUP_EXACT_DUPLICATE';
    ELSE
      -- ================================================================
      -- Soft / NEEDS_REVIEW pass on transaction_fingerprint
      -- ================================================================
      SELECT * INTO v_match_soft FROM public.transactions
        WHERE business_id = v_run.business_id
          AND bank_account_id = v_run.bank_account_id
          AND transaction_fingerprint = v_norm.transaction_fingerprint
        LIMIT 1;
      IF FOUND THEN
        v_matched_tx_id := v_match_soft.id;
        IF abs(v_match_soft.transaction_date - v_norm.transaction_date) <= p_soft_window_days
           AND abs(round((v_match_soft.amount - v_norm.amount) * 100)::int) <= p_amount_tolerance_cents THEN
          v_dedup_status := 'DUPLICATE_PROBABLE';
          v_audit_action := 'TRANSACTION_DEDUP_PROBABLE_DUPLICATE';
        ELSE
          v_dedup_status := 'NEEDS_REVIEW';
          v_audit_action := 'TRANSACTION_DEDUP_NEEDS_REVIEW';
        END IF;
      ELSE
        v_dedup_status := 'NEW';
        v_audit_action := 'TRANSACTION_DEDUP_NEW';
      END IF;
    END IF;
  END IF;

  -- Derive source_row_index: lowest of the parsed_row_ids (FX pair picks the
  -- earlier leg). For phase 04 staging the parsed row id linkage is in jsonb;
  -- the simplest path is to look it up against statement_parsed_rows.
  SELECT COALESCE(MIN(p.source_row_index), 0) INTO v_source_row_index
    FROM public.statement_parsed_rows p
    WHERE p.id = ANY (v_norm.parsed_row_ids);

  -- ====================================================================
  -- Side-effect: NEW -> INSERT transactions; PROBABLE/NEEDS_REVIEW -> review_issue
  -- ====================================================================
  IF v_dedup_status = 'NEW' THEN
    v_transaction_id := public.gen_uuid_v7();
    INSERT INTO public.transactions
      (id, organization_id, business_id, bank_account_id, statement_upload_id,
       source_row_index, source_row_hash, transaction_fingerprint,
       transaction_date, booking_date, amount, currency, direction,
       transaction_type, normalized_description, counterparty_name,
       counterparty_identifier_masked, counterparty_identifier_encrypted, reference,
       fx_paired_legs, dedup_status, secondary_tags,
       classification_status, match_status, ledger_status, review_status,
       created_at, updated_at)
    VALUES
      (v_transaction_id, v_run.organization_id, v_run.business_id, v_run.bank_account_id,
       v_run.statement_upload_id, v_source_row_index, v_norm.source_row_hash, v_norm.transaction_fingerprint,
       v_norm.transaction_date, v_norm.booking_date, v_norm.amount, v_norm.currency, v_norm.direction,
       COALESCE(v_norm.transaction_type_candidate, 'UNKNOWN'::public.transaction_type_enum),
       v_norm.normalized_description, v_norm.counterparty_name,
       v_norm.counterparty_identifier_masked, v_norm.counterparty_identifier_encrypted, v_norm.reference,
       v_norm.fx_paired_legs, 'NEW'::public.transaction_dedup_status_enum, '[]'::jsonb,
       'PENDING'::public.transaction_classification_status_enum,
       'UNMATCHED'::public.transaction_match_status_enum,
       'PENDING'::public.transaction_ledger_status_enum,
       'NONE'::public.transaction_review_status_enum,
       clock_timestamp(), clock_timestamp());
  ELSIF v_dedup_status IN ('DUPLICATE_PROBABLE','NEEDS_REVIEW') THEN
    v_review_issue_id := public.gen_uuid_v7();
    IF v_dedup_status = 'DUPLICATE_PROBABLE' THEN
      v_issue_type := 'bank_pipeline.duplicate_probable';
      v_title       := 'Possible duplicate bank statement row';
      v_description := format('A row in this statement upload matches an existing transaction (fingerprint %s). Confirm whether to keep the new row, mark it as a duplicate, or edit and confirm.',
                              left(v_norm.transaction_fingerprint, 12));
    ELSE
      v_issue_type := 'bank_pipeline.duplicate_needs_review';
      v_title       := 'Ambiguous duplicate bank statement row';
      v_description := format('A row in this statement upload has the same fingerprint as an existing transaction but differs in date or amount beyond the auto-dedup tolerance. Manual review required.');
    END IF;
    v_card_payload := jsonb_build_object(
      'normalized_row_id',  v_norm.id,
      'statement_upload_id', v_run.statement_upload_id,
      'source_row_index',   v_source_row_index,
      'candidate', jsonb_build_object(
        'transaction_date', v_norm.transaction_date,
        'amount',           v_norm.amount,
        'currency',         v_norm.currency,
        'direction',        v_norm.direction::text,
        'description',      v_norm.normalized_description,
        'counterparty',     v_norm.counterparty_name),
      'matched_transaction', jsonb_build_object(
        'id',               v_match_soft.id,
        'transaction_date', v_match_soft.transaction_date,
        'amount',           v_match_soft.amount,
        'currency',         v_match_soft.currency),
      'dedup_status',       v_dedup_status::text);
    INSERT INTO public.review_issues
      (id, organization_id, business_id, workflow_run_id, transaction_id,
       issue_type, issue_group, severity,
       plain_language_title, plain_language_description,
       card_payload_json, card_content_tier_used, card_content_fallback_applied,
       status, created_at, updated_at)
    VALUES
      (v_review_issue_id, v_run.organization_id, v_run.business_id, v_run.workflow_run_id,
       v_matched_tx_id,  -- the existing tx is the entity the issue is about
       v_issue_type, 'POSSIBLE_WRONG_MATCH'::public.review_issue_group_enum,
       'MEDIUM'::public.review_issue_severity_enum,
       v_title, v_description,
       v_card_payload, 'NONE'::public.review_issue_card_content_tier_enum, false,
       'OPEN'::public.review_issue_status_enum,
       clock_timestamp(), clock_timestamp());
  END IF;

  -- Persist the classification (idempotency record)
  INSERT INTO public.statement_dedup_row_classifications
    (id, dedup_run_id, normalized_row_id, dedup_status,
     transaction_id, review_issue_id, matched_transaction_id,
     matched_within_batch, classified_at)
  VALUES
    (v_classification_id, p_dedup_run_id, p_normalized_row_id, v_dedup_status,
     v_transaction_id, v_review_issue_id, v_matched_tx_id,
     v_within_batch, clock_timestamp());

  -- Counter
  IF v_dedup_status = 'NEW' THEN
    UPDATE public.statement_dedup_runs SET new_count = new_count + 1, updated_at = clock_timestamp() WHERE id = p_dedup_run_id;
  ELSIF v_dedup_status = 'DUPLICATE_EXACT' THEN
    UPDATE public.statement_dedup_runs SET exact_duplicate_count = exact_duplicate_count + 1, updated_at = clock_timestamp() WHERE id = p_dedup_run_id;
  ELSIF v_dedup_status = 'DUPLICATE_PROBABLE' THEN
    UPDATE public.statement_dedup_runs SET probable_duplicate_count = probable_duplicate_count + 1, updated_at = clock_timestamp() WHERE id = p_dedup_run_id;
  ELSIF v_dedup_status = 'NEEDS_REVIEW' THEN
    UPDATE public.statement_dedup_runs SET needs_review_count = needs_review_count + 1, updated_at = clock_timestamp() WHERE id = p_dedup_run_id;
  END IF;

  -- Audit
  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_dedup';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => v_audit_action,
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id   => v_run.statement_upload_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_run.organization_id, p_business_id => v_run.business_id,
    p_after_state => jsonb_build_object(
      'dedup_run_id',          v_run.id,
      'normalized_row_id',     v_norm.id,
      'transaction_id',        v_transaction_id,
      'review_issue_id',       v_review_issue_id,
      'matched_transaction_id', v_matched_tx_id,
      'matched_within_batch',  v_within_batch,
      'dedup_status',          v_dedup_status::text,
      'source_row_index',      v_source_row_index,
      'transaction_fingerprint', v_norm.transaction_fingerprint),
    p_reason => format('dedup: %s (row %s)', v_dedup_status::text, v_source_row_index));

  RETURN jsonb_build_object('ok', true,
    'dedup_status',           v_dedup_status::text,
    'transaction_id',         v_transaction_id,
    'review_issue_id',        v_review_issue_id,
    'matched_transaction_id', v_matched_tx_id,
    'matched_within_batch',   v_within_batch,
    'audit_event_id',         v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.classify_and_record_dedup_row(uuid, uuid, int, int, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.classify_and_record_dedup_row(uuid, uuid, int, int, uuid) TO service_role;

-- ============================================================================
-- 6. RPC: complete_statement_dedup
-- ============================================================================
CREATE OR REPLACE FUNCTION public.complete_statement_dedup(
  p_dedup_run_id  uuid,
  p_actor_user_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run        public.statement_dedup_runs%ROWTYPE;
  v_audit_row  audit.audit_events;
  v_kind       audit.actor_kind_enum;
  v_system     text;
BEGIN
  IF p_dedup_run_id IS NULL THEN
    RAISE EXCEPTION 'complete_statement_dedup: p_dedup_run_id is required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_run FROM public.statement_dedup_runs WHERE id = p_dedup_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'complete_statement_dedup: dedup_run % not found', p_dedup_run_id USING ERRCODE='02000';
  END IF;
  IF v_run.status <> 'STARTED'::public.statement_dedup_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'DEDUP_NOT_STARTED',
      'current_status', v_run.status::text);
  END IF;

  UPDATE public.statement_dedup_runs
    SET status = 'COMPLETED'::public.statement_dedup_status_enum,
        completed_at = clock_timestamp(), updated_at = clock_timestamp()
    WHERE id = p_dedup_run_id
    RETURNING * INTO v_run;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_dedup';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'STATEMENT_DEDUP_BATCH_COMPLETED',
    p_subject_type => 'STATEMENT_UPLOAD'::audit.subject_type_enum,
    p_subject_id   => v_run.statement_upload_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_run.organization_id, p_business_id => v_run.business_id,
    p_after_state => jsonb_build_object(
      'dedup_run_id',             v_run.id,
      'new_count',                v_run.new_count,
      'exact_duplicate_count',    v_run.exact_duplicate_count,
      'probable_duplicate_count', v_run.probable_duplicate_count,
      'needs_review_count',       v_run.needs_review_count),
    p_reason => format('dedup batch completed: new=%s exact=%s probable=%s needs_review=%s',
                       v_run.new_count, v_run.exact_duplicate_count,
                       v_run.probable_duplicate_count, v_run.needs_review_count));

  RETURN jsonb_build_object('ok', true,
    'dedup_run_id',             v_run.id,
    'new_count',                v_run.new_count,
    'exact_duplicate_count',    v_run.exact_duplicate_count,
    'probable_duplicate_count', v_run.probable_duplicate_count,
    'needs_review_count',       v_run.needs_review_count,
    'audit_event_id',           v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.complete_statement_dedup(uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.complete_statement_dedup(uuid, uuid) TO service_role;

-- ============================================================================
-- 7. RPC: fail_statement_dedup
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fail_statement_dedup(
  p_dedup_run_id uuid,
  p_error_message text,
  p_actor_user_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run public.statement_dedup_runs%ROWTYPE;
BEGIN
  IF p_dedup_run_id IS NULL OR p_error_message IS NULL THEN
    RAISE EXCEPTION 'fail_statement_dedup: required params missing' USING ERRCODE='22000';
  END IF;
  IF length(p_error_message) = 0 OR length(p_error_message) > 2000 THEN
    RAISE EXCEPTION 'fail_statement_dedup: error_message length must be 1..2000' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_run FROM public.statement_dedup_runs WHERE id = p_dedup_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fail_statement_dedup: dedup_run % not found', p_dedup_run_id USING ERRCODE='02000';
  END IF;
  IF v_run.status <> 'STARTED'::public.statement_dedup_status_enum THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'DEDUP_NOT_STARTED',
      'current_status', v_run.status::text);
  END IF;
  UPDATE public.statement_dedup_runs
    SET status = 'FAILED'::public.statement_dedup_status_enum,
        error_message = p_error_message,
        completed_at = clock_timestamp(), updated_at = clock_timestamp()
    WHERE id = p_dedup_run_id;
  RETURN jsonb_build_object('ok', true, 'dedup_run_id', v_run.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.fail_statement_dedup(uuid, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.fail_statement_dedup(uuid, text, uuid) TO service_role;
