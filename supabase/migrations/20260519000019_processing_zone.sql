-- B04·P06 Processing Zone
-- ============================================================================
-- Short-lived staging for OCR text, extracted-field drafts, AI payloads, and
-- match-candidate bundles produced during a workflow run.
--
-- Lifecycle (set by recompute_processing_ttl_for_run as the run transitions):
--   * FINALIZED        -> prune 24h after finalize (short diagnostic window)
--   * FAILED/CANCELLED -> prune 30d after terminal state (post-mortem window)
--   * in-progress      -> NULL expires_at (no auto-prune)
-- prune_expired_processing_artifacts skips runs flagged
-- workflow_runs.legal_hold_active = true. B04·P11 fills in the full
-- legal-hold audit trail; the column lands here as a forward declaration.
--
-- Data minimisation: artifact_type = AI_PAYLOAD_REDACTED rejects payloads
-- that contain an IBAN-shaped string (Cyprus + general two-letter IBAN
-- regex). The Privacy Gateway in B06 is the only intended writer; this
-- CHECK is the post-hoc enforcement.
-- ============================================================================

-- ---- workflow_runs forward-declaration: legal_hold_active ----------------

ALTER TABLE public.workflow_runs
  ADD COLUMN IF NOT EXISTS legal_hold_active boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.workflow_runs.legal_hold_active IS
'B04·P06 forward declaration. When true, prune jobs skip artifacts referencing this run. B04·P11 extends with full legal_holds audit trail.';

-- ---- ENUMs ---------------------------------------------------------------

CREATE TYPE public.processing_artifact_type_enum AS ENUM (
  'OCR_TEXT',
  'EXTRACTED_FIELDS_DRAFT',
  'AI_PAYLOAD_REDACTED',
  'AI_RESPONSE',
  'MATCH_CANDIDATE_BUNDLE'
);

CREATE TYPE public.processing_artifact_source_ref_type_enum AS ENUM (
  'TRANSACTION', 'DOCUMENT', 'MATCH_RECORD', 'STATEMENT_UPLOAD', 'RAW_UPLOAD_FILE'
);

CREATE TYPE public.processing_artifact_event_type_enum AS ENUM (
  'PROCESSING_ARTIFACT_CREATED',
  'PROCESSING_ARTIFACT_PRUNED',
  'PROCESSING_ARTIFACT_PRUNE_SKIPPED'
);

CREATE TYPE public.processing_prune_skip_reason_enum AS ENUM (
  'LEGAL_HOLD',
  'RUN_NOT_TERMINAL',
  'TTL_NOT_REACHED',
  'OTHER'
);

-- ---- bucket --------------------------------------------------------------

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'processing-zone',
  'processing-zone',
  false,
  104857600,  -- 100 MiB; OCR outputs + AI payloads + match bundles
  ARRAY['text/plain','application/json','application/jsonl','application/octet-stream']
)
ON CONFLICT (id) DO NOTHING;

-- ---- processing_artifacts ------------------------------------------------

CREATE TABLE public.processing_artifacts (
  id                       uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id          uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  business_id              uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,
  workflow_run_id          uuid NOT NULL REFERENCES public.workflow_runs(id) ON DELETE CASCADE,

  artifact_type            public.processing_artifact_type_enum NOT NULL,

  source_reference_type    public.processing_artifact_source_ref_type_enum NOT NULL,
  source_reference_id      uuid NOT NULL,

  payload_inline           jsonb,
  payload_storage_bucket   text,
  payload_storage_path     text,
  payload_size_bytes       bigint,
  payload_hash             text NOT NULL,  -- SHA-256 hex of canonical payload

  expires_at               timestamptz,    -- NULL = no auto-prune yet

  created_at               timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT processing_artifacts_payload_xor_chk CHECK (
    (payload_inline IS NOT NULL AND payload_storage_path IS NULL)
    OR (payload_inline IS NULL AND payload_storage_path IS NOT NULL)
  ),
  CONSTRAINT processing_artifacts_storage_bucket_chk CHECK (
    (payload_storage_path IS NULL AND payload_storage_bucket IS NULL)
    OR (payload_storage_path IS NOT NULL AND payload_storage_bucket = 'processing-zone')
  ),
  CONSTRAINT processing_artifacts_payload_hash_chk CHECK (
    payload_hash ~ '^[0-9a-f]{64}$'
  ),
  CONSTRAINT processing_artifacts_payload_size_chk CHECK (
    payload_size_bytes IS NULL OR payload_size_bytes > 0
  ),
  -- Data-minimisation guard: AI_PAYLOAD_REDACTED must not contain an
  -- IBAN-shaped string (the Privacy Gateway should have stripped it).
  -- Cyprus IBAN: CY + 2 digits + 23 alphanumerics. General IBAN: any
  -- 2-letter country + 2 digits + 11..30 alphanumerics.
  CONSTRAINT processing_artifacts_no_iban_in_redacted_chk CHECK (
    artifact_type <> 'AI_PAYLOAD_REDACTED'
    OR payload_inline IS NULL
    OR payload_inline::text !~ '\m[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}\M'
  )
);

CREATE INDEX idx_processing_artifacts_workflow_run
  ON public.processing_artifacts (workflow_run_id);
CREATE INDEX idx_processing_artifacts_business_type
  ON public.processing_artifacts (business_id, artifact_type);
CREATE INDEX idx_processing_artifacts_expires
  ON public.processing_artifacts (expires_at)
  WHERE expires_at IS NOT NULL;
CREATE INDEX idx_processing_artifacts_source_ref
  ON public.processing_artifacts (source_reference_type, source_reference_id);
CREATE INDEX idx_processing_artifacts_organization
  ON public.processing_artifacts (organization_id);

ALTER TABLE public.processing_artifacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.processing_artifacts FORCE  ROW LEVEL SECURITY;

CREATE POLICY processing_artifacts_select ON public.processing_artifacts
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    AND business_id = ANY(public.current_user_businesses())
  );
CREATE POLICY processing_artifacts_no_insert ON public.processing_artifacts
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY processing_artifacts_no_update ON public.processing_artifacts
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY processing_artifacts_no_delete ON public.processing_artifacts
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ---- source-ref validator trigger ----------------------------------------
-- Postgres can't FK a polymorphic column; this trigger enforces existence +
-- tenancy match for the (source_reference_type, source_reference_id) pair.

CREATE OR REPLACE FUNCTION public.validate_processing_artifact_source_ref()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_ok boolean := false;
BEGIN
  CASE NEW.source_reference_type
    WHEN 'TRANSACTION' THEN
      SELECT EXISTS (
        SELECT 1 FROM public.transactions
        WHERE id = NEW.source_reference_id
          AND organization_id = NEW.organization_id
          AND business_id     = NEW.business_id
      ) INTO v_ok;
    WHEN 'DOCUMENT' THEN
      SELECT EXISTS (
        SELECT 1 FROM public.documents
        WHERE id = NEW.source_reference_id
          AND organization_id = NEW.organization_id
          AND business_id     = NEW.business_id
      ) INTO v_ok;
    WHEN 'MATCH_RECORD' THEN
      SELECT EXISTS (
        SELECT 1 FROM public.match_records
        WHERE id = NEW.source_reference_id
          AND organization_id = NEW.organization_id
          AND business_id     = NEW.business_id
      ) INTO v_ok;
    WHEN 'STATEMENT_UPLOAD' THEN
      SELECT EXISTS (
        SELECT 1 FROM public.statement_uploads
        WHERE id = NEW.source_reference_id
          AND organization_id = NEW.organization_id
          AND business_id     = NEW.business_id
      ) INTO v_ok;
    WHEN 'RAW_UPLOAD_FILE' THEN
      SELECT EXISTS (
        SELECT 1 FROM public.raw_upload_files
        WHERE id = NEW.source_reference_id
          AND organization_id = NEW.organization_id
          AND business_id     = NEW.business_id
      ) INTO v_ok;
  END CASE;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'processing artifact source_reference (%, %) not found in tenant (%, %)',
      NEW.source_reference_type, NEW.source_reference_id,
      NEW.organization_id, NEW.business_id
      USING ERRCODE = '23503';
  END IF;

  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_processing_artifacts_validate_source_ref
  BEFORE INSERT ON public.processing_artifacts
  FOR EACH ROW EXECUTE FUNCTION public.validate_processing_artifact_source_ref();

-- ---- processing_artifact_events -----------------------------------------

CREATE TABLE public.processing_artifact_events (
  id                       uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id          uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  business_id              uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,

  event_type               public.processing_artifact_event_type_enum NOT NULL,
  processing_artifact_id   uuid REFERENCES public.processing_artifacts(id) ON DELETE SET NULL,
  workflow_run_id          uuid REFERENCES public.workflow_runs(id) ON DELETE SET NULL,

  actor_user_id            uuid REFERENCES public.users(id),
  actor_system             text,
  skip_reason              public.processing_prune_skip_reason_enum,

  payload                  jsonb NOT NULL DEFAULT '{}'::jsonb,
  occurred_at              timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT processing_artifact_events_actor_chk CHECK (
    (actor_user_id IS NOT NULL) <> (actor_system IS NOT NULL)
  ),
  CONSTRAINT processing_artifact_events_skip_reason_chk CHECK (
    (event_type <> 'PROCESSING_ARTIFACT_PRUNE_SKIPPED' AND skip_reason IS NULL)
    OR (event_type = 'PROCESSING_ARTIFACT_PRUNE_SKIPPED' AND skip_reason IS NOT NULL)
  )
);

CREATE INDEX idx_processing_artifact_events_business_occurred
  ON public.processing_artifact_events (business_id, occurred_at DESC);
CREATE INDEX idx_processing_artifact_events_artifact
  ON public.processing_artifact_events (processing_artifact_id)
  WHERE processing_artifact_id IS NOT NULL;
CREATE INDEX idx_processing_artifact_events_workflow_run
  ON public.processing_artifact_events (workflow_run_id)
  WHERE workflow_run_id IS NOT NULL;
CREATE INDEX idx_processing_artifact_events_organization
  ON public.processing_artifact_events (organization_id);
CREATE INDEX idx_processing_artifact_events_actor_user
  ON public.processing_artifact_events (actor_user_id)
  WHERE actor_user_id IS NOT NULL;

ALTER TABLE public.processing_artifact_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.processing_artifact_events FORCE  ROW LEVEL SECURITY;

CREATE POLICY processing_artifact_events_select ON public.processing_artifact_events
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    AND business_id = ANY(public.current_user_businesses())
  );
CREATE POLICY processing_artifact_events_no_insert ON public.processing_artifact_events
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY processing_artifact_events_no_update ON public.processing_artifact_events
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY processing_artifact_events_no_delete ON public.processing_artifact_events
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ---- storage.objects RLS for processing-zone ----------------------------

CREATE POLICY processing_zone_object_select ON storage.objects
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    bucket_id = 'processing-zone'
    AND (storage.foldername(name))[1] = public.current_org()::text
    AND ((storage.foldername(name))[2])::uuid = ANY(public.current_user_businesses())
  );
CREATE POLICY processing_zone_object_no_insert ON storage.objects
  AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (bucket_id <> 'processing-zone');
CREATE POLICY processing_zone_object_no_update ON storage.objects
  AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (bucket_id <> 'processing-zone')
  WITH CHECK (bucket_id <> 'processing-zone');
CREATE POLICY processing_zone_object_no_delete ON storage.objects
  AS RESTRICTIVE FOR DELETE TO authenticated
  USING (bucket_id <> 'processing-zone');

-- ---- default expiry helper (declared first so write_processing_artifact
-- can resolve it under check_function_bodies = on) -----------------------

CREATE OR REPLACE FUNCTION public.processing_artifact_default_expiry(
  p_run_status     public.workflow_run_status_stub_enum,
  p_finalized_at   timestamptz
) RETURNS timestamptz
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $fn$
  SELECT CASE
    WHEN p_run_status = 'FINALIZED'
      THEN COALESCE(p_finalized_at, now()) + interval '24 hours'
    WHEN p_run_status IN ('FAILED','CANCELLED')
      THEN COALESCE(p_finalized_at, now()) + interval '30 days'
    ELSE NULL
  END
$fn$;

-- ---- write_processing_artifact (service-role) ----------------------------

CREATE OR REPLACE FUNCTION public.write_processing_artifact(
  p_workflow_run_id       uuid,
  p_artifact_type         public.processing_artifact_type_enum,
  p_source_reference_type public.processing_artifact_source_ref_type_enum,
  p_source_reference_id   uuid,
  p_payload_inline        jsonb,
  p_payload_storage_path  text,
  p_payload_size_bytes    bigint,
  p_payload_hash          text,
  p_actor_system          text DEFAULT 'processing-writer'
) RETURNS public.processing_artifacts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_run     public.workflow_runs;
  v_artifact public.processing_artifacts;
  v_expires timestamptz;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'workflow run % not found', p_workflow_run_id USING ERRCODE = 'P0002';
  END IF;

  v_expires := public.processing_artifact_default_expiry(v_run.status, v_run.finalized_at);

  INSERT INTO public.processing_artifacts (
    organization_id, business_id, workflow_run_id, artifact_type,
    source_reference_type, source_reference_id,
    payload_inline, payload_storage_bucket, payload_storage_path,
    payload_size_bytes, payload_hash, expires_at
  ) VALUES (
    v_run.organization_id, v_run.business_id, v_run.id, p_artifact_type,
    p_source_reference_type, p_source_reference_id,
    p_payload_inline,
    CASE WHEN p_payload_storage_path IS NULL THEN NULL ELSE 'processing-zone' END,
    p_payload_storage_path,
    p_payload_size_bytes, p_payload_hash, v_expires
  )
  RETURNING * INTO v_artifact;

  INSERT INTO public.processing_artifact_events (
    organization_id, business_id, event_type, processing_artifact_id,
    workflow_run_id, actor_system, payload
  ) VALUES (
    v_run.organization_id, v_run.business_id, 'PROCESSING_ARTIFACT_CREATED',
    v_artifact.id, v_run.id, p_actor_system,
    jsonb_build_object(
      'artifact_type', p_artifact_type::text,
      'source_reference_type', p_source_reference_type::text,
      'source_reference_id', p_source_reference_id,
      'storage_mode', CASE WHEN p_payload_storage_path IS NULL THEN 'INLINE' ELSE 'STORAGE' END,
      'payload_hash', p_payload_hash,
      'payload_size_bytes', p_payload_size_bytes,
      'expires_at', v_expires
    )
  );

  RETURN v_artifact;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION public.write_processing_artifact(uuid, public.processing_artifact_type_enum, public.processing_artifact_source_ref_type_enum, uuid, jsonb, text, bigint, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.write_processing_artifact(uuid, public.processing_artifact_type_enum, public.processing_artifact_source_ref_type_enum, uuid, jsonb, text, bigint, text, text) TO service_role;

-- ---- recompute_processing_ttl_for_run ------------------------------------
-- Called when a workflow run transitions terminal (B03 wires it up).

CREATE OR REPLACE FUNCTION public.recompute_processing_ttl_for_run(
  p_workflow_run_id uuid
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_run     public.workflow_runs;
  v_expires timestamptz;
  v_count   integer;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_workflow_run_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'workflow run % not found', p_workflow_run_id USING ERRCODE = 'P0002';
  END IF;

  v_expires := public.processing_artifact_default_expiry(v_run.status, v_run.finalized_at);

  UPDATE public.processing_artifacts
     SET expires_at = v_expires
   WHERE workflow_run_id = p_workflow_run_id
     -- Don't reduce an already-set expiry; allow extension only.
     AND (expires_at IS NULL OR (v_expires IS NOT NULL AND v_expires > expires_at));
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION public.recompute_processing_ttl_for_run(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.recompute_processing_ttl_for_run(uuid) TO service_role;

-- ---- prune_expired_processing_artifacts (background job) -----------------

CREATE OR REPLACE FUNCTION public.prune_expired_processing_artifacts(
  p_now   timestamptz DEFAULT now(),
  p_limit integer     DEFAULT 1000
) RETURNS TABLE (pruned integer, skipped integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_artifact record;
  v_run      public.workflow_runs;
  v_pruned   integer := 0;
  v_skipped  integer := 0;
  v_skip     public.processing_prune_skip_reason_enum;
BEGIN
  FOR v_artifact IN
    SELECT * FROM public.processing_artifacts
     WHERE expires_at IS NOT NULL
       AND expires_at <= p_now
     ORDER BY expires_at
     LIMIT p_limit
     FOR UPDATE SKIP LOCKED
  LOOP
    SELECT * INTO v_run FROM public.workflow_runs WHERE id = v_artifact.workflow_run_id;
    v_skip := NULL;
    IF v_run.legal_hold_active THEN
      v_skip := 'LEGAL_HOLD';
    ELSIF v_run.status NOT IN ('FINALIZED','FAILED','CANCELLED') THEN
      v_skip := 'RUN_NOT_TERMINAL';
    END IF;

    IF v_skip IS NOT NULL THEN
      INSERT INTO public.processing_artifact_events (
        organization_id, business_id, event_type, processing_artifact_id,
        workflow_run_id, actor_system, skip_reason, payload
      ) VALUES (
        v_artifact.organization_id, v_artifact.business_id,
        'PROCESSING_ARTIFACT_PRUNE_SKIPPED', v_artifact.id,
        v_artifact.workflow_run_id, 'prune-job', v_skip,
        jsonb_build_object(
          'artifact_type', v_artifact.artifact_type::text,
          'run_status',    v_run.status::text,
          'expires_at',    v_artifact.expires_at
        )
      );
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    -- The DB row is deleted here; the Storage object is deleted by a
    -- background worker that reads PROCESSING_ARTIFACT_PRUNED events whose
    -- payload.storage_cleanup_pending = true and calls the Storage API.
    -- Supabase blocks direct DELETE FROM storage.objects in user-defined
    -- functions (storage.protect_delete trigger).
    INSERT INTO public.processing_artifact_events (
      organization_id, business_id, event_type, processing_artifact_id,
      workflow_run_id, actor_system, payload
    ) VALUES (
      v_artifact.organization_id, v_artifact.business_id,
      'PROCESSING_ARTIFACT_PRUNED', v_artifact.id,
      v_artifact.workflow_run_id, 'prune-job',
      jsonb_build_object(
        'artifact_type',           v_artifact.artifact_type::text,
        'storage_bucket',          v_artifact.payload_storage_bucket,
        'storage_path',            v_artifact.payload_storage_path,
        'expired_at',              v_artifact.expires_at,
        'storage_cleanup_pending', (v_artifact.payload_storage_path IS NOT NULL)
      )
    );

    DELETE FROM public.processing_artifacts WHERE id = v_artifact.id;
    v_pruned := v_pruned + 1;
  END LOOP;

  RETURN QUERY SELECT v_pruned, v_skipped;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION public.prune_expired_processing_artifacts(timestamptz, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.prune_expired_processing_artifacts(timestamptz, integer) TO service_role;

COMMENT ON TABLE public.processing_artifacts IS
'B04·P06: intermediate artefacts (OCR text, extracted-field drafts, AI payloads, match bundles). TTL set by run state; pruned by background job. AI_PAYLOAD_REDACTED enforces a no-IBAN guard at write time.';
COMMENT ON TABLE public.processing_artifact_events IS
'B04·P06: minimal CREATED / PRUNED / PRUNE_SKIPPED audit. B05·P02 folds into the global hash-chain audit.';
COMMENT ON FUNCTION public.write_processing_artifact(uuid, public.processing_artifact_type_enum, public.processing_artifact_source_ref_type_enum, uuid, jsonb, text, bigint, text, text) IS
'B04·P06 write step: service_role only. Computes default expiry from run state, inserts the artefact + CREATED audit. Source-ref validity enforced by trigger; IBAN guard enforced by CHECK.';
COMMENT ON FUNCTION public.recompute_processing_ttl_for_run(uuid) IS
'B04·P06 TTL recompute: extend (never shrink) expires_at on attached artefacts when a run transitions terminal. Returns rows touched.';
COMMENT ON FUNCTION public.prune_expired_processing_artifacts(timestamptz, integer) IS
'B04·P06 prune job: deletes expired artefacts (DB + storage). Skips on legal_hold_active or non-terminal run, emitting PROCESSING_ARTIFACT_PRUNE_SKIPPED. Returns (pruned, skipped).';
