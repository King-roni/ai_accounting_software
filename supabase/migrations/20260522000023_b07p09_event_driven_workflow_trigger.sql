-- B07·P09 — Event-Driven Workflow Trigger
--
-- Producer side: STATEMENT_UPLOAD_COMPLETED outbox + emit/consume RPCs.
-- The consumer Python loop (poll outbox / respond to NOTIFY) lives in
-- Block 03 Phase 09; this migration ships the SQL contract the Python wraps.
--
-- Disabled-workflow signal: a business_workflow_config row with
-- enabled_phases = '[]'::jsonb OR enabled_phases IS NULL → disabled for that
-- workflow_type. No row OR non-empty array → enabled (default).

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'statement_upload_event_status_enum') THEN
    CREATE TYPE public.statement_upload_event_status_enum AS ENUM ('PENDING','CONSUMED','FAILED');
  END IF;
END$$;

CREATE TABLE IF NOT EXISTS public.statement_upload_events_outbox (
  event_id              uuid PRIMARY KEY,
  statement_upload_id   uuid NOT NULL REFERENCES public.statement_uploads(id),
  organization_id       uuid NOT NULL REFERENCES public.organizations(id),
  business_id           uuid NOT NULL REFERENCES public.business_entities(id),
  bank_account_id       uuid NOT NULL REFERENCES public.bank_accounts(id),
  declared_period_start date NOT NULL,
  declared_period_end   date NOT NULL,
  file_format           public.statement_file_format_enum NOT NULL,
  provider              text NOT NULL,
  actor_user_id         uuid REFERENCES public.users(id),
  status                public.statement_upload_event_status_enum NOT NULL DEFAULT 'PENDING',
  emitted_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
  consumed_at           timestamptz,
  failed_at             timestamptz,
  created_run_ids       uuid[] NOT NULL DEFAULT '{}',
  last_error_category   text,
  last_error_message    text,
  CONSTRAINT statement_upload_events_outbox_upload_uq UNIQUE (statement_upload_id),
  CONSTRAINT statement_upload_events_outbox_consumed_chk CHECK (
    (status = 'CONSUMED') = (consumed_at IS NOT NULL)
  ),
  CONSTRAINT statement_upload_events_outbox_failed_chk CHECK (
    (status = 'FAILED') = (failed_at IS NOT NULL AND last_error_category IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS statement_upload_events_outbox_status_idx
  ON public.statement_upload_events_outbox (status, emitted_at);

REVOKE ALL ON public.statement_upload_events_outbox FROM PUBLIC, authenticated, anon;
GRANT  SELECT ON public.statement_upload_events_outbox TO service_role;

-- ============================================================================
-- emit_statement_upload_completed_event
-- ============================================================================
CREATE OR REPLACE FUNCTION public.emit_statement_upload_completed_event(
  p_statement_upload_id uuid,
  p_actor_user_id       uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_upload  public.statement_uploads%ROWTYPE;
  v_event_id uuid := public.gen_uuid_v7();
  v_existing public.statement_upload_events_outbox%ROWTYPE;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_statement_upload_id IS NULL THEN
    RAISE EXCEPTION 'emit_statement_upload_completed_event: p_statement_upload_id is required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_upload FROM public.statement_uploads WHERE id = p_statement_upload_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'UPLOAD_NOT_FOUND',
      'statement_upload_id', p_statement_upload_id);
  END IF;

  -- Per-upload idempotency: same upload → same outbox row → idempotent emit
  INSERT INTO public.statement_upload_events_outbox
    (event_id, statement_upload_id, organization_id, business_id, bank_account_id,
     declared_period_start, declared_period_end, file_format, provider,
     actor_user_id, status, emitted_at)
  VALUES
    (v_event_id, v_upload.id, v_upload.organization_id, v_upload.business_id, v_upload.bank_account_id,
     v_upload.declared_period_start, v_upload.declared_period_end, v_upload.file_format, v_upload.provider,
     p_actor_user_id, 'PENDING', clock_timestamp())
  ON CONFLICT (statement_upload_id) DO NOTHING
  RETURNING event_id INTO v_event_id;

  IF v_event_id IS NULL THEN
    SELECT * INTO v_existing FROM public.statement_upload_events_outbox
      WHERE statement_upload_id = p_statement_upload_id;
    RETURN jsonb_build_object('ok', true, 'idempotent_replay', true,
      'event_id', v_existing.event_id, 'status', v_existing.status::text);
  END IF;

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_upload_trigger';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'STATEMENT_UPLOAD_EVENT_EMITTED',
    p_subject_type => 'TRIGGER_EVENT'::audit.subject_type_enum,
    p_subject_id => v_event_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_upload.organization_id, p_business_id => v_upload.business_id,
    p_after_state => jsonb_build_object(
      'event_id',              v_event_id,
      'event_kind',            'STATEMENT_UPLOAD_COMPLETED',
      'statement_upload_id',   v_upload.id,
      'bank_account_id',       v_upload.bank_account_id,
      'declared_period_start', v_upload.declared_period_start,
      'declared_period_end',   v_upload.declared_period_end,
      'file_format',           v_upload.file_format::text,
      'provider',              v_upload.provider,
      'actor_user_id',         p_actor_user_id),
    p_reason => format('STATEMENT_UPLOAD_COMPLETED event emitted: event_id=%s upload=%s',
                       v_event_id, v_upload.id));

  RETURN jsonb_build_object('ok', true,
    'event_id', v_event_id,
    'audit_event_id', v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.emit_statement_upload_completed_event(uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.emit_statement_upload_completed_event(uuid, uuid) TO service_role;

-- ============================================================================
-- consume_statement_upload_completed_event
-- ============================================================================
CREATE OR REPLACE FUNCTION public.consume_statement_upload_completed_event(
  p_event_id      uuid,
  p_actor_user_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_evt              public.statement_upload_events_outbox%ROWTYPE;
  v_processed       boolean;
  v_run_id          uuid;
  v_created_runs    uuid[] := '{}';
  v_types_enabled   text[] := '{}';
  v_out_disabled    boolean;
  v_in_disabled     boolean;
  v_audit_row       audit.audit_events;
  v_kind            audit.actor_kind_enum; v_system text;
  v_workflow_type   public.workflow_type_enum;
BEGIN
  IF p_event_id IS NULL THEN
    RAISE EXCEPTION 'consume_statement_upload_completed_event: p_event_id is required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_evt FROM public.statement_upload_events_outbox WHERE event_id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'EVENT_NOT_FOUND', 'event_id', p_event_id);
  END IF;

  -- Replay protection via trigger_events_processed (PK event_id text).
  SELECT EXISTS (SELECT 1 FROM public.trigger_events_processed
                 WHERE event_id = p_event_id::text) INTO v_processed;
  IF v_processed THEN
    IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_upload_trigger';
    ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
    v_audit_row := audit.emit_audit(
      p_actor_kind => v_kind, p_action => 'STATEMENT_UPLOAD_EVENT_REPLAY_NOOP',
      p_subject_type => 'TRIGGER_EVENT'::audit.subject_type_enum,
      p_subject_id => p_event_id,
      p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
      p_organization_id => v_evt.organization_id, p_business_id => v_evt.business_id,
      p_after_state => jsonb_build_object(
        'event_id', p_event_id,
        'created_run_ids', to_jsonb(v_evt.created_run_ids)),
      p_reason => format('replay noop on event %s', p_event_id));
    RETURN jsonb_build_object('ok', true, 'idempotent_replay', true,
      'event_id', p_event_id,
      'created_run_ids', to_jsonb(v_evt.created_run_ids),
      'audit_event_id', v_audit_row.id);
  END IF;

  -- Resolve per-business config: disabled iff row exists AND enabled_phases
  -- is either NULL or an empty jsonb array.
  SELECT EXISTS (
    SELECT 1 FROM public.business_workflow_config
    WHERE business_id = v_evt.business_id
      AND workflow_type = 'OUT_MONTHLY'::public.workflow_type_enum
      AND (enabled_phases IS NULL OR enabled_phases = '[]'::jsonb)
  ) INTO v_out_disabled;
  SELECT EXISTS (
    SELECT 1 FROM public.business_workflow_config
    WHERE business_id = v_evt.business_id
      AND workflow_type = 'IN_MONTHLY'::public.workflow_type_enum
      AND (enabled_phases IS NULL OR enabled_phases = '[]'::jsonb)
  ) INTO v_in_disabled;

  IF NOT v_out_disabled THEN
    v_workflow_type := 'OUT_MONTHLY'::public.workflow_type_enum;
    v_run_id := public.gen_uuid_v7();
    INSERT INTO public.workflow_runs
      (id, organization_id, business_id, workflow_type, principal_snapshot,
       period_start, period_end, trigger_kind, trigger_event_id, status,
       summary_json, created_at, updated_at)
    VALUES
      (v_run_id, v_evt.organization_id, v_evt.business_id, v_workflow_type,
       jsonb_build_object('actor_user_id', v_evt.actor_user_id,
                          'event_id',      v_evt.event_id,
                          'statement_upload_id', v_evt.statement_upload_id),
       v_evt.declared_period_start::timestamptz,
       (v_evt.declared_period_end + 1)::timestamptz,  -- period_end > period_start CHECK
       'EVENT'::public.trigger_kind_enum, p_event_id::text, 'CREATED',
       '{}'::jsonb, clock_timestamp(), clock_timestamp());
    v_created_runs := v_created_runs || v_run_id;
    v_types_enabled := v_types_enabled || 'OUT_MONTHLY';
  END IF;

  IF NOT v_in_disabled THEN
    v_workflow_type := 'IN_MONTHLY'::public.workflow_type_enum;
    v_run_id := public.gen_uuid_v7();
    INSERT INTO public.workflow_runs
      (id, organization_id, business_id, workflow_type, principal_snapshot,
       period_start, period_end, trigger_kind, trigger_event_id, status,
       summary_json, created_at, updated_at)
    VALUES
      (v_run_id, v_evt.organization_id, v_evt.business_id, v_workflow_type,
       jsonb_build_object('actor_user_id', v_evt.actor_user_id,
                          'event_id',      v_evt.event_id,
                          'statement_upload_id', v_evt.statement_upload_id),
       v_evt.declared_period_start::timestamptz,
       (v_evt.declared_period_end + 1)::timestamptz,
       'EVENT'::public.trigger_kind_enum, p_event_id::text, 'CREATED',
       '{}'::jsonb, clock_timestamp(), clock_timestamp());
    v_created_runs := v_created_runs || v_run_id;
    v_types_enabled := v_types_enabled || 'IN_MONTHLY';
  END IF;

  INSERT INTO public.trigger_events_processed
    (event_id, event_kind, business_id, organization_id, period_start, period_end,
     created_run_ids, payload, processed_at)
  VALUES
    (p_event_id::text, 'STATEMENT_UPLOAD_COMPLETED',
     v_evt.business_id, v_evt.organization_id,
     v_evt.declared_period_start::timestamptz,
     (v_evt.declared_period_end + 1)::timestamptz,
     v_created_runs,
     jsonb_build_object(
       'statement_upload_id',   v_evt.statement_upload_id,
       'bank_account_id',       v_evt.bank_account_id,
       'declared_period_start', v_evt.declared_period_start,
       'declared_period_end',   v_evt.declared_period_end,
       'file_format',           v_evt.file_format::text,
       'provider',              v_evt.provider,
       'workflow_types_created', to_jsonb(v_types_enabled)),
     clock_timestamp());

  UPDATE public.statement_upload_events_outbox
    SET status = 'CONSUMED'::public.statement_upload_event_status_enum,
        consumed_at = clock_timestamp(),
        created_run_ids = v_created_runs
    WHERE event_id = p_event_id;

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_upload_trigger';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'STATEMENT_UPLOAD_EVENT_CONSUMED',
    p_subject_type => 'TRIGGER_EVENT'::audit.subject_type_enum,
    p_subject_id => p_event_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_evt.organization_id, p_business_id => v_evt.business_id,
    p_after_state => jsonb_build_object(
      'event_id',                p_event_id,
      'statement_upload_id',     v_evt.statement_upload_id,
      'created_run_ids',         to_jsonb(v_created_runs),
      'workflow_types_enabled',  to_jsonb(v_types_enabled),
      'out_disabled',            v_out_disabled,
      'in_disabled',             v_in_disabled),
    p_reason => format('consumed event %s: created %s run(s) [%s]',
                       p_event_id, coalesce(array_length(v_created_runs, 1), 0),
                       array_to_string(v_types_enabled, ',')));

  RETURN jsonb_build_object('ok', true,
    'event_id',                p_event_id,
    'created_run_ids',         to_jsonb(v_created_runs),
    'workflow_types_enabled',  to_jsonb(v_types_enabled),
    'audit_event_id',          v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.consume_statement_upload_completed_event(uuid, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.consume_statement_upload_completed_event(uuid, uuid) TO service_role;

-- ============================================================================
-- record_statement_upload_event_handler_failed
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_statement_upload_event_handler_failed(
  p_event_id        uuid,
  p_error_category  text,
  p_error_message   text,
  p_actor_user_id   uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_evt public.statement_upload_events_outbox%ROWTYPE;
  v_audit_row audit.audit_events;
  v_kind audit.actor_kind_enum; v_system text;
BEGIN
  IF p_event_id IS NULL OR p_error_category IS NULL OR p_error_message IS NULL THEN
    RAISE EXCEPTION 'record_statement_upload_event_handler_failed: required params missing' USING ERRCODE='22000';
  END IF;
  IF length(p_error_message) = 0 OR length(p_error_message) > 2000 THEN
    RAISE EXCEPTION 'record_statement_upload_event_handler_failed: error_message length must be 1..2000' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_evt FROM public.statement_upload_events_outbox WHERE event_id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'EVENT_NOT_FOUND', 'event_id', p_event_id);
  END IF;

  UPDATE public.statement_upload_events_outbox
    SET status = 'FAILED'::public.statement_upload_event_status_enum,
        failed_at = clock_timestamp(),
        last_error_category = p_error_category,
        last_error_message  = p_error_message
    WHERE event_id = p_event_id;

  IF p_actor_user_id IS NULL THEN v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'statement_upload_trigger';
  ELSE v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL; END IF;
  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'STATEMENT_UPLOAD_EVENT_HANDLER_FAILED',
    p_subject_type => 'TRIGGER_EVENT'::audit.subject_type_enum,
    p_subject_id => p_event_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_evt.organization_id, p_business_id => v_evt.business_id,
    p_after_state => jsonb_build_object(
      'event_id',         p_event_id,
      'error_category',   p_error_category,
      'error_message',    p_error_message),
    p_reason => format('event handler failed on %s: %s — %s',
                       p_event_id, p_error_category, left(p_error_message, 200)));

  RETURN jsonb_build_object('ok', true,
    'event_id', p_event_id, 'audit_event_id', v_audit_row.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.record_statement_upload_event_handler_failed(uuid, text, text, uuid) FROM PUBLIC, authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.record_statement_upload_event_handler_failed(uuid, text, text, uuid) TO service_role;
