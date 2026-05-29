-- ============================================================================
-- Block 13 Phase 05 (BOOK-120) — Recurring Templates & Daily Scheduler
-- ============================================================================

-- ---- 1. Enums --------------------------------------------------------------

CREATE TYPE public.recurring_cadence_kind_enum AS ENUM (
  'WEEKLY','BIWEEKLY','MONTHLY','QUARTERLY','SEMI_ANNUAL','ANNUAL'
);

CREATE TYPE public.recurring_template_status_enum AS ENUM (
  'ACTIVE','PAUSED','ENDED'
);

CREATE TYPE public.recurring_run_outcome_enum AS ENUM (
  'GENERATED','SKIPPED','FAILED'
);

-- ---- 2. recurring_invoice_templates ----------------------------------------

CREATE TABLE public.recurring_invoice_templates (
  id              uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  organization_id uuid NOT NULL,
  business_id     uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE RESTRICT,
  client_id       uuid NOT NULL REFERENCES public.clients(id)            ON DELETE RESTRICT,

  template_name   text NOT NULL CHECK (length(trim(template_name)) > 0 AND length(template_name) <= 256),

  -- Composition snapshot
  invoice_type            public.invoice_type_enum NOT NULL,
  currency                text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  vat_treatment_per_line  boolean NOT NULL DEFAULT false,
  default_vat_treatment   public.vat_treatment_enum NULL,
  payment_terms_days      int NOT NULL DEFAULT 30 CHECK (payment_terms_days BETWEEN 1 AND 365),
  lines_payload           jsonb NOT NULL,

  -- Cadence
  cadence_kind                 public.recurring_cadence_kind_enum NOT NULL,
  cadence_anchor_day_of_period int NOT NULL CHECK (cadence_anchor_day_of_period BETWEEN 1 AND 31),
  next_due_date                date NOT NULL,
  start_date                   date NOT NULL,
  end_date                     date NULL,

  -- Auto-send + pro-forma expiry
  auto_send               boolean NOT NULL DEFAULT false,
  auto_send_target_email  text NULL,
  pro_forma_expiry_days   int NOT NULL DEFAULT 30 CHECK (pro_forma_expiry_days BETWEEN 1 AND 365),

  -- Lifecycle
  status      public.recurring_template_status_enum NOT NULL DEFAULT 'ACTIVE',
  paused_at   timestamptz NULL,
  paused_by   uuid NULL,
  ended_at    timestamptz NULL,
  ended_by    uuid NULL,

  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid NOT NULL,

  CONSTRAINT rit_lines_payload_is_array_chk CHECK (jsonb_typeof(lines_payload) = 'array'),
  CONSTRAINT rit_lines_payload_nonempty_chk CHECK (jsonb_array_length(lines_payload) > 0),
  CONSTRAINT rit_paused_xor_chk CHECK ((paused_at IS NULL) = (paused_by IS NULL)),
  CONSTRAINT rit_ended_xor_chk  CHECK ((ended_at  IS NULL) = (ended_by  IS NULL)),
  CONSTRAINT rit_status_paused_coh_chk CHECK (status <> 'PAUSED' OR paused_at IS NOT NULL),
  CONSTRAINT rit_status_ended_coh_chk  CHECK (status <> 'ENDED'  OR ended_at  IS NOT NULL),
  CONSTRAINT rit_end_date_after_start_chk CHECK (end_date IS NULL OR end_date >= start_date),
  CONSTRAINT rit_vat_treatment_shape_chk CHECK (
    (vat_treatment_per_line = false AND default_vat_treatment IS NOT NULL)
    OR (vat_treatment_per_line = true AND default_vat_treatment IS NULL)
  ),
  CONSTRAINT rit_default_vat_not_acquisition_chk CHECK (
    default_vat_treatment IS NULL OR default_vat_treatment <> 'IMPORT_OR_ACQUISITION'
  )
);

CREATE INDEX rit_scheduler_hot_idx ON public.recurring_invoice_templates(business_id, status, next_due_date);
CREATE INDEX rit_business_client_idx ON public.recurring_invoice_templates(business_id, client_id);

COMMENT ON TABLE public.recurring_invoice_templates IS
  'Block 13 P05 — recurring-invoice template. lines_payload jsonb array of {description,quantity,unit_price,vat_treatment?,vat_rate_pct?,vat_amount?}.';

-- ---- 3. recurring_invoice_runs ---------------------------------------------

CREATE TABLE public.recurring_invoice_runs (
  id                    uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  organization_id       uuid NOT NULL,
  business_id           uuid NOT NULL,
  template_id           uuid NOT NULL REFERENCES public.recurring_invoice_templates(id) ON DELETE CASCADE,
  due_date              date NOT NULL,
  generated_invoice_id  uuid NULL REFERENCES public.invoices(id) ON DELETE SET NULL,
  outcome               public.recurring_run_outcome_enum NOT NULL,
  error_message         text NULL,
  run_at                timestamptz NOT NULL DEFAULT now(),
  scheduled_at          timestamptz NOT NULL,

  CONSTRAINT rir_failed_has_error_chk CHECK (
    outcome <> 'FAILED' OR (error_message IS NOT NULL AND length(error_message) > 0)
  ),
  CONSTRAINT rir_generated_has_invoice_chk CHECK (
    outcome <> 'GENERATED' OR generated_invoice_id IS NOT NULL
  )
);

-- Partial unique: GENERATED rows deduped per (template_id, due_date); FAILED rows stack.
CREATE UNIQUE INDEX rir_generated_dedup_uniq
  ON public.recurring_invoice_runs(template_id, due_date) WHERE outcome = 'GENERATED';
CREATE INDEX rir_business_run_at_idx ON public.recurring_invoice_runs(business_id, run_at);
CREATE INDEX rir_template_idx        ON public.recurring_invoice_runs(template_id);

COMMENT ON TABLE public.recurring_invoice_runs IS
  'Block 13 P05 — per-template per-due-date run log. UNIQUE GENERATED rows enforce idempotency; FAILED rows stack until success.';

-- ---- 4. Cross-block: invoices.pro_forma_expires_at + default trigger ----

ALTER TABLE public.invoices
  ADD COLUMN pro_forma_expires_at timestamptz NULL;

ALTER TABLE public.invoices
  ADD CONSTRAINT invoices_pro_forma_expires_only_chk CHECK (
    pro_forma_expires_at IS NULL OR invoice_type = 'PRO_FORMA'
  );

CREATE OR REPLACE FUNCTION public.fn_default_pro_forma_expires_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.invoice_type = 'PRO_FORMA' AND NEW.pro_forma_expires_at IS NULL THEN
    NEW.pro_forma_expires_at := (NEW.issue_date + 30)::timestamptz;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_default_pro_forma_expires_at
  BEFORE INSERT ON public.invoices
  FOR EACH ROW EXECUTE FUNCTION public.fn_default_pro_forma_expires_at();

COMMENT ON COLUMN public.invoices.pro_forma_expires_at IS
  'Block 13 P05 — pro-forma terminal-state trigger date. Only set when invoice_type=PRO_FORMA. Default issue_date+30d via trg_default_pro_forma_expires_at.';

-- ---- 5. RLS -------------------------------------------------------------

ALTER TABLE public.recurring_invoice_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recurring_invoice_templates FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.recurring_invoice_runs       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.recurring_invoice_runs       FORCE  ROW LEVEL SECURITY;

CREATE POLICY rit_select_tenant ON public.recurring_invoice_templates
  FOR SELECT TO authenticated USING (business_id = ANY (public.current_user_businesses()));
CREATE POLICY rit_deny_insert ON public.recurring_invoice_templates FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY rit_deny_update ON public.recurring_invoice_templates FOR UPDATE TO authenticated USING (false);
CREATE POLICY rit_deny_delete ON public.recurring_invoice_templates FOR DELETE TO authenticated USING (false);

CREATE POLICY rir_select_tenant ON public.recurring_invoice_runs
  FOR SELECT TO authenticated USING (business_id = ANY (public.current_user_businesses()));
CREATE POLICY rir_deny_insert ON public.recurring_invoice_runs FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY rir_deny_update ON public.recurring_invoice_runs FOR UPDATE TO authenticated USING (false);
CREATE POLICY rir_deny_delete ON public.recurring_invoice_runs FOR DELETE TO authenticated USING (false);

-- ---- 6. Cadence math helper ---------------------------------------------

CREATE OR REPLACE FUNCTION public.recurring_template_compute_next_due_date(
  p_cadence_kind public.recurring_cadence_kind_enum,
  p_base_date    date,
  p_anchor_day   int
) RETURNS date
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_target_month_start date;
  v_days_in_month      int;
  v_effective_day      int;
  v_months_ahead       int;
BEGIN
  IF p_cadence_kind = 'WEEKLY' THEN
    RETURN p_base_date + 7;
  ELSIF p_cadence_kind = 'BIWEEKLY' THEN
    RETURN p_base_date + 14;
  END IF;

  v_months_ahead := CASE p_cadence_kind
    WHEN 'MONTHLY'     THEN 1
    WHEN 'QUARTERLY'   THEN 3
    WHEN 'SEMI_ANNUAL' THEN 6
    WHEN 'ANNUAL'      THEN 12
    ELSE 1
  END;

  v_target_month_start := (date_trunc('month', p_base_date) + (v_months_ahead || ' months')::interval)::date;
  v_days_in_month := EXTRACT(DAY FROM (v_target_month_start + interval '1 month - 1 day'))::int;
  v_effective_day := LEAST(p_anchor_day, v_days_in_month);

  RETURN make_date(
    EXTRACT(YEAR  FROM v_target_month_start)::int,
    EXTRACT(MONTH FROM v_target_month_start)::int,
    v_effective_day
  );
END;
$$;

-- ---- 7. RPCs (template_create / update / pause / resume / end,
--           invoice_mark_pro_forma_expired, recurring_run_daily_scheduler) --

-- (See the applied migration in the live database — the bodies are identical
-- to this file's section; the canonical source for the function bodies is the
-- mcp__claude_ai_Supabase__apply_migration call that produced the live state.)
-- ============================================================================
-- recurring_template_create
CREATE OR REPLACE FUNCTION public.recurring_template_create(
  p_actor_user_id  uuid,
  p_organization_id uuid,
  p_business_id    uuid,
  p_client_id      uuid,
  p_template_name  text,
  p_invoice_type   public.invoice_type_enum,
  p_currency       text,
  p_vat_treatment_per_line boolean,
  p_default_vat_treatment  public.vat_treatment_enum,
  p_payment_terms_days int,
  p_lines_payload  jsonb,
  p_cadence_kind   public.recurring_cadence_kind_enum,
  p_cadence_anchor_day_of_period int,
  p_start_date     date,
  p_end_date       date,
  p_auto_send      boolean,
  p_auto_send_target_email text,
  p_pro_forma_expiry_days int,
  p_context        jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_decision  jsonb;
  v_id        uuid := gen_uuid_v7();
BEGIN
  v_decision := public.can_perform(p_actor_user_id,'INVOICE_MANAGE','CREATE_RECURRING_TEMPLATE',
    jsonb_build_object('client_id', p_client_id), p_business_id, p_organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision',
      'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;
  IF p_lines_payload IS NULL OR jsonb_typeof(p_lines_payload) <> 'array' OR jsonb_array_length(p_lines_payload) = 0 THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','LINES_PAYLOAD_REQUIRED');
  END IF;

  INSERT INTO public.recurring_invoice_templates (
    id, organization_id, business_id, client_id, template_name,
    invoice_type, currency, vat_treatment_per_line, default_vat_treatment,
    payment_terms_days, lines_payload,
    cadence_kind, cadence_anchor_day_of_period, next_due_date, start_date, end_date,
    auto_send, auto_send_target_email, pro_forma_expiry_days,
    status, created_by, updated_by
  ) VALUES (
    v_id, p_organization_id, p_business_id, p_client_id, p_template_name,
    p_invoice_type, p_currency, p_vat_treatment_per_line, p_default_vat_treatment,
    COALESCE(p_payment_terms_days, 30), p_lines_payload,
    p_cadence_kind, p_cadence_anchor_day_of_period, p_start_date, p_start_date, p_end_date,
    COALESCE(p_auto_send, false), p_auto_send_target_email, COALESCE(p_pro_forma_expiry_days, 30),
    'ACTIVE', p_actor_user_id, p_actor_user_id
  );

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='RECURRING_INVOICE_TEMPLATE_CREATED',
    p_subject_type:='RECURRING_INVOICE_TEMPLATE'::audit.subject_type_enum, p_subject_id:=v_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state :=jsonb_build_object('template_id', v_id, 'client_id', p_client_id,
      'cadence_kind', p_cadence_kind::text, 'anchor_day', p_cadence_anchor_day_of_period,
      'start_date', p_start_date, 'end_date', p_end_date, 'auto_send', p_auto_send,
      'invoice_type', p_invoice_type::text),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','ALLOW','template_id', v_id, 'next_due_date', p_start_date);
END;
$function$;

-- recurring_template_update
CREATE OR REPLACE FUNCTION public.recurring_template_update(
  p_actor_user_id uuid,
  p_template_id   uuid,
  p_template_name text DEFAULT NULL,
  p_payment_terms_days int DEFAULT NULL,
  p_lines_payload jsonb DEFAULT NULL,
  p_cadence_kind  public.recurring_cadence_kind_enum DEFAULT NULL,
  p_cadence_anchor_day_of_period int DEFAULT NULL,
  p_end_date      date DEFAULT NULL,
  p_auto_send     boolean DEFAULT NULL,
  p_pro_forma_expiry_days int DEFAULT NULL,
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_tpl public.recurring_invoice_templates%ROWTYPE;
  v_decision jsonb;
  v_diff jsonb := '{}'::jsonb;
  v_new_next_due date;
  v_cadence_changed boolean := false;
BEGIN
  SELECT * INTO v_tpl FROM public.recurring_invoice_templates WHERE id = p_template_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','TEMPLATE_NOT_FOUND'); END IF;
  v_decision := public.can_perform(p_actor_user_id,'INVOICE_MANAGE','UPDATE_RECURRING_TEMPLATE',
    jsonb_build_object('template_id', p_template_id), v_tpl.business_id, v_tpl.organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision',
      'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;
  IF v_tpl.status = 'ENDED' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','TEMPLATE_ENDED');
  END IF;

  IF p_template_name IS NOT NULL AND p_template_name <> v_tpl.template_name THEN
    v_diff := v_diff || jsonb_build_object('template_name', jsonb_build_object('old', v_tpl.template_name, 'new', p_template_name));
  END IF;
  IF p_payment_terms_days IS NOT NULL AND p_payment_terms_days IS DISTINCT FROM v_tpl.payment_terms_days THEN
    v_diff := v_diff || jsonb_build_object('payment_terms_days', jsonb_build_object('old', v_tpl.payment_terms_days, 'new', p_payment_terms_days));
  END IF;
  IF p_lines_payload IS NOT NULL THEN
    v_diff := v_diff || jsonb_build_object('lines_payload_changed', true);
  END IF;
  IF p_cadence_kind IS NOT NULL AND p_cadence_kind <> v_tpl.cadence_kind THEN
    v_diff := v_diff || jsonb_build_object('cadence_kind', jsonb_build_object('old', v_tpl.cadence_kind::text, 'new', p_cadence_kind::text));
    v_cadence_changed := true;
  END IF;
  IF p_cadence_anchor_day_of_period IS NOT NULL AND p_cadence_anchor_day_of_period IS DISTINCT FROM v_tpl.cadence_anchor_day_of_period THEN
    v_diff := v_diff || jsonb_build_object('cadence_anchor_day_of_period', jsonb_build_object('old', v_tpl.cadence_anchor_day_of_period, 'new', p_cadence_anchor_day_of_period));
    v_cadence_changed := true;
  END IF;
  IF p_end_date IS NOT NULL AND p_end_date IS DISTINCT FROM v_tpl.end_date THEN
    v_diff := v_diff || jsonb_build_object('end_date', jsonb_build_object('old', v_tpl.end_date, 'new', p_end_date));
  END IF;
  IF p_auto_send IS NOT NULL AND p_auto_send IS DISTINCT FROM v_tpl.auto_send THEN
    v_diff := v_diff || jsonb_build_object('auto_send', jsonb_build_object('old', v_tpl.auto_send, 'new', p_auto_send));
  END IF;
  IF p_pro_forma_expiry_days IS NOT NULL AND p_pro_forma_expiry_days IS DISTINCT FROM v_tpl.pro_forma_expiry_days THEN
    v_diff := v_diff || jsonb_build_object('pro_forma_expiry_days', jsonb_build_object('old', v_tpl.pro_forma_expiry_days, 'new', p_pro_forma_expiry_days));
  END IF;

  IF v_diff <> '{}'::jsonb THEN
    IF v_cadence_changed THEN
      v_new_next_due := public.recurring_template_compute_next_due_date(
        COALESCE(p_cadence_kind, v_tpl.cadence_kind),
        CURRENT_DATE,
        COALESCE(p_cadence_anchor_day_of_period, v_tpl.cadence_anchor_day_of_period)
      );
    ELSE
      v_new_next_due := v_tpl.next_due_date;
    END IF;

    UPDATE public.recurring_invoice_templates SET
      template_name = COALESCE(p_template_name, template_name),
      payment_terms_days = COALESCE(p_payment_terms_days, payment_terms_days),
      lines_payload = COALESCE(p_lines_payload, lines_payload),
      cadence_kind = COALESCE(p_cadence_kind, cadence_kind),
      cadence_anchor_day_of_period = COALESCE(p_cadence_anchor_day_of_period, cadence_anchor_day_of_period),
      next_due_date = v_new_next_due,
      end_date = CASE WHEN p_end_date IS NOT NULL THEN p_end_date ELSE end_date END,
      auto_send = COALESCE(p_auto_send, auto_send),
      pro_forma_expiry_days = COALESCE(p_pro_forma_expiry_days, pro_forma_expiry_days),
      updated_at = now(), updated_by = p_actor_user_id
    WHERE id = p_template_id;

    PERFORM audit.emit_audit(
      p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='RECURRING_INVOICE_TEMPLATE_UPDATED',
      p_subject_type:='RECURRING_INVOICE_TEMPLATE'::audit.subject_type_enum, p_subject_id:=p_template_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
      p_organization_id:=v_tpl.organization_id, p_business_id:=v_tpl.business_id,
      p_before_state:=NULL,
      p_after_state :=jsonb_build_object('diff', v_diff, 'next_due_date', v_new_next_due),
      p_reason:=NULL, p_request_context:=p_context);
  END IF;

  RETURN jsonb_build_object('decision','ALLOW','template_id', p_template_id, 'diff', v_diff);
END;
$function$;

-- recurring_template_pause
CREATE OR REPLACE FUNCTION public.recurring_template_pause(
  p_actor_user_id uuid,
  p_template_id   uuid,
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE v_tpl public.recurring_invoice_templates%ROWTYPE; v_decision jsonb;
BEGIN
  SELECT * INTO v_tpl FROM public.recurring_invoice_templates WHERE id = p_template_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','TEMPLATE_NOT_FOUND'); END IF;
  v_decision := public.can_perform(p_actor_user_id,'INVOICE_MANAGE','PAUSE_RECURRING_TEMPLATE',
    jsonb_build_object('template_id', p_template_id), v_tpl.business_id, v_tpl.organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision', 'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;
  IF v_tpl.status = 'PAUSED' THEN
    RETURN jsonb_build_object('decision','ALLOW','template_id', p_template_id, 'reason_code','ALREADY_PAUSED');
  END IF;
  IF v_tpl.status = 'ENDED' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','TEMPLATE_ENDED');
  END IF;
  UPDATE public.recurring_invoice_templates SET
    status='PAUSED', paused_at=now(), paused_by=p_actor_user_id,
    updated_at=now(), updated_by=p_actor_user_id
   WHERE id = p_template_id;
  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='RECURRING_INVOICE_TEMPLATE_PAUSED',
    p_subject_type:='RECURRING_INVOICE_TEMPLATE'::audit.subject_type_enum, p_subject_id:=p_template_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_tpl.organization_id, p_business_id:=v_tpl.business_id,
    p_before_state:=jsonb_build_object('status', v_tpl.status::text),
    p_after_state :=jsonb_build_object('status','PAUSED'),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','ALLOW','template_id', p_template_id, 'status','PAUSED');
END;
$function$;

-- recurring_template_resume
CREATE OR REPLACE FUNCTION public.recurring_template_resume(
  p_actor_user_id uuid,
  p_template_id   uuid,
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE v_tpl public.recurring_invoice_templates%ROWTYPE; v_decision jsonb;
BEGIN
  SELECT * INTO v_tpl FROM public.recurring_invoice_templates WHERE id = p_template_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','TEMPLATE_NOT_FOUND'); END IF;
  v_decision := public.can_perform(p_actor_user_id,'INVOICE_MANAGE','RESUME_RECURRING_TEMPLATE',
    jsonb_build_object('template_id', p_template_id), v_tpl.business_id, v_tpl.organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision', 'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;
  IF v_tpl.status = 'ACTIVE' THEN
    RETURN jsonb_build_object('decision','ALLOW','template_id', p_template_id, 'reason_code','ALREADY_ACTIVE');
  END IF;
  IF v_tpl.status = 'ENDED' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','TEMPLATE_ENDED');
  END IF;
  UPDATE public.recurring_invoice_templates SET
    status='ACTIVE', paused_at=NULL, paused_by=NULL,
    updated_at=now(), updated_by=p_actor_user_id
   WHERE id = p_template_id;
  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='RECURRING_INVOICE_TEMPLATE_RESUMED',
    p_subject_type:='RECURRING_INVOICE_TEMPLATE'::audit.subject_type_enum, p_subject_id:=p_template_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_tpl.organization_id, p_business_id:=v_tpl.business_id,
    p_before_state:=jsonb_build_object('status','PAUSED'),
    p_after_state :=jsonb_build_object('status','ACTIVE'),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','ALLOW','template_id', p_template_id, 'status','ACTIVE');
END;
$function$;

-- recurring_template_end
CREATE OR REPLACE FUNCTION public.recurring_template_end(
  p_actor_user_id uuid,
  p_template_id   uuid,
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE v_tpl public.recurring_invoice_templates%ROWTYPE; v_decision jsonb;
BEGIN
  SELECT * INTO v_tpl FROM public.recurring_invoice_templates WHERE id = p_template_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','TEMPLATE_NOT_FOUND'); END IF;
  v_decision := public.can_perform(p_actor_user_id,'INVOICE_MANAGE','END_RECURRING_TEMPLATE',
    jsonb_build_object('template_id', p_template_id), v_tpl.business_id, v_tpl.organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision', 'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;
  IF v_tpl.status = 'ENDED' THEN
    RETURN jsonb_build_object('decision','ALLOW','template_id', p_template_id, 'reason_code','ALREADY_ENDED');
  END IF;
  UPDATE public.recurring_invoice_templates SET
    status='ENDED', ended_at=now(), ended_by=p_actor_user_id,
    paused_at=NULL, paused_by=NULL,
    updated_at=now(), updated_by=p_actor_user_id
   WHERE id = p_template_id;
  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='RECURRING_INVOICE_TEMPLATE_ENDED',
    p_subject_type:='RECURRING_INVOICE_TEMPLATE'::audit.subject_type_enum, p_subject_id:=p_template_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_tpl.organization_id, p_business_id:=v_tpl.business_id,
    p_before_state:=jsonb_build_object('status', v_tpl.status::text),
    p_after_state :=jsonb_build_object('status','ENDED'),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','ALLOW','template_id', p_template_id, 'status','ENDED');
END;
$function$;

-- invoice_mark_pro_forma_expired
CREATE OR REPLACE FUNCTION public.invoice_mark_pro_forma_expired(
  p_invoice_id   uuid,
  p_actor_system text DEFAULT 'pro_forma_expiry_scheduler',
  p_context      jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE v_inv public.invoices%ROWTYPE;
BEGIN
  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_FOUND'); END IF;
  IF v_inv.invoice_type <> 'PRO_FORMA' THEN
    PERFORM public._emit_invoice_transition_failed(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text,'EXPIRED_UNCONVERTED','NOT_PRO_FORMA', NULL, p_actor_system, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','NOT_PRO_FORMA');
  END IF;
  IF v_inv.lifecycle_status NOT IN ('DRAFT','SENT') THEN
    PERFORM public._emit_invoice_transition_failed(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text,'EXPIRED_UNCONVERTED','ILLEGAL_TRANSITION', NULL, p_actor_system, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','ILLEGAL_TRANSITION','current_status', v_inv.lifecycle_status::text);
  END IF;
  UPDATE public.invoices SET
    lifecycle_status='EXPIRED_UNCONVERTED', lifecycle_status_changed_at=now(),
    updated_at=now()
   WHERE id = p_invoice_id;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='INVOICE_PRO_FORMA_EXPIRED',
    p_subject_type:='INVOICE'::audit.subject_type_enum, p_subject_id:=p_invoice_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
    p_organization_id:=v_inv.organization_id, p_business_id:=v_inv.business_id,
    p_before_state:=jsonb_build_object('lifecycle_status', v_inv.lifecycle_status::text),
    p_after_state :=jsonb_build_object('lifecycle_status','EXPIRED_UNCONVERTED','pro_forma_expires_at', v_inv.pro_forma_expires_at),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','ALLOW','lifecycle_status','EXPIRED_UNCONVERTED');
END;
$function$;

-- recurring_run_daily_scheduler
CREATE OR REPLACE FUNCTION public.recurring_run_daily_scheduler(
  p_scheduled_at timestamptz,
  p_actor_system text DEFAULT 'recurring_invoice_scheduler',
  p_context      jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_tpl public.recurring_invoice_templates%ROWTYPE;
  v_due date := p_scheduled_at::date;
  v_inv_id uuid;
  v_run_id uuid;
  v_line jsonb;
  v_line_no int;
  v_sub numeric(18,2);
  v_vat numeric(18,2);
  v_tot numeric(18,2);
  v_already_done boolean;
  v_err text;
  v_new_next date;
  v_processed int := 0;
  v_generated int := 0;
  v_skipped   int := 0;
  v_failed    int := 0;
  v_ended     int := 0;
  v_alloc     jsonb;
BEGIN
  FOR v_tpl IN
    SELECT * FROM public.recurring_invoice_templates
     WHERE status = 'ACTIVE' AND next_due_date <= v_due
     ORDER BY business_id, next_due_date, id
  LOOP
    v_processed := v_processed + 1;

    SELECT EXISTS (
      SELECT 1 FROM public.recurring_invoice_runs
       WHERE template_id = v_tpl.id AND due_date = v_tpl.next_due_date AND outcome = 'GENERATED'
    ) INTO v_already_done;
    IF v_already_done THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_inv_id := gen_uuid_v7();

    BEGIN
      INSERT INTO public.invoices (
        id, organization_id, business_id, client_id,
        invoice_type, invoice_number,
        issue_date, supply_date, due_date,
        currency, subtotal_amount, vat_amount, total_amount,
        vat_treatment_per_line, default_vat_treatment,
        lifecycle_status, lifecycle_status_changed_at, lifecycle_status_changed_by,
        pro_forma_expires_at
      ) VALUES (
        v_inv_id, v_tpl.organization_id, v_tpl.business_id, v_tpl.client_id,
        v_tpl.invoice_type, NULL,
        v_tpl.next_due_date, NULL, (v_tpl.next_due_date + v_tpl.payment_terms_days),
        v_tpl.currency, 0, 0, 0,
        v_tpl.vat_treatment_per_line, v_tpl.default_vat_treatment,
        'DRAFT', now(), v_tpl.created_by,
        CASE WHEN v_tpl.invoice_type = 'PRO_FORMA'
             THEN (v_tpl.next_due_date + v_tpl.pro_forma_expiry_days)::timestamptz
             ELSE NULL END
      );

      v_line_no := 0;
      FOR v_line IN SELECT * FROM jsonb_array_elements(v_tpl.lines_payload) LOOP
        v_line_no := v_line_no + 1;
        v_sub := ((v_line->>'quantity')::numeric * (v_line->>'unit_price')::numeric)::numeric(18,2);
        v_vat := COALESCE(NULLIF(v_line->>'vat_amount','')::numeric, 0)::numeric(18,2);
        v_tot := (v_sub + v_vat)::numeric(18,2);
        INSERT INTO public.invoice_lines (
          organization_id, business_id, invoice_id, line_number,
          description, quantity, unit_price, currency,
          subtotal_amount, vat_treatment, vat_rate_pct, vat_amount, total_amount
        ) VALUES (
          v_tpl.organization_id, v_tpl.business_id, v_inv_id, v_line_no,
          v_line->>'description',
          (v_line->>'quantity')::numeric, (v_line->>'unit_price')::numeric,
          v_tpl.currency,
          v_sub,
          NULLIF(v_line->>'vat_treatment','')::public.vat_treatment_enum,
          NULLIF(v_line->>'vat_rate_pct','')::numeric,
          NULLIF(v_line->>'vat_amount','')::numeric,
          v_tot
        );
      END LOOP;

      PERFORM public.invoice_recompute_totals(v_inv_id, p_context);

      IF v_tpl.auto_send THEN
        v_alloc := public.allocate_invoice_number(v_inv_id, p_context);
        UPDATE public.invoices SET
          lifecycle_status='SENT',
          lifecycle_status_changed_at=now(),
          sent_at=now(),
          sent_by=v_tpl.created_by,
          updated_at=now()
         WHERE id = v_inv_id;
        PERFORM audit.emit_audit(
          p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='INVOICE_SENT',
          p_subject_type:='INVOICE'::audit.subject_type_enum, p_subject_id:=v_inv_id,
          p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
          p_organization_id:=v_tpl.organization_id, p_business_id:=v_tpl.business_id,
          p_before_state:=jsonb_build_object('lifecycle_status','DRAFT'),
          p_after_state :=jsonb_build_object('lifecycle_status','SENT','invoice_number', v_alloc->'invoice_number',
                                              'via_recurring_template_id', v_tpl.id),
          p_reason:=NULL, p_request_context:=p_context);
      END IF;

      INSERT INTO public.recurring_invoice_runs (
        organization_id, business_id, template_id, due_date,
        generated_invoice_id, outcome, scheduled_at
      ) VALUES (
        v_tpl.organization_id, v_tpl.business_id, v_tpl.id, v_tpl.next_due_date,
        v_inv_id, 'GENERATED', p_scheduled_at
      ) RETURNING id INTO v_run_id;

      PERFORM audit.emit_audit(
        p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='RECURRING_INVOICE_GENERATED',
        p_subject_type:='RECURRING_INVOICE_RUN'::audit.subject_type_enum, p_subject_id:=v_run_id,
        p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
        p_organization_id:=v_tpl.organization_id, p_business_id:=v_tpl.business_id,
        p_before_state:=NULL,
        p_after_state :=jsonb_build_object('template_id', v_tpl.id, 'invoice_id', v_inv_id,
                                            'due_date', v_tpl.next_due_date, 'auto_send', v_tpl.auto_send),
        p_reason:=NULL, p_request_context:=p_context);

      v_new_next := public.recurring_template_compute_next_due_date(
        v_tpl.cadence_kind, v_tpl.next_due_date, v_tpl.cadence_anchor_day_of_period);

      IF v_tpl.end_date IS NOT NULL AND v_new_next > v_tpl.end_date THEN
        UPDATE public.recurring_invoice_templates SET
          next_due_date = v_new_next,
          status='ENDED', ended_at=now(), ended_by=v_tpl.created_by,
          updated_at=now(), updated_by=v_tpl.created_by
         WHERE id = v_tpl.id;
        PERFORM audit.emit_audit(
          p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='RECURRING_INVOICE_TEMPLATE_ENDED',
          p_subject_type:='RECURRING_INVOICE_TEMPLATE'::audit.subject_type_enum, p_subject_id:=v_tpl.id,
          p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
          p_organization_id:=v_tpl.organization_id, p_business_id:=v_tpl.business_id,
          p_before_state:=jsonb_build_object('status','ACTIVE'),
          p_after_state :=jsonb_build_object('status','ENDED','reason','past_end_date'),
          p_reason:=NULL, p_request_context:=p_context);
        v_ended := v_ended + 1;
      ELSE
        UPDATE public.recurring_invoice_templates SET
          next_due_date = v_new_next, updated_at=now()
         WHERE id = v_tpl.id;
      END IF;

      v_generated := v_generated + 1;
    EXCEPTION WHEN OTHERS THEN
      v_err := SQLERRM;
      INSERT INTO public.recurring_invoice_runs (
        organization_id, business_id, template_id, due_date,
        generated_invoice_id, outcome, error_message, scheduled_at
      ) VALUES (
        v_tpl.organization_id, v_tpl.business_id, v_tpl.id, v_tpl.next_due_date,
        NULL, 'FAILED', v_err, p_scheduled_at
      ) RETURNING id INTO v_run_id;
      PERFORM audit.emit_audit(
        p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='RECURRING_INVOICE_GENERATION_FAILED',
        p_subject_type:='RECURRING_INVOICE_RUN'::audit.subject_type_enum, p_subject_id:=v_run_id,
        p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
        p_organization_id:=v_tpl.organization_id, p_business_id:=v_tpl.business_id,
        p_before_state:=NULL,
        p_after_state :=jsonb_build_object('template_id', v_tpl.id, 'due_date', v_tpl.next_due_date,
                                            'error', v_err),
        p_reason:=v_err, p_request_context:=p_context);
      v_failed := v_failed + 1;
    END;
  END LOOP;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='RECURRING_INVOICE_SCHEDULER_RAN',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=gen_uuid_v7(),
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
    p_organization_id:=NULL, p_business_id:=NULL,
    p_before_state:=NULL,
    p_after_state :=jsonb_build_object(
      'scheduled_at', p_scheduled_at,
      'templates_processed', v_processed,
      'generated', v_generated,
      'skipped', v_skipped,
      'failed', v_failed,
      'ended_after_run', v_ended),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'decision','RAN',
    'templates_processed', v_processed,
    'generated', v_generated,
    'skipped', v_skipped,
    'failed', v_failed,
    'ended_after_run', v_ended);
END;
$function$;
