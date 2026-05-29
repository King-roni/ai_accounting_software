-- Block 04 audit fixes — 2026-05-20
-- ============================================================================
-- Three issues surfaced by the post-Block-04 audit:
--
--  #1  Step-up enforcement was silently bypassed in archive RPCs.
--      public.consume_step_up_token returns TABLE(consumed boolean, reason text);
--      callers used PERFORM (discarded the result), so any invalid token was
--      accepted. Callers now mirror B02's change_member_role pattern:
--          SELECT consumed, reason INTO v_consumed, v_reason FROM ...;
--          IF NOT v_consumed THEN RAISE EXCEPTION ...; END IF;
--
--  #4  archive.retention_policies has updated_at column but no trigger; direct
--      service-role UPDATEs would silently leave it stale.
--
--  #12 ~30 unindexed FKs (mostly organization_id + actor user_id) — would
--      table-scan on parent DELETE under load. Add covering indexes.
-- ============================================================================

-- ----- Fix #1 — archive.update_retention_policy -------------------------

CREATE OR REPLACE FUNCTION archive.update_retention_policy(
  p_business_id     uuid,
  p_retention_years integer,
  p_step_up_token   uuid
) RETURNS archive.retention_policies
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = archive, public, pg_temp
AS $fn$
DECLARE
  v_user     uuid := public.current_user_id();
  v_org      uuid;
  v_role     public.user_role;
  v_row      archive.retention_policies;
  v_old      integer;
  v_consumed boolean;
  v_reason   text;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
  IF p_retention_years < 6 THEN
    RAISE EXCEPTION 'retention_years % below legal minimum (6)', p_retention_years USING ERRCODE='22000';
  END IF;
  SELECT bur.role INTO v_role FROM public.business_user_roles bur
    WHERE bur.user_id = v_user AND bur.business_id = p_business_id AND bur.status='ACTIVE';
  IF v_role IS NULL OR v_role NOT IN ('OWNER','ADMIN') THEN
    RAISE EXCEPTION 'role does not grant retention policy update (got %)', v_role USING ERRCODE='42501';
  END IF;

  SELECT consumed, reason INTO v_consumed, v_reason
    FROM public.consume_step_up_token(p_step_up_token, p_business_id, 'retention_policy_update', NULL);
  IF NOT v_consumed THEN
    RAISE EXCEPTION 'RETENTION_POLICY_STEP_UP_REJECTED:%', v_reason USING ERRCODE='42501';
  END IF;

  SELECT organization_id INTO v_org FROM public.business_entities WHERE id = p_business_id;
  SELECT retention_years INTO v_old FROM archive.retention_policies WHERE business_id = p_business_id;
  INSERT INTO archive.retention_policies (business_id, organization_id, retention_years, updated_at, updated_by)
  VALUES (p_business_id, v_org, p_retention_years, now(), v_user)
  ON CONFLICT (business_id) DO UPDATE
    SET retention_years = EXCLUDED.retention_years,
        updated_at      = now(),
        updated_by      = EXCLUDED.updated_by
  RETURNING * INTO v_row;

  INSERT INTO archive.archive_events (organization_id, business_id, event_type, actor_user_id, payload)
  VALUES (v_org, p_business_id, 'RETENTION_POLICY_UPDATED', v_user,
          jsonb_build_object('old_retention_years', v_old, 'new_retention_years', p_retention_years));
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION archive.update_retention_policy(uuid, integer, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION archive.update_retention_policy(uuid, integer, uuid) TO authenticated, service_role;

-- ----- Fix #1 — archive.set_legal_hold ---------------------------------

CREATE OR REPLACE FUNCTION archive.set_legal_hold(
  p_business_id uuid, p_hold_reason text, p_step_up_token uuid
) RETURNS archive.legal_holds
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = archive, public, pg_temp
AS $fn$
DECLARE
  v_user uuid := public.current_user_id();
  v_org  uuid;
  v_role public.user_role;
  v_row  archive.legal_holds;
  v_consumed boolean; v_reason text;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
  IF p_hold_reason IS NULL OR length(btrim(p_hold_reason)) = 0 THEN
    RAISE EXCEPTION 'hold_reason must be non-empty' USING ERRCODE='22000';
  END IF;
  SELECT bur.role INTO v_role FROM public.business_user_roles bur
    WHERE bur.user_id = v_user AND bur.business_id = p_business_id AND bur.status='ACTIVE';
  IF v_role IS NULL OR v_role <> 'OWNER' THEN
    RAISE EXCEPTION 'role does not grant legal hold management (got %); OWNER only', v_role USING ERRCODE='42501';
  END IF;

  SELECT consumed, reason INTO v_consumed, v_reason
    FROM public.consume_step_up_token(p_step_up_token, p_business_id, 'legal_hold_set', NULL);
  IF NOT v_consumed THEN
    RAISE EXCEPTION 'LEGAL_HOLD_SET_STEP_UP_REJECTED:%', v_reason USING ERRCODE='42501';
  END IF;

  SELECT organization_id INTO v_org FROM public.business_entities WHERE id = p_business_id;

  INSERT INTO archive.legal_holds (organization_id, business_id, status, hold_reason, set_by, set_at)
  VALUES (v_org, p_business_id, 'ACTIVE', btrim(p_hold_reason), v_user, now())
  RETURNING * INTO v_row;

  INSERT INTO archive.archive_events (organization_id, business_id, event_type, actor_user_id, payload)
  VALUES (v_org, p_business_id, 'LEGAL_HOLD_SET', v_user,
          jsonb_build_object('legal_hold_id', v_row.id, 'hold_reason', v_row.hold_reason, 'set_at', v_row.set_at));
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION archive.set_legal_hold(uuid, text, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION archive.set_legal_hold(uuid, text, uuid) TO authenticated, service_role;

-- ----- Fix #1 — archive.lift_legal_hold --------------------------------

CREATE OR REPLACE FUNCTION archive.lift_legal_hold(
  p_legal_hold_id uuid, p_lift_reason text, p_step_up_token uuid
) RETURNS archive.legal_holds
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = archive, public, pg_temp
AS $fn$
DECLARE
  v_user uuid := public.current_user_id();
  v_role public.user_role;
  v_row  archive.legal_holds;
  v_consumed boolean; v_reason text;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
  IF p_lift_reason IS NULL OR length(btrim(p_lift_reason)) = 0 THEN
    RAISE EXCEPTION 'lift_reason must be non-empty' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_row FROM archive.legal_holds WHERE id = p_legal_hold_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'legal hold % not found', p_legal_hold_id USING ERRCODE='P0002'; END IF;
  IF v_row.status <> 'ACTIVE' THEN
    RAISE EXCEPTION 'legal hold % is not ACTIVE (got %)', p_legal_hold_id, v_row.status USING ERRCODE='22023';
  END IF;
  SELECT bur.role INTO v_role FROM public.business_user_roles bur
    WHERE bur.user_id = v_user AND bur.business_id = v_row.business_id AND bur.status='ACTIVE';
  IF v_role IS NULL OR v_role <> 'OWNER' THEN
    RAISE EXCEPTION 'role does not grant legal hold management (got %); OWNER only', v_role USING ERRCODE='42501';
  END IF;

  SELECT consumed, reason INTO v_consumed, v_reason
    FROM public.consume_step_up_token(p_step_up_token, v_row.business_id, 'legal_hold_lift', NULL);
  IF NOT v_consumed THEN
    RAISE EXCEPTION 'LEGAL_HOLD_LIFT_STEP_UP_REJECTED:%', v_reason USING ERRCODE='42501';
  END IF;

  UPDATE archive.legal_holds
     SET status='LIFTED', lift_reason=btrim(p_lift_reason), lifted_by=v_user, lifted_at=now()
   WHERE id = p_legal_hold_id
  RETURNING * INTO v_row;

  INSERT INTO archive.archive_events (organization_id, business_id, event_type, actor_user_id, payload)
  VALUES (v_row.organization_id, v_row.business_id, 'LEGAL_HOLD_LIFTED', v_user,
          jsonb_build_object('legal_hold_id', v_row.id, 'hold_reason', v_row.hold_reason,
                             'lift_reason', v_row.lift_reason, 'set_at', v_row.set_at, 'lifted_at', v_row.lifted_at));
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION archive.lift_legal_hold(uuid, text, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION archive.lift_legal_hold(uuid, text, uuid) TO authenticated, service_role;

-- ----- Fix #4 — retention_policies updated_at trigger ------------------

CREATE TRIGGER retention_policies_set_updated_at
  BEFORE UPDATE ON archive.retention_policies
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ----- Fix #12 — FK-covering indexes -----------------------------------

CREATE INDEX IF NOT EXISTS idx_documents_organization              ON public.documents (organization_id);
CREATE INDEX IF NOT EXISTS idx_match_records_organization          ON public.match_records (organization_id);
CREATE INDEX IF NOT EXISTS idx_match_records_matched_by_user       ON public.match_records (matched_by_user_id) WHERE matched_by_user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_match_records_confirmed_by          ON public.match_records (confirmed_by) WHERE confirmed_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_review_issues_organization          ON public.review_issues (organization_id);
CREATE INDEX IF NOT EXISTS idx_review_issues_match_record          ON public.review_issues (match_record_id) WHERE match_record_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_review_issues_draft_ledger_entry    ON public.review_issues (draft_ledger_entry_id) WHERE draft_ledger_entry_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_review_issues_assigned_by           ON public.review_issues (assigned_by) WHERE assigned_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_review_issues_snoozed_by            ON public.review_issues (snoozed_by) WHERE snoozed_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_review_issues_resolved_by           ON public.review_issues (resolved_by) WHERE resolved_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_review_issues_auto_resolution_trig  ON public.review_issues (auto_resolution_trigger_issue_id) WHERE auto_resolution_trigger_issue_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_transactions_organization           ON public.transactions (organization_id);
CREATE INDEX IF NOT EXISTS idx_draft_ledger_entries_organization   ON public.draft_ledger_entries (organization_id);
CREATE INDEX IF NOT EXISTS idx_draft_ledger_entries_match_record   ON public.draft_ledger_entries (match_record_id) WHERE match_record_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_statement_uploads_organization      ON public.statement_uploads (organization_id);
CREATE INDEX IF NOT EXISTS idx_statement_uploads_uploaded_by       ON public.statement_uploads (uploaded_by);
CREATE INDEX IF NOT EXISTS idx_evidence_pdfs_organization          ON public.evidence_pdfs (organization_id);
CREATE INDEX IF NOT EXISTS idx_workflow_runs_organization          ON public.workflow_runs (organization_id);
CREATE INDEX IF NOT EXISTS idx_step_up_tokens_organization         ON public.step_up_tokens (organization_id);

CREATE INDEX IF NOT EXISTS idx_business_integrations_organization     ON public.business_integrations (organization_id);
CREATE INDEX IF NOT EXISTS idx_business_integrations_connected_user   ON public.business_integrations (connected_user_id) WHERE connected_user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_business_integrations_disconnected_by  ON public.business_integrations (disconnected_by) WHERE disconnected_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_business_user_roles_assigned_by        ON public.business_user_roles (assigned_by);
CREATE INDEX IF NOT EXISTS idx_drive_folder_mappings_organization     ON public.drive_folder_mappings (organization_id);
CREATE INDEX IF NOT EXISTS idx_organization_invitations_invited_by    ON public.organization_invitations (invited_by);
CREATE INDEX IF NOT EXISTS idx_organization_invitations_accepted_by   ON public.organization_invitations (accepted_by_user_id) WHERE accepted_by_user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_organization_invitations_revoked_by    ON public.organization_invitations (revoked_by) WHERE revoked_by IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_analytics_cash_movement_org           ON analytics.cash_movement (organization_id);
CREATE INDEX IF NOT EXISTS idx_analytics_client_invoice_status_org   ON analytics.client_invoice_status (organization_id);
CREATE INDEX IF NOT EXISTS idx_analytics_expense_overview_org        ON analytics.expense_overview (organization_id);
CREATE INDEX IF NOT EXISTS idx_analytics_finalized_periods_index_org ON analytics.finalized_periods_index (organization_id);
CREATE INDEX IF NOT EXISTS idx_analytics_income_overview_org         ON analytics.income_overview (organization_id);
CREATE INDEX IF NOT EXISTS idx_analytics_missing_documents_org       ON analytics.missing_documents (organization_id);
CREATE INDEX IF NOT EXISTS idx_analytics_monthly_overview_org        ON analytics.monthly_overview (organization_id);
CREATE INDEX IF NOT EXISTS idx_analytics_review_issues_summary_org   ON analytics.review_issues_summary (organization_id);
CREATE INDEX IF NOT EXISTS idx_analytics_subscriptions_overview_org  ON analytics.subscriptions_overview (organization_id);
CREATE INDEX IF NOT EXISTS idx_analytics_team_member_costs_org       ON analytics.team_member_costs (organization_id);
CREATE INDEX IF NOT EXISTS idx_analytics_vat_summary_org             ON analytics.vat_summary (organization_id);
