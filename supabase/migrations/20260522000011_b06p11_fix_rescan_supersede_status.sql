-- B06·P11 — Fix-up: rescan supersede uses DISMISSED, not AUTO_RESOLVED_BY_RESCAN
--
-- review_issues has constraint review_issue_auto_resolved_trigger_chk:
--   (status <> 'AUTO_RESOLVED_BY_RESCAN') OR (auto_resolution_trigger_issue_id IS NOT NULL)
--
-- That status was designed for B14's *cascading resolution* — one issue's
-- resolution auto-resolves another, with trigger_issue_id pointing at the
-- causing issue. Our rescan supersede has no single "triggering" review_issue
-- (the trigger is the rescan event), so the constraint fails.
--
-- Pragmatic fix: use DISMISSED with resolution_note='superseded by rescan'
-- and resolution_action='SUPERSEDED_BY_RESCAN'. This honors the spec's
-- "replaces existing OPEN issues" semantic (DISMISSED is terminal; history
-- preserved) without forcing a sentinel trigger_issue_id.
--
-- Forward-only fix per repo convention. The original B06·P11 migration
-- (20260522000010) stays as a record of what was applied; this file corrects
-- the behaviour of start_end_scan_rescan_affected.

CREATE OR REPLACE FUNCTION public.start_end_scan_rescan_affected(
  p_workflow_run_id uuid, p_business_id uuid, p_organization_id uuid,
  p_affected_entity_kind text, p_affected_entity_ids uuid[],
  p_actor_user_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_superseded int;
  v_scan_envelope jsonb;
  v_scan_id uuid;
  v_kind audit.actor_kind_enum;
  v_system text;
  v_audit_row audit.audit_events;
BEGIN
  IF p_workflow_run_id IS NULL OR p_business_id IS NULL OR p_organization_id IS NULL
     OR p_affected_entity_kind IS NULL OR p_affected_entity_ids IS NULL
     OR array_length(p_affected_entity_ids, 1) = 0 THEN
    RAISE EXCEPTION 'start_end_scan_rescan_affected: required params missing or empty entity list'
      USING ERRCODE='22000';
  END IF;
  IF p_affected_entity_kind NOT IN ('transaction','document','match_record','draft_ledger_entry') THEN
    RAISE EXCEPTION 'start_end_scan_rescan_affected: unknown affected_entity_kind %', p_affected_entity_kind
      USING ERRCODE='22023';
  END IF;

  -- Supersede existing OPEN issues for the affected entities. Use DISMISSED
  -- because AUTO_RESOLVED_BY_RESCAN requires a trigger_issue_id (B14 cascade
  -- pattern, not our use case). DISMISSED is terminal — preserves history —
  -- and the resolution_action / resolution_note distinguish a rescan
  -- supersede from a normal operator dismissal.
  UPDATE public.review_issues
    SET status              = 'DISMISSED'::public.review_issue_status_enum,
        resolution_action   = 'SUPERSEDED_BY_RESCAN',
        resolution_note     = format('Superseded by re-scan on %s entity %s',
                                     p_affected_entity_kind,
                                     array_to_string(p_affected_entity_ids, ', ')),
        resolved_at         = clock_timestamp(),
        updated_at          = clock_timestamp()
    WHERE workflow_run_id = p_workflow_run_id
      AND status = 'OPEN'::public.review_issue_status_enum
      AND CASE p_affected_entity_kind
            WHEN 'transaction'        THEN transaction_id        = ANY(p_affected_entity_ids)
            WHEN 'document'           THEN document_id           = ANY(p_affected_entity_ids)
            WHEN 'match_record'       THEN match_record_id       = ANY(p_affected_entity_ids)
            WHEN 'draft_ledger_entry' THEN draft_ledger_entry_id = ANY(p_affected_entity_ids)
          END;
  GET DIAGNOSTICS v_superseded = ROW_COUNT;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'end_scan';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;

  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'END_SCAN_RESCAN_AFFECTED',
    p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id => p_workflow_run_id, p_actor_user_id => p_actor_user_id,
    p_actor_system => v_system, p_organization_id => p_organization_id,
    p_business_id => p_business_id,
    p_reason => format('rescan affected %s %s entit%s; %s OPEN issue(s) superseded',
                        array_length(p_affected_entity_ids, 1), p_affected_entity_kind,
                        CASE WHEN array_length(p_affected_entity_ids,1) = 1 THEN 'y' ELSE 'ies' END,
                        v_superseded),
    p_after_state => jsonb_build_object(
      'workflow_run_id',      p_workflow_run_id,
      'affected_entity_kind', p_affected_entity_kind,
      'affected_entity_ids',  to_jsonb(p_affected_entity_ids),
      'superseded_count',     v_superseded,
      'supersede_status',     'DISMISSED',
      'supersede_action',     'SUPERSEDED_BY_RESCAN'));

  v_scan_envelope := public.start_end_scan(
    p_workflow_run_id, p_business_id, p_organization_id,
    true, p_affected_entity_kind, p_affected_entity_ids, p_actor_user_id);
  v_scan_id := (v_scan_envelope->>'scan_id')::uuid;

  RETURN jsonb_build_object('ok', true,
    'scan_id', v_scan_id,
    'superseded_count', v_superseded,
    'audit_event_id', v_audit_row.id);
END;
$function$;
