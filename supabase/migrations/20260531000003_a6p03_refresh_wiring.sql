-- ============================================================================
-- A6.3 (R6 · Analytics Projections) — Refresh wiring.
--
-- dashboard_trigger_manual_refresh ("Refresh now") and the finalization
-- subscriber dashboard_handle_archive_promotion_event only flipped the
-- dashboard_refresh_state flag + emitted an audit row with a hardcoded
-- cards_refreshed:11 — they never recomputed anything. Now both call the real
-- analytics.refresh_business(...) and report the actual table count.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.dashboard_trigger_manual_refresh(p_business_id uuid, p_organization_id uuid, p_actor_user_id uuid, p_context jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'audit', 'pg_temp'
AS $$
DECLARE v_count int;
BEGIN
  INSERT INTO public.dashboard_refresh_state (business_id, organization_id, currently_refreshing, updated_at)
       VALUES (p_business_id, p_organization_id, true, clock_timestamp())
  ON CONFLICT (business_id) DO UPDATE SET currently_refreshing = true, updated_at = clock_timestamp();

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='DASHBOARD_REFRESH_TRIGGERED_MANUALLY',
    p_subject_type:='BUSINESS'::audit.subject_type_enum, p_subject_id:=p_business_id,
    p_actor_user_id:=p_actor_user_id, p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_after_state:=jsonb_build_object('triggered_by', p_actor_user_id), p_request_context:=p_context);

  -- Real recompute of the analytics projections.
  v_count := analytics.refresh_business(p_business_id, NULL, 'dashboard-manual', p_actor_user_id);

  UPDATE public.dashboard_refresh_state
     SET currently_refreshing = false, last_refreshed_at = clock_timestamp(), updated_at = clock_timestamp()
   WHERE business_id = p_business_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='DASHBOARD_REFRESH_COMPLETED',
    p_subject_type:='BUSINESS'::audit.subject_type_enum, p_subject_id:=p_business_id,
    p_actor_user_id:=p_actor_user_id, p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_after_state:=jsonb_build_object('trigger', 'manual', 'cards_refreshed', v_count));

  RETURN jsonb_build_object('decision', 'REFRESHED', 'cards_count', v_count);
END;
$$;

CREATE OR REPLACE FUNCTION public.dashboard_handle_archive_promotion_event(p_archive_package_id uuid, p_manifest_version_number integer, p_business_id uuid, p_organization_id uuid, p_period_start date, p_period_end date, p_audit_event_id uuid, p_context jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'audit', 'pg_temp'
AS $$
DECLARE v_count int;
BEGIN
  IF p_audit_event_id IS NULL THEN
    RAISE EXCEPTION 'dashboard_handle_archive_promotion_event: audit_event_id required' USING ERRCODE='22000';
  END IF;
  IF EXISTS (SELECT 1 FROM public.dashboard_processed_events WHERE event_id = p_audit_event_id) THEN
    RETURN jsonb_build_object('decision', 'IDEMPOTENT_NO_OP', 'event_id', p_audit_event_id);
  END IF;
  INSERT INTO public.dashboard_processed_events (event_id, business_id) VALUES (p_audit_event_id, p_business_id);
  INSERT INTO public.dashboard_refresh_state (business_id, organization_id, currently_refreshing, updated_at)
       VALUES (p_business_id, p_organization_id, true, clock_timestamp())
  ON CONFLICT (business_id) DO UPDATE SET currently_refreshing = true, updated_at = clock_timestamp();

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='DASHBOARD_REFRESH_TRIGGERED_BY_EVENT',
    p_subject_type:='BUSINESS'::audit.subject_type_enum, p_subject_id:=p_business_id,
    p_actor_system:='dashboard_archive_promotion_subscriber',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_after_state:=jsonb_build_object('archive_package_id', p_archive_package_id, 'manifest_version_number', p_manifest_version_number,
      'period_start', p_period_start, 'period_end', p_period_end, 'source_event_id', p_audit_event_id),
    p_request_context:=p_context);

  -- Real recompute on finalization/archive promotion.
  v_count := analytics.refresh_business(p_business_id, NULL, 'dashboard-archive-promotion', NULL);

  UPDATE public.dashboard_refresh_state
     SET currently_refreshing = false, last_refreshed_at = clock_timestamp(),
         last_refreshed_by_event_id = p_audit_event_id, updated_at = clock_timestamp()
   WHERE business_id = p_business_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='DASHBOARD_REFRESH_COMPLETED',
    p_subject_type:='BUSINESS'::audit.subject_type_enum, p_subject_id:=p_business_id,
    p_actor_system:='dashboard_archive_promotion_subscriber',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_after_state:=jsonb_build_object('source_event_id', p_audit_event_id, 'cards_refreshed', v_count));

  RETURN jsonb_build_object('decision', 'REFRESHED', 'cards_count', v_count);
END;
$$;
