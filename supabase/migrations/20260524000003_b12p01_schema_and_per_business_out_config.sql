-- B12·P01 — Schema & Per-Business OUT Config
-- =====================================================================
-- Block 12 opens. Delivers:
--   * 4 cross-block additions to workflow_runs (Block 12 owns rationale;
--     Block 03 owns the column per spec). trigger_kind already exists.
--   * 2 new enums: workflow_approval_method_enum (STANDARD, STEP_UP)
--     and adjustment_delta_kind_enum (5 values per spec).
--   * 3 new tables: workflow_run_approvals, adjustment_records,
--     out_workflow_business_config — all with RLS (SELECT-only via
--     current_org + current_user_businesses; writes blocked → go through
--     SECURITY DEFINER RPCs).
--   * Bootstrap loader load_out_workflow_config_for_business (idempotent,
--     emits OUT_WORKFLOW_CONFIG_INITIALIZED).
--   * Settings API update_out_workflow_config (OWNER/ADMIN-gated, reuses
--     _ledger_assert_owner_or_admin since it's a generic role check; emits
--     OUT_WORKFLOW_CONFIG_UPDATED with field-level before/after).
--   * get_out_workflow_config STABLE reader.
--   * Type-registration stubs register_out_monthly_type /
--     register_out_adjustment_type — full registration is owned by P02 / P09.
--
-- Pre-existing adjustment_records (placeholder, 0 rows) was DROP CASCADE'd —
-- the dependent add_adjustment_record RPC targeted the old shape with
-- different columns (target_record_id, target_record_type, delta) and would
-- not work against the canonical B12·P01 shape (run_id, parent_run_id,
-- delta_kind enum, delta_payload). Block 12 Phase 09 will deliver the new
-- adjustment RPCs.
--
-- 3 audit actions emitted from this phase (subject_type=BUSINESS or
-- WORKFLOW_CONFIG):
--   OUT_WORKFLOW_CONFIG_INITIALIZED  (BUSINESS, SYSTEM)
--   OUT_WORKFLOW_CONFIG_UPDATED      (BUSINESS, USER)
--   OUT_WORKFLOW_TYPE_REGISTERED     (WORKFLOW_CONFIG, SYSTEM)
-- =====================================================================

BEGIN;

DROP TABLE IF EXISTS public.adjustment_records CASCADE;

-- 1. workflow_runs cross-block additions ----------------------------------

ALTER TABLE public.workflow_runs
  ADD COLUMN paired_run_id          uuid REFERENCES public.workflow_runs(id),
  ADD COLUMN triggered_by_user_id   uuid REFERENCES public.users(id),
  ADD COLUMN triggered_by_event_id  uuid,
  ADD COLUMN manual_trigger_note    text;
CREATE INDEX workflow_runs_paired_run_id_idx ON public.workflow_runs (paired_run_id)
  WHERE paired_run_id IS NOT NULL;
COMMENT ON COLUMN public.workflow_runs.paired_run_id IS
  'Set on the OUT and IN runs created from a single STATEMENT_UPLOAD_COMPLETED event; self-referential FK so the pair is reconstructible without scanning all runs (Block 12 owns rationale; Block 03 owns column per spec).';

-- 2. New enums ------------------------------------------------------------

CREATE TYPE public.workflow_approval_method_enum AS ENUM ('STANDARD','STEP_UP');
CREATE TYPE public.adjustment_delta_kind_enum AS ENUM
  ('RECLASSIFY_TRANSACTION','ADD_EVIDENCE','CORRECT_VAT_TREATMENT','ADJUST_AMOUNT','OTHER');

-- 3. workflow_run_approvals -----------------------------------------------

CREATE TABLE public.workflow_run_approvals (
  id              uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id uuid NOT NULL,
  business_id     uuid NOT NULL,
  run_id          uuid NOT NULL REFERENCES public.workflow_runs(id),
  approved_by     uuid NOT NULL REFERENCES public.users(id),
  approved_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
  approval_method public.workflow_approval_method_enum NOT NULL DEFAULT 'STANDARD',
  approval_note   text,
  revoked_by      uuid REFERENCES public.users(id),
  revoked_at      timestamptz,
  created_at      timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX wra_run_idx ON public.workflow_run_approvals (run_id);
ALTER TABLE public.workflow_run_approvals ENABLE ROW LEVEL SECURITY;
CREATE POLICY wra_select ON public.workflow_run_approvals FOR SELECT
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
CREATE POLICY wra_no_insert ON public.workflow_run_approvals FOR INSERT WITH CHECK (false);
CREATE POLICY wra_no_update ON public.workflow_run_approvals FOR UPDATE USING (false);
CREATE POLICY wra_no_delete ON public.workflow_run_approvals FOR DELETE USING (false);

-- 4. adjustment_records (canonical B12·P01 shape) -------------------------

CREATE TABLE public.adjustment_records (
  id                  uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id     uuid NOT NULL,
  business_id         uuid NOT NULL,
  run_id              uuid NOT NULL REFERENCES public.workflow_runs(id),
  parent_run_id       uuid NOT NULL REFERENCES public.workflow_runs(id),
  parent_period_start date NOT NULL,
  parent_period_end   date NOT NULL,
  reason              text NOT NULL,
  delta_kind          public.adjustment_delta_kind_enum NOT NULL,
  delta_payload       jsonb NOT NULL DEFAULT '{}'::jsonb,
  requesting_user_id  uuid NOT NULL REFERENCES public.users(id),
  created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT adjustment_records_reason_nonempty CHECK (length(trim(reason)) > 0)
);
CREATE INDEX adjustment_records_business_parent_idx ON public.adjustment_records (business_id, parent_run_id);
CREATE INDEX adjustment_records_business_period_idx ON public.adjustment_records (business_id, parent_period_start);
ALTER TABLE public.adjustment_records ENABLE ROW LEVEL SECURITY;
CREATE POLICY ar_select ON public.adjustment_records FOR SELECT
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
CREATE POLICY ar_no_insert ON public.adjustment_records FOR INSERT WITH CHECK (false);
CREATE POLICY ar_no_update ON public.adjustment_records FOR UPDATE USING (false);
CREATE POLICY ar_no_delete ON public.adjustment_records FOR DELETE USING (false);

-- 5. out_workflow_business_config -----------------------------------------

CREATE TABLE public.out_workflow_business_config (
  id              uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id uuid NOT NULL,
  business_id     uuid NOT NULL,
  evidence_discovery_email_enabled    boolean NOT NULL DEFAULT true,
  evidence_discovery_drive_enabled    boolean NOT NULL DEFAULT true,
  manual_upload_hold_reminder_days    int     NOT NULL DEFAULT 7,
  manual_upload_hold_reminder_enabled boolean NOT NULL DEFAULT true,
  auto_start_on_statement_upload      boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at       timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_updated_by  uuid REFERENCES public.users(id),
  CONSTRAINT out_workflow_business_config_business_unique UNIQUE (business_id),
  CONSTRAINT out_workflow_business_config_reminder_days_positive CHECK (manual_upload_hold_reminder_days > 0)
);
CREATE INDEX out_workflow_business_config_business_idx ON public.out_workflow_business_config (business_id);
ALTER TABLE public.out_workflow_business_config ENABLE ROW LEVEL SECURITY;
CREATE POLICY owbc_select ON public.out_workflow_business_config FOR SELECT
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
CREATE POLICY owbc_no_insert ON public.out_workflow_business_config FOR INSERT WITH CHECK (false);
CREATE POLICY owbc_no_update ON public.out_workflow_business_config FOR UPDATE USING (false);
CREATE POLICY owbc_no_delete ON public.out_workflow_business_config FOR DELETE USING (false);

-- 6. Bootstrap loader (idempotent) ---------------------------------------

CREATE OR REPLACE FUNCTION public.load_out_workflow_config_for_business(
  p_organization_id uuid, p_business_id uuid,
  p_actor_user_id uuid DEFAULT NULL, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_existing int; v_config_id uuid;
BEGIN
  SELECT count(*) INTO v_existing FROM public.out_workflow_business_config WHERE business_id = p_business_id;
  IF v_existing > 0 THEN
    RETURN jsonb_build_object('decision','NOOP','reason','already_initialized','business_id',p_business_id);
  END IF;
  v_config_id := public.gen_uuid_v7();
  INSERT INTO public.out_workflow_business_config (id, organization_id, business_id, last_updated_by)
  VALUES (v_config_id, p_organization_id, p_business_id, p_actor_user_id);

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='OUT_WORKFLOW_CONFIG_INITIALIZED',
    p_subject_type:='BUSINESS'::audit.subject_type_enum, p_subject_id:=p_business_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_workflow_bootstrap',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('config_id', v_config_id, 'initiating_user_id', p_actor_user_id),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','INITIALIZED','config_id',v_config_id);
END;
$$;

-- 7. Settings API: update (OWNER/ADMIN) + get ----------------------------

CREATE OR REPLACE FUNCTION public.update_out_workflow_config(
  p_organization_id uuid, p_business_id uuid, p_patch jsonb,
  p_actor_user_id uuid, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_role public.user_role;
  v_before jsonb; v_after jsonb;
  v_email_old boolean; v_email_new boolean;
  v_drive_old boolean; v_drive_new boolean;
  v_days_old int;     v_days_new int;
  v_rem_old boolean;  v_rem_new boolean;
  v_auto_old boolean; v_auto_new boolean;
BEGIN
  v_role := public._ledger_assert_owner_or_admin(p_actor_user_id, p_business_id);

  SELECT evidence_discovery_email_enabled, evidence_discovery_drive_enabled,
         manual_upload_hold_reminder_days, manual_upload_hold_reminder_enabled, auto_start_on_statement_upload
    INTO v_email_old, v_drive_old, v_days_old, v_rem_old, v_auto_old
    FROM public.out_workflow_business_config WHERE business_id = p_business_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'CONFIG_NOT_FOUND' USING errcode='check_violation';
  END IF;

  v_email_new := COALESCE((p_patch->>'evidence_discovery_email_enabled')::boolean, v_email_old);
  v_drive_new := COALESCE((p_patch->>'evidence_discovery_drive_enabled')::boolean, v_drive_old);
  v_days_new  := COALESCE((p_patch->>'manual_upload_hold_reminder_days')::int, v_days_old);
  v_rem_new   := COALESCE((p_patch->>'manual_upload_hold_reminder_enabled')::boolean, v_rem_old);
  v_auto_new  := COALESCE((p_patch->>'auto_start_on_statement_upload')::boolean, v_auto_old);

  UPDATE public.out_workflow_business_config
    SET evidence_discovery_email_enabled = v_email_new,
        evidence_discovery_drive_enabled = v_drive_new,
        manual_upload_hold_reminder_days = v_days_new,
        manual_upload_hold_reminder_enabled = v_rem_new,
        auto_start_on_statement_upload = v_auto_new,
        last_updated_by = p_actor_user_id, updated_at = clock_timestamp()
   WHERE business_id = p_business_id;

  v_before := jsonb_build_object(
    'evidence_discovery_email_enabled', v_email_old,
    'evidence_discovery_drive_enabled', v_drive_old,
    'manual_upload_hold_reminder_days', v_days_old,
    'manual_upload_hold_reminder_enabled', v_rem_old,
    'auto_start_on_statement_upload', v_auto_old);
  v_after := jsonb_build_object(
    'evidence_discovery_email_enabled', v_email_new,
    'evidence_discovery_drive_enabled', v_drive_new,
    'manual_upload_hold_reminder_days', v_days_new,
    'manual_upload_hold_reminder_enabled', v_rem_new,
    'auto_start_on_statement_upload', v_auto_new);

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='OUT_WORKFLOW_CONFIG_UPDATED',
    p_subject_type:='BUSINESS'::audit.subject_type_enum, p_subject_id:=p_business_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=v_role, p_actor_session_id:=NULL,
    p_actor_system:=NULL, p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=v_before, p_after_state:=v_after,
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','UPDATED','before',v_before,'after',v_after);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_out_workflow_config(
  p_organization_id uuid, p_business_id uuid
) RETURNS jsonb LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT to_jsonb(c) FROM public.out_workflow_business_config c WHERE c.business_id = p_business_id;
$$;

-- 8. Type-registration stubs (Phase 02 / Phase 09 own the full registration)

CREATE OR REPLACE FUNCTION public.register_out_monthly_type(
  p_actor_user_id uuid DEFAULT NULL, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
BEGIN
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='OUT_WORKFLOW_TYPE_REGISTERED',
    p_subject_type:='WORKFLOW_CONFIG'::audit.subject_type_enum, p_subject_id:=NULL,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_workflow_boot',
    p_organization_id:=NULL, p_business_id:=NULL,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('workflow_type','OUT_MONTHLY','note','Stub: Phase 02 owns the 12-phase definition'),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','REGISTERED_STUB','workflow_type','OUT_MONTHLY');
END;
$$;

CREATE OR REPLACE FUNCTION public.register_out_adjustment_type(
  p_actor_user_id uuid DEFAULT NULL, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
BEGIN
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='OUT_WORKFLOW_TYPE_REGISTERED',
    p_subject_type:='WORKFLOW_CONFIG'::audit.subject_type_enum, p_subject_id:=NULL,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_workflow_boot',
    p_organization_id:=NULL, p_business_id:=NULL,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('workflow_type','OUT_ADJUSTMENT','note','Stub: Phase 09 owns the 6-phase definition'),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','REGISTERED_STUB','workflow_type','OUT_ADJUSTMENT');
END;
$$;

-- 9. Privileges -----------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.load_out_workflow_config_for_business(uuid, uuid, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.update_out_workflow_config(uuid, uuid, jsonb, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.register_out_monthly_type(uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.register_out_adjustment_type(uuid, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.load_out_workflow_config_for_business(uuid, uuid, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_out_workflow_config(uuid, uuid, jsonb, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_out_workflow_config(uuid, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.register_out_monthly_type(uuid, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.register_out_adjustment_type(uuid, jsonb) TO service_role;

COMMIT;
