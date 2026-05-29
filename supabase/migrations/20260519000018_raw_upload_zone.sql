-- B04·P05 Raw Upload Zone
-- ============================================================================
-- Private EU-region storage bucket (`raw-uploads`) + raw_upload_files grant
-- ledger + storage.objects RLS + SECURITY DEFINER RPCs that drive the
-- sign -> confirm -> view / orphan-sweep lifecycle.
--
-- file_audit_events captures FILE_UPLOAD_REQUESTED / FILE_UPLOADED /
-- FILE_UPLOAD_ORPHANED / FILE_VIEWED / FILE_DOWNLOADED / FILE_UPLOAD_REJECTED
-- as a minimal log; B05·P02 folds these into the global hash-chain audit.
--
-- Path layout: {organization_id}/{business_id}/{entity_type}/{file_id}
-- ============================================================================

-- ---- ENUMs ---------------------------------------------------------------

CREATE TYPE public.upload_entity_type_enum AS ENUM (
  'STATEMENT', 'INVOICE', 'RECEIPT', 'CONTRACT', 'EVIDENCE_PDF'
);

CREATE TYPE public.raw_upload_status_enum AS ENUM (
  'PENDING', 'CONFIRMED', 'ORPHANED', 'REJECTED'
);

CREATE TYPE public.file_audit_event_type_enum AS ENUM (
  'FILE_UPLOAD_REQUESTED', 'FILE_UPLOADED', 'FILE_UPLOAD_ORPHANED',
  'FILE_VIEWED', 'FILE_DOWNLOADED', 'FILE_UPLOAD_REJECTED'
);

CREATE TYPE public.upload_reject_reason_enum AS ENUM (
  'SIZE_LIMIT_EXCEEDED', 'CONTENT_TYPE_NOT_ALLOWED',
  'CONTENT_SNIFF_MISMATCH', 'HASH_MISMATCH', 'OUT_OF_SCOPE', 'OTHER'
);

-- ---- bucket ----------------------------------------------------------------

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'raw-uploads',
  'raw-uploads',
  false,
  52428800,  -- 50 MiB hard ceiling; per-entity caps enforced in RPC
  ARRAY[
    'application/pdf',
    'image/jpeg', 'image/png', 'image/heic',
    'text/csv',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  ]
)
ON CONFLICT (id) DO NOTHING;

-- ---- raw_upload_files ------------------------------------------------------

CREATE TABLE public.raw_upload_files (
  id                      uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id         uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  business_id             uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,

  entity_type             public.upload_entity_type_enum NOT NULL,
  storage_bucket          text NOT NULL DEFAULT 'raw-uploads',
  storage_path            text NOT NULL,
  original_filename       text NOT NULL,

  declared_size_bytes     bigint NOT NULL,
  declared_content_type   text   NOT NULL,
  actual_size_bytes       bigint,
  actual_content_type     text,

  file_hash               text,  -- SHA-256 hex of bytes; recorded at CONFIRM

  status                  public.raw_upload_status_enum NOT NULL DEFAULT 'PENDING',
  reject_reason           public.upload_reject_reason_enum,
  reject_detail           text,

  grant_expires_at        timestamptz NOT NULL,
  confirmed_at            timestamptz,
  orphaned_at             timestamptz,
  rejected_at             timestamptz,

  requested_by            uuid NOT NULL REFERENCES public.users(id),
  confirmed_by_user_id    uuid REFERENCES public.users(id),
  confirmed_by_system     text,

  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT raw_upload_files_size_positive_chk CHECK (declared_size_bytes > 0),
  CONSTRAINT raw_upload_files_actual_size_positive_chk CHECK (
    actual_size_bytes IS NULL OR actual_size_bytes > 0
  ),
  CONSTRAINT raw_upload_files_hash_format_chk CHECK (
    file_hash IS NULL OR file_hash ~ '^[0-9a-f]{64}$'
  ),
  CONSTRAINT raw_upload_files_confirmed_chk CHECK (
    (status <> 'CONFIRMED') OR (
      file_hash IS NOT NULL
      AND actual_size_bytes IS NOT NULL
      AND actual_content_type IS NOT NULL
      AND confirmed_at IS NOT NULL
    )
  ),
  CONSTRAINT raw_upload_files_rejected_chk CHECK (
    (status <> 'REJECTED') OR (reject_reason IS NOT NULL AND rejected_at IS NOT NULL)
  ),
  CONSTRAINT raw_upload_files_orphaned_chk CHECK (
    (status <> 'ORPHANED') OR (orphaned_at IS NOT NULL)
  ),
  CONSTRAINT raw_upload_files_confirmed_by_exclusive_chk CHECK (
    (status <> 'CONFIRMED')
    OR ((confirmed_by_user_id IS NOT NULL) <> (confirmed_by_system IS NOT NULL))
  )
);

CREATE UNIQUE INDEX idx_raw_upload_files_storage_path
  ON public.raw_upload_files (storage_path);

CREATE INDEX idx_raw_upload_files_business_status
  ON public.raw_upload_files (business_id, status);

CREATE INDEX idx_raw_upload_files_pending_grant_expires
  ON public.raw_upload_files (grant_expires_at)
  WHERE status = 'PENDING';

CREATE INDEX idx_raw_upload_files_business_hash
  ON public.raw_upload_files (business_id, file_hash)
  WHERE file_hash IS NOT NULL;

CREATE TRIGGER raw_upload_files_set_updated_at
  BEFORE UPDATE ON public.raw_upload_files
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.raw_upload_files ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.raw_upload_files FORCE  ROW LEVEL SECURITY;

CREATE POLICY raw_upload_files_select ON public.raw_upload_files
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    AND business_id = ANY(public.current_user_businesses())
  );
CREATE POLICY raw_upload_files_no_insert ON public.raw_upload_files
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY raw_upload_files_no_update ON public.raw_upload_files
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY raw_upload_files_no_delete ON public.raw_upload_files
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ---- file_audit_events -----------------------------------------------------

CREATE TABLE public.file_audit_events (
  id                  uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id     uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  business_id         uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,

  event_type          public.file_audit_event_type_enum NOT NULL,
  raw_upload_file_id  uuid REFERENCES public.raw_upload_files(id) ON DELETE SET NULL,
  storage_path        text,

  actor_user_id       uuid REFERENCES public.users(id),
  actor_system        text,

  payload             jsonb NOT NULL DEFAULT '{}'::jsonb,

  occurred_at         timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT file_audit_events_actor_chk CHECK (
    (actor_user_id IS NOT NULL) <> (actor_system IS NOT NULL)
  )
);

CREATE INDEX idx_file_audit_events_business_occurred
  ON public.file_audit_events (business_id, occurred_at DESC);

CREATE INDEX idx_file_audit_events_raw_upload_file
  ON public.file_audit_events (raw_upload_file_id)
  WHERE raw_upload_file_id IS NOT NULL;

CREATE INDEX idx_file_audit_events_business_event_type
  ON public.file_audit_events (business_id, event_type, occurred_at DESC);

ALTER TABLE public.file_audit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.file_audit_events FORCE  ROW LEVEL SECURITY;

CREATE POLICY file_audit_events_select ON public.file_audit_events
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    AND business_id = ANY(public.current_user_businesses())
  );
CREATE POLICY file_audit_events_no_insert ON public.file_audit_events
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY file_audit_events_no_update ON public.file_audit_events
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY file_audit_events_no_delete ON public.file_audit_events
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ---- storage.objects RLS for raw-uploads -----------------------------------
-- SELECT: tenant-scoped via path prefix ({org}/{biz}/{entity}/{file_id}).
-- Mutations to objects in the raw-uploads bucket are RESTRICTIVE-blocked
-- from authenticated; signed URLs carry their own scope at the Storage API
-- layer and bypass these policies, and service-role DEFINER paths do
-- post-upload state transitions on raw_upload_files only.

CREATE POLICY raw_uploads_object_select ON storage.objects
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    bucket_id = 'raw-uploads'
    AND (storage.foldername(name))[1] = public.current_org()::text
    AND ((storage.foldername(name))[2])::uuid = ANY(public.current_user_businesses())
  );

CREATE POLICY raw_uploads_object_no_insert ON storage.objects
  AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (bucket_id <> 'raw-uploads');

CREATE POLICY raw_uploads_object_no_update ON storage.objects
  AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (bucket_id <> 'raw-uploads')
  WITH CHECK (bucket_id <> 'raw-uploads');

CREATE POLICY raw_uploads_object_no_delete ON storage.objects
  AS RESTRICTIVE FOR DELETE TO authenticated
  USING (bucket_id <> 'raw-uploads');

-- ---- helper functions (size caps, allowed content types) -------------------

CREATE OR REPLACE FUNCTION public.raw_upload_size_limit(
  p_entity public.upload_entity_type_enum
) RETURNS bigint
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE p_entity
    WHEN 'STATEMENT'    THEN 52428800::bigint  -- 50 MiB
    WHEN 'INVOICE'      THEN 26214400::bigint  -- 25 MiB
    WHEN 'RECEIPT'      THEN 26214400::bigint  -- 25 MiB
    WHEN 'CONTRACT'     THEN 26214400::bigint  -- 25 MiB
    WHEN 'EVIDENCE_PDF' THEN 10485760::bigint  -- 10 MiB
  END
$$;

CREATE OR REPLACE FUNCTION public.raw_upload_allowed_content_types(
  p_entity public.upload_entity_type_enum
) RETURNS text[]
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE p_entity
    WHEN 'STATEMENT'    THEN ARRAY['text/csv','application/pdf']
    WHEN 'INVOICE'      THEN ARRAY['application/pdf','image/jpeg','image/png','image/heic',
                                    'application/vnd.openxmlformats-officedocument.wordprocessingml.document']
    WHEN 'RECEIPT'      THEN ARRAY['application/pdf','image/jpeg','image/png','image/heic']
    WHEN 'CONTRACT'     THEN ARRAY['application/pdf',
                                    'application/vnd.openxmlformats-officedocument.wordprocessingml.document']
    WHEN 'EVIDENCE_PDF' THEN ARRAY['application/pdf']
  END
$$;

-- ---- request_raw_upload (sign step) ---------------------------------------

CREATE OR REPLACE FUNCTION public.request_raw_upload(
  p_business_id           uuid,
  p_entity_type           public.upload_entity_type_enum,
  p_original_filename     text,
  p_declared_size_bytes   bigint,
  p_declared_content_type text,
  p_grant_ttl_seconds     integer DEFAULT 900
) RETURNS TABLE (
  raw_upload_file_id uuid,
  storage_bucket     text,
  storage_path       text,
  grant_expires_at   timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id    uuid := public.current_user_id();
  v_org_id     uuid;
  v_size_cap   bigint;
  v_allowed    text[];
  v_file_id    uuid;
  v_path       text;
  v_expires_at timestamptz;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '28000';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.business_user_roles bur
    JOIN public.business_entities be ON be.id = bur.business_id
    WHERE bur.user_id = v_user_id
      AND bur.business_id = p_business_id
      AND bur.status = 'ACTIVE'
      AND be.is_active = true
  ) THEN
    RAISE EXCEPTION 'business access denied' USING ERRCODE = '42501';
  END IF;

  SELECT organization_id INTO v_org_id
    FROM public.business_entities WHERE id = p_business_id;

  v_size_cap := public.raw_upload_size_limit(p_entity_type);
  v_allowed  := public.raw_upload_allowed_content_types(p_entity_type);

  -- Request-time validation just raises; the API layer owns the request-time
  -- FILE_UPLOAD_REJECTED audit (audit-then-raise inside a DEFINER function
  -- would roll back the audit row along with the exception).
  IF p_declared_size_bytes <= 0 OR p_declared_size_bytes > v_size_cap THEN
    RAISE EXCEPTION 'declared size % exceeds cap % for %', p_declared_size_bytes, v_size_cap, p_entity_type
      USING ERRCODE = '22000';
  END IF;

  IF NOT (p_declared_content_type = ANY (v_allowed)) THEN
    RAISE EXCEPTION 'content type % not allowed for %', p_declared_content_type, p_entity_type
      USING ERRCODE = '22000';
  END IF;

  IF p_grant_ttl_seconds < 60 OR p_grant_ttl_seconds > 3600 THEN
    RAISE EXCEPTION 'grant TTL must be 60..3600 seconds' USING ERRCODE = '22000';
  END IF;

  v_file_id    := public.gen_uuid_v7();
  v_path       := v_org_id::text || '/' || p_business_id::text || '/'
                  || p_entity_type::text || '/' || v_file_id::text;
  v_expires_at := now() + make_interval(secs => p_grant_ttl_seconds);

  INSERT INTO public.raw_upload_files (
    id, organization_id, business_id, entity_type,
    storage_bucket, storage_path, original_filename,
    declared_size_bytes, declared_content_type,
    status, grant_expires_at, requested_by
  ) VALUES (
    v_file_id, v_org_id, p_business_id, p_entity_type,
    'raw-uploads', v_path, p_original_filename,
    p_declared_size_bytes, p_declared_content_type,
    'PENDING', v_expires_at, v_user_id
  );

  INSERT INTO public.file_audit_events (
    organization_id, business_id, event_type, raw_upload_file_id, storage_path,
    actor_user_id, payload
  ) VALUES (
    v_org_id, p_business_id, 'FILE_UPLOAD_REQUESTED', v_file_id, v_path,
    v_user_id,
    jsonb_build_object(
      'entity_type', p_entity_type::text,
      'declared_size_bytes', p_declared_size_bytes,
      'declared_content_type', p_declared_content_type,
      'grant_ttl_seconds', p_grant_ttl_seconds
    )
  );

  RETURN QUERY SELECT v_file_id, 'raw-uploads'::text, v_path, v_expires_at;
END;
$$;

REVOKE ALL ON FUNCTION public.request_raw_upload(uuid, public.upload_entity_type_enum, text, bigint, text, integer) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.request_raw_upload(uuid, public.upload_entity_type_enum, text, bigint, text, integer) TO authenticated;

-- ---- confirm_raw_upload (post-upload step; service-role only) -------------

CREATE OR REPLACE FUNCTION public.confirm_raw_upload(
  p_raw_upload_file_id  uuid,
  p_file_hash           text,
  p_actual_size_bytes   bigint,
  p_actual_content_type text,
  p_confirmed_by_system text DEFAULT NULL
) RETURNS public.raw_upload_files
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row     public.raw_upload_files;
  v_user_id uuid := public.current_user_id();
  v_actor   text;
  v_allowed text[];
BEGIN
  v_actor := COALESCE(p_confirmed_by_system, 'service-role');

  SELECT * INTO v_row FROM public.raw_upload_files
    WHERE id = p_raw_upload_file_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'raw upload not found' USING ERRCODE = 'P0002';
  END IF;

  IF v_row.status <> 'PENDING' THEN
    RAISE EXCEPTION 'raw upload already in terminal state %', v_row.status
      USING ERRCODE = '22023';
  END IF;

  -- Validation failures return the row in its new terminal state (REJECTED /
  -- ORPHANED) with the matching audit event persisted. Raising would roll
  -- back both the state transition AND the audit row, so we return-on-fail
  -- and let callers branch on v_row.status.

  IF v_row.grant_expires_at < now() THEN
    UPDATE public.raw_upload_files
       SET status = 'ORPHANED', orphaned_at = now()
     WHERE id = p_raw_upload_file_id
     RETURNING * INTO v_row;
    INSERT INTO public.file_audit_events (
      organization_id, business_id, event_type, raw_upload_file_id, storage_path,
      actor_system, payload
    ) VALUES (
      v_row.organization_id, v_row.business_id, 'FILE_UPLOAD_ORPHANED',
      v_row.id, v_row.storage_path, v_actor,
      jsonb_build_object('reason','grant_ttl_expired_at_confirm')
    );
    RETURN v_row;
  END IF;

  IF p_file_hash IS NULL OR p_file_hash !~ '^[0-9a-f]{64}$' THEN
    UPDATE public.raw_upload_files
       SET status = 'REJECTED', rejected_at = now(),
           reject_reason = 'HASH_MISMATCH',
           reject_detail = 'malformed file_hash'
     WHERE id = p_raw_upload_file_id
     RETURNING * INTO v_row;
    INSERT INTO public.file_audit_events (
      organization_id, business_id, event_type, raw_upload_file_id, storage_path,
      actor_system, payload
    ) VALUES (
      v_row.organization_id, v_row.business_id, 'FILE_UPLOAD_REJECTED',
      v_row.id, v_row.storage_path, v_actor,
      jsonb_build_object('reason','HASH_MISMATCH','detail','malformed file_hash')
    );
    RETURN v_row;
  END IF;

  IF p_actual_size_bytes IS NULL OR p_actual_size_bytes <= 0
     OR p_actual_size_bytes > public.raw_upload_size_limit(v_row.entity_type) THEN
    UPDATE public.raw_upload_files
       SET status = 'REJECTED', rejected_at = now(),
           reject_reason = 'SIZE_LIMIT_EXCEEDED',
           reject_detail = format('actual_size=%s cap=%s',
                                   p_actual_size_bytes,
                                   public.raw_upload_size_limit(v_row.entity_type))
     WHERE id = p_raw_upload_file_id
     RETURNING * INTO v_row;
    INSERT INTO public.file_audit_events (
      organization_id, business_id, event_type, raw_upload_file_id, storage_path,
      actor_system, payload
    ) VALUES (
      v_row.organization_id, v_row.business_id, 'FILE_UPLOAD_REJECTED',
      v_row.id, v_row.storage_path, v_actor,
      jsonb_build_object('reason','SIZE_LIMIT_EXCEEDED',
                         'actual_size_bytes', p_actual_size_bytes)
    );
    RETURN v_row;
  END IF;

  v_allowed := public.raw_upload_allowed_content_types(v_row.entity_type);
  IF NOT (p_actual_content_type = ANY (v_allowed)) THEN
    UPDATE public.raw_upload_files
       SET status = 'REJECTED', rejected_at = now(),
           reject_reason = 'CONTENT_TYPE_NOT_ALLOWED',
           reject_detail = format('actual=%s', p_actual_content_type)
     WHERE id = p_raw_upload_file_id
     RETURNING * INTO v_row;
    INSERT INTO public.file_audit_events (
      organization_id, business_id, event_type, raw_upload_file_id, storage_path,
      actor_system, payload
    ) VALUES (
      v_row.organization_id, v_row.business_id, 'FILE_UPLOAD_REJECTED',
      v_row.id, v_row.storage_path, v_actor,
      jsonb_build_object('reason','CONTENT_TYPE_NOT_ALLOWED',
                         'actual_content_type', p_actual_content_type)
    );
    RETURN v_row;
  END IF;

  IF p_actual_content_type <> v_row.declared_content_type THEN
    UPDATE public.raw_upload_files
       SET status = 'REJECTED', rejected_at = now(),
           reject_reason = 'CONTENT_SNIFF_MISMATCH',
           reject_detail = format('declared=%s actual=%s',
                                   v_row.declared_content_type, p_actual_content_type)
     WHERE id = p_raw_upload_file_id
     RETURNING * INTO v_row;
    INSERT INTO public.file_audit_events (
      organization_id, business_id, event_type, raw_upload_file_id, storage_path,
      actor_system, payload
    ) VALUES (
      v_row.organization_id, v_row.business_id, 'FILE_UPLOAD_REJECTED',
      v_row.id, v_row.storage_path, v_actor,
      jsonb_build_object('reason','CONTENT_SNIFF_MISMATCH',
                         'declared_content_type', v_row.declared_content_type,
                         'actual_content_type', p_actual_content_type)
    );
    RETURN v_row;
  END IF;

  UPDATE public.raw_upload_files
     SET status               = 'CONFIRMED',
         file_hash            = p_file_hash,
         actual_size_bytes    = p_actual_size_bytes,
         actual_content_type  = p_actual_content_type,
         confirmed_at         = now(),
         confirmed_by_user_id = CASE WHEN p_confirmed_by_system IS NULL THEN v_user_id ELSE NULL END,
         confirmed_by_system  = p_confirmed_by_system
   WHERE id = p_raw_upload_file_id
   RETURNING * INTO v_row;

  INSERT INTO public.file_audit_events (
    organization_id, business_id, event_type, raw_upload_file_id, storage_path,
    actor_user_id, actor_system, payload
  ) VALUES (
    v_row.organization_id, v_row.business_id, 'FILE_UPLOADED',
    v_row.id, v_row.storage_path,
    CASE WHEN p_confirmed_by_system IS NULL THEN v_user_id ELSE NULL END,
    p_confirmed_by_system,
    jsonb_build_object(
      'file_hash', p_file_hash,
      'actual_size_bytes', p_actual_size_bytes,
      'actual_content_type', p_actual_content_type
    )
  );

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.confirm_raw_upload(uuid, text, bigint, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.confirm_raw_upload(uuid, text, bigint, text, text) TO service_role;

-- ---- record_raw_upload_view (read-event audit; called by authenticated) ---

CREATE OR REPLACE FUNCTION public.record_raw_upload_view(
  p_raw_upload_file_id uuid,
  p_event_type         public.file_audit_event_type_enum DEFAULT 'FILE_VIEWED'
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row     public.raw_upload_files;
  v_user_id uuid := public.current_user_id();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = '28000';
  END IF;
  IF p_event_type NOT IN ('FILE_VIEWED','FILE_DOWNLOADED') THEN
    RAISE EXCEPTION 'invalid event type %', p_event_type USING ERRCODE = '22000';
  END IF;

  SELECT * INTO v_row FROM public.raw_upload_files WHERE id = p_raw_upload_file_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'raw upload not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_row.status <> 'CONFIRMED' THEN
    RAISE EXCEPTION 'file not in CONFIRMED state' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.business_user_roles bur
    WHERE bur.user_id = v_user_id
      AND bur.business_id = v_row.business_id
      AND bur.status = 'ACTIVE'
  ) THEN
    RAISE EXCEPTION 'business access denied' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.file_audit_events (
    organization_id, business_id, event_type, raw_upload_file_id, storage_path,
    actor_user_id, payload
  ) VALUES (
    v_row.organization_id, v_row.business_id, p_event_type,
    v_row.id, v_row.storage_path, v_user_id, '{}'::jsonb
  );
END;
$$;

REVOKE ALL ON FUNCTION public.record_raw_upload_view(uuid, public.file_audit_event_type_enum) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.record_raw_upload_view(uuid, public.file_audit_event_type_enum) TO authenticated;

-- ---- sweep_orphaned_raw_uploads (background job; service-role only) -------

CREATE OR REPLACE FUNCTION public.sweep_orphaned_raw_uploads(
  p_now timestamptz DEFAULT now()
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_orphan record;
  v_count  integer := 0;
BEGIN
  FOR v_orphan IN
    SELECT id, organization_id, business_id, storage_path
      FROM public.raw_upload_files
     WHERE status = 'PENDING' AND grant_expires_at < p_now
     FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.raw_upload_files
       SET status = 'ORPHANED', orphaned_at = p_now
     WHERE id = v_orphan.id;
    INSERT INTO public.file_audit_events (
      organization_id, business_id, event_type, raw_upload_file_id, storage_path,
      actor_system, payload
    ) VALUES (
      v_orphan.organization_id, v_orphan.business_id, 'FILE_UPLOAD_ORPHANED',
      v_orphan.id, v_orphan.storage_path, 'orphan-sweep',
      jsonb_build_object('swept_at', p_now)
    );
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.sweep_orphaned_raw_uploads(timestamptz) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.sweep_orphaned_raw_uploads(timestamptz) TO service_role;

-- ---- comments --------------------------------------------------------------

COMMENT ON TABLE  public.raw_upload_files IS
'B04·P05: grant ledger for the raw-uploads bucket. Lifecycle PENDING -> CONFIRMED / ORPHANED / REJECTED. file_hash populated at confirm. Writes blocked from authenticated; SECURITY DEFINER RPCs are the only writers.';
COMMENT ON TABLE  public.file_audit_events IS
'B04·P05: minimal file-scope event log (request / upload / orphan / view / download / reject). Subsumed by global hash-chain audit in B05·P02.';
COMMENT ON FUNCTION public.request_raw_upload(uuid, public.upload_entity_type_enum, text, bigint, text, integer) IS
'B04·P05 sign step: validates declared size + content type, issues a path under {org}/{biz}/{entity}/{file_id}, returns grant id + expiry. Caller (authenticated) then receives a signed upload URL from the API layer.';
COMMENT ON FUNCTION public.confirm_raw_upload(uuid, text, bigint, text, text) IS
'B04·P05 confirm step: service-role only. Validates hash format, actual size, content-sniff match against declared type; on success moves PENDING -> CONFIRMED and records file_hash; otherwise REJECTED with reason.';
COMMENT ON FUNCTION public.record_raw_upload_view(uuid, public.file_audit_event_type_enum) IS
'B04·P05 view-event audit: emits FILE_VIEWED / FILE_DOWNLOADED. Caller must have an ACTIVE membership on the file''s business.';
COMMENT ON FUNCTION public.sweep_orphaned_raw_uploads(timestamptz) IS
'B04·P05 orphan sweep: moves PENDING rows past grant_expires_at to ORPHANED + emits FILE_UPLOAD_ORPHANED. Run hourly.';

-- ---- ACL tighten (anon + authenticated lock-down for service-role-only fns)
REVOKE EXECUTE ON FUNCTION public.confirm_raw_upload(uuid, text, bigint, text, text)   FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.sweep_orphaned_raw_uploads(timestamptz)               FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.request_raw_upload(uuid, public.upload_entity_type_enum, text, bigint, text, integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.record_raw_upload_view(uuid, public.file_audit_event_type_enum)                       FROM anon;

-- ---- FK-covering indexes (advisor INFO mitigation) -----------------------
CREATE INDEX IF NOT EXISTS idx_raw_upload_files_organization
  ON public.raw_upload_files (organization_id);
CREATE INDEX IF NOT EXISTS idx_raw_upload_files_requested_by
  ON public.raw_upload_files (requested_by);
CREATE INDEX IF NOT EXISTS idx_raw_upload_files_confirmed_by_user
  ON public.raw_upload_files (confirmed_by_user_id)
  WHERE confirmed_by_user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_file_audit_events_organization
  ON public.file_audit_events (organization_id);
CREATE INDEX IF NOT EXISTS idx_file_audit_events_actor_user
  ON public.file_audit_events (actor_user_id)
  WHERE actor_user_id IS NOT NULL;
