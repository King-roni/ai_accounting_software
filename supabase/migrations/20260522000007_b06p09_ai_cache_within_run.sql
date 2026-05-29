-- B06·P09 — AI Cache (Within Run)
--
-- Within-run cache: identical Tier 2 / Tier 3 calls inside the same workflow
-- run return the cached response without re-invoking the model. Cache key
-- includes prompt_version and policy_version so prompt updates and redaction
-- policy changes invalidate the cache automatically.
--
-- Spec: Docs/phases/06_ai_layer/09_ai_cache_within_run.md
--
-- Builds:
--   1. ai_cache table (per-run; RLS-gated reads; UNIQUE(run, key))
--   2. make_ai_cache_key()        — SHA-256 hex over canonical key tuple
--   3. ai_cache_lookup()          — atomic SELECT + increment hit_count + emit AI_CACHE_HIT
--   4. ai_cache_store()           — race-safe INSERT … ON CONFLICT DO NOTHING + emit AI_CACHE_STORED
--   5. ai_cache_prune_for_run()   — DELETE all rows for a run + emit AI_CACHE_PRUNED
--
-- Gateway wire-up (cache check between redaction step 3 and routing step 4 in
-- ai_gateway_invoke_begin) is deferred to the orchestrator wire-up phase along
-- with P05–P08.

-- ============================================================================
-- 1. ai_cache table
-- ============================================================================
CREATE TABLE public.ai_cache (
  id              uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id uuid NOT NULL,
  business_id     uuid NOT NULL REFERENCES public.business_entities(id),
  workflow_run_id uuid NOT NULL,
  cache_key       text NOT NULL,
  tool_name       text NOT NULL REFERENCES public.tool_registry(tool_name),
  prompt_id       text NULL,
  prompt_version  text NULL,
  policy_version  text NULL,
  response        jsonb NOT NULL,
  hit_count       int  NOT NULL DEFAULT 0,
  last_hit_at     timestamptz NULL,
  created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ai_cache_key_sha256_hex CHECK (cache_key ~ '^[0-9a-f]{64}$'),
  CONSTRAINT ai_cache_response_obj   CHECK (jsonb_typeof(response) = 'object'),
  CONSTRAINT ai_cache_hit_count_nonneg CHECK (hit_count >= 0),
  CONSTRAINT ai_cache_uq UNIQUE (workflow_run_id, cache_key)
);
COMMENT ON TABLE public.ai_cache IS
  'Within-run AI gateway cache. UNIQUE(workflow_run_id, cache_key) enforces per-run scope; cross-run reuse is explicitly out of MVP per Stage 1 decision. Rows are pruned with the run''s other Processing-zone artefacts via ai_cache_prune_for_run (B04·P06 TTL job).';

CREATE INDEX idx_ai_cache_business_run ON public.ai_cache (business_id, workflow_run_id);

-- Grants + RLS — service_role writes; authenticated reads only tenant rows.
REVOKE INSERT, UPDATE, DELETE ON public.ai_cache FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ai_cache TO service_role;

ALTER TABLE public.ai_cache ENABLE ROW LEVEL SECURITY;

CREATE POLICY ai_cache_select ON public.ai_cache
  FOR SELECT
  USING ((organization_id = public.current_org())
         AND (business_id = ANY (public.current_user_businesses())));

CREATE POLICY ai_cache_no_update_authenticated ON public.ai_cache
  FOR UPDATE TO authenticated USING (false);

CREATE POLICY ai_cache_no_delete_authenticated ON public.ai_cache
  FOR DELETE TO authenticated USING (false);

-- ============================================================================
-- 2. make_ai_cache_key
-- ============================================================================
CREATE OR REPLACE FUNCTION public.make_ai_cache_key(
  p_tool_name       text,
  p_prompt_id       text,
  p_prompt_version  text,
  p_policy_version  text,
  p_input           jsonb
) RETURNS text
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
DECLARE
  v_canonical text;
BEGIN
  IF p_tool_name IS NULL OR p_input IS NULL THEN
    RAISE EXCEPTION 'make_ai_cache_key: p_tool_name and p_input required' USING ERRCODE='22000';
  END IF;
  -- Field separator: ASCII unit separator (\x1f). Cannot appear inside
  -- canonical JSON output so collisions across fields are impossible.
  v_canonical := p_tool_name || E'\x1f'
              || COALESCE(p_prompt_id, '')      || E'\x1f'
              || COALESCE(p_prompt_version, '') || E'\x1f'
              || COALESCE(p_policy_version, '') || E'\x1f'
              || audit.canonical_jsonb(p_input);
  RETURN encode(digest(v_canonical, 'sha256'), 'hex');
END;
$function$;
COMMENT ON FUNCTION public.make_ai_cache_key(text, text, text, text, jsonb) IS
  'SHA-256 hex over <tool_name>\x1f<prompt_id>\x1f<prompt_version>\x1f<policy_version>\x1f<canonical_jsonb(input)>. Including prompt_version means a prompt update invalidates the cache; including policy_version means a redaction-policy change invalidates the cache.';

REVOKE EXECUTE ON FUNCTION public.make_ai_cache_key(text, text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.make_ai_cache_key(text, text, text, text, jsonb) TO service_role;

-- ============================================================================
-- 3. ai_cache_lookup
-- ============================================================================
CREATE OR REPLACE FUNCTION public.ai_cache_lookup(
  p_workflow_run_id uuid,
  p_business_id     uuid,
  p_organization_id uuid,
  p_cache_key       text,
  p_actor_user_id   uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_row     public.ai_cache%ROWTYPE;
  v_kind    audit.actor_kind_enum;
  v_system  text;
  v_audit   audit.audit_events;
BEGIN
  IF p_workflow_run_id IS NULL OR p_business_id IS NULL OR p_organization_id IS NULL
     OR p_cache_key IS NULL THEN
    RAISE EXCEPTION 'ai_cache_lookup: required params missing' USING ERRCODE='22000';
  END IF;

  -- FOR UPDATE so the increment is atomic with the read.
  SELECT * INTO v_row FROM public.ai_cache
    WHERE workflow_run_id = p_workflow_run_id
      AND cache_key = p_cache_key
    FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'hit', false);
  END IF;

  UPDATE public.ai_cache
    SET hit_count   = hit_count + 1,
        last_hit_at = clock_timestamp()
    WHERE id = v_row.id
    RETURNING * INTO v_row;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum;
    v_system := 'ai_cache';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum;
    v_system := NULL;
  END IF;

  v_audit := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'AI_CACHE_HIT',
    p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id => p_workflow_run_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => p_organization_id, p_business_id => p_business_id,
    p_reason => format('AI cache hit on run %s (cache_id %s, hit_count %s)',
                        p_workflow_run_id, v_row.id, v_row.hit_count),
    p_after_state => jsonb_build_object(
      'cache_id', v_row.id, 'workflow_run_id', p_workflow_run_id,
      'cache_key', v_row.cache_key, 'tool_name', v_row.tool_name,
      'prompt_id', v_row.prompt_id, 'prompt_version', v_row.prompt_version,
      'policy_version', v_row.policy_version,
      'hit_count', v_row.hit_count));

  RETURN jsonb_build_object('ok', true, 'hit', true,
    'cache_id', v_row.id, 'response', v_row.response,
    'tool_name', v_row.tool_name,
    'prompt_id', v_row.prompt_id, 'prompt_version', v_row.prompt_version,
    'policy_version', v_row.policy_version,
    'hit_count', v_row.hit_count,
    'audit_event_id', v_audit.id);
END;
$function$;
COMMENT ON FUNCTION public.ai_cache_lookup(uuid, uuid, uuid, text, uuid) IS
  'Atomic SELECT FOR UPDATE + increment hit_count + emit AI_CACHE_HIT on hit. Returns {hit: false} on miss (no audit).';

REVOKE EXECUTE ON FUNCTION public.ai_cache_lookup(uuid, uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ai_cache_lookup(uuid, uuid, uuid, text, uuid) TO service_role;

-- ============================================================================
-- 4. ai_cache_store
-- ============================================================================
CREATE OR REPLACE FUNCTION public.ai_cache_store(
  p_workflow_run_id uuid,
  p_business_id     uuid,
  p_organization_id uuid,
  p_cache_key       text,
  p_tool_name       text,
  p_response        jsonb,
  p_prompt_id       text DEFAULT NULL,
  p_prompt_version  text DEFAULT NULL,
  p_policy_version  text DEFAULT NULL,
  p_actor_user_id   uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_id     uuid;
  v_kind   audit.actor_kind_enum;
  v_system text;
  v_audit  audit.audit_events;
BEGIN
  IF p_workflow_run_id IS NULL OR p_business_id IS NULL OR p_organization_id IS NULL
     OR p_cache_key IS NULL OR p_tool_name IS NULL OR p_response IS NULL THEN
    RAISE EXCEPTION 'ai_cache_store: required params missing' USING ERRCODE='22000';
  END IF;
  IF jsonb_typeof(p_response) <> 'object' THEN
    RAISE EXCEPTION 'ai_cache_store: p_response must be a JSON object' USING ERRCODE='22023';
  END IF;

  INSERT INTO public.ai_cache (
    organization_id, business_id, workflow_run_id, cache_key,
    tool_name, prompt_id, prompt_version, policy_version, response
  ) VALUES (
    p_organization_id, p_business_id, p_workflow_run_id, p_cache_key,
    p_tool_name, p_prompt_id, p_prompt_version, p_policy_version, p_response
  )
  ON CONFLICT (workflow_run_id, cache_key) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    -- Race-safe no-op: another tx already stored this key for this run.
    RETURN jsonb_build_object('ok', true, 'stored', false, 'reason', 'ALREADY_CACHED');
  END IF;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'ai_cache';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;

  v_audit := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'AI_CACHE_STORED',
    p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id => p_workflow_run_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => p_organization_id, p_business_id => p_business_id,
    p_reason => format('AI cache stored on run %s (cache_id %s, tool %s)',
                        p_workflow_run_id, v_id, p_tool_name),
    p_after_state => jsonb_build_object(
      'cache_id', v_id, 'workflow_run_id', p_workflow_run_id,
      'cache_key', p_cache_key, 'tool_name', p_tool_name,
      'prompt_id', p_prompt_id, 'prompt_version', p_prompt_version,
      'policy_version', p_policy_version));

  RETURN jsonb_build_object('ok', true, 'stored', true,
    'cache_id', v_id, 'audit_event_id', v_audit.id);
END;
$function$;
COMMENT ON FUNCTION public.ai_cache_store(uuid, uuid, uuid, text, text, jsonb, text, text, text, uuid) IS
  'Race-safe cache write. INSERT … ON CONFLICT DO NOTHING means a duplicate store is a no-op (no audit). Caller (the gateway) is responsible for only calling this on AIResult.SUCCESS — the function stores whatever shape it''s given; the SUCCESS guard belongs upstream.';

REVOKE EXECUTE ON FUNCTION public.ai_cache_store(uuid, uuid, uuid, text, text, jsonb, text, text, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ai_cache_store(uuid, uuid, uuid, text, text, jsonb, text, text, text, uuid) TO service_role;

-- ============================================================================
-- 5. ai_cache_prune_for_run
-- ============================================================================
CREATE OR REPLACE FUNCTION public.ai_cache_prune_for_run(
  p_workflow_run_id uuid,
  p_reason          text,
  p_actor_user_id   uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_pruned  int;
  v_biz_id  uuid;
  v_org_id  uuid;
  v_kind    audit.actor_kind_enum;
  v_system  text;
  v_audit   audit.audit_events;
BEGIN
  IF p_workflow_run_id IS NULL THEN
    RAISE EXCEPTION 'ai_cache_prune_for_run: p_workflow_run_id required' USING ERRCODE='22000';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'ai_cache_prune_for_run: p_reason non-empty required' USING ERRCODE='22000';
  END IF;

  -- Grab business + org from the first matching row (all rows for a run share
  -- the same tenant by definition).
  SELECT business_id, organization_id INTO v_biz_id, v_org_id
    FROM public.ai_cache WHERE workflow_run_id = p_workflow_run_id LIMIT 1;

  DELETE FROM public.ai_cache WHERE workflow_run_id = p_workflow_run_id;
  GET DIAGNOSTICS v_pruned = ROW_COUNT;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'ai_cache_pruner';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;

  v_audit := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'AI_CACHE_PRUNED',
    p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id => p_workflow_run_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_org_id, p_business_id => v_biz_id,
    p_reason => format('AI cache pruned for run %s: %s', p_workflow_run_id, p_reason),
    p_after_state => jsonb_build_object(
      'workflow_run_id', p_workflow_run_id,
      'pruned_count', v_pruned,
      'reason', p_reason));

  RETURN jsonb_build_object('ok', true,
    'workflow_run_id', p_workflow_run_id,
    'pruned_count', v_pruned,
    'audit_event_id', v_audit.id);
END;
$function$;
COMMENT ON FUNCTION public.ai_cache_prune_for_run(uuid, text, uuid) IS
  'Deletes all ai_cache rows for the run + emits AI_CACHE_PRUNED. Called by B04·P06''s TTL job on FINALIZED runs (or by operator on demand). p_reason is required (audit trail).';

REVOKE EXECUTE ON FUNCTION public.ai_cache_prune_for_run(uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ai_cache_prune_for_run(uuid, text, uuid) TO service_role;
