-- B06·P11 — End-Scan Engine
--
-- The framework the anomaly checks plug into. Ships the scan-metadata table,
-- the lifecycle RPCs (start / record_check / raise_issue / complete / rescan),
-- and the 5 spec-named audit events. The actual check catalogue (deterministic
-- SQL queries for each anomaly kind) is sub-doc work per spec §Sub-doc Hooks.
--
-- Spec: Docs/phases/06_ai_layer/11_end_scan_engine.md
--
-- Architecture rules the engine honours:
--   * Never resolves issues (B14 owns resolution)
--   * Never advances workflow state (B03 owns transitions)
--   * Never writes to draft_ledger_entries / match_records / transactions
--   * Only write targets: review_issues + end_scan_runs
-- Enforced by code review + by the non-write-boundary lifecycle test.

-- ============================================================================
-- 1. end_scan_status_enum
-- ============================================================================
CREATE TYPE public.end_scan_status_enum AS ENUM (
  'STARTED', 'COMPLETED', 'FAILED', 'CANCELLED'
);
COMMENT ON TYPE public.end_scan_status_enum IS
  'Lifecycle status of an end_scan_runs row. STARTED is the in-flight state; COMPLETED / FAILED / CANCELLED are terminal.';

-- ============================================================================
-- 2. end_scan_runs
-- ============================================================================
CREATE TABLE public.end_scan_runs (
  id                       uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  workflow_run_id          uuid NOT NULL,
  business_id              uuid NOT NULL REFERENCES public.business_entities(id),
  organization_id          uuid NOT NULL,
  is_rescan                boolean NOT NULL DEFAULT false,
  affected_entity_kind     text NULL,
  affected_entity_ids      uuid[] NULL,
  status                   public.end_scan_status_enum NOT NULL DEFAULT 'STARTED',
  started_at               timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at             timestamptz NULL,
  finding_count            int NOT NULL DEFAULT 0,
  severity_counts          jsonb NOT NULL DEFAULT
    '{"LOW":0,"MEDIUM":0,"HIGH":0,"BLOCKING":0}'::jsonb,
  checks_ran_count         int NOT NULL DEFAULT 0,
  CONSTRAINT esr_terminal_state_completion
    CHECK ((status = 'STARTED' AND completed_at IS NULL)
           OR (status <> 'STARTED' AND completed_at IS NOT NULL)),
  CONSTRAINT esr_rescan_has_affected
    CHECK ((is_rescan = false
            AND affected_entity_kind IS NULL
            AND affected_entity_ids IS NULL)
           OR (is_rescan = true
               AND affected_entity_kind IS NOT NULL
               AND affected_entity_ids IS NOT NULL
               AND array_length(affected_entity_ids, 1) > 0)),
  CONSTRAINT esr_finding_count_nonneg     CHECK (finding_count >= 0),
  CONSTRAINT esr_checks_ran_count_nonneg  CHECK (checks_ran_count >= 0),
  CONSTRAINT esr_severity_counts_obj      CHECK (jsonb_typeof(severity_counts) = 'object'),
  CONSTRAINT esr_completed_after_started  CHECK (completed_at IS NULL OR completed_at >= started_at)
);
COMMENT ON TABLE public.end_scan_runs IS
  'Per-scan metadata. One row per start_end_scan invocation per workflow_run_id. The engine''s only write targets are this table and review_issues (B14 territory). Anything else (ledger, matches, transactions) is out-of-scope per spec.';

CREATE INDEX idx_esr_business_started ON public.end_scan_runs (business_id, started_at DESC);
CREATE INDEX idx_esr_active ON public.end_scan_runs (workflow_run_id) WHERE status = 'STARTED';

REVOKE ALL ON public.end_scan_runs FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.end_scan_runs TO service_role;

-- ============================================================================
-- 3. start_end_scan
-- ============================================================================
CREATE OR REPLACE FUNCTION public.start_end_scan(
  p_workflow_run_id      uuid,
  p_business_id          uuid,
  p_organization_id      uuid,
  p_is_rescan            boolean DEFAULT false,
  p_affected_entity_kind text   DEFAULT NULL,
  p_affected_entity_ids  uuid[] DEFAULT NULL,
  p_actor_user_id        uuid   DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_scan_id      uuid;
  v_kind         audit.actor_kind_enum;
  v_system       text;
  v_audit_row    audit.audit_events;
BEGIN
  IF p_workflow_run_id IS NULL OR p_business_id IS NULL OR p_organization_id IS NULL THEN
    RAISE EXCEPTION 'start_end_scan: required params missing' USING ERRCODE='22000';
  END IF;

  INSERT INTO public.end_scan_runs (
    workflow_run_id, business_id, organization_id,
    is_rescan, affected_entity_kind, affected_entity_ids
  ) VALUES (
    p_workflow_run_id, p_business_id, p_organization_id,
    p_is_rescan, p_affected_entity_kind, p_affected_entity_ids
  )
  RETURNING id INTO v_scan_id;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'end_scan';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;

  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'END_SCAN_STARTED',
    p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id => p_workflow_run_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => p_organization_id, p_business_id => p_business_id,
    p_reason => format('End-scan %sstarted for run %s',
                        CASE WHEN p_is_rescan THEN 're-' ELSE '' END,
                        p_workflow_run_id),
    p_after_state => jsonb_build_object(
      'scan_id',              v_scan_id,
      'workflow_run_id',      p_workflow_run_id,
      'is_rescan',            p_is_rescan,
      'affected_entity_kind', p_affected_entity_kind,
      'affected_entity_ids',  COALESCE(to_jsonb(p_affected_entity_ids), 'null'::jsonb)));

  RETURN jsonb_build_object('ok', true, 'scan_id', v_scan_id,
    'is_rescan', p_is_rescan, 'audit_event_id', v_audit_row.id);
END;
$function$;
COMMENT ON FUNCTION public.start_end_scan(uuid, uuid, uuid, boolean, text, uuid[], uuid) IS
  'Creates an end_scan_runs row and emits END_SCAN_STARTED. is_rescan=true requires affected_entity_kind + affected_entity_ids (CHECK constraint).';

REVOKE EXECUTE ON FUNCTION public.start_end_scan(uuid, uuid, uuid, boolean, text, uuid[], uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.start_end_scan(uuid, uuid, uuid, boolean, text, uuid[], uuid) TO service_role;

-- ============================================================================
-- 4. record_end_scan_check
-- ============================================================================
CREATE OR REPLACE FUNCTION public.record_end_scan_check(
  p_scan_id         uuid,
  p_check_name      text,
  p_finding_count   int     DEFAULT 0,
  p_deterministic   boolean DEFAULT true,
  p_duration_ms     int     DEFAULT NULL,
  p_actor_user_id   uuid    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_scan      public.end_scan_runs%ROWTYPE;
  v_kind      audit.actor_kind_enum;
  v_system    text;
  v_audit_row audit.audit_events;
BEGIN
  IF p_scan_id IS NULL OR p_check_name IS NULL THEN
    RAISE EXCEPTION 'record_end_scan_check: required params missing' USING ERRCODE='22000';
  END IF;
  IF p_check_name !~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$' THEN
    RAISE EXCEPTION 'record_end_scan_check: check_name must be namespaced (e.g. out_evidence.missing_invoice); got %', p_check_name
      USING ERRCODE='22023';
  END IF;
  IF p_finding_count < 0 THEN
    RAISE EXCEPTION 'record_end_scan_check: finding_count must be non-negative' USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_scan FROM public.end_scan_runs WHERE id = p_scan_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'record_end_scan_check: scan % not found', p_scan_id USING ERRCODE='22023';
  END IF;
  IF v_scan.status <> 'STARTED'::public.end_scan_status_enum THEN
    RAISE EXCEPTION 'record_end_scan_check: scan % is in terminal state %', p_scan_id, v_scan.status
      USING ERRCODE='22023';
  END IF;

  UPDATE public.end_scan_runs SET checks_ran_count = checks_ran_count + 1
    WHERE id = p_scan_id;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'end_scan';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;

  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'END_SCAN_CHECK_RAN',
    p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum,
    p_subject_id => v_scan.workflow_run_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_scan.organization_id, p_business_id => v_scan.business_id,
    p_reason => format('end-scan check %s ran (%s findings)', p_check_name, p_finding_count),
    p_after_state => jsonb_build_object(
      'scan_id',         p_scan_id,
      'workflow_run_id', v_scan.workflow_run_id,
      'check_name',      p_check_name,
      'finding_count',   p_finding_count,
      'deterministic',   p_deterministic,
      'duration_ms',     p_duration_ms));

  RETURN jsonb_build_object('ok', true,
    'scan_id', p_scan_id,
    'checks_ran_count', v_scan.checks_ran_count + 1,
    'audit_event_id', v_audit_row.id);
END;
$function$;
COMMENT ON FUNCTION public.record_end_scan_check(uuid, text, int, boolean, int, uuid) IS
  'Per-check observability emission. check_name must be namespaced (lowercase dot-separated).';

REVOKE EXECUTE ON FUNCTION public.record_end_scan_check(uuid, text, int, boolean, int, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_end_scan_check(uuid, text, int, boolean, int, uuid) TO service_role;

-- ============================================================================
-- 5. raise_end_scan_issue
-- ============================================================================
CREATE OR REPLACE FUNCTION public.raise_end_scan_issue(
  p_scan_id                       uuid,
  p_issue_type                    text,
  p_issue_group                   public.review_issue_group_enum,
  p_severity                      public.review_issue_severity_enum,
  p_plain_language_title          text,
  p_plain_language_description    text,
  p_recommended_action            text DEFAULT NULL,
  p_transaction_id                uuid DEFAULT NULL,
  p_document_id                   uuid DEFAULT NULL,
  p_match_record_id               uuid DEFAULT NULL,
  p_draft_ledger_entry_id         uuid DEFAULT NULL,
  p_card_payload_json             jsonb DEFAULT '{}'::jsonb,
  p_card_content_tier_used        public.review_issue_card_content_tier_enum DEFAULT 'NONE',
  p_card_content_fallback_applied boolean DEFAULT false,
  p_actor_user_id                 uuid  DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_scan       public.end_scan_runs%ROWTYPE;
  v_issue_id   uuid;
  v_sev_key    text;
  v_counts     jsonb;
  v_kind       audit.actor_kind_enum;
  v_system     text;
  v_audit_row  audit.audit_events;
BEGIN
  IF p_scan_id IS NULL OR p_issue_type IS NULL OR p_issue_group IS NULL OR p_severity IS NULL
     OR p_plain_language_title IS NULL OR p_plain_language_description IS NULL THEN
    RAISE EXCEPTION 'raise_end_scan_issue: required params missing' USING ERRCODE='22000';
  END IF;
  IF p_issue_type !~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$' THEN
    RAISE EXCEPTION 'raise_end_scan_issue: issue_type must be namespaced (e.g. out_evidence.missing_invoice); got %', p_issue_type
      USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_scan FROM public.end_scan_runs WHERE id = p_scan_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'raise_end_scan_issue: scan % not found', p_scan_id USING ERRCODE='22023';
  END IF;
  IF v_scan.status <> 'STARTED'::public.end_scan_status_enum THEN
    RAISE EXCEPTION 'raise_end_scan_issue: scan % is in terminal state %', p_scan_id, v_scan.status
      USING ERRCODE='22023';
  END IF;

  INSERT INTO public.review_issues (
    organization_id, business_id, workflow_run_id,
    transaction_id, document_id, match_record_id, draft_ledger_entry_id,
    issue_type, issue_group, severity,
    plain_language_title, plain_language_description, recommended_action,
    card_payload_json, card_content_tier_used, card_content_fallback_applied,
    status
  ) VALUES (
    v_scan.organization_id, v_scan.business_id, v_scan.workflow_run_id,
    p_transaction_id, p_document_id, p_match_record_id, p_draft_ledger_entry_id,
    p_issue_type, p_issue_group, p_severity,
    p_plain_language_title, p_plain_language_description, p_recommended_action,
    COALESCE(p_card_payload_json, '{}'::jsonb),
    p_card_content_tier_used, p_card_content_fallback_applied,
    'OPEN'::public.review_issue_status_enum
  )
  RETURNING id INTO v_issue_id;

  v_sev_key := p_severity::text;
  v_counts  := v_scan.severity_counts;
  v_counts  := jsonb_set(v_counts, ARRAY[v_sev_key],
                          to_jsonb(COALESCE((v_counts->>v_sev_key)::int, 0) + 1), true);
  UPDATE public.end_scan_runs
    SET finding_count = finding_count + 1, severity_counts = v_counts
    WHERE id = p_scan_id;

  IF p_actor_user_id IS NULL THEN
    v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'end_scan';
  ELSE
    v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
  END IF;

  v_audit_row := audit.emit_audit(
    p_actor_kind => v_kind, p_action => 'END_SCAN_ISSUE_RAISED',
    p_subject_type => 'REVIEW_ISSUE'::audit.subject_type_enum,
    p_subject_id => v_issue_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => v_scan.organization_id, p_business_id => v_scan.business_id,
    p_reason => format('end-scan issue raised: %s (%s)', p_issue_type, p_severity),
    p_after_state => jsonb_build_object(
      'issue_id',         v_issue_id,
      'scan_id',          p_scan_id,
      'workflow_run_id',  v_scan.workflow_run_id,
      'issue_type',       p_issue_type,
      'issue_group',      p_issue_group::text,
      'severity',         p_severity::text,
      'fallback_applied', p_card_content_fallback_applied));

  RETURN jsonb_build_object('ok', true,
    'review_issue_id', v_issue_id,
    'finding_count',   v_scan.finding_count + 1,
    'audit_event_id',  v_audit_row.id);
END;
$function$;
COMMENT ON FUNCTION public.raise_end_scan_issue(uuid, text, public.review_issue_group_enum, public.review_issue_severity_enum, text, text, text, uuid, uuid, uuid, uuid, jsonb, public.review_issue_card_content_tier_enum, boolean, uuid) IS
  'Inserts a review_issues row (status=OPEN) and bumps the parent end_scan_runs counters. Emits END_SCAN_ISSUE_RAISED. The only place outside B14 that writes to review_issues — engine''s sole non-end_scan_runs write target per spec.';

REVOKE EXECUTE ON FUNCTION public.raise_end_scan_issue(uuid, text, public.review_issue_group_enum, public.review_issue_severity_enum, text, text, text, uuid, uuid, uuid, uuid, jsonb, public.review_issue_card_content_tier_enum, boolean, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.raise_end_scan_issue(uuid, text, public.review_issue_group_enum, public.review_issue_severity_enum, text, text, text, uuid, uuid, uuid, uuid, jsonb, public.review_issue_card_content_tier_enum, boolean, uuid) TO service_role;

-- ============================================================================
-- 6. complete_end_scan
-- ============================================================================
CREATE OR REPLACE FUNCTION public.complete_end_scan(
  p_scan_id        uuid,
  p_terminal_status public.end_scan_status_enum,
  p_actor_user_id  uuid DEFAULT NULL,
  p_failure_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_scan      public.end_scan_runs%ROWTYPE;
  v_action    text;
  v_kind      audit.actor_kind_enum;
  v_system    text;
  v_audit_row audit.audit_events;
BEGIN
  IF p_scan_id IS NULL OR p_terminal_status IS NULL THEN
    RAISE EXCEPTION 'complete_end_scan: required params missing' USING ERRCODE='22000';
  END IF;
  IF p_terminal_status = 'STARTED'::public.end_scan_status_enum THEN
    RAISE EXCEPTION 'complete_end_scan: cannot transition to STARTED — must be COMPLETED / FAILED / CANCELLED'
      USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_scan FROM public.end_scan_runs WHERE id = p_scan_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'complete_end_scan: scan % not found', p_scan_id USING ERRCODE='22023';
  END IF;
  IF v_scan.status <> 'STARTED'::public.end_scan_status_enum THEN
    RAISE EXCEPTION 'complete_end_scan: scan % already in terminal state %', p_scan_id, v_scan.status
      USING ERRCODE='22023';
  END IF;

  UPDATE public.end_scan_runs
    SET status = p_terminal_status, completed_at = clock_timestamp()
    WHERE id = p_scan_id;

  -- CANCELLED is operator-initiated and does not emit a stream-marker event.
  IF p_terminal_status IN ('COMPLETED'::public.end_scan_status_enum,
                            'FAILED'::public.end_scan_status_enum) THEN
    v_action := CASE p_terminal_status
                  WHEN 'COMPLETED' THEN 'END_SCAN_COMPLETED'
                  WHEN 'FAILED'    THEN 'END_SCAN_FAILED'
                END;
    IF p_actor_user_id IS NULL THEN
      v_kind := 'SYSTEM'::audit.actor_kind_enum; v_system := 'end_scan';
    ELSE
      v_kind := 'USER'::audit.actor_kind_enum; v_system := NULL;
    END IF;
    v_audit_row := audit.emit_audit(
      p_actor_kind => v_kind, p_action => v_action,
      p_subject_type => 'WORKFLOW_RUN'::audit.subject_type_enum,
      p_subject_id => v_scan.workflow_run_id,
      p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
      p_organization_id => v_scan.organization_id, p_business_id => v_scan.business_id,
      p_reason => format('end-scan %s for run %s (%s findings)',
                          lower(p_terminal_status::text), v_scan.workflow_run_id, v_scan.finding_count),
      p_after_state => jsonb_build_object(
        'scan_id',          p_scan_id,
        'workflow_run_id',  v_scan.workflow_run_id,
        'status',           p_terminal_status::text,
        'finding_count',    v_scan.finding_count,
        'severity_counts',  v_scan.severity_counts,
        'checks_ran_count', v_scan.checks_ran_count,
        'failure_reason',   p_failure_reason));
  END IF;

  RETURN jsonb_build_object('ok', true,
    'scan_id', p_scan_id,
    'status', p_terminal_status::text,
    'finding_count', v_scan.finding_count,
    'severity_counts', v_scan.severity_counts,
    'audit_event_id', COALESCE(v_audit_row.id, NULL));
END;
$function$;
COMMENT ON FUNCTION public.complete_end_scan(uuid, public.end_scan_status_enum, uuid, text) IS
  'Transitions an end_scan_runs row to a terminal state. Emits END_SCAN_COMPLETED on COMPLETED, END_SCAN_FAILED on FAILED, no audit on CANCELLED.';

REVOKE EXECUTE ON FUNCTION public.complete_end_scan(uuid, public.end_scan_status_enum, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_end_scan(uuid, public.end_scan_status_enum, uuid, text) TO service_role;

-- ============================================================================
-- 7. start_end_scan_rescan_affected
-- ============================================================================
CREATE OR REPLACE FUNCTION public.start_end_scan_rescan_affected(
  p_workflow_run_id      uuid,
  p_business_id          uuid,
  p_organization_id      uuid,
  p_affected_entity_kind text,
  p_affected_entity_ids  uuid[],
  p_actor_user_id        uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_superseded int;
  v_scan_envelope jsonb;
  v_scan_id    uuid;
  v_kind       audit.actor_kind_enum;
  v_system     text;
  v_audit_row  audit.audit_events;
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

  -- Supersede existing OPEN review_issues for the affected entities. Status
  -- AUTO_RESOLVED_BY_RESCAN exists on review_issue_status_enum exactly for
  -- this lifecycle and keeps the issue history intact (no DELETE).
  UPDATE public.review_issues
    SET status = 'AUTO_RESOLVED_BY_RESCAN'::public.review_issue_status_enum,
        resolved_at = clock_timestamp(),
        updated_at = clock_timestamp()
    WHERE workflow_run_id = p_workflow_run_id
      AND status = 'OPEN'::public.review_issue_status_enum
      AND CASE p_affected_entity_kind
            WHEN 'transaction'         THEN transaction_id         = ANY(p_affected_entity_ids)
            WHEN 'document'            THEN document_id            = ANY(p_affected_entity_ids)
            WHEN 'match_record'        THEN match_record_id        = ANY(p_affected_entity_ids)
            WHEN 'draft_ledger_entry' THEN draft_ledger_entry_id  = ANY(p_affected_entity_ids)
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
    p_subject_id => p_workflow_run_id,
    p_actor_user_id => p_actor_user_id, p_actor_system => v_system,
    p_organization_id => p_organization_id, p_business_id => p_business_id,
    p_reason => format('rescan affected %s %s entit%s; %s existing OPEN issue(s) superseded',
                        array_length(p_affected_entity_ids, 1), p_affected_entity_kind,
                        CASE WHEN array_length(p_affected_entity_ids,1) = 1 THEN 'y' ELSE 'ies' END,
                        v_superseded),
    p_after_state => jsonb_build_object(
      'workflow_run_id',      p_workflow_run_id,
      'affected_entity_kind', p_affected_entity_kind,
      'affected_entity_ids',  to_jsonb(p_affected_entity_ids),
      'superseded_count',     v_superseded));

  v_scan_envelope := public.start_end_scan(
    p_workflow_run_id => p_workflow_run_id,
    p_business_id => p_business_id,
    p_organization_id => p_organization_id,
    p_is_rescan => true,
    p_affected_entity_kind => p_affected_entity_kind,
    p_affected_entity_ids => p_affected_entity_ids,
    p_actor_user_id => p_actor_user_id);
  v_scan_id := (v_scan_envelope->>'scan_id')::uuid;

  RETURN jsonb_build_object('ok', true,
    'scan_id',           v_scan_id,
    'superseded_count',  v_superseded,
    'audit_event_id',    v_audit_row.id);
END;
$function$;
COMMENT ON FUNCTION public.start_end_scan_rescan_affected(uuid, uuid, uuid, text, uuid[], uuid) IS
  'Rescan affected entities only. First flips existing OPEN review_issues for those entities to AUTO_RESOLVED_BY_RESCAN (no DELETE — keeps issue history), then delegates to start_end_scan(is_rescan=true). Emits END_SCAN_RESCAN_AFFECTED before delegating. Spec invariant: "Re-scan replaces existing OPEN issues; it does not duplicate them."';

REVOKE EXECUTE ON FUNCTION public.start_end_scan_rescan_affected(uuid, uuid, uuid, text, uuid[], uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.start_end_scan_rescan_affected(uuid, uuid, uuid, text, uuid[], uuid) TO service_role;
