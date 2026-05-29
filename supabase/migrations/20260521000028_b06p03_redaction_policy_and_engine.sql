-- B06·P03 — Redaction Policy & Engine (migration 2 of 2)
--
-- Wires the redaction step into the AI gateway pipeline. Allowlist-based:
-- tool input_schema annotates each property with x_redaction_field_kind;
-- redaction_policies maps (policy_version, tier, field_kind) → default_action.
-- The active policy version is held in a singleton row that the gateway reads
-- on every call.
--
-- Spec: Docs/phases/06_ai_layer/03_redaction_policy_and_engine.md
--
-- Builds:
--   1. redaction_field_kind_enum + redaction_action_enum
--   2. redaction_policies table + singleton redaction_active_policy
--   3. Seed: policy version 'v1' for Tier 2 + Tier 3
--   4. current_redaction_policy_version()
--   5. apply_redaction() — the engine
--   6. ai_gateway_invocations.redaction_policy_version column
--   7. ai_gateway_invoke_begin — rewired to call apply_redaction() between
--      minimization and routing
--   8. activate_redaction_policy() — Owner-only policy version pointer flip
--
-- Migration 1 (20260521000027) added the three ALTER TYPE enum values used
-- by this file.

-- ============================================================================
-- 1. Enums
-- ============================================================================
CREATE TYPE public.redaction_field_kind_enum AS ENUM (
  'IBAN',
  'ACCOUNT_NUMBER',
  'VAT_NUMBER',
  'COUNTERPARTY_IDENTIFIER',
  'PERSONAL_ADDRESS',
  'EMAIL_BODY',
  'FREE_TEXT_DESCRIPTION',
  'NAME'
);
COMMENT ON TYPE public.redaction_field_kind_enum IS
  'Sensitivity classification declared on input_schema properties via the x_redaction_field_kind extension keyword. Used by apply_redaction to look up policy actions in redaction_policies.';

CREATE TYPE public.redaction_action_enum AS ENUM (
  'DROP',
  'MASK_LAST_N',
  'MASK_FIXED',
  'KEEP_IF_DECLARED'
);
COMMENT ON TYPE public.redaction_action_enum IS
  'Per-tier default action for a given field_kind. MASK_LAST_N uses keys.mask_field for IBAN/ACCOUNT_NUMBER/VAT_NUMBER and inline mask for COUNTERPARTY_IDENTIFIER. MASK_FIXED returns ''***''. KEEP_IF_DECLARED preserves the value (and runs PII scan if the kind is FREE_TEXT_DESCRIPTION).';

-- ============================================================================
-- 2. Tables
-- ============================================================================
CREATE TABLE public.redaction_policies (
  id                 uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  policy_version     text NOT NULL,
  tier               public.ai_tier_enum NOT NULL,
  field_kind         public.redaction_field_kind_enum NOT NULL,
  default_action     public.redaction_action_enum NOT NULL,
  action_param       int NULL,
  notes              text NULL,
  created_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_by_user_id uuid NULL REFERENCES public.users(id),
  CONSTRAINT redaction_policies_no_tier_none CHECK (tier <> 'NONE'::public.ai_tier_enum),
  CONSTRAINT redaction_policies_mask_last_n_has_param
    CHECK ((default_action = 'MASK_LAST_N'::public.redaction_action_enum AND action_param IS NOT NULL AND action_param > 0)
           OR (default_action <> 'MASK_LAST_N'::public.redaction_action_enum)),
  CONSTRAINT redaction_policies_uq UNIQUE (policy_version, tier, field_kind)
);
COMMENT ON TABLE public.redaction_policies IS
  'Per-tier, per-field-kind default actions, grouped by policy_version. Adding a new policy means inserting a new (policy_version, tier, field_kind) set of rows via migration; activation flips the pointer in redaction_active_policy.';

REVOKE ALL ON public.redaction_policies FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.redaction_policies TO service_role;

CREATE TABLE public.redaction_active_policy (
  id                    int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  active_policy_version text NOT NULL,
  activated_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  activated_by_user_id  uuid NULL REFERENCES public.users(id),
  is_rollback           boolean NOT NULL DEFAULT false
);
COMMENT ON TABLE public.redaction_active_policy IS
  'Singleton table (CHECK id=1) holding the currently-active redaction policy version. Flipped via activate_redaction_policy(); read on every gateway invocation by current_redaction_policy_version().';

REVOKE ALL ON public.redaction_active_policy FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.redaction_active_policy TO service_role;

-- ============================================================================
-- 3. Seed: policy version v1
-- ============================================================================
INSERT INTO public.redaction_policies (policy_version, tier, field_kind, default_action, action_param, notes)
VALUES
  -- Tier 3 (EXTERNAL_LLM) — strict per spec §Default Tier 3 policy
  ('v1','EXTERNAL_LLM','IBAN',                   'MASK_LAST_N',       4,    'spec §Default Tier 3 — MASK_LAST_N(4) via keys.mask_field'),
  ('v1','EXTERNAL_LLM','ACCOUNT_NUMBER',         'MASK_LAST_N',       4,    'spec §Default Tier 3 — MASK_LAST_N(4) via keys.mask_field'),
  ('v1','EXTERNAL_LLM','COUNTERPARTY_IDENTIFIER','MASK_LAST_N',       4,    'spec §Default Tier 3 — inline mask (not in keys.field_kind_enum)'),
  ('v1','EXTERNAL_LLM','VAT_NUMBER',             'KEEP_IF_DECLARED',  NULL, 'public business identifier; spec silent — kept'),
  ('v1','EXTERNAL_LLM','PERSONAL_ADDRESS',       'DROP',              NULL, 'spec §Default Tier 3 — DROP unless explicitly declared'),
  ('v1','EXTERNAL_LLM','EMAIL_BODY',             'DROP',              NULL, 'spec §Default Tier 3 — DROP; only structured extracted fields pass'),
  ('v1','EXTERNAL_LLM','FREE_TEXT_DESCRIPTION',  'KEEP_IF_DECLARED',  NULL, 'spec §Default Tier 3 — KEEP_IF_DECLARED + PII pattern scan'),
  ('v1','EXTERNAL_LLM','NAME',                   'KEEP_IF_DECLARED',  NULL, 'spec §Default Tier 3 — no default redaction; GDPR pseudonymization elsewhere'),
  -- Tier 2 (LOCAL_LLM) — less restrictive per spec §Default Tier 2 policy
  ('v1','LOCAL_LLM','IBAN',                      'KEEP_IF_DECLARED',  NULL, 'spec §Default Tier 2 — KEEP_IF_DECLARED'),
  ('v1','LOCAL_LLM','ACCOUNT_NUMBER',            'KEEP_IF_DECLARED',  NULL, 'spec §Default Tier 2 — KEEP_IF_DECLARED'),
  ('v1','LOCAL_LLM','COUNTERPARTY_IDENTIFIER',   'KEEP_IF_DECLARED',  NULL, 'spec §Default Tier 2 — KEEP_IF_DECLARED'),
  ('v1','LOCAL_LLM','VAT_NUMBER',                'KEEP_IF_DECLARED',  NULL, 'public business identifier'),
  ('v1','LOCAL_LLM','PERSONAL_ADDRESS',          'KEEP_IF_DECLARED',  NULL, 'spec §Default Tier 2 — KEEP_IF_DECLARED'),
  ('v1','LOCAL_LLM','EMAIL_BODY',                'KEEP_IF_DECLARED',  NULL, 'spec §Default Tier 2 — KEEP_IF_DECLARED'),
  ('v1','LOCAL_LLM','FREE_TEXT_DESCRIPTION',     'KEEP_IF_DECLARED',  NULL, 'spec §Default Tier 2 — KEEP_IF_DECLARED + PII scan'),
  ('v1','LOCAL_LLM','NAME',                      'KEEP_IF_DECLARED',  NULL, 'no default redaction');

INSERT INTO public.redaction_active_policy (id, active_policy_version)
VALUES (1, 'v1');

-- ============================================================================
-- 4. current_redaction_policy_version
-- ============================================================================
CREATE OR REPLACE FUNCTION public.current_redaction_policy_version()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT active_policy_version FROM public.redaction_active_policy WHERE id = 1;
$$;
COMMENT ON FUNCTION public.current_redaction_policy_version() IS
  'Returns the currently active redaction policy version from the singleton redaction_active_policy row.';

REVOKE EXECUTE ON FUNCTION public.current_redaction_policy_version() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.current_redaction_policy_version() TO service_role;

-- ============================================================================
-- 5. apply_redaction
-- ============================================================================
CREATE OR REPLACE FUNCTION public.apply_redaction(
  p_tier           public.ai_tier_enum,
  p_payload        jsonb,
  p_input_schema   jsonb,
  p_policy_version text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_props        jsonb;
  v_out          jsonb := '{}'::jsonb;
  v_key          text;
  v_val          jsonb;
  v_val_text     text;
  v_field_kind   text;
  v_policy_row   public.redaction_policies%ROWTYPE;
  v_drops        jsonb := '{}'::jsonb;
  v_masks        jsonb := '{}'::jsonb;
  v_drop_count   int := 0;
  v_mask_count   int := 0;
  v_kept_count   int := 0;
  v_pii_field    text;
  v_pii_pattern  text;
BEGIN
  IF p_tier IS NULL OR p_payload IS NULL OR p_input_schema IS NULL OR p_policy_version IS NULL THEN
    RAISE EXCEPTION 'apply_redaction: required params missing' USING ERRCODE = '22000';
  END IF;
  IF p_tier = 'NONE'::public.ai_tier_enum THEN
    RAISE EXCEPTION 'apply_redaction: tier NONE not supported (Tier 1 must not reach gateway)' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_payload) <> 'object' THEN
    RETURN jsonb_build_object('ok', true, 'redacted_payload', p_payload,
                              'drop_count', 0, 'mask_count', 0, 'kept_count', 0,
                              'drops_by_field_kind', '{}'::jsonb,
                              'masks_by_field_kind', '{}'::jsonb);
  END IF;

  v_props := p_input_schema -> 'properties';

  FOR v_key IN SELECT * FROM jsonb_object_keys(p_payload) LOOP
    v_val := p_payload -> v_key;
    v_field_kind := v_props -> v_key ->> 'x_redaction_field_kind';

    -- Declared in schema but unclassified → kept as-is. (Minimization in P02
    -- already dropped undeclared keys, so v_key is in schema.properties.)
    IF v_field_kind IS NULL THEN
      v_out := v_out || jsonb_build_object(v_key, v_val);
      v_kept_count := v_kept_count + 1;
      CONTINUE;
    END IF;

    SELECT * INTO v_policy_row
      FROM public.redaction_policies
     WHERE policy_version = p_policy_version
       AND tier           = p_tier
       AND field_kind     = v_field_kind::public.redaction_field_kind_enum;

    IF NOT FOUND THEN
      -- Fail-closed: missing policy entry → drop with warning category MISSING_POLICY
      v_drop_count := v_drop_count + 1;
      v_drops := jsonb_set(v_drops, ARRAY['MISSING_POLICY'],
                           to_jsonb(COALESCE((v_drops->>'MISSING_POLICY')::int, 0) + 1), true);
      CONTINUE;
    END IF;

    IF v_policy_row.default_action = 'DROP'::public.redaction_action_enum THEN
      v_drop_count := v_drop_count + 1;
      v_drops := jsonb_set(v_drops, ARRAY[v_field_kind],
                           to_jsonb(COALESCE((v_drops->>v_field_kind)::int, 0) + 1), true);

    ELSIF v_policy_row.default_action = 'MASK_FIXED'::public.redaction_action_enum THEN
      v_out := v_out || jsonb_build_object(v_key, '***');
      v_mask_count := v_mask_count + 1;
      v_masks := jsonb_set(v_masks, ARRAY[v_field_kind],
                           to_jsonb(COALESCE((v_masks->>v_field_kind)::int, 0) + 1), true);

    ELSIF v_policy_row.default_action = 'MASK_LAST_N'::public.redaction_action_enum THEN
      IF jsonb_typeof(v_val) = 'string' THEN
        v_val_text := v_val #>> '{}';
        IF v_field_kind IN ('IBAN','ACCOUNT_NUMBER','VAT_NUMBER') THEN
          v_out := v_out || jsonb_build_object(v_key,
                     keys.mask_field(v_val_text, v_field_kind::keys.field_kind_enum));
        ELSE
          -- COUNTERPARTY_IDENTIFIER and any other future kind: inline mask.
          v_out := v_out || jsonb_build_object(v_key,
                     CASE WHEN length(regexp_replace(v_val_text,'\s','','g'))
                                  <= COALESCE(v_policy_row.action_param, 4)
                          THEN '***'
                          ELSE '***' || right(regexp_replace(v_val_text,'\s','','g'),
                                              COALESCE(v_policy_row.action_param, 4))
                     END);
        END IF;
      ELSE
        v_out := v_out || jsonb_build_object(v_key, '***');
      END IF;
      v_mask_count := v_mask_count + 1;
      v_masks := jsonb_set(v_masks, ARRAY[v_field_kind],
                           to_jsonb(COALESCE((v_masks->>v_field_kind)::int, 0) + 1), true);

    ELSIF v_policy_row.default_action = 'KEEP_IF_DECLARED'::public.redaction_action_enum THEN
      v_out := v_out || jsonb_build_object(v_key, v_val);
      v_kept_count := v_kept_count + 1;

      -- PII pattern scan on free-text kept fields. The catalogue is
      -- intentionally pragmatic; the full catalogue lives in the sub-doc
      -- pii_pattern_catalogue.md (referenced by spec §Sub-doc Hooks).
      IF v_field_kind = 'FREE_TEXT_DESCRIPTION' AND jsonb_typeof(v_val) = 'string' THEN
        v_val_text := v_val #>> '{}';
        IF v_val_text ~ '\m[A-Z]{2}[0-9]{2}[A-Z0-9]{4,30}\M' THEN
          v_pii_field := v_key; v_pii_pattern := 'IBAN_LIKE'; EXIT;
        ELSIF v_val_text ~ '\m[0-9]{3}-[0-9]{2}-[0-9]{4}\M' THEN
          v_pii_field := v_key; v_pii_pattern := 'US_SSN'; EXIT;
        ELSIF v_val_text ~ '\m[0-9]{13,19}\M' THEN
          v_pii_field := v_key; v_pii_pattern := 'CREDIT_CARD_DIGITS'; EXIT;
        ELSIF v_val_text ~ '\m[0-9]{10,12}\M' THEN
          v_pii_field := v_key; v_pii_pattern := 'BANK_ACCOUNT_DIGITS'; EXIT;
        END IF;
      END IF;

    ELSE
      RAISE EXCEPTION 'apply_redaction: unknown action %', v_policy_row.default_action;
    END IF;
  END LOOP;

  IF v_pii_field IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok',               false,
      'reason',           'PII_IN_NON_DECLARED_FIELD',
      'offending_field',  v_pii_field,
      'matched_pattern',  v_pii_pattern
    );
  END IF;

  RETURN jsonb_build_object(
    'ok',                  true,
    'redacted_payload',    v_out,
    'drop_count',          v_drop_count,
    'mask_count',          v_mask_count,
    'kept_count',          v_kept_count,
    'drops_by_field_kind', v_drops,
    'masks_by_field_kind', v_masks
  );
END;
$function$;
COMMENT ON FUNCTION public.apply_redaction(public.ai_tier_enum, jsonb, jsonb, text) IS
  'Redaction engine. Walks top-level keys of p_payload, reads x_redaction_field_kind from input_schema.properties, looks up policy in redaction_policies, applies DROP/MASK_LAST_N/MASK_FIXED/KEEP_IF_DECLARED. Runs PII pattern scan on FREE_TEXT_DESCRIPTION kept fields; on match returns ok=false with reason=PII_IN_NON_DECLARED_FIELD. Fail-closed on missing policy entries (drops with MISSING_POLICY category). Never returns the redacted field values in error envelopes — only field-name and pattern code.';

REVOKE EXECUTE ON FUNCTION public.apply_redaction(public.ai_tier_enum, jsonb, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_redaction(public.ai_tier_enum, jsonb, jsonb, text) TO service_role;

-- ============================================================================
-- 6. ai_gateway_invocations: add redaction_policy_version column
-- ============================================================================
ALTER TABLE public.ai_gateway_invocations
  ADD COLUMN redaction_policy_version text NULL;
COMMENT ON COLUMN public.ai_gateway_invocations.redaction_policy_version IS
  'Active redaction policy version at the time of begin. Captured for P07 AI_USAGE_RECORDED and audit reconstruction. NULL only on rows inserted by pre-P03 code paths (none in this codebase) or on early-error returns before redaction runs.';

-- ============================================================================
-- 7. ai_gateway_invoke_begin — rewired to call apply_redaction
-- ============================================================================
CREATE OR REPLACE FUNCTION public.ai_gateway_invoke_begin(
  p_tool_name        text,
  p_business_id      uuid,
  p_input            jsonb,
  p_workflow_run_id  uuid DEFAULT NULL,
  p_calling_phase    text DEFAULT NULL,
  p_actor_user_id    uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_biz             public.business_entities%ROWTYPE;
  v_tool            public.tool_registry%ROWTYPE;
  v_tier_label      text;
  v_schema_chk      jsonb;
  v_minimized       jsonb;
  v_dropped_undecl  int;
  v_policy_version  text;
  v_redact          jsonb;
  v_route           jsonb;
  v_route_dec       text;
  v_invocation_id   uuid;
  v_audit_kind      audit.actor_kind_enum;
  v_actor_system    text;
  v_audit_row       audit.audit_events;
BEGIN
  IF p_tool_name IS NULL OR p_business_id IS NULL OR p_input IS NULL THEN
    RAISE EXCEPTION 'ai_gateway_invoke_begin: p_tool_name, p_business_id, p_input required'
      USING ERRCODE = '22000';
  END IF;

  SELECT * INTO v_biz FROM public.business_entities WHERE id = p_business_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'decision', 'ERROR',
      'error_code', 'BUSINESS_NOT_FOUND',
      'message', format('business %s not found', p_business_id));
  END IF;

  SELECT * INTO v_tool FROM public.tool_registry WHERE tool_name = p_tool_name;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'decision', 'ERROR',
      'error_code', 'TOOL_NOT_FOUND',
      'message', format('tool %s not registered', p_tool_name));
  END IF;

  IF v_tool.ai_tier = 'NONE'::public.ai_tier_enum THEN
    RETURN jsonb_build_object('ok', false, 'decision', 'ERROR',
      'error_code', 'TIER_1_BYPASS_REQUIRED',
      'message', format('tool %s is Tier 1 (no AI); must not reach gateway', p_tool_name));
  END IF;

  v_tier_label     := public.ai_tier_canonical_label(v_tool.ai_tier);
  v_policy_version := public.current_redaction_policy_version();

  IF p_actor_user_id IS NULL THEN
    v_audit_kind := 'SYSTEM'::audit.actor_kind_enum;
    v_actor_system := 'ai_gateway';
  ELSE
    v_audit_kind := 'USER'::audit.actor_kind_enum;
    v_actor_system := NULL;
  END IF;

  -- Step 1: input schema validation
  v_schema_chk := public._jsonb_matches_schema(p_input, v_tool.input_schema);
  IF NOT (v_schema_chk->>'valid')::boolean THEN
    INSERT INTO public.ai_gateway_invocations (
      business_id, workflow_run_id, tool_name, tier, tier_label, model_id,
      calling_phase, actor_user_id, status, result_variant,
      input_received, error_detail, finalized_at, redaction_policy_version
    ) VALUES (
      p_business_id, p_workflow_run_id, p_tool_name, v_tool.ai_tier, v_tier_label, NULL,
      p_calling_phase, p_actor_user_id,
      'COMPLETED_SCHEMA_VIOLATION_INPUT'::public.ai_gateway_invocation_status_enum,
      'SCHEMA_VIOLATION_INPUT'::public.ai_gateway_result_variant_enum,
      p_input, v_schema_chk->'errors', clock_timestamp(), v_policy_version
    )
    RETURNING id INTO v_invocation_id;

    v_audit_row := audit.emit_audit(
      p_actor_kind => v_audit_kind, p_action => 'AI_GATEWAY_VALIDATION_FAILED',
      p_subject_type => 'AI_GATEWAY_INVOCATION'::audit.subject_type_enum,
      p_subject_id => v_invocation_id, p_actor_user_id => p_actor_user_id,
      p_actor_system => v_actor_system, p_organization_id => v_biz.organization_id,
      p_business_id => p_business_id,
      p_reason => format('input failed schema for tool %s', p_tool_name),
      p_after_state => jsonb_build_object(
        'invocation_id', v_invocation_id, 'tool_name', p_tool_name,
        'variant', 'SCHEMA_VIOLATION_INPUT', 'errors', v_schema_chk->'errors')
    );

    RETURN jsonb_build_object('ok', false, 'invocation_id', v_invocation_id,
      'result_variant', 'SCHEMA_VIOLATION_INPUT',
      'errors', v_schema_chk->'errors', 'audit_event_id', v_audit_row.id);
  END IF;

  -- Step 2: payload minimization. Track how many keys were dropped for the
  -- AI_REDACTION_ALLOWLIST_DROP audit (spec §Allowlist enforcement warning).
  v_minimized := public.ai_gateway_minimize_payload(v_tool.input_schema, p_input);
  v_dropped_undecl := (
    SELECT count(*) FROM jsonb_object_keys(p_input) AS k
    WHERE NOT (v_minimized ? k)
  );

  IF v_dropped_undecl > 0 THEN
    PERFORM audit.emit_audit(
      p_actor_kind => v_audit_kind, p_action => 'AI_REDACTION_ALLOWLIST_DROP',
      p_subject_type => 'AI_GATEWAY_INVOCATION'::audit.subject_type_enum,
      p_subject_id => NULL,  -- invocation row not yet created at this point
      p_actor_user_id => p_actor_user_id, p_actor_system => v_actor_system,
      p_organization_id => v_biz.organization_id, p_business_id => p_business_id,
      p_reason => format('%s undeclared key(s) dropped from input for tool %s',
                          v_dropped_undecl, p_tool_name),
      p_after_state => jsonb_build_object(
        'tool_name', p_tool_name, 'dropped_count', v_dropped_undecl,
        'dropped_keys', (SELECT jsonb_agg(k) FROM jsonb_object_keys(p_input) AS k
                          WHERE NOT (v_minimized ? k))
      )
    );
  END IF;

  -- Step 3: redaction
  v_redact := public.apply_redaction(v_tool.ai_tier, v_minimized,
                                      v_tool.input_schema, v_policy_version);

  IF NOT (v_redact->>'ok')::boolean THEN
    -- PII pattern hit in a non-declared-as-PII field → reject.
    INSERT INTO public.ai_gateway_invocations (
      business_id, workflow_run_id, tool_name, tier, tier_label, model_id,
      calling_phase, actor_user_id, status, result_variant,
      input_received, minimized_input, error_detail, finalized_at,
      redaction_policy_version
    ) VALUES (
      p_business_id, p_workflow_run_id, p_tool_name, v_tool.ai_tier, v_tier_label, NULL,
      p_calling_phase, p_actor_user_id,
      'COMPLETED_REDACTION_REJECTED'::public.ai_gateway_invocation_status_enum,
      'REDACTION_REJECTED'::public.ai_gateway_result_variant_enum,
      p_input, v_minimized,
      jsonb_build_object(
        'reason',           v_redact->>'reason',
        'offending_field',  v_redact->>'offending_field',
        'matched_pattern',  v_redact->>'matched_pattern'),
      clock_timestamp(), v_policy_version
    )
    RETURNING id INTO v_invocation_id;

    -- Pair of audit events: the gateway-level rejection + the security signal
    PERFORM audit.emit_audit(
      p_actor_kind => v_audit_kind, p_action => 'AI_REDACTION_REJECTED',
      p_subject_type => 'AI_GATEWAY_INVOCATION'::audit.subject_type_enum,
      p_subject_id => v_invocation_id, p_actor_user_id => p_actor_user_id,
      p_actor_system => v_actor_system, p_organization_id => v_biz.organization_id,
      p_business_id => p_business_id,
      p_reason => format('redaction rejected for tool %s (reason=%s)',
                          p_tool_name, v_redact->>'reason'),
      p_after_state => jsonb_build_object(
        'invocation_id',  v_invocation_id,
        'tool_name',      p_tool_name,
        'reason',         v_redact->>'reason',
        'offending_field', v_redact->>'offending_field',
        'matched_pattern', v_redact->>'matched_pattern')
    );
    v_audit_row := audit.emit_audit(
      p_actor_kind => v_audit_kind, p_action => 'AI_PII_DETECTED_IN_NON_DECLARED_FIELD',
      p_subject_type => 'AI_GATEWAY_INVOCATION'::audit.subject_type_enum,
      p_subject_id => v_invocation_id, p_actor_user_id => p_actor_user_id,
      p_actor_system => v_actor_system, p_organization_id => v_biz.organization_id,
      p_business_id => p_business_id,
      p_reason => format('PII pattern %s matched in non-declared field %s of tool %s — likely caller bug',
                          v_redact->>'matched_pattern', v_redact->>'offending_field', p_tool_name),
      p_after_state => jsonb_build_object(
        'invocation_id',  v_invocation_id,
        'tool_name',      p_tool_name,
        'offending_field', v_redact->>'offending_field',
        'matched_pattern', v_redact->>'matched_pattern')
    );

    RETURN jsonb_build_object('ok', false, 'invocation_id', v_invocation_id,
      'result_variant', 'REDACTION_REJECTED',
      'reason', v_redact->>'reason',
      'offending_field', v_redact->>'offending_field',
      'matched_pattern', v_redact->>'matched_pattern',
      'audit_event_id', v_audit_row.id);
  END IF;

  v_minimized := v_redact->'redacted_payload';

  -- AI_REDACTION_APPLIED: counts only, never values. Emitted even when all
  -- counts are zero so the audit trail is uniform across every gateway call.
  PERFORM audit.emit_audit(
    p_actor_kind => v_audit_kind, p_action => 'AI_REDACTION_APPLIED',
    p_subject_type => 'AI_GATEWAY_INVOCATION'::audit.subject_type_enum,
    p_subject_id => NULL,  -- invocation row not yet created
    p_actor_user_id => p_actor_user_id, p_actor_system => v_actor_system,
    p_organization_id => v_biz.organization_id, p_business_id => p_business_id,
    p_reason => format('redaction applied for tool %s tier %s (drops=%s masks=%s kept=%s)',
                        p_tool_name, v_tier_label,
                        v_redact->>'drop_count', v_redact->>'mask_count', v_redact->>'kept_count'),
    p_after_state => jsonb_build_object(
      'tool_name',           p_tool_name,
      'tier',                v_tool.ai_tier::text,
      'policy_version',      v_policy_version,
      'drop_count',          (v_redact->>'drop_count')::int,
      'mask_count',          (v_redact->>'mask_count')::int,
      'kept_count',          (v_redact->>'kept_count')::int,
      'drops_by_field_kind', v_redact->'drops_by_field_kind',
      'masks_by_field_kind', v_redact->'masks_by_field_kind')
  );

  -- Step 4: routing
  v_route := public.route_ai_call(
    p_tool_name => p_tool_name, p_business_id => p_business_id,
    p_workflow_run_id => p_workflow_run_id, p_calling_phase => p_calling_phase,
    p_actor_user_id => p_actor_user_id);
  v_route_dec := v_route->>'decision';

  IF v_route_dec = 'BLOCK' THEN
    INSERT INTO public.ai_gateway_invocations (
      business_id, workflow_run_id, tool_name, tier, tier_label, model_id,
      calling_phase, actor_user_id, status, result_variant,
      input_received, minimized_input, error_detail, finalized_at,
      redaction_policy_version
    ) VALUES (
      p_business_id, p_workflow_run_id, p_tool_name, v_tool.ai_tier, v_tier_label, NULL,
      p_calling_phase, p_actor_user_id,
      'COMPLETED_TIER_BLOCKED'::public.ai_gateway_invocation_status_enum,
      'TIER_BLOCKED'::public.ai_gateway_result_variant_enum,
      p_input, v_minimized,
      jsonb_build_object('routing_reason', v_route->>'routing_reason',
                         'route_audit_event_id', v_route->>'audit_event_id'),
      clock_timestamp(), v_policy_version
    )
    RETURNING id INTO v_invocation_id;

    RETURN jsonb_build_object('ok', false, 'invocation_id', v_invocation_id,
      'result_variant', 'TIER_BLOCKED',
      'routing_reason', v_route->>'routing_reason',
      'audit_event_id', v_route->>'audit_event_id');
  ELSIF v_route_dec <> 'ALLOW' THEN
    RETURN jsonb_build_object('ok', false, 'decision', 'ERROR',
      'error_code', COALESCE(v_route->>'error_code', 'ROUTING_UNEXPECTED'),
      'message', format('routing returned unexpected decision: %s', v_route_dec),
      'route_envelope', v_route);
  END IF;

  -- Happy path: row inserted PREPARED, AI_GATEWAY_INVOKED emitted
  INSERT INTO public.ai_gateway_invocations (
    business_id, workflow_run_id, tool_name, tier, tier_label, model_id, prompt_version,
    calling_phase, actor_user_id, status, input_received, minimized_input,
    redaction_policy_version
  ) VALUES (
    p_business_id, p_workflow_run_id, p_tool_name, v_tool.ai_tier, v_tier_label,
    v_route->>'model_id', v_route->>'prompt_version',
    p_calling_phase, p_actor_user_id,
    'PREPARED'::public.ai_gateway_invocation_status_enum, p_input, v_minimized,
    v_policy_version
  )
  RETURNING id INTO v_invocation_id;

  v_audit_row := audit.emit_audit(
    p_actor_kind => v_audit_kind, p_action => 'AI_GATEWAY_INVOKED',
    p_subject_type => 'AI_GATEWAY_INVOCATION'::audit.subject_type_enum,
    p_subject_id => v_invocation_id, p_actor_user_id => p_actor_user_id,
    p_actor_system => v_actor_system, p_organization_id => v_biz.organization_id,
    p_business_id => p_business_id,
    p_reason => format('gateway invocation prepared for tool %s tier %s',
                        p_tool_name, v_tier_label),
    p_after_state => jsonb_build_object(
      'invocation_id', v_invocation_id, 'tool_name', p_tool_name,
      'tier', v_tool.ai_tier::text, 'tier_label', v_tier_label,
      'model_id', v_route->>'model_id', 'calling_phase', p_calling_phase,
      'workflow_run_id', p_workflow_run_id,
      'redaction_policy_version', v_policy_version)
  );

  RETURN jsonb_build_object(
    'ok',              true,
    'invocation_id',   v_invocation_id,
    'tier',            v_tool.ai_tier::text,
    'tier_label',      v_tier_label,
    'model_id',        v_route->>'model_id',
    'prompt_version',  v_route->>'prompt_version',
    'minimized_input', v_minimized,
    'redaction_policy_version', v_policy_version,
    'audit_event_id',  v_audit_row.id);
END;
$function$;
COMMENT ON FUNCTION public.ai_gateway_invoke_begin(text, uuid, jsonb, uuid, text, uuid) IS
  'AI gateway chokepoint (begin phase, B06·P03 rewire). Spec pipeline steps 1-4: validate input schema → minimize → redact (apply_redaction) → route. Emits AI_GATEWAY_INVOKED on prep, AI_GATEWAY_VALIDATION_FAILED on input schema fail, AI_REDACTION_ALLOWLIST_DROP when undeclared keys were dropped, AI_REDACTION_APPLIED with redaction counts, AI_REDACTION_REJECTED + AI_PII_DETECTED_IN_NON_DECLARED_FIELD on PII pattern hit. Records redaction_policy_version on the invocation row.';

REVOKE EXECUTE ON FUNCTION public.ai_gateway_invoke_begin(text, uuid, jsonb, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ai_gateway_invoke_begin(text, uuid, jsonb, uuid, text, uuid) TO service_role;

-- ============================================================================
-- 8. activate_redaction_policy — Owner-only pointer flip
-- ============================================================================
CREATE OR REPLACE FUNCTION public.activate_redaction_policy(
  p_actor_user_id  uuid,
  p_target_version text,
  p_is_rollback    boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_perm        jsonb;
  v_perm_dec    text;
  v_exists      boolean;
  v_prev        text;
  v_reject_code text;
  v_reject_msg  text;
  v_audit_row   audit.audit_events;
  v_action_name text;
BEGIN
  IF p_actor_user_id IS NULL OR p_target_version IS NULL THEN
    RAISE EXCEPTION 'activate_redaction_policy: required params missing'
      USING ERRCODE = '22000';
  END IF;

  v_perm := public.can_perform(
    p_actor_user_id   => p_actor_user_id,
    p_surface         => 'redaction_policy',
    p_action          => 'activate',
    p_resource        => jsonb_build_object('target_version', p_target_version),
    p_business_id     => NULL,
    p_organization_id => NULL
  );
  v_perm_dec := v_perm->>'decision';
  IF v_perm_dec = 'DENY' THEN
    v_reject_code := 'PERMISSION_DENIED';
    v_reject_msg  := format('actor lacks permission redaction_policy:activate (reason=%s)',
                             v_perm->>'reason_code');
  ELSIF v_perm_dec NOT IN ('ALLOW','STEP_UP') THEN
    v_reject_code := 'PERMISSION_DENIED';
    v_reject_msg  := format('unexpected can_perform decision: %s', v_perm_dec);
  END IF;

  IF v_reject_code IS NULL THEN
    SELECT EXISTS(SELECT 1 FROM public.redaction_policies WHERE policy_version = p_target_version)
      INTO v_exists;
    IF NOT v_exists THEN
      v_reject_code := 'POLICY_VERSION_NOT_FOUND';
      v_reject_msg  := format('redaction policy version %s has no rows', p_target_version);
    END IF;
  END IF;

  IF v_reject_code IS NOT NULL THEN
    v_audit_row := audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum,
      p_action     => 'AI_REDACTION_POLICY_ACTIVATE_REJECTED',
      p_subject_type => 'REDACTION_POLICY'::audit.subject_type_enum,
      p_subject_id => NULL, p_actor_user_id => p_actor_user_id,
      p_reason => v_reject_msg,
      p_after_state => jsonb_build_object(
        'rejection_code', v_reject_code, 'target_version', p_target_version,
        'is_rollback', p_is_rollback)
    );
    RETURN jsonb_build_object('ok', false, 'reason', v_reject_code,
      'message', v_reject_msg, 'audit_event_id', v_audit_row.id);
  END IF;

  SELECT active_policy_version INTO v_prev FROM public.redaction_active_policy WHERE id = 1;

  UPDATE public.redaction_active_policy
     SET active_policy_version = p_target_version,
         activated_at          = clock_timestamp(),
         activated_by_user_id  = p_actor_user_id,
         is_rollback           = p_is_rollback
   WHERE id = 1;

  v_action_name := CASE WHEN p_is_rollback THEN 'AI_REDACTION_POLICY_ROLLED_BACK'
                                            ELSE 'AI_REDACTION_POLICY_ACTIVATED' END;
  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum, p_action => v_action_name,
    p_subject_type => 'REDACTION_POLICY'::audit.subject_type_enum,
    p_subject_id => NULL, p_actor_user_id => p_actor_user_id,
    p_before_state => jsonb_build_object('active_policy_version', v_prev),
    p_after_state => jsonb_build_object('active_policy_version', p_target_version,
                                         'is_rollback', p_is_rollback),
    p_reason => format('redaction policy active version %s → %s (rollback=%s)',
                        v_prev, p_target_version, p_is_rollback)
  );

  RETURN jsonb_build_object('ok', true,
    'previous_version', v_prev,
    'active_policy_version', p_target_version,
    'is_rollback', p_is_rollback,
    'audit_event_id', v_audit_row.id);
END;
$function$;
COMMENT ON FUNCTION public.activate_redaction_policy(uuid, text, boolean) IS
  'Owner-only RPC to flip the singleton redaction_active_policy pointer to p_target_version. Validates the version exists (≥1 row in redaction_policies). Emits AI_REDACTION_POLICY_ACTIVATED on forward, AI_REDACTION_POLICY_ROLLED_BACK on rollback, AI_REDACTION_POLICY_ACTIVATE_REJECTED on policy failure (Mitigation A).';

REVOKE EXECUTE ON FUNCTION public.activate_redaction_policy(uuid, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.activate_redaction_policy(uuid, text, boolean) TO service_role;
