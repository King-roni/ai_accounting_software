-- B03·P11 Adjustment Runs
-- =============================================================================
-- Adjustment workflow types end-to-end at the engine level:
-- - Parent-run validation (exists, business match, type match, finalized, within 6 years)
-- - adjustment_records data model with reason + structured delta
-- - intake gate helper (ADVANCE only when ≥1 record exists)
-- - Finalization handoff stub for B15
--
-- Five new audit actions (text):
--   WORKFLOW_ADJUSTMENT_CREATED, WORKFLOW_ADJUSTMENT_RECORD_ADDED,
--   WORKFLOW_ADJUSTMENT_FINALIZED, WORKFLOW_ADJUSTMENT_REJECTED_OUTSIDE_RETENTION,
--   WORKFLOW_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED
-- =============================================================================

CREATE TYPE public.adjustment_target_record_type_enum AS ENUM ('LEDGER_ENTRY','MATCH_RECORD');

CREATE TABLE public.adjustment_records (
  id                  uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  workflow_run_id     uuid NOT NULL REFERENCES public.workflow_runs(id) ON DELETE RESTRICT,
  target_record_id    uuid NOT NULL,
  target_record_type  public.adjustment_target_record_type_enum NOT NULL,
  reason              text NOT NULL,
  delta               jsonb NOT NULL,
  business_id         uuid NOT NULL REFERENCES public.business_entities(id),
  organization_id     uuid NOT NULL REFERENCES public.organizations(id),
  created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_by          uuid REFERENCES public.users(id),
  CONSTRAINT ar_reason_nonempty CHECK (length(btrim(reason)) > 0),
  CONSTRAINT ar_delta_object_nonempty CHECK (jsonb_typeof(delta) = 'object' AND delta <> '{}'::jsonb)
);

CREATE INDEX idx_ar_run      ON public.adjustment_records (workflow_run_id);
CREATE INDEX idx_ar_target   ON public.adjustment_records (target_record_id, target_record_type);
CREATE INDEX idx_ar_business ON public.adjustment_records (business_id);

CREATE OR REPLACE FUNCTION public.fn_check_adjustment_record_run_type()
RETURNS trigger LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $fn$
DECLARE v_type public.workflow_type_enum;
BEGIN
  SELECT workflow_type INTO v_type FROM public.workflow_runs WHERE id = NEW.workflow_run_id;
  IF v_type IS NULL THEN
    RAISE EXCEPTION 'adjustment_records: workflow_run % not found', NEW.workflow_run_id USING ERRCODE='P0002';
  END IF;
  IF v_type NOT IN ('OUT_ADJUSTMENT','IN_ADJUSTMENT') THEN
    RAISE EXCEPTION 'adjustment_records: workflow_run % is type % (must be OUT_ADJUSTMENT or IN_ADJUSTMENT)', NEW.workflow_run_id, v_type
      USING ERRCODE='P0001';
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_ar_run_type
  BEFORE INSERT OR UPDATE OF workflow_run_id ON public.adjustment_records
  FOR EACH ROW EXECUTE FUNCTION public.fn_check_adjustment_record_run_type();

ALTER TABLE public.adjustment_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.adjustment_records FORCE  ROW LEVEL SECURITY;
CREATE POLICY ar_select_tenancy ON public.adjustment_records AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY ar_no_insert      ON public.adjustment_records AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY ar_no_update      ON public.adjustment_records AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY ar_no_delete      ON public.adjustment_records AS RESTRICTIVE FOR DELETE TO authenticated USING (false);
GRANT SELECT ON public.adjustment_records TO authenticated, service_role;

-- ---- Refined trigger_run_manual --------------------------------------------
CREATE OR REPLACE FUNCTION public.trigger_run_manual(
  p_actor_user_id      uuid,
  p_business_id        uuid,
  p_workflow_type      public.workflow_type_enum,
  p_period_start       timestamptz,
  p_period_end         timestamptz,
  p_principal_snapshot jsonb,
  p_parent_run_id      uuid DEFAULT NULL,
  p_context            jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_biz       public.business_entities;
  v_def_exists boolean;
  v_perm      jsonb;
  v_perm_dec  text;
  v_active    integer;
  v_run_id    uuid;
  v_reject_code text;
  v_reject_msg  text;
  v_is_adjustment boolean;
  v_specific_audit text;
  v_parent    public.workflow_runs;
  v_expected_parent_type public.workflow_type_enum;
BEGIN
  IF p_actor_user_id IS NULL OR p_business_id IS NULL OR p_workflow_type IS NULL
     OR p_period_start IS NULL OR p_period_end IS NULL OR p_principal_snapshot IS NULL THEN
    RAISE EXCEPTION 'trigger_run_manual: required params missing' USING ERRCODE='22000';
  END IF;

  v_is_adjustment := p_workflow_type IN ('OUT_ADJUSTMENT'::public.workflow_type_enum, 'IN_ADJUSTMENT'::public.workflow_type_enum);
  v_expected_parent_type := CASE p_workflow_type
                              WHEN 'OUT_ADJUSTMENT' THEN 'OUT_MONTHLY'::public.workflow_type_enum
                              WHEN 'IN_ADJUSTMENT'  THEN 'IN_MONTHLY'::public.workflow_type_enum
                              ELSE NULL END;

  PERFORM public._acquire_trigger_lock(p_business_id, p_workflow_type);

  SELECT * INTO v_biz FROM public.business_entities WHERE id = p_business_id;
  IF NOT FOUND THEN
    v_reject_code := 'BUSINESS_NOT_FOUND';
    v_reject_msg  := format('business %s not found', p_business_id);
  END IF;

  IF v_reject_code IS NULL THEN
    SELECT EXISTS(SELECT 1 FROM public.workflow_type_definitions WHERE workflow_type = p_workflow_type) INTO v_def_exists;
    IF NOT v_def_exists THEN
      v_reject_code := 'UNKNOWN_TYPE';
      v_reject_msg  := format('workflow_type %s not registered', p_workflow_type);
    END IF;
  END IF;

  IF v_reject_code IS NULL THEN
    v_perm := public.can_perform(
      p_actor_user_id   => p_actor_user_id,
      p_surface         => 'workflow_run',
      p_action          => 'execute',
      p_resource        => jsonb_build_object('workflow_type', p_workflow_type, 'business_id', p_business_id),
      p_business_id     => p_business_id,
      p_organization_id => v_biz.organization_id
    );
    v_perm_dec := v_perm->>'decision';
    IF v_perm_dec = 'DENY' THEN
      v_reject_code := 'PERMISSION_DENIED';
      v_reject_msg  := format('actor lacks permission workflow_run:execute (reason=%s)', v_perm->>'reason_code');
    ELSIF v_perm_dec NOT IN ('ALLOW','STEP_UP') THEN
      v_reject_code := 'PERMISSION_DENIED';
      v_reject_msg  := format('unexpected can_perform decision: %s', v_perm_dec);
    END IF;
  END IF;

  IF v_reject_code IS NULL AND v_is_adjustment AND p_parent_run_id IS NULL THEN
    v_reject_code := 'PARENT_REQUIRED';
    v_reject_msg  := format('adjustment workflow %s requires parent_run_id', p_workflow_type);
  END IF;

  -- P11: deep parent validation
  IF v_reject_code IS NULL AND v_is_adjustment THEN
    SELECT * INTO v_parent FROM public.workflow_runs WHERE id = p_parent_run_id;
    IF NOT FOUND THEN
      v_reject_code := 'PARENT_NOT_FOUND';
      v_reject_msg  := format('parent_run_id %s not found', p_parent_run_id);
    ELSIF v_parent.business_id <> p_business_id THEN
      v_reject_code := 'PARENT_BUSINESS_MISMATCH';
      v_reject_msg  := format('parent run business %s ≠ target business %s', v_parent.business_id, p_business_id);
    ELSIF v_parent.workflow_type <> v_expected_parent_type THEN
      v_reject_code := 'PARENT_TYPE_MISMATCH';
      v_reject_msg  := format('parent run type %s ≠ expected %s for adjustment %s',
                              v_parent.workflow_type, v_expected_parent_type, p_workflow_type);
    ELSIF v_parent.status <> 'FINALIZED'::public.workflow_run_status_enum THEN
      v_reject_code := 'PARENT_NOT_FINALIZED';
      v_reject_msg  := format('parent run %s status is %s (must be FINALIZED)', p_parent_run_id, v_parent.status);
      v_specific_audit := 'WORKFLOW_ADJUSTMENT_REJECTED_PARENT_NOT_FINALIZED';
    ELSIF v_parent.finalized_at < clock_timestamp() - interval '6 years' THEN
      v_reject_code := 'PARENT_OUTSIDE_RETENTION';
      v_reject_msg  := format('parent run finalized at %s is outside the 6-year retention window', v_parent.finalized_at);
      v_specific_audit := 'WORKFLOW_ADJUSTMENT_REJECTED_OUTSIDE_RETENTION';
    END IF;
  END IF;

  IF v_reject_code IS NULL THEN
    IF v_is_adjustment THEN
      SELECT count(*) INTO v_active
        FROM public.workflow_runs
       WHERE business_id = p_business_id
         AND workflow_type = p_workflow_type
         AND parent_run_id IS NOT DISTINCT FROM p_parent_run_id
         AND status NOT IN ('FINALIZED','ABORTED','FAILED','CANCELLED');
      IF v_active > 0 THEN
        v_reject_code := 'DUPLICATE_ADJUSTMENT';
        v_reject_msg  := format('active adjustment exists for business %s + type %s + parent %s',
                                p_business_id, p_workflow_type, p_parent_run_id);
        v_specific_audit := 'WORKFLOW_RUN_REJECTED_DUPLICATE_ADJUSTMENT';
      END IF;
    ELSE
      SELECT count(*) INTO v_active
        FROM public.workflow_runs
       WHERE business_id = p_business_id
         AND workflow_type = p_workflow_type
         AND status NOT IN ('FINALIZED','ABORTED','FAILED','CANCELLED');
      IF v_active > 0 THEN
        v_reject_code := 'DUPLICATE_ACTIVE';
        v_reject_msg  := format('active run exists for business %s + type %s', p_business_id, p_workflow_type);
        v_specific_audit := 'WORKFLOW_RUN_REJECTED_DUPLICATE';
      END IF;
    END IF;
  END IF;

  IF v_reject_code IS NOT NULL THEN
    PERFORM audit.emit_audit(
      p_actor_kind     => 'USER'::audit.actor_kind_enum,
      p_action         => 'WORKFLOW_RUN_TRIGGER_REJECTED',
      p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
      p_subject_id     => NULL,
      p_business_id    => p_business_id,
      p_organization_id=> v_biz.organization_id,
      p_actor_user_id  => p_actor_user_id,
      p_reason         => v_reject_msg,
      p_after_state    => jsonb_build_object(
        'rejection_code', v_reject_code, 'business_id', p_business_id,
        'workflow_type', p_workflow_type::text, 'trigger_kind', 'MANUAL',
        'parent_run_id', p_parent_run_id, 'context', p_context
      )
    );
    IF v_specific_audit IS NOT NULL THEN
      PERFORM audit.emit_audit(
        p_actor_kind     => 'USER'::audit.actor_kind_enum,
        p_action         => v_specific_audit,
        p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
        p_subject_id     => NULL,
        p_business_id    => p_business_id,
        p_organization_id=> v_biz.organization_id,
        p_actor_user_id  => p_actor_user_id,
        p_reason         => v_reject_msg,
        p_after_state    => jsonb_build_object(
          'rejection_code', v_reject_code, 'business_id', p_business_id,
          'workflow_type', p_workflow_type::text, 'parent_run_id', p_parent_run_id,
          'parent_finalized_at', CASE WHEN v_parent.id IS NOT NULL THEN to_jsonb(v_parent.finalized_at) ELSE NULL END
        )
      );
    END IF;
    RETURN jsonb_build_object('ok', false, 'reason', v_reject_code, 'message', v_reject_msg);
  END IF;

  INSERT INTO public.workflow_runs (
    organization_id, business_id, principal_snapshot, workflow_type,
    period_start, period_end, started_by, parent_run_id,
    trigger_kind, trigger_event_id
  ) VALUES (
    v_biz.organization_id, p_business_id, p_principal_snapshot, p_workflow_type,
    p_period_start, p_period_end, p_actor_user_id, p_parent_run_id,
    'MANUAL'::public.trigger_kind_enum, NULL
  )
  RETURNING id INTO v_run_id;

  PERFORM audit.emit_audit(
    p_actor_kind     => 'USER'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_RUN_TRIGGERED_MANUAL',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => v_run_id,
    p_business_id    => p_business_id,
    p_organization_id=> v_biz.organization_id,
    p_actor_user_id  => p_actor_user_id,
    p_reason         => format('manual trigger of %s for business %s', p_workflow_type, p_business_id),
    p_after_state    => jsonb_build_object(
      'run_id', v_run_id, 'workflow_type', p_workflow_type::text,
      'business_id', p_business_id, 'period_start', p_period_start,
      'period_end', p_period_end, 'parent_run_id', p_parent_run_id, 'trigger_kind', 'MANUAL'
    )
  );

  IF v_is_adjustment THEN
    PERFORM audit.emit_audit(
      p_actor_kind     => 'USER'::audit.actor_kind_enum,
      p_action         => 'WORKFLOW_ADJUSTMENT_CREATED',
      p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
      p_subject_id     => v_run_id,
      p_business_id    => p_business_id,
      p_organization_id=> v_biz.organization_id,
      p_actor_user_id  => p_actor_user_id,
      p_reason         => format('adjustment %s created against parent %s', p_workflow_type, p_parent_run_id),
      p_after_state    => jsonb_build_object(
        'run_id', v_run_id, 'workflow_type', p_workflow_type::text,
        'parent_run_id', p_parent_run_id,
        'parent_finalized_at', v_parent.finalized_at,
        'retention_window_years', 6
      )
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'run_id', v_run_id, 'trigger_kind', 'MANUAL');
END;
$fn$;

-- ---- add_adjustment_record -------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_adjustment_record(
  p_run_id             uuid,
  p_target_record_id   uuid,
  p_target_record_type public.adjustment_target_record_type_enum,
  p_reason             text,
  p_delta              jsonb,
  p_actor_user_id      uuid
) RETURNS public.adjustment_records
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_run     public.workflow_runs;
  v_record  public.adjustment_records;
BEGIN
  IF p_run_id IS NULL OR p_target_record_id IS NULL OR p_target_record_type IS NULL
     OR p_reason IS NULL OR p_delta IS NULL OR p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'add_adjustment_record: required params missing' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'add_adjustment_record: run % not found', p_run_id USING ERRCODE='P0002'; END IF;
  IF v_run.workflow_type NOT IN ('OUT_ADJUSTMENT','IN_ADJUSTMENT') THEN
    RAISE EXCEPTION 'add_adjustment_record: run % is type % (must be adjustment)', p_run_id, v_run.workflow_type USING ERRCODE='P0001';
  END IF;
  IF v_run.status NOT IN ('RUNNING','REVIEW_HOLD','PAUSED') THEN
    RAISE EXCEPTION 'add_adjustment_record: run % status % does not accept new records', p_run_id, v_run.status USING ERRCODE='P0001';
  END IF;

  INSERT INTO public.adjustment_records (
    workflow_run_id, target_record_id, target_record_type, reason, delta,
    business_id, organization_id, created_by
  ) VALUES (
    p_run_id, p_target_record_id, p_target_record_type, p_reason, p_delta,
    v_run.business_id, v_run.organization_id, p_actor_user_id
  )
  RETURNING * INTO v_record;

  PERFORM audit.emit_audit(
    p_actor_kind     => 'USER'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_ADJUSTMENT_RECORD_ADDED',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => p_run_id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_user_id  => p_actor_user_id,
    p_reason         => format('adjustment record added for %s %s', p_target_record_type, p_target_record_id),
    p_after_state    => jsonb_build_object(
      'run_id',               p_run_id,
      'adjustment_record_id', v_record.id,
      'target_record_id',     p_target_record_id,
      'target_record_type',   p_target_record_type::text,
      'reason_excerpt',       left(p_reason, 200),
      'delta_keys',           (SELECT array_agg(k) FROM jsonb_object_keys(p_delta) AS k)
    )
  );

  RETURN v_record;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.add_adjustment_record(uuid, uuid, public.adjustment_target_record_type_enum, text, jsonb, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.add_adjustment_record(uuid, uuid, public.adjustment_target_record_type_enum, text, jsonb, uuid) TO authenticated, service_role;

-- ---- check_adjustment_intake_gate ------------------------------------------
CREATE OR REPLACE FUNCTION public.check_adjustment_intake_gate(p_run_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE v_cnt integer;
BEGIN
  IF p_run_id IS NULL THEN
    RAISE EXCEPTION 'check_adjustment_intake_gate: run_id required' USING ERRCODE='22000';
  END IF;
  SELECT count(*) INTO v_cnt FROM public.adjustment_records WHERE workflow_run_id = p_run_id;
  IF v_cnt > 0 THEN
    RETURN jsonb_build_object('decision', 'ADVANCE', 'record_count', v_cnt);
  END IF;
  RETURN jsonb_build_object('decision', 'HOLD',
                            'reason', 'ADJUSTMENT_INTAKE: at least one adjustment_record with reason + delta is required',
                            'record_count', 0);
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.check_adjustment_intake_gate(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.check_adjustment_intake_gate(uuid) TO authenticated, service_role;

-- ---- record_adjustment_finalization_handoff --------------------------------
CREATE OR REPLACE FUNCTION public.record_adjustment_finalization_handoff(
  p_run_id        uuid,
  p_actor_user_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_run          public.workflow_runs;
  v_record_count integer;
  v_target_types text[];
  v_audit        audit.audit_events;
BEGIN
  IF p_run_id IS NULL OR p_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'record_adjustment_finalization_handoff: run_id + actor required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'record_adjustment_finalization_handoff: run % not found', p_run_id USING ERRCODE='P0002'; END IF;
  IF v_run.workflow_type NOT IN ('OUT_ADJUSTMENT','IN_ADJUSTMENT') THEN
    RAISE EXCEPTION 'record_adjustment_finalization_handoff: run % is type % (must be adjustment)', p_run_id, v_run.workflow_type USING ERRCODE='P0001';
  END IF;

  SELECT count(*), array_agg(DISTINCT target_record_type::text)
    INTO v_record_count, v_target_types
    FROM public.adjustment_records WHERE workflow_run_id = p_run_id;

  v_audit := audit.emit_audit(
    p_actor_kind     => 'USER'::audit.actor_kind_enum,
    p_action         => 'WORKFLOW_ADJUSTMENT_FINALIZED',
    p_subject_type   => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id     => p_run_id,
    p_business_id    => v_run.business_id,
    p_organization_id=> v_run.organization_id,
    p_actor_user_id  => p_actor_user_id,
    p_reason         => format('adjustment %s finalization handoff (%s records, types=%s)',
                               v_run.workflow_type, COALESCE(v_record_count, 0), v_target_types),
    p_after_state    => jsonb_build_object(
      'run_id',        p_run_id,
      'workflow_type', v_run.workflow_type::text,
      'parent_run_id', v_run.parent_run_id,
      'record_count',  COALESCE(v_record_count, 0),
      'target_types',  to_jsonb(COALESCE(v_target_types, ARRAY[]::text[])),
      'b15_handoff',   'pending — B15 will swap this stub with archive-additive write'
    )
  );
  RETURN jsonb_build_object('audit_event_id', v_audit.event_id, 'record_count', COALESCE(v_record_count, 0));
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.record_adjustment_finalization_handoff(uuid, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.record_adjustment_finalization_handoff(uuid, uuid) TO authenticated, service_role;

COMMENT ON TABLE public.adjustment_records IS
'B03·P11 adjustment record schema. Each row is an explicit reason + structured delta amending a target record (LEDGER_ENTRY, MATCH_RECORD). Trigger enforces workflow_run_id references an adjustment-typed run.';

COMMENT ON FUNCTION public.trigger_run_manual(uuid, uuid, public.workflow_type_enum, timestamptz, timestamptz, jsonb, uuid, jsonb) IS
'B03·P09+P10+P11 manual trigger chokepoint. Codes: BUSINESS_NOT_FOUND, UNKNOWN_TYPE, PERMISSION_DENIED, PARENT_REQUIRED, PARENT_NOT_FOUND, PARENT_BUSINESS_MISMATCH, PARENT_TYPE_MISMATCH, PARENT_NOT_FINALIZED, PARENT_OUTSIDE_RETENTION, DUPLICATE_ACTIVE, DUPLICATE_ADJUSTMENT. On adjustment success emits both WORKFLOW_RUN_TRIGGERED_MANUAL and WORKFLOW_ADJUSTMENT_CREATED.';

COMMENT ON FUNCTION public.check_adjustment_intake_gate(uuid) IS
'B03·P11 exit gate for ADJUSTMENT_INTAKE/DRAFT phase. ADVANCE iff ≥1 adjustment_record exists for the run. Engine code-side wraps this in a B03·P05 record_gate_decision call.';

COMMENT ON FUNCTION public.record_adjustment_finalization_handoff(uuid, uuid) IS
'B03·P11 stub for B15 archive-additive handoff. Emits WORKFLOW_ADJUSTMENT_FINALIZED with record summary. Block 15 will hook-swap to write to the actual archive bundle; the audit payload captures everything B15 needs.';
