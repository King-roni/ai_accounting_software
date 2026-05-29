-- Fix: audit_events_actor_kind_chk requires USER xor SYSTEM (not both).
-- load_in_workflow_config_for_business passed both actor_user_id and actor_system;
-- collapse to one based on which is provided.

CREATE OR REPLACE FUNCTION public.load_in_workflow_config_for_business(
  p_organization_id uuid,
  p_business_id     uuid,
  p_actor_user_id   uuid DEFAULT NULL,
  p_actor_system    text DEFAULT 'business_provisioning',
  p_context         jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $function$
DECLARE v_id uuid; v_inserted boolean := false;
BEGIN
  INSERT INTO public.in_workflow_business_config (
    organization_id, business_id, auto_start_on_statement_upload, last_updated_by
  ) VALUES (
    p_organization_id, p_business_id, true, p_actor_user_id
  )
  ON CONFLICT (business_id) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NOT NULL THEN
    v_inserted := true;
    PERFORM audit.emit_audit(
      p_actor_kind:=CASE WHEN p_actor_user_id IS NOT NULL THEN 'USER' ELSE 'SYSTEM' END::audit.actor_kind_enum,
      p_action:='IN_WORKFLOW_CONFIG_INITIALIZED',
      p_subject_type:='BUSINESS'::audit.subject_type_enum, p_subject_id:=p_business_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:=CASE WHEN p_actor_user_id IS NOT NULL THEN NULL ELSE p_actor_system END,
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state :=jsonb_build_object('config_id', v_id, 'auto_start_on_statement_upload', true),
      p_reason:=NULL, p_request_context:=p_context);
  END IF;
  RETURN jsonb_build_object('decision','ALLOW','inserted', v_inserted);
END;
$function$;
