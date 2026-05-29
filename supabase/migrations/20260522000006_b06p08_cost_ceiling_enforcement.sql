-- B06·P08 — Cost Ceiling Enforcement
--
-- Soft per-run cost ceiling: warn at threshold, block at ceiling, allow
-- override after step-up. The gateway's pre-call gate calls
-- check_run_cost_ceiling before dispatch; BLOCKED returns trip the
-- caller-side transition to REVIEW_HOLD (B03·P04) and create a B14 review
-- issue (downstream consumer of AI_COST_CEILING_HIT with is_first_hit=true).
--
-- Spec: Docs/phases/06_ai_layer/08_cost_ceiling_enforcement.md
--
-- Builds:
--   1. business_ai_config extension (ceiling cols)
--   2. ai_cost_ceiling_runs table (per-run frozen state + bookkeeping)
--   3. update_business_cost_ceiling      (Owner-only config write)
--   4. ensure_run_cost_ceiling_state     (idempotent run-start snapshot)
--   5. check_run_cost_ceiling            (the pre-call gate)
--   6. request_cost_ceiling_override     (audit-only signal)
--   7. grant_cost_ceiling_override       (Owner-only, consumes step-up token)
--   8. deny_cost_ceiling_override        (Owner-only denial path)
--   9. get_run_cost_ceiling_state        (read API for review queue card)

-- ============================================================================
-- 1. business_ai_config — ceiling cols
-- ============================================================================
ALTER TABLE public.business_ai_config
  ADD COLUMN default_ceiling_per_run    numeric(14,6) NULL,
  ADD COLUMN warning_threshold_pct      numeric(5,2)  NOT NULL DEFAULT 80.00,
  ADD COLUMN ceiling_currency           text          NOT NULL DEFAULT 'EUR',
  ADD COLUMN tier_2_gating_enabled      boolean       NOT NULL DEFAULT false,
  ADD COLUMN cost_ceiling_updated_at    timestamptz   NULL,
  ADD COLUMN cost_ceiling_updated_by_user_id uuid NULL REFERENCES public.users(id),
  ADD CONSTRAINT business_ai_config_default_ceiling_positive
    CHECK (default_ceiling_per_run IS NULL OR default_ceiling_per_run > 0),
  ADD CONSTRAINT business_ai_config_warning_pct_range
    CHECK (warning_threshold_pct > 0 AND warning_threshold_pct <= 100);
COMMENT ON COLUMN public.business_ai_config.default_ceiling_per_run IS
  'Per-run soft ceiling for AI cost. NULL → no ceiling enforced (business has not opted in).';
COMMENT ON COLUMN public.business_ai_config.tier_2_gating_enabled IS
  'If true, Tier 2 (local LLM) costs count toward the per-run ceiling alongside Tier 3. If false, Tier 2 is tracked but not gated. Default false.';

-- ============================================================================
-- 2. ai_cost_ceiling_runs
-- ============================================================================
CREATE TABLE public.ai_cost_ceiling_runs (
  workflow_run_id                uuid PRIMARY KEY,
  business_id                    uuid NOT NULL REFERENCES public.business_entities(id),
  original_ceiling               numeric(14,6) NOT NULL,
  effective_ceiling              numeric(14,6) NOT NULL,
  warning_threshold_pct          numeric(5,2)  NOT NULL,
  currency                       text          NOT NULL,
  tier_2_gating_enabled          boolean       NOT NULL,
  warning_emitted_at             timestamptz NULL,
  first_ceiling_hit_at           timestamptz NULL,
  last_ceiling_hit_at            timestamptz NULL,
  override_count                 int NOT NULL DEFAULT 0,
  first_override_granted_at      timestamptz NULL,
  last_override_granted_at       timestamptz NULL,
  last_override_granted_by_user_id uuid NULL REFERENCES public.users(id),
  created_at                     timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at                     timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT ai_cost_ceiling_runs_original_positive
    CHECK (original_ceiling > 0),
  CONSTRAINT ai_cost_ceiling_runs_effective_geq_original
    CHECK (effective_ceiling >= original_ceiling),
  CONSTRAINT ai_cost_ceiling_runs_warning_pct_range
    CHECK (warning_threshold_pct > 0 AND warning_threshold_pct <= 100),
  CONSTRAINT ai_cost_ceiling_runs_override_count_nonneg
    CHECK (override_count >= 0)
);
COMMENT ON TABLE public.ai_cost_ceiling_runs IS
  'Per-run frozen ceiling state. Only inserted when business_ai_config.default_ceiling_per_run IS NOT NULL at run start (i.e., the business has opted into ceilings). Absence of a row = the gate is a no-op (returns ALLOW unconditionally).';

REVOKE ALL ON public.ai_cost_ceiling_runs FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.ai_cost_ceiling_runs TO service_role;

-- ============================================================================
-- 3. update_business_cost_ceiling
-- ============================================================================
CREATE OR REPLACE FUNCTION public.update_business_cost_ceiling(
  p_actor_user_id            uuid,
  p_business_id              uuid,
  p_default_ceiling_per_run  numeric,
  p_warning_threshold_pct    numeric DEFAULT NULL,
  p_ceiling_currency         text    DEFAULT NULL,
  p_tier_2_gating_enabled    boolean DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_biz       public.business_entities%ROWTYPE;
  v_perm      jsonb;
  v_perm_dec  text;
  v_before    public.business_ai_config%ROWTYPE;
  v_after     public.business_ai_config%ROWTYPE;
  v_reject_code text;
  v_reject_msg  text;
  v_audit_row   audit.audit_events;
BEGIN
  IF p_actor_user_id IS NULL OR p_business_id IS NULL THEN
    RAISE EXCEPTION 'update_business_cost_ceiling: required params missing' USING ERRCODE='22000';
  END IF;
  IF p_default_ceiling_per_run IS NOT NULL AND p_default_ceiling_per_run <= 0 THEN
    v_reject_code := 'CEILING_MUST_BE_POSITIVE';
    v_reject_msg  := 'default_ceiling_per_run must be > 0 (NULL to disable)';
  END IF;
  IF v_reject_code IS NULL AND p_warning_threshold_pct IS NOT NULL
     AND (p_warning_threshold_pct <= 0 OR p_warning_threshold_pct > 100) THEN
    v_reject_code := 'WARNING_PCT_OUT_OF_RANGE';
    v_reject_msg  := 'warning_threshold_pct must be in (0, 100]';
  END IF;

  IF v_reject_code IS NULL THEN
    SELECT * INTO v_biz FROM public.business_entities WHERE id = p_business_id;
    IF NOT FOUND THEN
      v_reject_code := 'BUSINESS_NOT_FOUND';
      v_reject_msg  := format('business %s not found', p_business_id);
    END IF;
  END IF;

  IF v_reject_code IS NULL THEN
    v_perm := public.can_perform(
      p_actor_user_id   => p_actor_user_id,
      p_surface         => 'business_ai_config',
      p_action          => 'update_cost_ceiling',
      p_resource        => jsonb_build_object('business_id', p_business_id),
      p_business_id     => p_business_id,
      p_organization_id => v_biz.organization_id);
    v_perm_dec := v_perm->>'decision';
    IF v_perm_dec = 'DENY' THEN
      v_reject_code := 'PERMISSION_DENIED';
      v_reject_msg  := format('actor lacks permission business_ai_config:update_cost_ceiling (reason=%s)',
                              v_perm->>'reason_code');
    ELSIF v_perm_dec NOT IN ('ALLOW','STEP_UP') THEN
      v_reject_code := 'PERMISSION_DENIED';
      v_reject_msg  := format('unexpected can_perform decision: %s', v_perm_dec);
    END IF;
  END IF;

  IF v_reject_code IS NOT NULL THEN
    v_audit_row := audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum,
      p_action     => 'AI_COST_CONFIG_UPDATE_REJECTED',
      p_subject_type => 'BUSINESS_AI_CONFIG'::audit.subject_type_enum,
      p_subject_id   => NULL,
      p_actor_user_id => p_actor_user_id, p_business_id => p_business_id,
      p_organization_id => v_biz.organization_id,
      p_reason => v_reject_msg,
      p_after_state => jsonb_build_object(
        'rejection_code', v_reject_code, 'business_id', p_business_id,
        'requested', jsonb_build_object(
          'default_ceiling_per_run', p_default_ceiling_per_run,
          'warning_threshold_pct',   p_warning_threshold_pct,
          'ceiling_currency',        p_ceiling_currency,
          'tier_2_gating_enabled',   p_tier_2_gating_enabled)));
    RETURN jsonb_build_object('ok', false, 'reason', v_reject_code,
      'message', v_reject_msg, 'audit_event_id', v_audit_row.id);
  END IF;

  SELECT * INTO v_before FROM public.business_ai_config WHERE business_id = p_business_id;

  INSERT INTO public.business_ai_config (
    business_id, default_ceiling_per_run,
    warning_threshold_pct, ceiling_currency, tier_2_gating_enabled,
    cost_ceiling_updated_at, cost_ceiling_updated_by_user_id,
    updated_by_user_id, updated_at
  ) VALUES (
    p_business_id, p_default_ceiling_per_run,
    COALESCE(p_warning_threshold_pct, 80.00),
    COALESCE(p_ceiling_currency, 'EUR'),
    COALESCE(p_tier_2_gating_enabled, false),
    clock_timestamp(), p_actor_user_id,
    p_actor_user_id, clock_timestamp()
  )
  ON CONFLICT (business_id) DO UPDATE
    SET default_ceiling_per_run      = EXCLUDED.default_ceiling_per_run,
        warning_threshold_pct        = COALESCE(EXCLUDED.warning_threshold_pct,
                                                public.business_ai_config.warning_threshold_pct),
        ceiling_currency             = COALESCE(EXCLUDED.ceiling_currency,
                                                public.business_ai_config.ceiling_currency),
        tier_2_gating_enabled        = COALESCE(EXCLUDED.tier_2_gating_enabled,
                                                public.business_ai_config.tier_2_gating_enabled),
        cost_ceiling_updated_at      = clock_timestamp(),
        cost_ceiling_updated_by_user_id = EXCLUDED.cost_ceiling_updated_by_user_id,
        updated_at                   = clock_timestamp(),
        updated_by_user_id           = EXCLUDED.updated_by_user_id
  RETURNING * INTO v_after;

  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'AI_COST_CONFIG_UPDATED',
    p_subject_type => 'BUSINESS_AI_CONFIG'::audit.subject_type_enum,
    p_subject_id => v_after.id,
    p_actor_user_id => p_actor_user_id, p_business_id => p_business_id,
    p_organization_id => v_biz.organization_id,
    p_before_state => CASE WHEN v_before.id IS NOT NULL THEN
      jsonb_build_object(
        'default_ceiling_per_run', v_before.default_ceiling_per_run,
        'warning_threshold_pct',   v_before.warning_threshold_pct,
        'ceiling_currency',        v_before.ceiling_currency,
        'tier_2_gating_enabled',   v_before.tier_2_gating_enabled)
      ELSE NULL END,
    p_after_state => jsonb_build_object(
      'business_id',              p_business_id,
      'default_ceiling_per_run',  v_after.default_ceiling_per_run,
      'warning_threshold_pct',    v_after.warning_threshold_pct,
      'ceiling_currency',         v_after.ceiling_currency,
      'tier_2_gating_enabled',    v_after.tier_2_gating_enabled),
    p_reason => format('business_ai_config cost ceiling updated for business %s',
                        p_business_id));

  RETURN jsonb_build_object('ok', true,
    'business_id', p_business_id,
    'default_ceiling_per_run', v_after.default_ceiling_per_run,
    'warning_threshold_pct',   v_after.warning_threshold_pct,
    'ceiling_currency',        v_after.ceiling_currency,
    'tier_2_gating_enabled',   v_after.tier_2_gating_enabled,
    'audit_event_id',          v_audit_row.id);
END;
$function$;
COMMENT ON FUNCTION public.update_business_cost_ceiling(uuid, uuid, numeric, numeric, text, boolean) IS
  'Owner-only RPC to update per-business cost-ceiling config. UPSERT semantics. Mitigation A on policy failure.';
REVOKE EXECUTE ON FUNCTION public.update_business_cost_ceiling(uuid, uuid, numeric, numeric, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_business_cost_ceiling(uuid, uuid, numeric, numeric, text, boolean) TO service_role;

-- ============================================================================
-- 4. ensure_run_cost_ceiling_state
-- ============================================================================
CREATE OR REPLACE FUNCTION public.ensure_run_cost_ceiling_state(
  p_workflow_run_id uuid, p_business_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_existing public.ai_cost_ceiling_runs%ROWTYPE;
  v_cfg      public.business_ai_config%ROWTYPE;
  v_new      public.ai_cost_ceiling_runs%ROWTYPE;
BEGIN
  IF p_workflow_run_id IS NULL OR p_business_id IS NULL THEN
    RAISE EXCEPTION 'ensure_run_cost_ceiling_state: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_existing FROM public.ai_cost_ceiling_runs
    WHERE workflow_run_id = p_workflow_run_id;
  IF FOUND THEN
    RETURN jsonb_build_object('ok', true, 'created', false,
      'effective_ceiling', v_existing.effective_ceiling,
      'currency', v_existing.currency);
  END IF;
  SELECT * INTO v_cfg FROM public.business_ai_config WHERE business_id = p_business_id;
  IF NOT FOUND OR v_cfg.default_ceiling_per_run IS NULL THEN
    -- Business has not opted into ceilings. No row inserted; gate will return ALLOW.
    RETURN jsonb_build_object('ok', true, 'created', false, 'no_ceiling', true);
  END IF;
  INSERT INTO public.ai_cost_ceiling_runs (
    workflow_run_id, business_id, original_ceiling, effective_ceiling,
    warning_threshold_pct, currency, tier_2_gating_enabled
  ) VALUES (
    p_workflow_run_id, p_business_id, v_cfg.default_ceiling_per_run,
    v_cfg.default_ceiling_per_run, v_cfg.warning_threshold_pct,
    v_cfg.ceiling_currency, v_cfg.tier_2_gating_enabled
  ) RETURNING * INTO v_new;
  RETURN jsonb_build_object('ok', true, 'created', true,
    'workflow_run_id', v_new.workflow_run_id,
    'effective_ceiling', v_new.effective_ceiling,
    'warning_threshold_pct', v_new.warning_threshold_pct,
    'currency', v_new.currency,
    'tier_2_gating_enabled', v_new.tier_2_gating_enabled);
END;
$function$;
COMMENT ON FUNCTION public.ensure_run_cost_ceiling_state(uuid, uuid) IS
  'Idempotent run-start snapshot. Inserts a row only when business has opted into ceilings (default_ceiling_per_run IS NOT NULL).';
REVOKE EXECUTE ON FUNCTION public.ensure_run_cost_ceiling_state(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ensure_run_cost_ceiling_state(uuid, uuid) TO service_role;

-- ============================================================================
-- 5. check_run_cost_ceiling — the pre-call gate
-- ============================================================================
CREATE OR REPLACE FUNCTION public.check_run_cost_ceiling(
  p_workflow_run_id     uuid,
  p_business_id         uuid,
  p_ai_tier             public.ai_tier_enum,
  p_projected_cost_delta numeric
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_state      public.ai_cost_ceiling_runs%ROWTYPE;
  v_biz        public.business_entities%ROWTYPE;
  v_current_spend numeric(14,6);
  v_projected_total numeric(14,6);
  v_warning_floor numeric(14,6);
  v_decision    text;
  v_audit_row   audit.audit_events;
  v_warning_emitted_now boolean := false;
  v_is_first_hit boolean := false;
  v_filter_tier_2 boolean;
BEGIN
  IF p_workflow_run_id IS NULL OR p_business_id IS NULL
     OR p_ai_tier IS NULL OR p_projected_cost_delta IS NULL THEN
    RAISE EXCEPTION 'check_run_cost_ceiling: required params missing' USING ERRCODE='22000';
  END IF;
  IF p_projected_cost_delta < 0 THEN
    RAISE EXCEPTION 'check_run_cost_ceiling: projected_cost_delta must be non-negative'
      USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_state FROM public.ai_cost_ceiling_runs
    WHERE workflow_run_id = p_workflow_run_id;
  IF NOT FOUND THEN
    -- No ceiling configured for this run → unconditional ALLOW.
    RETURN jsonb_build_object('decision', 'ALLOW', 'no_ceiling', true);
  END IF;

  -- Tracking-only path: if tier is LOCAL_LLM and gating is disabled, return ALLOW
  -- without computing spend.
  IF p_ai_tier = 'LOCAL_LLM'::public.ai_tier_enum AND NOT v_state.tier_2_gating_enabled THEN
    RETURN jsonb_build_object('decision', 'ALLOW',
      'tier_2_tracked_not_gated', true,
      'effective_ceiling', v_state.effective_ceiling,
      'currency', v_state.currency);
  END IF;

  v_filter_tier_2 := v_state.tier_2_gating_enabled;
  SELECT COALESCE(SUM(cost_estimate), 0) INTO v_current_spend
    FROM public.ai_usage_records
    WHERE workflow_run_id = p_workflow_run_id
      AND validation_outcome = 'SUCCESS'::public.ai_gateway_result_variant_enum
      AND cache_hit = false
      AND (v_filter_tier_2 = true OR ai_tier <> 'LOCAL_LLM'::public.ai_tier_enum);

  v_projected_total := v_current_spend + p_projected_cost_delta;
  v_warning_floor := v_state.effective_ceiling * v_state.warning_threshold_pct / 100;

  SELECT * INTO v_biz FROM public.business_entities WHERE id = p_business_id;

  IF v_projected_total < v_warning_floor THEN
    v_decision := 'ALLOW';
  ELSIF v_projected_total < v_state.effective_ceiling THEN
    v_decision := 'WARNING';
    IF v_state.warning_emitted_at IS NULL THEN
      UPDATE public.ai_cost_ceiling_runs
        SET warning_emitted_at = clock_timestamp(), updated_at = clock_timestamp()
        WHERE workflow_run_id = p_workflow_run_id;
      PERFORM audit.emit_audit(
        p_actor_kind => 'SYSTEM'::audit.actor_kind_enum,
        p_action => 'AI_COST_WARNING',
        p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum,
        p_subject_id => p_workflow_run_id,
        p_actor_system => 'ai_cost_ceiling',
        p_organization_id => v_biz.organization_id, p_business_id => p_business_id,
        p_reason => format('AI cost ≥ %s%% of ceiling for run %s',
                            v_state.warning_threshold_pct, p_workflow_run_id),
        p_after_state => jsonb_build_object(
          'workflow_run_id', p_workflow_run_id, 'current_spend', v_current_spend,
          'projected_total', v_projected_total,
          'warning_floor', v_warning_floor,
          'effective_ceiling', v_state.effective_ceiling,
          'currency', v_state.currency,
          'triggering_tier', p_ai_tier::text));
      v_warning_emitted_now := true;
    END IF;
  ELSE
    -- projected_total >= effective_ceiling
    IF v_state.first_override_granted_at IS NULL THEN
      v_decision := 'BLOCKED';
      v_is_first_hit := (v_state.first_ceiling_hit_at IS NULL);
    ELSE
      v_decision := 'REQUIRES_STEP_UP';
      v_is_first_hit := false;
    END IF;
    UPDATE public.ai_cost_ceiling_runs
      SET first_ceiling_hit_at = COALESCE(first_ceiling_hit_at, clock_timestamp()),
          last_ceiling_hit_at  = clock_timestamp(),
          updated_at = clock_timestamp()
      WHERE workflow_run_id = p_workflow_run_id;
    v_audit_row := audit.emit_audit(
      p_actor_kind => 'SYSTEM'::audit.actor_kind_enum,
      p_action => 'AI_COST_CEILING_HIT',
      p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum,
      p_subject_id => p_workflow_run_id,
      p_actor_system => 'ai_cost_ceiling',
      p_organization_id => v_biz.organization_id, p_business_id => p_business_id,
      p_reason => format('AI cost ceiling hit on run %s (first_hit=%s, decision=%s)',
                          p_workflow_run_id, v_is_first_hit, v_decision),
      p_after_state => jsonb_build_object(
        'workflow_run_id', p_workflow_run_id, 'is_first_hit', v_is_first_hit,
        'decision', v_decision, 'current_spend', v_current_spend,
        'projected_total', v_projected_total,
        'effective_ceiling', v_state.effective_ceiling,
        'override_count', v_state.override_count,
        'currency', v_state.currency,
        'triggering_tier', p_ai_tier::text));
  END IF;

  RETURN jsonb_build_object(
    'decision', v_decision,
    'current_spend', v_current_spend,
    'projected_total', v_projected_total,
    'effective_ceiling', v_state.effective_ceiling,
    'original_ceiling', v_state.original_ceiling,
    'warning_threshold_pct', v_state.warning_threshold_pct,
    'warning_floor', v_warning_floor,
    'currency', v_state.currency,
    'warning_emitted_now', v_warning_emitted_now,
    'is_first_hit', v_is_first_hit,
    'override_count', v_state.override_count);
END;
$function$;
COMMENT ON FUNCTION public.check_run_cost_ceiling(uuid, uuid, public.ai_tier_enum, numeric) IS
  'Pre-call gate. Sums ai_usage_records.cost_estimate for the run (SUCCESS + cache_hit=false; Tier 2 filtered out unless tier_2_gating_enabled). Returns ALLOW / WARNING / BLOCKED / REQUIRES_STEP_UP. Emits AI_COST_WARNING (deduped per run) and AI_COST_CEILING_HIT (every hit, with is_first_hit flag for downstream B14 review-issue creation).';
REVOKE EXECUTE ON FUNCTION public.check_run_cost_ceiling(uuid, uuid, public.ai_tier_enum, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.check_run_cost_ceiling(uuid, uuid, public.ai_tier_enum, numeric) TO service_role;

-- ============================================================================
-- 6. request_cost_ceiling_override
-- ============================================================================
CREATE OR REPLACE FUNCTION public.request_cost_ceiling_override(
  p_actor_user_id uuid, p_workflow_run_id uuid, p_business_id uuid, p_reason text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_biz public.business_entities%ROWTYPE; v_audit_row audit.audit_events;
BEGIN
  IF p_actor_user_id IS NULL OR p_workflow_run_id IS NULL OR p_business_id IS NULL
     OR p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'request_cost_ceiling_override: required params missing (reason non-empty)' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_biz FROM public.business_entities WHERE id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'request_cost_ceiling_override: business % not found', p_business_id
      USING ERRCODE='22023';
  END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'AI_COST_OVERRIDE_REQUESTED',
    p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id => p_workflow_run_id,
    p_actor_user_id => p_actor_user_id,
    p_organization_id => v_biz.organization_id, p_business_id => p_business_id,
    p_reason => p_reason,
    p_after_state => jsonb_build_object('workflow_run_id', p_workflow_run_id,
                                         'requested_reason', p_reason));
  RETURN jsonb_build_object('ok', true, 'audit_event_id', v_audit_row.id);
END;
$function$;
COMMENT ON FUNCTION public.request_cost_ceiling_override(uuid, uuid, uuid, text) IS
  'Audit-only signal that the user clicked "Continue past AI cost ceiling" in the review queue. No state mutation; emits AI_COST_OVERRIDE_REQUESTED. The actual grant requires step-up via grant_cost_ceiling_override.';
REVOKE EXECUTE ON FUNCTION public.request_cost_ceiling_override(uuid, uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.request_cost_ceiling_override(uuid, uuid, uuid, text) TO service_role;

-- ============================================================================
-- 7. grant_cost_ceiling_override
-- ============================================================================
CREATE OR REPLACE FUNCTION public.grant_cost_ceiling_override(
  p_actor_user_id      uuid,
  p_workflow_run_id    uuid,
  p_business_id        uuid,
  p_step_up_token_id   uuid,
  p_extended_ceiling   numeric DEFAULT NULL,
  p_reason             text    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_biz       public.business_entities%ROWTYPE;
  v_perm      jsonb;
  v_perm_dec  text;
  v_state     public.ai_cost_ceiling_runs%ROWTYPE;
  v_step_up   record;
  v_new_ceiling numeric(14,6);
  v_reject_code text;
  v_reject_msg  text;
  v_audit_row   audit.audit_events;
BEGIN
  IF p_actor_user_id IS NULL OR p_workflow_run_id IS NULL OR p_business_id IS NULL
     OR p_step_up_token_id IS NULL THEN
    RAISE EXCEPTION 'grant_cost_ceiling_override: required params missing'
      USING ERRCODE='22000';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'grant_cost_ceiling_override: reason non-empty required'
      USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_biz FROM public.business_entities WHERE id = p_business_id;
  IF NOT FOUND THEN
    v_reject_code := 'BUSINESS_NOT_FOUND';
    v_reject_msg  := format('business %s not found', p_business_id);
  END IF;

  IF v_reject_code IS NULL THEN
    v_perm := public.can_perform(
      p_actor_user_id   => p_actor_user_id,
      p_surface         => 'ai_cost_override',
      p_action          => 'grant',
      p_resource        => jsonb_build_object('workflow_run_id', p_workflow_run_id),
      p_business_id     => p_business_id,
      p_organization_id => v_biz.organization_id);
    v_perm_dec := v_perm->>'decision';
    IF v_perm_dec = 'DENY' THEN
      v_reject_code := 'PERMISSION_DENIED';
      v_reject_msg  := format('actor lacks permission ai_cost_override:grant (reason=%s)',
                              v_perm->>'reason_code');
    ELSIF v_perm_dec NOT IN ('ALLOW','STEP_UP') THEN
      v_reject_code := 'PERMISSION_DENIED';
      v_reject_msg  := format('unexpected can_perform decision: %s', v_perm_dec);
    END IF;
  END IF;

  IF v_reject_code IS NULL THEN
    SELECT * INTO v_state FROM public.ai_cost_ceiling_runs WHERE workflow_run_id = p_workflow_run_id;
    IF NOT FOUND THEN
      v_reject_code := 'NO_CEILING_FOR_RUN';
      v_reject_msg  := format('run %s has no ceiling state — nothing to override', p_workflow_run_id);
    END IF;
  END IF;

  IF v_reject_code IS NULL THEN
    SELECT * INTO v_step_up FROM public.consume_step_up_token(
      p_token_id     => p_step_up_token_id,
      p_business_id  => p_business_id,
      p_surface      => 'ai_cost_override',
      p_action_id    => NULL);
    IF NOT v_step_up.consumed THEN
      v_reject_code := 'STEP_UP_FAILED';
      v_reject_msg  := format('step-up token consumption failed: %s', v_step_up.reason);
    END IF;
  END IF;

  IF v_reject_code IS NOT NULL THEN
    v_audit_row := audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum,
      p_action => 'AI_COST_OVERRIDE_DENIED',
      p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum,
      p_subject_id => p_workflow_run_id,
      p_actor_user_id => p_actor_user_id,
      p_organization_id => v_biz.organization_id, p_business_id => p_business_id,
      p_reason => v_reject_msg,
      p_after_state => jsonb_build_object(
        'rejection_code', v_reject_code, 'workflow_run_id', p_workflow_run_id,
        'requested_extended_ceiling', p_extended_ceiling,
        'requested_reason', p_reason));
    RETURN jsonb_build_object('ok', false, 'reason', v_reject_code,
      'message', v_reject_msg, 'audit_event_id', v_audit_row.id);
  END IF;

  -- Compute new ceiling: default is current effective + original (spec: "another full ceiling's worth").
  v_new_ceiling := COALESCE(p_extended_ceiling, v_state.effective_ceiling + v_state.original_ceiling);
  IF v_new_ceiling <= v_state.effective_ceiling THEN
    v_audit_row := audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum,
      p_action => 'AI_COST_OVERRIDE_DENIED',
      p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum,
      p_subject_id => p_workflow_run_id,
      p_actor_user_id => p_actor_user_id,
      p_organization_id => v_biz.organization_id, p_business_id => p_business_id,
      p_reason => format('extended_ceiling (%s) must exceed current effective_ceiling (%s)',
                          v_new_ceiling, v_state.effective_ceiling),
      p_after_state => jsonb_build_object(
        'rejection_code', 'CEILING_NOT_INCREASED',
        'workflow_run_id', p_workflow_run_id,
        'effective_ceiling', v_state.effective_ceiling,
        'requested', v_new_ceiling));
    RETURN jsonb_build_object('ok', false, 'reason', 'CEILING_NOT_INCREASED',
      'audit_event_id', v_audit_row.id);
  END IF;

  UPDATE public.ai_cost_ceiling_runs
    SET effective_ceiling           = v_new_ceiling,
        override_count              = override_count + 1,
        first_override_granted_at   = COALESCE(first_override_granted_at, clock_timestamp()),
        last_override_granted_at    = clock_timestamp(),
        last_override_granted_by_user_id = p_actor_user_id,
        updated_at                  = clock_timestamp()
    WHERE workflow_run_id = p_workflow_run_id;

  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'AI_COST_OVERRIDE_GRANTED',
    p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id => p_workflow_run_id,
    p_actor_user_id => p_actor_user_id,
    p_organization_id => v_biz.organization_id, p_business_id => p_business_id,
    p_before_state => jsonb_build_object(
      'effective_ceiling', v_state.effective_ceiling,
      'override_count', v_state.override_count),
    p_after_state => jsonb_build_object(
      'workflow_run_id', p_workflow_run_id,
      'effective_ceiling', v_new_ceiling,
      'override_count', v_state.override_count + 1,
      'step_up_token_id', p_step_up_token_id,
      'reason', p_reason),
    p_reason => format('AI cost ceiling override granted for run %s (%s → %s)',
                        p_workflow_run_id, v_state.effective_ceiling, v_new_ceiling));

  RETURN jsonb_build_object('ok', true,
    'workflow_run_id', p_workflow_run_id,
    'previous_effective_ceiling', v_state.effective_ceiling,
    'new_effective_ceiling', v_new_ceiling,
    'override_count', v_state.override_count + 1,
    'audit_event_id', v_audit_row.id);
END;
$function$;
COMMENT ON FUNCTION public.grant_cost_ceiling_override(uuid, uuid, uuid, uuid, numeric, text) IS
  'Owner-only RPC. Consumes a step-up token (surface=ai_cost_override) and bumps effective_ceiling. Default extension = +original_ceiling (per spec). Emits AI_COST_OVERRIDE_GRANTED on success, AI_COST_OVERRIDE_DENIED on policy / step-up / ceiling-not-increased failure (Mitigation A).';
REVOKE EXECUTE ON FUNCTION public.grant_cost_ceiling_override(uuid, uuid, uuid, uuid, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.grant_cost_ceiling_override(uuid, uuid, uuid, uuid, numeric, text) TO service_role;

-- ============================================================================
-- 8. deny_cost_ceiling_override
-- ============================================================================
CREATE OR REPLACE FUNCTION public.deny_cost_ceiling_override(
  p_actor_user_id uuid, p_workflow_run_id uuid, p_business_id uuid, p_reason text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_biz public.business_entities%ROWTYPE; v_audit_row audit.audit_events;
BEGIN
  IF p_actor_user_id IS NULL OR p_workflow_run_id IS NULL OR p_business_id IS NULL
     OR p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'deny_cost_ceiling_override: required params missing (reason non-empty)'
      USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_biz FROM public.business_entities WHERE id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'deny_cost_ceiling_override: business % not found', p_business_id USING ERRCODE='22023';
  END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'AI_COST_OVERRIDE_DENIED',
    p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id => p_workflow_run_id,
    p_actor_user_id => p_actor_user_id,
    p_organization_id => v_biz.organization_id, p_business_id => p_business_id,
    p_reason => p_reason,
    p_after_state => jsonb_build_object('workflow_run_id', p_workflow_run_id,
      'rejection_code', 'MANUAL_DENIAL', 'denial_reason', p_reason));
  RETURN jsonb_build_object('ok', true, 'audit_event_id', v_audit_row.id);
END;
$function$;
COMMENT ON FUNCTION public.deny_cost_ceiling_override(uuid, uuid, uuid, text) IS
  'Admin denial path. Records AI_COST_OVERRIDE_DENIED with rejection_code=MANUAL_DENIAL.';
REVOKE EXECUTE ON FUNCTION public.deny_cost_ceiling_override(uuid, uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deny_cost_ceiling_override(uuid, uuid, uuid, text) TO service_role;

-- ============================================================================
-- 9. get_run_cost_ceiling_state — read API
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_run_cost_ceiling_state(p_workflow_run_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_state public.ai_cost_ceiling_runs%ROWTYPE;
  v_current_spend_t3 numeric(14,6);
  v_current_spend_all numeric(14,6);
BEGIN
  IF p_workflow_run_id IS NULL THEN
    RAISE EXCEPTION 'get_run_cost_ceiling_state: p_workflow_run_id required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_state FROM public.ai_cost_ceiling_runs WHERE workflow_run_id = p_workflow_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'no_ceiling', true,
      'workflow_run_id', p_workflow_run_id);
  END IF;
  SELECT COALESCE(SUM(cost_estimate), 0) INTO v_current_spend_t3
    FROM public.ai_usage_records
    WHERE workflow_run_id = p_workflow_run_id
      AND validation_outcome = 'SUCCESS'::public.ai_gateway_result_variant_enum
      AND cache_hit = false AND ai_tier <> 'LOCAL_LLM'::public.ai_tier_enum;
  SELECT COALESCE(SUM(cost_estimate), 0) INTO v_current_spend_all
    FROM public.ai_usage_records
    WHERE workflow_run_id = p_workflow_run_id
      AND validation_outcome = 'SUCCESS'::public.ai_gateway_result_variant_enum
      AND cache_hit = false;
  RETURN jsonb_build_object('ok', true,
    'workflow_run_id', v_state.workflow_run_id,
    'business_id', v_state.business_id,
    'original_ceiling', v_state.original_ceiling,
    'effective_ceiling', v_state.effective_ceiling,
    'warning_threshold_pct', v_state.warning_threshold_pct,
    'currency', v_state.currency,
    'tier_2_gating_enabled', v_state.tier_2_gating_enabled,
    'current_spend_tier_3', v_current_spend_t3,
    'current_spend_all_tiers', v_current_spend_all,
    'gated_spend', CASE WHEN v_state.tier_2_gating_enabled THEN v_current_spend_all ELSE v_current_spend_t3 END,
    'warning_emitted_at', v_state.warning_emitted_at,
    'first_ceiling_hit_at', v_state.first_ceiling_hit_at,
    'last_ceiling_hit_at', v_state.last_ceiling_hit_at,
    'override_count', v_state.override_count,
    'first_override_granted_at', v_state.first_override_granted_at,
    'last_override_granted_at', v_state.last_override_granted_at);
END;
$function$;
COMMENT ON FUNCTION public.get_run_cost_ceiling_state(uuid) IS
  'Read API for the review-queue card. Returns the frozen ceiling state plus live spend computed from ai_usage_records.';
REVOKE EXECUTE ON FUNCTION public.get_run_cost_ceiling_state(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_run_cost_ceiling_state(uuid) TO service_role, authenticated;
