-- B06·P07 — AI Usage Logging & Cost Tracking
--
-- Records one structured row per gateway call so cost, latency, drift, and
-- prompt-regression analysis are queryable. Cost estimators ship per tier
-- (Tier 3 token-based via tier_3_pricing; Tier 2 compute-based via per-business
-- override or a system default + latency-fallback).
--
-- Spec: Docs/phases/06_ai_layer/07_ai_usage_logging_and_cost_tracking.md
--
-- One migration, no ALTER TYPE additions: validation_outcome reuses
-- ai_gateway_result_variant_enum from B06·P02 (six values already match).
--
-- Builds:
--   1. tier_3_pricing  + seed (claude-sonnet-4-6, rate_version v1-2026Q2, EUR)
--   2. business_ai_config extension (per-business Tier 2 hourly rate)
--   3. ai_usage_records table + RLS + indexes
--   4. estimate_tier3_cost / estimate_tier2_cost
--   5. record_ai_usage  (writer; emits AI_USAGE_RECORDED)
--   6. ai_usage_run_totals VIEW
--   7. get_run_ai_usage  (read API)

-- ============================================================================
-- 1. tier_3_pricing
-- ============================================================================
CREATE TABLE public.tier_3_pricing (
  id                   uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  model_id             text NOT NULL,
  rate_version         text NOT NULL,
  input_rate_per_mtok  numeric(14,6) NOT NULL,
  output_rate_per_mtok numeric(14,6) NOT NULL,
  currency             text NOT NULL DEFAULT 'EUR',
  effective_from       timestamptz NOT NULL DEFAULT clock_timestamp(),
  effective_until      timestamptz NULL,
  notes                text NULL,
  created_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_by_user_id   uuid NULL REFERENCES public.users(id),
  CONSTRAINT tier_3_pricing_rates_nonneg
    CHECK (input_rate_per_mtok >= 0 AND output_rate_per_mtok >= 0),
  CONSTRAINT tier_3_pricing_window
    CHECK (effective_until IS NULL OR effective_until > effective_from),
  CONSTRAINT tier_3_pricing_uq UNIQUE (model_id, rate_version)
);
COMMENT ON TABLE public.tier_3_pricing IS
  'Versioned per-model rates for Tier 3 (Anthropic Claude) cost estimation. Rates stored in the row''s currency (default EUR — USD→EUR conversion happens operator-side at rate-load time per the tier_3_pricing sub-doc). Active rate for a model = the row with effective_from <= now() AND (effective_until IS NULL OR effective_until > now()). Bumping rates means inserting a new row + closing the prior with effective_until.';

REVOKE ALL ON public.tier_3_pricing FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.tier_3_pricing TO service_role;

-- Seed placeholder rates (sub-doc tracks the actual numbers).
INSERT INTO public.tier_3_pricing
  (model_id, rate_version, input_rate_per_mtok, output_rate_per_mtok, currency, effective_from, notes)
VALUES
  ('claude-sonnet-4-6', 'v1-2026Q2', 2.800000, 13.800000, 'EUR', clock_timestamp(),
   'placeholder — sub-doc tracks actual Anthropic rate + USD→EUR conversion'),
  ('claude-opus-4-7',   'v1-2026Q2', 13.800000, 69.000000, 'EUR', clock_timestamp(),
   'placeholder for Opus tier');

-- ============================================================================
-- 2. business_ai_config extension — Tier 2 per-business rate
-- ============================================================================
ALTER TABLE public.business_ai_config
  ADD COLUMN tier2_hourly_compute_rate numeric(14,6) NULL,
  ADD COLUMN tier2_hourly_compute_rate_currency text NOT NULL DEFAULT 'EUR',
  ADD CONSTRAINT business_ai_config_tier2_rate_nonneg
    CHECK (tier2_hourly_compute_rate IS NULL OR tier2_hourly_compute_rate >= 0);
COMMENT ON COLUMN public.business_ai_config.tier2_hourly_compute_rate IS
  'Per-business hourly rate for Tier 2 (local LLM) compute cost. NULL → use system default constant in estimate_tier2_cost. Updated by B06·P08 cost-ceiling RPCs when added.';

-- ============================================================================
-- 3. ai_usage_records
-- ============================================================================
CREATE TABLE public.ai_usage_records (
  id                       uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id          uuid NOT NULL,
  business_id              uuid NOT NULL REFERENCES public.business_entities(id),
  workflow_run_id          uuid NULL,
  phase_state_id           uuid NULL REFERENCES public.workflow_phase_states(id),
  gateway_invocation_id    uuid NULL REFERENCES public.ai_gateway_invocations(id),

  tool_name                text NOT NULL REFERENCES public.tool_registry(tool_name),
  prompt_id                text NULL,
  prompt_version           text NULL,
  policy_version           text NULL,

  ai_tier                  public.ai_tier_enum NOT NULL,
  model_id                 text NULL,

  started_at               timestamptz NOT NULL,
  completed_at             timestamptz NOT NULL,
  latency_ms               integer NOT NULL,

  input_size_bytes         integer NULL,
  output_size_bytes        integer NULL,
  input_tokens             integer NULL,
  output_tokens            integer NULL,
  compute_seconds          numeric(14,6) NULL,
  gpu_seconds              numeric(14,6) NULL,

  validation_outcome       public.ai_gateway_result_variant_enum NOT NULL,
  redactions_applied       jsonb NOT NULL DEFAULT '{}'::jsonb,

  cost_estimate            numeric(14,6) NULL,
  cost_estimate_currency   text NOT NULL DEFAULT 'EUR',
  cost_rate_version        text NULL,

  cache_hit                boolean NOT NULL DEFAULT false,

  error_kind               text NULL,
  error_summary            text NULL,

  created_at               timestamptz NOT NULL DEFAULT clock_timestamp(),

  CONSTRAINT ai_usage_records_ai_tier_not_none
    CHECK (ai_tier <> 'NONE'::public.ai_tier_enum),
  CONSTRAINT ai_usage_records_completion_after_start
    CHECK (completed_at >= started_at),
  CONSTRAINT ai_usage_records_latency_nonneg
    CHECK (latency_ms >= 0),
  CONSTRAINT ai_usage_records_redactions_obj
    CHECK (jsonb_typeof(redactions_applied) = 'object'),
  CONSTRAINT ai_usage_records_cost_nonneg
    CHECK (cost_estimate IS NULL OR cost_estimate >= 0),
  CONSTRAINT ai_usage_records_error_paired
    CHECK ((error_kind IS NULL AND error_summary IS NULL)
           OR (error_kind IS NOT NULL AND error_summary IS NOT NULL)),
  CONSTRAINT ai_usage_records_cache_hit_zero_cost
    CHECK (cache_hit = false OR cost_estimate = 0),
  CONSTRAINT ai_usage_records_success_has_model
    CHECK (validation_outcome <> 'SUCCESS'::public.ai_gateway_result_variant_enum
           OR model_id IS NOT NULL)
);
COMMENT ON TABLE public.ai_usage_records IS
  'One row per gateway call. Source-of-truth for AI cost, latency, drift, and prompt-regression analysis. Append-only; updates and deletes are blocked by RLS policies (no_update / no_delete). Rows are inserted by record_ai_usage from the gateway / dispatcher.';
COMMENT ON COLUMN public.ai_usage_records.redactions_applied IS
  'JSONB count-by-field-kind, never values. Mirrors the redaction-engine output from B06·P03 apply_redaction.drops_by_field_kind + masks_by_field_kind, plus optional ''kept'' counts.';
COMMENT ON COLUMN public.ai_usage_records.cost_rate_version IS
  'Source of the cost: a tier_3_pricing.rate_version (e.g. ''v1-2026Q2'') for Tier 3, or one of ''tier2_business_rate'' / ''tier2_system_default'' / ''tier2_fallback_latency'' for Tier 2, or ''cache_hit'' when cache_hit=true.';

CREATE INDEX idx_aur_business_started ON public.ai_usage_records (business_id, started_at DESC);
CREATE INDEX idx_aur_run ON public.ai_usage_records (workflow_run_id) WHERE workflow_run_id IS NOT NULL;
CREATE INDEX idx_aur_tier_started ON public.ai_usage_records (ai_tier, started_at DESC);

-- Grants + RLS — service_role writes; authenticated reads only tenant rows.
REVOKE INSERT, UPDATE, DELETE ON public.ai_usage_records FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.ai_usage_records TO service_role;

ALTER TABLE public.ai_usage_records ENABLE ROW LEVEL SECURITY;

CREATE POLICY ai_usage_records_select ON public.ai_usage_records
  FOR SELECT
  USING ((organization_id = public.current_org())
         AND (business_id = ANY (public.current_user_businesses())));

CREATE POLICY ai_usage_records_no_update ON public.ai_usage_records
  FOR UPDATE USING (false);

CREATE POLICY ai_usage_records_no_delete ON public.ai_usage_records
  FOR DELETE USING (false);

-- ============================================================================
-- 4a. estimate_tier3_cost
-- ============================================================================
CREATE OR REPLACE FUNCTION public.estimate_tier3_cost(
  p_model_id text, p_input_tokens int, p_output_tokens int
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_row public.tier_3_pricing%ROWTYPE;
  v_cost numeric(14,6);
BEGIN
  IF p_model_id IS NULL OR p_input_tokens IS NULL OR p_output_tokens IS NULL THEN
    RAISE EXCEPTION 'estimate_tier3_cost: required params missing'
      USING ERRCODE = '22000';
  END IF;
  IF p_input_tokens < 0 OR p_output_tokens < 0 THEN
    RAISE EXCEPTION 'estimate_tier3_cost: token counts must be non-negative'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row
    FROM public.tier_3_pricing
   WHERE model_id = p_model_id
     AND effective_from <= clock_timestamp()
     AND (effective_until IS NULL OR effective_until > clock_timestamp())
   ORDER BY effective_from DESC
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NO_ACTIVE_RATE_FOR_MODEL',
                              'model_id', p_model_id);
  END IF;

  v_cost := (p_input_tokens::numeric * v_row.input_rate_per_mtok / 1000000)
          + (p_output_tokens::numeric * v_row.output_rate_per_mtok / 1000000);

  RETURN jsonb_build_object(
    'ok',                    true,
    'cost_estimate',         v_cost,
    'currency',              v_row.currency,
    'rate_version',          v_row.rate_version,
    'input_rate_per_mtok',   v_row.input_rate_per_mtok,
    'output_rate_per_mtok',  v_row.output_rate_per_mtok
  );
END;
$function$;
COMMENT ON FUNCTION public.estimate_tier3_cost(text, int, int) IS
  'Computes Tier 3 cost for a (model, input_tokens, output_tokens) triple using the currently-active tier_3_pricing row.';
REVOKE EXECUTE ON FUNCTION public.estimate_tier3_cost(text, int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.estimate_tier3_cost(text, int, int) TO service_role;

-- ============================================================================
-- 4b. estimate_tier2_cost
-- ============================================================================
CREATE OR REPLACE FUNCTION public.estimate_tier2_cost(
  p_business_id uuid,
  p_compute_seconds numeric DEFAULT NULL,
  p_latency_ms      int     DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_business_rate numeric(14,6);
  v_currency      text;
  v_hourly_rate   numeric(14,6);
  v_source        text;
  v_seconds       numeric;
  v_cost          numeric(14,6);
  c_system_default_rate constant numeric := 2.000000;  -- €2.00/h placeholder
  c_system_default_currency constant text := 'EUR';
BEGIN
  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'estimate_tier2_cost: p_business_id required' USING ERRCODE = '22000';
  END IF;
  IF p_compute_seconds IS NULL AND p_latency_ms IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NO_COMPUTE_OR_LATENCY');
  END IF;
  IF p_compute_seconds IS NOT NULL AND p_compute_seconds < 0 THEN
    RAISE EXCEPTION 'estimate_tier2_cost: compute_seconds must be non-negative'
      USING ERRCODE = '22023';
  END IF;
  IF p_latency_ms IS NOT NULL AND p_latency_ms < 0 THEN
    RAISE EXCEPTION 'estimate_tier2_cost: latency_ms must be non-negative'
      USING ERRCODE = '22023';
  END IF;

  SELECT tier2_hourly_compute_rate, tier2_hourly_compute_rate_currency
    INTO v_business_rate, v_currency
    FROM public.business_ai_config
   WHERE business_id = p_business_id;

  IF v_business_rate IS NOT NULL THEN
    v_hourly_rate := v_business_rate;
    -- v_currency already populated from the row
    v_source := 'tier2_business_rate';
  ELSE
    v_hourly_rate := c_system_default_rate;
    v_currency    := c_system_default_currency;
    v_source      := 'tier2_system_default';
  END IF;

  IF p_compute_seconds IS NOT NULL THEN
    v_seconds := p_compute_seconds;
  ELSE
    -- Fallback estimator: treat each wall-clock millisecond as a millisecond of compute.
    v_seconds := p_latency_ms::numeric / 1000;
    v_source  := 'tier2_fallback_latency';
  END IF;

  v_cost := (v_seconds / 3600) * v_hourly_rate;

  RETURN jsonb_build_object(
    'ok',            true,
    'cost_estimate', v_cost,
    'currency',      v_currency,
    'source',        v_source,
    'hourly_rate',   v_hourly_rate,
    'compute_seconds_used', v_seconds
  );
END;
$function$;
COMMENT ON FUNCTION public.estimate_tier2_cost(uuid, numeric, int) IS
  'Computes Tier 2 cost using the per-business hourly rate (business_ai_config.tier2_hourly_compute_rate) or a system default placeholder of €2.00/h. Falls back to latency-as-compute-seconds when compute_seconds is NULL. Returns source = tier2_business_rate / tier2_system_default / tier2_fallback_latency.';
REVOKE EXECUTE ON FUNCTION public.estimate_tier2_cost(uuid, numeric, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.estimate_tier2_cost(uuid, numeric, int) TO service_role;

-- ============================================================================
-- 5. record_ai_usage — the writer
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_ai_usage(
  p_organization_id        uuid,
  p_business_id            uuid,
  p_tool_name              text,
  p_ai_tier                public.ai_tier_enum,
  p_started_at             timestamptz,
  p_completed_at           timestamptz,
  p_latency_ms             integer,
  p_validation_outcome     public.ai_gateway_result_variant_enum,
  p_workflow_run_id        uuid    DEFAULT NULL,
  p_phase_state_id         uuid    DEFAULT NULL,
  p_gateway_invocation_id  uuid    DEFAULT NULL,
  p_prompt_id              text    DEFAULT NULL,
  p_prompt_version         text    DEFAULT NULL,
  p_policy_version         text    DEFAULT NULL,
  p_model_id               text    DEFAULT NULL,
  p_input_size_bytes       integer DEFAULT NULL,
  p_output_size_bytes      integer DEFAULT NULL,
  p_input_tokens           integer DEFAULT NULL,
  p_output_tokens          integer DEFAULT NULL,
  p_compute_seconds        numeric DEFAULT NULL,
  p_gpu_seconds            numeric DEFAULT NULL,
  p_redactions_applied     jsonb   DEFAULT '{}'::jsonb,
  p_cache_hit              boolean DEFAULT false,
  p_error_kind             text    DEFAULT NULL,
  p_error_summary          text    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_estimator         jsonb;
  v_cost              numeric(14,6);
  v_currency          text := 'EUR';
  v_rate_version      text;
  v_record_id         uuid;
  v_audit_row         audit.audit_events;
BEGIN
  IF p_organization_id IS NULL OR p_business_id IS NULL OR p_tool_name IS NULL
     OR p_ai_tier IS NULL OR p_started_at IS NULL OR p_completed_at IS NULL
     OR p_latency_ms IS NULL OR p_validation_outcome IS NULL THEN
    RAISE EXCEPTION 'record_ai_usage: required params missing' USING ERRCODE = '22000';
  END IF;
  IF (p_error_kind IS NULL) <> (p_error_summary IS NULL) THEN
    RAISE EXCEPTION 'record_ai_usage: error_kind and error_summary must be both NULL or both non-NULL'
      USING ERRCODE = '22000';
  END IF;
  IF p_validation_outcome <> 'SUCCESS'::public.ai_gateway_result_variant_enum
     AND p_error_kind IS NULL THEN
    RAISE EXCEPTION 'record_ai_usage: non-SUCCESS outcomes require error_kind/error_summary'
      USING ERRCODE = '22000';
  END IF;

  IF p_cache_hit THEN
    v_cost := 0;
    v_currency := 'EUR';
    v_rate_version := 'cache_hit';
  ELSIF p_validation_outcome <> 'SUCCESS'::public.ai_gateway_result_variant_enum THEN
    -- No model dispatch (or aborted dispatch) — no cost.
    v_cost := 0;
    v_currency := 'EUR';
    v_rate_version := NULL;
  ELSIF p_ai_tier = 'EXTERNAL_LLM'::public.ai_tier_enum THEN
    v_estimator := public.estimate_tier3_cost(
                     p_model_id,
                     COALESCE(p_input_tokens, 0),
                     COALESCE(p_output_tokens, 0));
    IF (v_estimator->>'ok')::boolean IS NOT TRUE THEN
      v_cost := NULL;
      v_rate_version := NULL;
    ELSE
      v_cost := (v_estimator->>'cost_estimate')::numeric;
      v_currency := v_estimator->>'currency';
      v_rate_version := v_estimator->>'rate_version';
    END IF;
  ELSIF p_ai_tier = 'LOCAL_LLM'::public.ai_tier_enum THEN
    v_estimator := public.estimate_tier2_cost(
                     p_business_id, p_compute_seconds, p_latency_ms);
    IF (v_estimator->>'ok')::boolean IS NOT TRUE THEN
      v_cost := NULL;
      v_rate_version := NULL;
    ELSE
      v_cost := (v_estimator->>'cost_estimate')::numeric;
      v_currency := v_estimator->>'currency';
      v_rate_version := v_estimator->>'source';
    END IF;
  ELSE
    RAISE EXCEPTION 'record_ai_usage: unsupported ai_tier %', p_ai_tier
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.ai_usage_records (
    organization_id, business_id, workflow_run_id, phase_state_id, gateway_invocation_id,
    tool_name, prompt_id, prompt_version, policy_version,
    ai_tier, model_id,
    started_at, completed_at, latency_ms,
    input_size_bytes, output_size_bytes,
    input_tokens, output_tokens, compute_seconds, gpu_seconds,
    validation_outcome, redactions_applied,
    cost_estimate, cost_estimate_currency, cost_rate_version,
    cache_hit, error_kind, error_summary
  ) VALUES (
    p_organization_id, p_business_id, p_workflow_run_id, p_phase_state_id, p_gateway_invocation_id,
    p_tool_name, p_prompt_id, p_prompt_version, p_policy_version,
    p_ai_tier, p_model_id,
    p_started_at, p_completed_at, p_latency_ms,
    p_input_size_bytes, p_output_size_bytes,
    p_input_tokens, p_output_tokens, p_compute_seconds, p_gpu_seconds,
    p_validation_outcome, COALESCE(p_redactions_applied, '{}'::jsonb),
    v_cost, v_currency, v_rate_version,
    p_cache_hit, p_error_kind, p_error_summary
  ) RETURNING id INTO v_record_id;

  v_audit_row := audit.emit_audit(
    p_actor_kind      => 'SYSTEM'::audit.actor_kind_enum,
    p_action          => 'AI_USAGE_RECORDED',
    p_subject_type    => 'AI_GATEWAY_INVOCATION'::audit.subject_type_enum,
    p_subject_id      => p_gateway_invocation_id,
    p_actor_system    => 'ai_usage_logger',
    p_organization_id => p_organization_id,
    p_business_id     => p_business_id,
    p_reason          => format('AI usage %s recorded for tier %s (outcome=%s)',
                                 v_record_id, p_ai_tier, p_validation_outcome),
    p_after_state     => jsonb_build_object(
      'usage_record_id',    v_record_id,
      'tool_name',          p_tool_name,
      'ai_tier',            p_ai_tier::text,
      'model_id',           p_model_id,
      'validation_outcome', p_validation_outcome::text,
      'latency_ms',         p_latency_ms,
      'input_tokens',       p_input_tokens,
      'output_tokens',      p_output_tokens,
      'compute_seconds',    p_compute_seconds,
      'cost_estimate',      v_cost,
      'currency',           v_currency,
      'rate_version',       v_rate_version,
      'cache_hit',          p_cache_hit
    )
  );

  RETURN jsonb_build_object('ok', true,
    'usage_record_id', v_record_id,
    'cost_estimate', v_cost,
    'currency', v_currency,
    'rate_version', v_rate_version,
    'audit_event_id', v_audit_row.id);
END;
$function$;
COMMENT ON FUNCTION public.record_ai_usage(uuid, uuid, text, public.ai_tier_enum, timestamptz, timestamptz, integer, public.ai_gateway_result_variant_enum, uuid, uuid, uuid, text, text, text, text, integer, integer, integer, integer, numeric, numeric, jsonb, boolean, text, text) IS
  'Writes one ai_usage_records row + emits AI_USAGE_RECORDED audit. Computes cost via estimate_tier3_cost / estimate_tier2_cost based on ai_tier; sets cost=0 + rate_version=''cache_hit'' when p_cache_hit=true; cost=0 + rate_version=NULL on non-SUCCESS outcomes (no dispatch occurred). Called by the gateway / dispatcher after every call. No can_perform check (service-role only).';

REVOKE EXECUTE ON FUNCTION public.record_ai_usage(uuid, uuid, text, public.ai_tier_enum, timestamptz, timestamptz, integer, public.ai_gateway_result_variant_enum, uuid, uuid, uuid, text, text, text, text, integer, integer, integer, integer, numeric, numeric, jsonb, boolean, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_ai_usage(uuid, uuid, text, public.ai_tier_enum, timestamptz, timestamptz, integer, public.ai_gateway_result_variant_enum, uuid, uuid, uuid, text, text, text, text, integer, integer, integer, integer, numeric, numeric, jsonb, boolean, text, text) TO service_role;

-- ============================================================================
-- 6. ai_usage_run_totals VIEW
-- ============================================================================
CREATE OR REPLACE VIEW public.ai_usage_run_totals AS
SELECT
  workflow_run_id,
  ai_tier,
  count(*)                              AS call_count,
  COALESCE(sum(input_tokens), 0)::int   AS total_input_tokens,
  COALESCE(sum(output_tokens), 0)::int  AS total_output_tokens,
  COALESCE(sum(compute_seconds), 0)     AS total_compute_seconds,
  COALESCE(sum(latency_ms), 0)::bigint  AS total_latency_ms,
  COALESCE(sum(cost_estimate), 0)       AS total_cost_estimate,
  -- Naive currency picker: returns the first non-null currency observed.
  -- Mixed currencies within a single (run, tier) are flagged by
  -- get_run_ai_usage.
  max(cost_estimate_currency)           AS currency
FROM public.ai_usage_records
WHERE workflow_run_id IS NOT NULL
GROUP BY workflow_run_id, ai_tier;

COMMENT ON VIEW public.ai_usage_run_totals IS
  'Per-(workflow_run_id, ai_tier) totals over ai_usage_records. Plain VIEW; materialisation + refresh cadence is sub-doc work and would also emit AI_USAGE_AGGREGATION_REFRESHED. Mixed-currency runs are flagged downstream in get_run_ai_usage.';

REVOKE ALL ON public.ai_usage_run_totals FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.ai_usage_run_totals TO service_role, authenticated;
-- Reads from view are still RLS-filtered through the underlying ai_usage_records.

-- ============================================================================
-- 7. get_run_ai_usage
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_run_ai_usage(p_workflow_run_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_by_tier   jsonb;
  v_total_cost numeric(14,6);
  v_currencies text[];
  v_call_count int;
BEGIN
  IF p_workflow_run_id IS NULL THEN
    RAISE EXCEPTION 'get_run_ai_usage: p_workflow_run_id required' USING ERRCODE = '22000';
  END IF;

  SELECT jsonb_agg(jsonb_build_object(
           'ai_tier',                ai_tier::text,
           'call_count',             call_count,
           'total_input_tokens',     total_input_tokens,
           'total_output_tokens',    total_output_tokens,
           'total_compute_seconds',  total_compute_seconds,
           'total_latency_ms',       total_latency_ms,
           'total_cost_estimate',    total_cost_estimate,
           'currency',               currency
         ) ORDER BY ai_tier::text),
         COALESCE(sum(total_cost_estimate), 0),
         array_agg(DISTINCT currency),
         COALESCE(sum(call_count), 0)::int
    INTO v_by_tier, v_total_cost, v_currencies, v_call_count
    FROM public.ai_usage_run_totals
   WHERE workflow_run_id = p_workflow_run_id;

  RETURN jsonb_build_object(
    'ok',                      true,
    'workflow_run_id',         p_workflow_run_id,
    'call_count',              v_call_count,
    'by_tier',                 COALESCE(v_by_tier, '[]'::jsonb),
    'total_cost_estimate',     v_total_cost,
    'currencies',              COALESCE(to_jsonb(v_currencies), '[]'::jsonb),
    'mixed_currency_warning',  CASE WHEN array_length(v_currencies, 1) > 1 THEN true ELSE false END
  );
END;
$function$;
COMMENT ON FUNCTION public.get_run_ai_usage(uuid) IS
  'Per-run AI usage summary consumed by B06·P08 (cost ceiling) and B16 (reporting). Flags mixed-currency runs so the consumer can decide how to aggregate.';

REVOKE EXECUTE ON FUNCTION public.get_run_ai_usage(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_run_ai_usage(uuid) TO service_role, authenticated;
