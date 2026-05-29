-- B09·P02 — Document Lifecycle State Machine
-- One chokepoint, declarative transition table, audit-coupled emission.
-- Direct UPDATEs to documents.extraction_status are forbidden in production
-- code paths; column-level REVOKE enforces this for ordinary roles.
--
-- Audit family: DOCUMENT_STATE_CHANGED, DOCUMENT_STATE_CHANGE_REJECTED,
-- DOCUMENT_STUB_CREATED.

-- 1. Transition registry -----------------------------------------------------

CREATE TABLE IF NOT EXISTS public.document_state_transitions (
  from_state    public.document_extraction_status_enum NOT NULL,
  to_state      public.document_extraction_status_enum NOT NULL,
  is_stub_only  boolean NOT NULL DEFAULT false,
  notes         text,
  CONSTRAINT dst_no_self CHECK (from_state <> to_state),
  PRIMARY KEY (from_state, to_state)
);

INSERT INTO public.document_state_transitions (from_state, to_state, is_stub_only, notes) VALUES
  ('DISCOVERED',       'INGESTED',         false, 'file fetched from source, hashed, persisted to Raw Upload'),
  ('INGESTED',         'EXTRACTED',        false, 'at least one extraction layer produced a result'),
  ('EXTRACTED',        'LINKED_CANDIDATE', false, 'published to matching engine as candidate'),
  ('LINKED_CANDIDATE', 'MATCHED',          false, 'matching engine confirmed match'),
  ('LINKED_CANDIDATE', 'DISMISSED',        false, 'no match found, user rejected, or no longer relevant'),
  ('MATCHED',          'DISMISSED',        false, 'user later un-matches and rejects the document'),
  ('DISCOVERED',       'DISMISSED',        true,  'stub-only bypass: manual upload with no actual file')
ON CONFLICT (from_state, to_state) DO NOTHING;

ALTER TABLE public.document_state_transitions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS dst_select ON public.document_state_transitions;
CREATE POLICY dst_select ON public.document_state_transitions FOR SELECT USING (true);
DROP POLICY IF EXISTS dst_no_insert ON public.document_state_transitions;
CREATE POLICY dst_no_insert ON public.document_state_transitions FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS dst_no_update ON public.document_state_transitions;
CREATE POLICY dst_no_update ON public.document_state_transitions FOR UPDATE USING (false);
DROP POLICY IF EXISTS dst_no_delete ON public.document_state_transitions;
CREATE POLICY dst_no_delete ON public.document_state_transitions FOR DELETE USING (false);


-- 2. transition_document chokepoint RPC --------------------------------------

CREATE OR REPLACE FUNCTION public.transition_document(
  p_document_id  uuid,
  p_target_state public.document_extraction_status_enum,
  p_reason       text DEFAULT NULL,
  p_context      jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_from_state      public.document_extraction_status_enum;
  v_document_type   public.document_type_enum;
  v_organization_id uuid;
  v_business_id     uuid;
  v_is_stub_only    boolean;
  v_registry_hit    boolean;
BEGIN
  SELECT extraction_status, document_type, organization_id, business_id
    INTO v_from_state, v_document_type, v_organization_id, v_business_id
  FROM public.documents
  WHERE id = p_document_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'decision',     'REJECTED',
      'reason',       'DOCUMENT_NOT_FOUND',
      'document_id',  p_document_id,
      'attempted_to', p_target_state
    );
  END IF;

  IF v_from_state = p_target_state THEN
    RETURN jsonb_build_object(
      'decision',    'NOOP',
      'document_id', p_document_id,
      'from_state',  v_from_state,
      'to_state',    p_target_state
    );
  END IF;

  SELECT is_stub_only INTO v_is_stub_only
  FROM public.document_state_transitions
  WHERE from_state = v_from_state AND to_state = p_target_state;
  v_registry_hit := FOUND;

  IF NOT v_registry_hit THEN
    PERFORM audit.emit_audit(
      p_actor_kind       := 'SYSTEM'::audit.actor_kind_enum,
      p_action           := 'DOCUMENT_STATE_CHANGE_REJECTED',
      p_subject_type     := 'DOCUMENT'::audit.subject_type_enum,
      p_subject_id       := p_document_id,
      p_actor_user_id    := NULL,
      p_actor_role       := NULL,
      p_actor_session_id := NULL,
      p_actor_system     := 'document_lifecycle',
      p_organization_id  := v_organization_id,
      p_business_id      := v_business_id,
      p_before_state     := jsonb_build_object('extraction_status', v_from_state),
      p_after_state      := jsonb_build_object(
        'attempted_to', p_target_state,
        'rejection',    'ILLEGAL_TRANSITION'
      ),
      p_reason           := p_reason,
      p_request_context  := p_context
    );
    RETURN jsonb_build_object(
      'decision',     'REJECTED',
      'reason',       'ILLEGAL_TRANSITION',
      'document_id',  p_document_id,
      'from_state',   v_from_state,
      'attempted_to', p_target_state
    );
  END IF;

  IF v_is_stub_only AND v_document_type <> 'STUB' THEN
    PERFORM audit.emit_audit(
      p_actor_kind       := 'SYSTEM'::audit.actor_kind_enum,
      p_action           := 'DOCUMENT_STATE_CHANGE_REJECTED',
      p_subject_type     := 'DOCUMENT'::audit.subject_type_enum,
      p_subject_id       := p_document_id,
      p_actor_user_id    := NULL,
      p_actor_role       := NULL,
      p_actor_session_id := NULL,
      p_actor_system     := 'document_lifecycle',
      p_organization_id  := v_organization_id,
      p_business_id      := v_business_id,
      p_before_state     := jsonb_build_object(
        'extraction_status', v_from_state,
        'document_type',     v_document_type
      ),
      p_after_state      := jsonb_build_object(
        'attempted_to', p_target_state,
        'rejection',    'STUB_ONLY_TRANSITION'
      ),
      p_reason           := p_reason,
      p_request_context  := p_context
    );
    RETURN jsonb_build_object(
      'decision',     'REJECTED',
      'reason',       'STUB_ONLY_TRANSITION',
      'document_id',  p_document_id,
      'from_state',   v_from_state,
      'attempted_to', p_target_state
    );
  END IF;

  UPDATE public.documents
     SET extraction_status = p_target_state,
         updated_at        = clock_timestamp()
   WHERE id = p_document_id;

  PERFORM audit.emit_audit(
    p_actor_kind       := 'SYSTEM'::audit.actor_kind_enum,
    p_action           := 'DOCUMENT_STATE_CHANGED',
    p_subject_type     := 'DOCUMENT'::audit.subject_type_enum,
    p_subject_id       := p_document_id,
    p_actor_user_id    := NULL,
    p_actor_role       := NULL,
    p_actor_session_id := NULL,
    p_actor_system     := 'document_lifecycle',
    p_organization_id  := v_organization_id,
    p_business_id      := v_business_id,
    p_before_state     := jsonb_build_object('extraction_status', v_from_state),
    p_after_state      := jsonb_build_object('extraction_status', p_target_state),
    p_reason           := p_reason,
    p_request_context  := p_context
  );

  RETURN jsonb_build_object(
    'decision',    'APPLIED',
    'document_id', p_document_id,
    'from_state',  v_from_state,
    'to_state',    p_target_state
  );
END;
$$;


-- 3. create_document_stub RPC ------------------------------------------------

CREATE OR REPLACE FUNCTION public.create_document_stub(
  p_organization_id uuid,
  p_business_id     uuid,
  p_reason          text,
  p_context         jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_document_id      uuid;
  v_dismiss_envelope jsonb;
BEGIN
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'STUB_REASON_REQUIRED'
      USING errcode = 'check_violation';
  END IF;

  INSERT INTO public.documents (
    organization_id, business_id, source, document_type,
    extraction_status, discovery_reason
  ) VALUES (
    p_organization_id, p_business_id,
    'MANUAL'::public.document_source_enum,
    'STUB'::public.document_type_enum,
    'DISCOVERED'::public.document_extraction_status_enum,
    p_reason
  )
  RETURNING id INTO v_document_id;

  PERFORM audit.emit_audit(
    p_actor_kind       := 'SYSTEM'::audit.actor_kind_enum,
    p_action           := 'DOCUMENT_STUB_CREATED',
    p_subject_type     := 'DOCUMENT'::audit.subject_type_enum,
    p_subject_id       := v_document_id,
    p_actor_user_id    := NULL,
    p_actor_role       := NULL,
    p_actor_session_id := NULL,
    p_actor_system     := 'document_lifecycle',
    p_organization_id  := p_organization_id,
    p_business_id      := p_business_id,
    p_before_state     := NULL,
    p_after_state      := jsonb_build_object(
      'document_type',     'STUB',
      'extraction_status', 'DISCOVERED',
      'discovery_reason',  p_reason
    ),
    p_reason           := p_reason,
    p_request_context  := p_context
  );

  v_dismiss_envelope := public.transition_document(
    p_document_id  => v_document_id,
    p_target_state => 'DISMISSED'::public.document_extraction_status_enum,
    p_reason       => p_reason,
    p_context      => p_context
  );

  RETURN jsonb_build_object(
    'document_id', v_document_id,
    'state',       (v_dismiss_envelope->>'to_state'),
    'transition',  v_dismiss_envelope
  );
END;
$$;


-- 4. Privilege grants --------------------------------------------------------
-- Defense in depth: revoke column-level UPDATE on extraction_status from
-- ordinary roles; only the SECURITY DEFINER chokepoint (running as owner)
-- can mutate it.

REVOKE UPDATE (extraction_status) ON public.documents FROM PUBLIC;
REVOKE UPDATE (extraction_status) ON public.documents FROM authenticated;
REVOKE UPDATE (extraction_status) ON public.documents FROM anon;

REVOKE EXECUTE ON FUNCTION public.transition_document(uuid, public.document_extraction_status_enum, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.create_document_stub(uuid, uuid, text, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.transition_document(uuid, public.document_extraction_status_enum, text, jsonb) TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.create_document_stub(uuid, uuid, text, jsonb) TO authenticated, service_role;

GRANT SELECT ON public.document_state_transitions TO authenticated, anon;
