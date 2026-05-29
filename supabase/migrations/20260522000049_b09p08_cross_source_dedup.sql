-- B09·P08 — Cross-Source Document Deduplication.
-- Single chokepoint that runs at the DISCOVERED → INGESTED boundary, after
-- the finder/orchestrator has computed the file's content hash. Collapses
-- content-identical discoveries from multiple sources into one canonical
-- document with multiple document_source_links, and applies a cross-source
-- confidence boost capped at 0.95 the second time a hash is seen.
--
-- No new tables / enums / columns: documents.document_hash (B04·P03) +
-- documents.discovery_confidence (B09·P05) + document_source_links (B09·P01)
-- + idx_documents_business_hash already provide everything we need.
--
-- Audit family additions:
--   DOCUMENT_CROSS_SOURCE_DUPLICATE_DETECTED   (DOCUMENT subject, canonical)
--   DOCUMENT_CONFIDENCE_BOOSTED_VIA_CROSS_SOURCE (DOCUMENT subject)
--   DOCUMENT_THIRD_SOURCE_OBSERVED             (DOCUMENT subject, cap-reached)

CREATE OR REPLACE FUNCTION public.ingest_document_with_hash_check(
  p_document_id   uuid,
  p_document_hash text,
  p_context       jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id   uuid;
  v_business_id       uuid;
  v_candidate_status  public.document_extraction_status_enum;
  v_candidate_source  public.document_source_enum;
  v_candidate_dc      numeric;
  v_canonical_id      uuid;
  v_canonical_dc      numeric;
  v_canonical_source  public.document_source_enum;
  v_n_before          int;
  v_n_after           int;
  v_new_dc            numeric;
  v_transition_env    jsonb;
  v_emit_boost        boolean := false;
  v_emit_third        boolean := false;
BEGIN
  IF p_document_hash IS NULL OR p_document_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'DOCUMENT_HASH_INVALID_FORMAT' USING errcode='check_violation';
  END IF;

  SELECT organization_id, business_id, extraction_status, source, discovery_confidence
    INTO v_organization_id, v_business_id, v_candidate_status, v_candidate_source, v_candidate_dc
  FROM public.documents
  WHERE id = p_document_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'decision','REJECTED','reason','DOCUMENT_NOT_FOUND','document_id',p_document_id
    );
  END IF;

  IF v_candidate_status <> 'DISCOVERED' THEN
    RETURN jsonb_build_object(
      'decision','REJECTED','reason','DOCUMENT_NOT_DISCOVERED',
      'document_id',p_document_id,'current_status',v_candidate_status
    );
  END IF;

  -- Look for a canonical doc in the same business with the same hash.
  -- Pick the oldest (smallest id since gen_uuid_v7 is time-sortable).
  SELECT id, discovery_confidence, source
    INTO v_canonical_id, v_canonical_dc, v_canonical_source
  FROM public.documents
  WHERE business_id = v_business_id
    AND document_hash = p_document_hash
    AND id <> p_document_id
  ORDER BY id ASC
  LIMIT 1;

  IF NOT FOUND THEN
    -- INGEST path: set hash, transition DISCOVERED → INGESTED
    UPDATE public.documents
      SET document_hash = p_document_hash,
          updated_at    = clock_timestamp()
    WHERE id = p_document_id;

    v_transition_env := public.transition_document(
      p_document_id  => p_document_id,
      p_target_state => 'INGESTED'::public.document_extraction_status_enum,
      p_reason       => 'cross_source_dedup_no_match',
      p_context      => jsonb_build_object('document_hash', p_document_hash)
                        || COALESCE(p_context,'{}'::jsonb)
    );

    RETURN jsonb_build_object(
      'decision','INGESTED','document_id',p_document_id,
      'document_hash',p_document_hash,'transition',v_transition_env,
      'is_new',true
    );
  END IF;

  -- ABSORB path: canonical exists; collapse this candidate into it.
  -- Lock canonical for the re-parent + boost write.
  PERFORM 1 FROM public.documents WHERE id = v_canonical_id FOR UPDATE;

  SELECT count(*) INTO v_n_before
    FROM public.document_source_links WHERE document_id = v_canonical_id;

  -- Re-parent dsl rows from the candidate to the canonical.
  -- The dsl table has UNIQUE(business_id, source_kind, source_external_id);
  -- if the candidate's dsl would collide with an already-present canonical
  -- dsl, we let the canonical row stay and drop the candidate's.
  UPDATE public.document_source_links
    SET document_id = v_canonical_id
  WHERE document_id = p_document_id
    AND NOT EXISTS (
      SELECT 1 FROM public.document_source_links existing
      WHERE existing.business_id = v_business_id
        AND existing.source_kind = document_source_links.source_kind
        AND existing.source_external_id = document_source_links.source_external_id
        AND existing.document_id = v_canonical_id
    );
  -- Any candidate dsl rows that would have collided with canonical's existing
  -- dsl get cleaned up here (we keep canonical's authoritative row):
  DELETE FROM public.document_source_links
   WHERE document_id = p_document_id;

  SELECT count(*) INTO v_n_after
    FROM public.document_source_links WHERE document_id = v_canonical_id;

  -- Confidence boost: only on the transition from 1 → 2 sources
  IF v_n_before = 1 THEN
    v_new_dc := LEAST(0.95::numeric,
                      GREATEST(COALESCE(v_canonical_dc, 0), COALESCE(v_candidate_dc, 0))
                      + 0.10::numeric);
    UPDATE public.documents
      SET discovery_confidence = v_new_dc,
          updated_at           = clock_timestamp()
    WHERE id = v_canonical_id;
    v_emit_boost := true;
  ELSIF v_n_before >= 2 THEN
    v_emit_third := true;
    v_new_dc := v_canonical_dc; -- unchanged
  ELSE
    v_new_dc := v_canonical_dc;
  END IF;

  -- Delete the absorbed candidate. At this lifecycle boundary it has no
  -- downstream dependencies (no extraction_results yet, no review_issues,
  -- and we just moved its dsl rows). Audit events that mention it remain
  -- in the immutable log as dangling subject_ids — intentional.
  DELETE FROM public.documents WHERE id = p_document_id;

  -- Always emit the duplicate-detected event.
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='DOCUMENT_CROSS_SOURCE_DUPLICATE_DETECTED',
    p_subject_type:='DOCUMENT'::audit.subject_type_enum,
    p_subject_id:=v_canonical_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='cross_source_dedup',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=jsonb_build_object('sources_count', v_n_before),
    p_after_state:=jsonb_build_object(
      'canonical_document_id', v_canonical_id,
      'absorbed_document_id',  p_document_id,
      'document_hash',         p_document_hash,
      'canonical_source',      v_canonical_source,
      'candidate_source',      v_candidate_source,
      'sources_count_after',   v_n_after
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  IF v_emit_boost THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='DOCUMENT_CONFIDENCE_BOOSTED_VIA_CROSS_SOURCE',
      p_subject_type:='DOCUMENT'::audit.subject_type_enum,
      p_subject_id:=v_canonical_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='cross_source_dedup',
      p_organization_id:=v_organization_id, p_business_id:=v_business_id,
      p_before_state:=jsonb_build_object('discovery_confidence', v_canonical_dc),
      p_after_state:=jsonb_build_object(
        'discovery_confidence', v_new_dc,
        'sources_count',        v_n_after,
        'boost_applied',        0.10
      ),
      p_reason:=NULL, p_request_context:=p_context
    );
  END IF;

  IF v_emit_third THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='DOCUMENT_THIRD_SOURCE_OBSERVED',
      p_subject_type:='DOCUMENT'::audit.subject_type_enum,
      p_subject_id:=v_canonical_id,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='cross_source_dedup',
      p_organization_id:=v_organization_id, p_business_id:=v_business_id,
      p_before_state:=jsonb_build_object('sources_count', v_n_before),
      p_after_state:=jsonb_build_object(
        'sources_count',         v_n_after,
        'discovery_confidence',  v_new_dc,
        'note',                  'cap reached at 2 sources; no further boost'
      ),
      p_reason:=NULL, p_request_context:=p_context
    );
  END IF;

  RETURN jsonb_build_object(
    'decision','ABSORBED',
    'canonical_document_id', v_canonical_id,
    'absorbed_document_id',  p_document_id,
    'sources_count',         v_n_after,
    'discovery_confidence',  v_new_dc,
    'boost_applied',         v_emit_boost,
    'third_source_observed', v_emit_third
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.ingest_document_with_hash_check(uuid, text, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.ingest_document_with_hash_check(uuid, text, jsonb) TO authenticated, service_role;
