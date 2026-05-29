-- B06·P04 — Prompt Management (migration 2 of 2)
--
-- Treats prompts as versioned artifacts with declared schemas + maintained test
-- corpora. The DB layer is the runtime registry; the on-disk corpus
-- (Docs/sub/.../prompts/) is the source-of-truth and gets synced via
-- scripts/sync_prompts_to_registry.py.
--
-- Spec: Docs/phases/06_ai_layer/04_prompt_management.md
--
-- Builds:
--   1. prompt_environment_enum (TEST, PRODUCTION)
--   2. prompt_registry + prompt_test_cases + prompt_deployments
--   3. register_prompt  / deploy_prompt / rollback_prompt
--   4. get_prompt / current_prompt_version (read helpers)
--   5. record_prompt_regression_failed (CI signal)
--
-- Migration 1 (20260522000001) added PROMPT to audit.subject_type_enum.

-- ============================================================================
-- 1. Enum
-- ============================================================================
CREATE TYPE public.prompt_environment_enum AS ENUM ('TEST', 'PRODUCTION');
COMMENT ON TYPE public.prompt_environment_enum IS
  'Deployment environments for prompt versions. TEST is the soak environment; PRODUCTION requires either a one-week soak (B06·P04 spec §Promotion path) or an Owner override.';

-- ============================================================================
-- 2. Tables
-- ============================================================================
CREATE TABLE public.prompt_registry (
  prompt_id            text NOT NULL,
  version              text NOT NULL,
  purpose              text NOT NULL,
  input_schema         jsonb NOT NULL,
  output_schema        jsonb NOT NULL,
  ai_tier              public.ai_tier_enum NOT NULL,
  prompt_template_text text NOT NULL,
  content_hash         text NOT NULL,
  registered_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
  registered_by_user_id uuid NULL REFERENCES public.users(id),
  CONSTRAINT prompt_registry_pkey PRIMARY KEY (prompt_id, version),
  CONSTRAINT prompt_registry_id_namespaced
    CHECK (prompt_id ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
  CONSTRAINT prompt_registry_version_semver
    CHECK (version ~ '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$'),
  CONSTRAINT prompt_registry_ai_tier_not_none
    CHECK (ai_tier <> 'NONE'::public.ai_tier_enum),
  CONSTRAINT prompt_registry_content_hash_sha256_hex
    CHECK (content_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT prompt_registry_input_schema_obj  CHECK (jsonb_typeof(input_schema)  = 'object'),
  CONSTRAINT prompt_registry_output_schema_obj CHECK (jsonb_typeof(output_schema) = 'object')
);
COMMENT ON TABLE public.prompt_registry IS
  'One row per (prompt_id, version). Content is immutable for a given version — bumping prompt_template_text or schemas requires a new version. content_hash is SHA-256 hex of the canonical-serialised meta + template, used by sync_prompts_to_registry.py to detect drift between on-disk and in-DB.';

REVOKE ALL ON public.prompt_registry FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.prompt_registry TO service_role;

CREATE TABLE public.prompt_test_cases (
  prompt_id              text NOT NULL,
  version                text NOT NULL,
  case_name              text NOT NULL,
  input                  jsonb NOT NULL,
  expected_output        jsonb NULL,
  must_contain_assertions jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_adversarial_anchor  boolean NOT NULL DEFAULT false,
  created_at             timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT prompt_test_cases_pkey PRIMARY KEY (prompt_id, version, case_name),
  CONSTRAINT prompt_test_cases_fk
    FOREIGN KEY (prompt_id, version) REFERENCES public.prompt_registry(prompt_id, version)
    ON DELETE CASCADE,
  CONSTRAINT prompt_test_cases_case_name_kebab
    CHECK (case_name ~ '^[a-z0-9][a-z0-9_-]*$'),
  CONSTRAINT prompt_test_cases_input_obj  CHECK (jsonb_typeof(input) = 'object'),
  CONSTRAINT prompt_test_cases_assertions_array
    CHECK (jsonb_typeof(must_contain_assertions) = 'array')
);
COMMENT ON TABLE public.prompt_test_cases IS
  'Versioned test corpus for a prompt. New versions may add cases but the registry-level CHECK enforces ≥5 cases including ≥1 is_adversarial_anchor at registration time. Removing a case from a published version requires a documented removal entry (sub-doc workflow), enforced outside the DB.';

REVOKE ALL ON public.prompt_test_cases FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.prompt_test_cases TO service_role;

CREATE TABLE public.prompt_deployments (
  id                    uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  prompt_id             text NOT NULL,
  version               text NOT NULL,
  environment           public.prompt_environment_enum NOT NULL,
  deployed_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
  deployed_by_user_id   uuid NULL REFERENCES public.users(id),
  is_current            boolean NOT NULL,
  is_rollback           boolean NOT NULL DEFAULT false,
  is_override           boolean NOT NULL DEFAULT false,
  override_reason       text NULL,
  rollback_reason       text NULL,
  CONSTRAINT prompt_deployments_fk
    FOREIGN KEY (prompt_id, version) REFERENCES public.prompt_registry(prompt_id, version),
  CONSTRAINT prompt_deployments_override_has_reason
    CHECK ((is_override = false) OR (override_reason IS NOT NULL AND length(trim(override_reason)) > 0)),
  CONSTRAINT prompt_deployments_rollback_has_reason
    CHECK ((is_rollback = false) OR (rollback_reason IS NOT NULL AND length(trim(rollback_reason)) > 0))
);
CREATE UNIQUE INDEX prompt_deployments_one_current_per_env_prompt
  ON public.prompt_deployments (environment, prompt_id)
  WHERE is_current = true;
CREATE INDEX prompt_deployments_history ON public.prompt_deployments (prompt_id, environment, deployed_at DESC);
COMMENT ON TABLE public.prompt_deployments IS
  'Append-only deployment log per (prompt_id, environment). At most one row per (env, prompt_id) has is_current=true (partial UNIQUE). Rollbacks and overrides are flagged explicitly so audit reconstruction can distinguish forward deploys from rollbacks and explicit-override promotions.';

REVOKE ALL ON public.prompt_deployments FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.prompt_deployments TO service_role;

-- ============================================================================
-- 3. register_prompt
-- ============================================================================
CREATE OR REPLACE FUNCTION public.register_prompt(
  p_actor_user_id        uuid,
  p_prompt_id            text,
  p_version              text,
  p_purpose              text,
  p_input_schema         jsonb,
  p_output_schema        jsonb,
  p_ai_tier              public.ai_tier_enum,
  p_prompt_template_text text,
  p_content_hash         text,
  p_test_cases           jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_perm        jsonb;
  v_perm_dec    text;
  v_exists      boolean;
  v_case_count  int;
  v_adv_count   int;
  v_case        jsonb;
  v_reject_code text;
  v_reject_msg  text;
  v_audit_row   audit.audit_events;
BEGIN
  IF p_actor_user_id IS NULL OR p_prompt_id IS NULL OR p_version IS NULL
     OR p_purpose IS NULL OR p_input_schema IS NULL OR p_output_schema IS NULL
     OR p_ai_tier IS NULL OR p_prompt_template_text IS NULL
     OR p_content_hash IS NULL OR p_test_cases IS NULL THEN
    RAISE EXCEPTION 'register_prompt: required params missing' USING ERRCODE = '22000';
  END IF;

  v_perm := public.can_perform(
    p_actor_user_id => p_actor_user_id, p_surface => 'prompt_registry',
    p_action => 'register',
    p_resource => jsonb_build_object('prompt_id', p_prompt_id, 'version', p_version),
    p_business_id => NULL, p_organization_id => NULL);
  v_perm_dec := v_perm->>'decision';
  IF v_perm_dec = 'DENY' THEN
    v_reject_code := 'PERMISSION_DENIED';
    v_reject_msg  := format('actor lacks permission prompt_registry:register (reason=%s)', v_perm->>'reason_code');
  ELSIF v_perm_dec NOT IN ('ALLOW','STEP_UP') THEN
    v_reject_code := 'PERMISSION_DENIED';
    v_reject_msg  := format('unexpected can_perform decision: %s', v_perm_dec);
  END IF;

  IF v_reject_code IS NULL THEN
    SELECT EXISTS(SELECT 1 FROM public.prompt_registry WHERE prompt_id = p_prompt_id AND version = p_version)
      INTO v_exists;
    IF v_exists THEN
      v_reject_code := 'DUPLICATE_VERSION';
      v_reject_msg  := format('prompt %s version %s already registered', p_prompt_id, p_version);
    END IF;
  END IF;

  -- Test corpus shape: must be array, ≥5 cases, ≥1 adversarial anchor.
  IF v_reject_code IS NULL THEN
    IF jsonb_typeof(p_test_cases) <> 'array' THEN
      v_reject_code := 'TEST_CASES_NOT_ARRAY';
      v_reject_msg  := 'p_test_cases must be a JSON array';
    ELSE
      v_case_count := jsonb_array_length(p_test_cases);
      IF v_case_count < 5 THEN
        v_reject_code := 'TEST_CASES_INSUFFICIENT';
        v_reject_msg  := format('spec requires ≥5 test cases per prompt version (got %s)', v_case_count);
      ELSE
        SELECT count(*) INTO v_adv_count
          FROM jsonb_array_elements(p_test_cases) AS c
         WHERE COALESCE((c->>'is_adversarial_anchor')::boolean, false);
        IF v_adv_count < 1 THEN
          v_reject_code := 'NO_ADVERSARIAL_ANCHOR';
          v_reject_msg  := 'spec requires ≥1 test case with is_adversarial_anchor=true';
        END IF;
      END IF;
    END IF;
  END IF;

  IF v_reject_code IS NOT NULL THEN
    v_audit_row := audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum,
      p_action => 'AI_PROMPT_REGISTER_REJECTED',
      p_subject_type => 'PROMPT'::audit.subject_type_enum,
      p_subject_id => NULL, p_actor_user_id => p_actor_user_id,
      p_reason => v_reject_msg,
      p_after_state => jsonb_build_object(
        'rejection_code', v_reject_code, 'prompt_id', p_prompt_id, 'version', p_version));
    RETURN jsonb_build_object('ok', false, 'reason', v_reject_code,
      'message', v_reject_msg, 'audit_event_id', v_audit_row.id);
  END IF;

  INSERT INTO public.prompt_registry (
    prompt_id, version, purpose, input_schema, output_schema, ai_tier,
    prompt_template_text, content_hash, registered_by_user_id
  ) VALUES (
    p_prompt_id, p_version, p_purpose, p_input_schema, p_output_schema, p_ai_tier,
    p_prompt_template_text, p_content_hash, p_actor_user_id
  );

  FOR v_case IN SELECT jsonb_array_elements(p_test_cases) LOOP
    INSERT INTO public.prompt_test_cases (
      prompt_id, version, case_name, input, expected_output,
      must_contain_assertions, is_adversarial_anchor
    ) VALUES (
      p_prompt_id, p_version,
      v_case->>'case_name',
      v_case->'input',
      v_case->'expected_output',
      COALESCE(v_case->'must_contain_assertions', '[]'::jsonb),
      COALESCE((v_case->>'is_adversarial_anchor')::boolean, false)
    );
  END LOOP;

  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'AI_PROMPT_REGISTERED',
    p_subject_type => 'PROMPT'::audit.subject_type_enum,
    p_subject_id => NULL, p_actor_user_id => p_actor_user_id,
    p_reason => format('prompt %s version %s registered (%s test cases)',
                        p_prompt_id, p_version, v_case_count),
    p_after_state => jsonb_build_object(
      'prompt_id', p_prompt_id, 'version', p_version, 'ai_tier', p_ai_tier::text,
      'content_hash', p_content_hash, 'test_case_count', v_case_count,
      'adversarial_anchor_count', v_adv_count));

  RETURN jsonb_build_object('ok', true, 'prompt_id', p_prompt_id, 'version', p_version,
    'test_case_count', v_case_count, 'audit_event_id', v_audit_row.id);
END;
$function$;
COMMENT ON FUNCTION public.register_prompt(uuid, text, text, text, jsonb, jsonb, public.ai_tier_enum, text, text, jsonb) IS
  'Owner-only RPC. Inserts a prompt version + its test cases atomically. Enforces: prompt_id namespaced, version semver, content_hash sha256-hex, ≥5 test cases with ≥1 adversarial anchor. Emits AI_PROMPT_REGISTERED on success, AI_PROMPT_REGISTER_REJECTED on policy failure (Mitigation A).';
REVOKE EXECUTE ON FUNCTION public.register_prompt(uuid, text, text, text, jsonb, jsonb, public.ai_tier_enum, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_prompt(uuid, text, text, text, jsonb, jsonb, public.ai_tier_enum, text, text, jsonb) TO service_role;

-- ============================================================================
-- 4. deploy_prompt — handles forward deploy, override path, and soak-window check
-- ============================================================================
CREATE OR REPLACE FUNCTION public.deploy_prompt(
  p_actor_user_id  uuid,
  p_prompt_id      text,
  p_version        text,
  p_environment    public.prompt_environment_enum,
  p_is_override    boolean DEFAULT false,
  p_override_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_perm        jsonb;
  v_perm_dec    text;
  v_exists      boolean;
  v_test_deploy timestamptz;
  v_soak_elapsed_interval interval;
  v_reject_code text;
  v_reject_msg  text;
  v_audit_row   audit.audit_events;
  v_action_name text;
  v_deploy_id   uuid;
BEGIN
  IF p_actor_user_id IS NULL OR p_prompt_id IS NULL OR p_version IS NULL OR p_environment IS NULL THEN
    RAISE EXCEPTION 'deploy_prompt: required params missing' USING ERRCODE = '22000';
  END IF;
  IF p_is_override = true AND (p_override_reason IS NULL OR length(trim(p_override_reason)) = 0) THEN
    v_reject_code := 'MISSING_OVERRIDE_REASON';
    v_reject_msg  := 'p_is_override=true requires a non-empty p_override_reason';
  END IF;

  IF v_reject_code IS NULL THEN
    v_perm := public.can_perform(
      p_actor_user_id => p_actor_user_id, p_surface => 'prompt_deployment',
      p_action => 'deploy',
      p_resource => jsonb_build_object('prompt_id', p_prompt_id, 'version', p_version,
                                        'environment', p_environment::text),
      p_business_id => NULL, p_organization_id => NULL);
    v_perm_dec := v_perm->>'decision';
    IF v_perm_dec = 'DENY' THEN
      v_reject_code := 'PERMISSION_DENIED';
      v_reject_msg  := format('actor lacks permission prompt_deployment:deploy (reason=%s)',
                               v_perm->>'reason_code');
    ELSIF v_perm_dec NOT IN ('ALLOW','STEP_UP') THEN
      v_reject_code := 'PERMISSION_DENIED';
      v_reject_msg  := format('unexpected can_perform decision: %s', v_perm_dec);
    END IF;
  END IF;

  IF v_reject_code IS NULL THEN
    SELECT EXISTS(SELECT 1 FROM public.prompt_registry
                  WHERE prompt_id = p_prompt_id AND version = p_version)
      INTO v_exists;
    IF NOT v_exists THEN
      v_reject_code := 'VERSION_NOT_FOUND';
      v_reject_msg  := format('prompt %s version %s not registered', p_prompt_id, p_version);
    END IF;
  END IF;

  -- Soak-window check: PRODUCTION deploy of a version requires the same
  -- (prompt_id, version) to have been deployed to TEST ≥ 7 days ago, OR an
  -- explicit override with a reason.
  IF v_reject_code IS NULL
     AND p_environment = 'PRODUCTION'::public.prompt_environment_enum
     AND NOT p_is_override THEN
    SELECT MIN(deployed_at) INTO v_test_deploy
      FROM public.prompt_deployments
     WHERE prompt_id = p_prompt_id AND version = p_version
       AND environment = 'TEST'::public.prompt_environment_enum;
    IF v_test_deploy IS NULL THEN
      v_reject_code := 'SOAK_NOT_ELAPSED';
      v_reject_msg  := format('prompt %s version %s has never been deployed to TEST; cannot promote to PRODUCTION without override',
                               p_prompt_id, p_version);
    ELSIF (clock_timestamp() - v_test_deploy) < interval '7 days' THEN
      v_soak_elapsed_interval := clock_timestamp() - v_test_deploy;
      v_reject_code := 'SOAK_NOT_ELAPSED';
      v_reject_msg  := format('soak window not elapsed (%s < 7 days); first TEST deploy at %s. Use is_override=true with a reason to bypass.',
                               v_soak_elapsed_interval, v_test_deploy);
    END IF;
  END IF;

  IF v_reject_code IS NOT NULL THEN
    v_audit_row := audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum,
      p_action => 'AI_PROMPT_DEPLOY_REJECTED',
      p_subject_type => 'PROMPT'::audit.subject_type_enum,
      p_subject_id => NULL, p_actor_user_id => p_actor_user_id,
      p_reason => v_reject_msg,
      p_after_state => jsonb_build_object(
        'rejection_code', v_reject_code, 'prompt_id', p_prompt_id, 'version', p_version,
        'environment', p_environment::text, 'is_override', p_is_override));
    RETURN jsonb_build_object('ok', false, 'reason', v_reject_code,
      'message', v_reject_msg, 'audit_event_id', v_audit_row.id);
  END IF;

  -- Flip the previous current row (if any) to is_current=false.
  UPDATE public.prompt_deployments
     SET is_current = false
   WHERE environment = p_environment AND prompt_id = p_prompt_id AND is_current = true;

  INSERT INTO public.prompt_deployments (
    prompt_id, version, environment, deployed_by_user_id,
    is_current, is_rollback, is_override, override_reason
  ) VALUES (
    p_prompt_id, p_version, p_environment, p_actor_user_id,
    true, false, p_is_override, p_override_reason
  ) RETURNING id INTO v_deploy_id;

  v_action_name := CASE WHEN p_is_override THEN 'AI_PROMPT_PROMOTION_OVERRIDE_USED'
                                            ELSE 'AI_PROMPT_DEPLOYED' END;
  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => v_action_name,
    p_subject_type => 'PROMPT'::audit.subject_type_enum,
    p_subject_id => v_deploy_id, p_actor_user_id => p_actor_user_id,
    p_reason => format('prompt %s version %s deployed to %s (override=%s)',
                        p_prompt_id, p_version, p_environment, p_is_override),
    p_after_state => jsonb_build_object(
      'deployment_id', v_deploy_id, 'prompt_id', p_prompt_id, 'version', p_version,
      'environment', p_environment::text, 'is_override', p_is_override,
      'override_reason', p_override_reason));

  RETURN jsonb_build_object('ok', true, 'deployment_id', v_deploy_id,
    'prompt_id', p_prompt_id, 'version', p_version,
    'environment', p_environment::text, 'is_override', p_is_override,
    'audit_event_id', v_audit_row.id);
END;
$function$;
COMMENT ON FUNCTION public.deploy_prompt(uuid, text, text, public.prompt_environment_enum, boolean, text) IS
  'Owner-only RPC. Flips the is_current pointer for (env, prompt_id) and inserts a new prompt_deployments row. Enforces the 7-day soak window for PRODUCTION promotions unless is_override=true with override_reason. Emits AI_PROMPT_DEPLOYED on normal forward deploy, AI_PROMPT_PROMOTION_OVERRIDE_USED on override path, AI_PROMPT_DEPLOY_REJECTED on policy / soak / version failure (Mitigation A).';
REVOKE EXECUTE ON FUNCTION public.deploy_prompt(uuid, text, text, public.prompt_environment_enum, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deploy_prompt(uuid, text, text, public.prompt_environment_enum, boolean, text) TO service_role;

-- ============================================================================
-- 5. rollback_prompt
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rollback_prompt(
  p_actor_user_id   uuid,
  p_prompt_id       text,
  p_environment     public.prompt_environment_enum,
  p_target_version  text,
  p_rollback_reason text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_perm        jsonb;
  v_perm_dec    text;
  v_exists      boolean;
  v_prev_version text;
  v_reject_code text;
  v_reject_msg  text;
  v_audit_row   audit.audit_events;
  v_deploy_id   uuid;
BEGIN
  IF p_actor_user_id IS NULL OR p_prompt_id IS NULL OR p_environment IS NULL
     OR p_target_version IS NULL OR p_rollback_reason IS NULL
     OR length(trim(p_rollback_reason)) = 0 THEN
    RAISE EXCEPTION 'rollback_prompt: required params missing (rollback_reason non-empty required)'
      USING ERRCODE = '22000';
  END IF;

  v_perm := public.can_perform(
    p_actor_user_id => p_actor_user_id, p_surface => 'prompt_deployment',
    p_action => 'rollback',
    p_resource => jsonb_build_object('prompt_id', p_prompt_id, 'environment', p_environment::text,
                                      'target_version', p_target_version),
    p_business_id => NULL, p_organization_id => NULL);
  v_perm_dec := v_perm->>'decision';
  IF v_perm_dec = 'DENY' THEN
    v_reject_code := 'PERMISSION_DENIED';
    v_reject_msg  := format('actor lacks permission prompt_deployment:rollback (reason=%s)',
                             v_perm->>'reason_code');
  ELSIF v_perm_dec NOT IN ('ALLOW','STEP_UP') THEN
    v_reject_code := 'PERMISSION_DENIED';
    v_reject_msg  := format('unexpected can_perform decision: %s', v_perm_dec);
  END IF;

  IF v_reject_code IS NULL THEN
    SELECT EXISTS(SELECT 1 FROM public.prompt_registry
                  WHERE prompt_id = p_prompt_id AND version = p_target_version)
      INTO v_exists;
    IF NOT v_exists THEN
      v_reject_code := 'VERSION_NOT_FOUND';
      v_reject_msg  := format('prompt %s version %s not registered', p_prompt_id, p_target_version);
    END IF;
  END IF;

  IF v_reject_code IS NOT NULL THEN
    v_audit_row := audit.emit_audit(
      p_actor_kind => 'USER'::audit.actor_kind_enum,
      p_action => 'AI_PROMPT_DEPLOY_REJECTED',
      p_subject_type => 'PROMPT'::audit.subject_type_enum,
      p_subject_id => NULL, p_actor_user_id => p_actor_user_id,
      p_reason => v_reject_msg,
      p_after_state => jsonb_build_object(
        'rejection_code', v_reject_code, 'prompt_id', p_prompt_id,
        'target_version', p_target_version, 'environment', p_environment::text,
        'rollback', true));
    RETURN jsonb_build_object('ok', false, 'reason', v_reject_code,
      'message', v_reject_msg, 'audit_event_id', v_audit_row.id);
  END IF;

  SELECT version INTO v_prev_version
    FROM public.prompt_deployments
   WHERE environment = p_environment AND prompt_id = p_prompt_id AND is_current = true;

  UPDATE public.prompt_deployments
     SET is_current = false
   WHERE environment = p_environment AND prompt_id = p_prompt_id AND is_current = true;

  INSERT INTO public.prompt_deployments (
    prompt_id, version, environment, deployed_by_user_id,
    is_current, is_rollback, rollback_reason
  ) VALUES (
    p_prompt_id, p_target_version, p_environment, p_actor_user_id,
    true, true, p_rollback_reason
  ) RETURNING id INTO v_deploy_id;

  v_audit_row := audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'AI_PROMPT_ROLLED_BACK',
    p_subject_type => 'PROMPT'::audit.subject_type_enum,
    p_subject_id => v_deploy_id, p_actor_user_id => p_actor_user_id,
    p_before_state => jsonb_build_object('previous_version', v_prev_version),
    p_after_state => jsonb_build_object(
      'deployment_id', v_deploy_id, 'prompt_id', p_prompt_id, 'version', p_target_version,
      'environment', p_environment::text, 'rollback_reason', p_rollback_reason),
    p_reason => format('prompt %s in %s rolled back from %s to %s: %s',
                        p_prompt_id, p_environment, v_prev_version, p_target_version, p_rollback_reason));

  RETURN jsonb_build_object('ok', true, 'deployment_id', v_deploy_id,
    'prompt_id', p_prompt_id, 'environment', p_environment::text,
    'previous_version', v_prev_version, 'target_version', p_target_version,
    'audit_event_id', v_audit_row.id);
END;
$function$;
COMMENT ON FUNCTION public.rollback_prompt(uuid, text, public.prompt_environment_enum, text, text) IS
  'Owner-only RPC. Flips is_current to a prior version. rollback_reason is mandatory (non-empty). Emits AI_PROMPT_ROLLED_BACK on success, AI_PROMPT_DEPLOY_REJECTED on policy / version failure.';
REVOKE EXECUTE ON FUNCTION public.rollback_prompt(uuid, text, public.prompt_environment_enum, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rollback_prompt(uuid, text, public.prompt_environment_enum, text, text) TO service_role;

-- ============================================================================
-- 6. get_prompt / current_prompt_version (read helpers)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_prompt(p_prompt_id text, p_version text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_row public.prompt_registry%ROWTYPE;
  v_cases jsonb;
BEGIN
  SELECT * INTO v_row FROM public.prompt_registry
    WHERE prompt_id = p_prompt_id AND version = p_version;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'VERSION_NOT_FOUND',
      'prompt_id', p_prompt_id, 'version', p_version);
  END IF;
  SELECT jsonb_agg(jsonb_build_object(
           'case_name', case_name, 'input', input, 'expected_output', expected_output,
           'must_contain_assertions', must_contain_assertions,
           'is_adversarial_anchor', is_adversarial_anchor) ORDER BY case_name)
    INTO v_cases
    FROM public.prompt_test_cases
   WHERE prompt_id = p_prompt_id AND version = p_version;
  RETURN jsonb_build_object('ok', true,
    'prompt_id', v_row.prompt_id, 'version', v_row.version, 'purpose', v_row.purpose,
    'input_schema', v_row.input_schema, 'output_schema', v_row.output_schema,
    'ai_tier', v_row.ai_tier::text, 'prompt_template_text', v_row.prompt_template_text,
    'content_hash', v_row.content_hash, 'registered_at', v_row.registered_at,
    'test_cases', COALESCE(v_cases, '[]'::jsonb));
END;
$$;
COMMENT ON FUNCTION public.get_prompt(text, text) IS
  'Read-only: returns full prompt definition including test corpus. NULL → VERSION_NOT_FOUND envelope.';
REVOKE EXECUTE ON FUNCTION public.get_prompt(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_prompt(text, text) TO service_role;

CREATE OR REPLACE FUNCTION public.current_prompt_version(
  p_prompt_id text, p_environment public.prompt_environment_enum
) RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT version FROM public.prompt_deployments
    WHERE prompt_id = p_prompt_id AND environment = p_environment AND is_current = true;
$$;
COMMENT ON FUNCTION public.current_prompt_version(text, public.prompt_environment_enum) IS
  'Returns the currently-deployed prompt version for (prompt_id, environment), NULL if never deployed.';
REVOKE EXECUTE ON FUNCTION public.current_prompt_version(text, public.prompt_environment_enum) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.current_prompt_version(text, public.prompt_environment_enum) TO service_role;

-- ============================================================================
-- 7. record_prompt_regression_failed — CI signal
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_prompt_regression_failed(
  p_actor_user_id uuid,
  p_prompt_id     text,
  p_version       text,
  p_failed_cases  jsonb,
  p_ci_run_id     text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_count     int;
  v_audit_row audit.audit_events;
  v_kind      audit.actor_kind_enum;
  v_system    text;
BEGIN
  IF p_prompt_id IS NULL OR p_version IS NULL OR p_failed_cases IS NULL THEN
    RAISE EXCEPTION 'record_prompt_regression_failed: required params missing' USING ERRCODE = '22000';
  END IF;
  IF jsonb_typeof(p_failed_cases) <> 'array' OR jsonb_array_length(p_failed_cases) = 0 THEN
    RAISE EXCEPTION 'record_prompt_regression_failed: p_failed_cases must be a non-empty array'
      USING ERRCODE = '22000';
  END IF;
  v_count := jsonb_array_length(p_failed_cases);
  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'prompt_regression_runner';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'AI_PROMPT_REGRESSION_FAILED',
    p_subject_type => 'PROMPT'::audit.subject_type_enum,
    p_subject_id => NULL, p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_reason => format('prompt %s version %s failed regression (%s case(s))',
                        p_prompt_id, p_version, v_count),
    p_after_state => jsonb_build_object(
      'prompt_id', p_prompt_id, 'version', p_version,
      'failed_case_count', v_count, 'failed_cases', p_failed_cases,
      'ci_run_id', p_ci_run_id));
  RETURN jsonb_build_object('ok', true, 'audit_event_id', v_audit_row.id,
    'failed_case_count', v_count);
END;
$function$;
COMMENT ON FUNCTION public.record_prompt_regression_failed(uuid, text, text, jsonb, text) IS
  'CI-callable signal. Emits AI_PROMPT_REGRESSION_FAILED. No can_perform check — it''s a regression-test signal from the CI runner, not a state mutation. Allows SYSTEM actor (NULL p_actor_user_id) for headless CI.';
REVOKE EXECUTE ON FUNCTION public.record_prompt_regression_failed(uuid, text, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_prompt_regression_failed(uuid, text, text, jsonb, text) TO service_role;
