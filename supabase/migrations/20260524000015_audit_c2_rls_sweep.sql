-- Audit C2 — enable RLS + per-tenant policies on 20 runtime tables
-- =====================================================================
-- Before this migration, 20 tables in `public` had rowsecurity=false,
-- meaning any authenticated PostgREST caller could read them across tenant
-- boundaries (Supabase grants SELECT on public.* to authenticated by default).
--
-- Pattern matches existing project convention (workflow_runs, transactions,
-- documents, etc.): ENABLE + FORCE RLS + 4 policies per table:
--   <t>_select — restricted to current_org() + current_user_businesses()
--   <t>_no_insert — WITH CHECK (false)
--   <t>_no_update — USING (false)
--   <t>_no_delete — USING (false)
-- Writes still flow through SECURITY DEFINER RPCs as before; FORCE RLS does
-- not block those because the function owner role bypasses RLS in this
-- project's setup (verified against workflow_runs which is also FORCEd).
--
-- 4 categories of policy:
--   A. Per-business with org+biz cols (canonical pattern)
--   B. Per-business with biz-only column (no org check)
--   C. Per-row via parent FK (EXISTS subquery on parent's biz)
--   D. Global admin config (deny SELECT to authenticated; service_role bypasses)
-- =====================================================================

BEGIN;

-- ===== CATEGORY A: per-business with org + biz =====
-- end_scan_runs, out_workflow_reminders, statement_dedup_runs,
-- statement_normalization_runs, statement_normalized_rows,
-- statement_parse_runs, statement_upload_events_outbox

-- end_scan_runs
ALTER TABLE public.end_scan_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.end_scan_runs FORCE ROW LEVEL SECURITY;
CREATE POLICY end_scan_runs_select   ON public.end_scan_runs FOR SELECT USING (organization_id = current_org() AND business_id = ANY (current_user_businesses()));
CREATE POLICY end_scan_runs_no_insert ON public.end_scan_runs FOR INSERT WITH CHECK (false);
CREATE POLICY end_scan_runs_no_update ON public.end_scan_runs FOR UPDATE USING (false);
CREATE POLICY end_scan_runs_no_delete ON public.end_scan_runs FOR DELETE USING (false);

-- out_workflow_reminders
ALTER TABLE public.out_workflow_reminders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.out_workflow_reminders FORCE ROW LEVEL SECURITY;
CREATE POLICY out_workflow_reminders_select   ON public.out_workflow_reminders FOR SELECT USING (organization_id = current_org() AND business_id = ANY (current_user_businesses()));
CREATE POLICY out_workflow_reminders_no_insert ON public.out_workflow_reminders FOR INSERT WITH CHECK (false);
CREATE POLICY out_workflow_reminders_no_update ON public.out_workflow_reminders FOR UPDATE USING (false);
CREATE POLICY out_workflow_reminders_no_delete ON public.out_workflow_reminders FOR DELETE USING (false);

-- statement_dedup_runs
ALTER TABLE public.statement_dedup_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.statement_dedup_runs FORCE ROW LEVEL SECURITY;
CREATE POLICY statement_dedup_runs_select   ON public.statement_dedup_runs FOR SELECT USING (organization_id = current_org() AND business_id = ANY (current_user_businesses()));
CREATE POLICY statement_dedup_runs_no_insert ON public.statement_dedup_runs FOR INSERT WITH CHECK (false);
CREATE POLICY statement_dedup_runs_no_update ON public.statement_dedup_runs FOR UPDATE USING (false);
CREATE POLICY statement_dedup_runs_no_delete ON public.statement_dedup_runs FOR DELETE USING (false);

-- statement_normalization_runs
ALTER TABLE public.statement_normalization_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.statement_normalization_runs FORCE ROW LEVEL SECURITY;
CREATE POLICY statement_normalization_runs_select   ON public.statement_normalization_runs FOR SELECT USING (organization_id = current_org() AND business_id = ANY (current_user_businesses()));
CREATE POLICY statement_normalization_runs_no_insert ON public.statement_normalization_runs FOR INSERT WITH CHECK (false);
CREATE POLICY statement_normalization_runs_no_update ON public.statement_normalization_runs FOR UPDATE USING (false);
CREATE POLICY statement_normalization_runs_no_delete ON public.statement_normalization_runs FOR DELETE USING (false);

-- statement_normalized_rows
ALTER TABLE public.statement_normalized_rows ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.statement_normalized_rows FORCE ROW LEVEL SECURITY;
CREATE POLICY statement_normalized_rows_select   ON public.statement_normalized_rows FOR SELECT USING (organization_id = current_org() AND business_id = ANY (current_user_businesses()));
CREATE POLICY statement_normalized_rows_no_insert ON public.statement_normalized_rows FOR INSERT WITH CHECK (false);
CREATE POLICY statement_normalized_rows_no_update ON public.statement_normalized_rows FOR UPDATE USING (false);
CREATE POLICY statement_normalized_rows_no_delete ON public.statement_normalized_rows FOR DELETE USING (false);

-- statement_parse_runs
ALTER TABLE public.statement_parse_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.statement_parse_runs FORCE ROW LEVEL SECURITY;
CREATE POLICY statement_parse_runs_select   ON public.statement_parse_runs FOR SELECT USING (organization_id = current_org() AND business_id = ANY (current_user_businesses()));
CREATE POLICY statement_parse_runs_no_insert ON public.statement_parse_runs FOR INSERT WITH CHECK (false);
CREATE POLICY statement_parse_runs_no_update ON public.statement_parse_runs FOR UPDATE USING (false);
CREATE POLICY statement_parse_runs_no_delete ON public.statement_parse_runs FOR DELETE USING (false);

-- statement_upload_events_outbox
ALTER TABLE public.statement_upload_events_outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.statement_upload_events_outbox FORCE ROW LEVEL SECURITY;
CREATE POLICY statement_upload_events_outbox_select   ON public.statement_upload_events_outbox FOR SELECT USING (organization_id = current_org() AND business_id = ANY (current_user_businesses()));
CREATE POLICY statement_upload_events_outbox_no_insert ON public.statement_upload_events_outbox FOR INSERT WITH CHECK (false);
CREATE POLICY statement_upload_events_outbox_no_update ON public.statement_upload_events_outbox FOR UPDATE USING (false);
CREATE POLICY statement_upload_events_outbox_no_delete ON public.statement_upload_events_outbox FOR DELETE USING (false);


-- ===== CATEGORY B: per-business with biz-only column (no org column) =====
-- ai_cost_ceiling_runs, ai_gateway_invocations, business_ai_config,
-- classification_auto_confirm_thresholds

-- ai_cost_ceiling_runs
ALTER TABLE public.ai_cost_ceiling_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_cost_ceiling_runs FORCE ROW LEVEL SECURITY;
CREATE POLICY ai_cost_ceiling_runs_select   ON public.ai_cost_ceiling_runs FOR SELECT USING (business_id = ANY (current_user_businesses()));
CREATE POLICY ai_cost_ceiling_runs_no_insert ON public.ai_cost_ceiling_runs FOR INSERT WITH CHECK (false);
CREATE POLICY ai_cost_ceiling_runs_no_update ON public.ai_cost_ceiling_runs FOR UPDATE USING (false);
CREATE POLICY ai_cost_ceiling_runs_no_delete ON public.ai_cost_ceiling_runs FOR DELETE USING (false);

-- ai_gateway_invocations
ALTER TABLE public.ai_gateway_invocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_gateway_invocations FORCE ROW LEVEL SECURITY;
CREATE POLICY ai_gateway_invocations_select   ON public.ai_gateway_invocations FOR SELECT USING (business_id = ANY (current_user_businesses()));
CREATE POLICY ai_gateway_invocations_no_insert ON public.ai_gateway_invocations FOR INSERT WITH CHECK (false);
CREATE POLICY ai_gateway_invocations_no_update ON public.ai_gateway_invocations FOR UPDATE USING (false);
CREATE POLICY ai_gateway_invocations_no_delete ON public.ai_gateway_invocations FOR DELETE USING (false);

-- business_ai_config
ALTER TABLE public.business_ai_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_ai_config FORCE ROW LEVEL SECURITY;
CREATE POLICY business_ai_config_select   ON public.business_ai_config FOR SELECT USING (business_id = ANY (current_user_businesses()));
CREATE POLICY business_ai_config_no_insert ON public.business_ai_config FOR INSERT WITH CHECK (false);
CREATE POLICY business_ai_config_no_update ON public.business_ai_config FOR UPDATE USING (false);
CREATE POLICY business_ai_config_no_delete ON public.business_ai_config FOR DELETE USING (false);

-- classification_auto_confirm_thresholds
ALTER TABLE public.classification_auto_confirm_thresholds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.classification_auto_confirm_thresholds FORCE ROW LEVEL SECURITY;
CREATE POLICY classification_auto_confirm_thresholds_select   ON public.classification_auto_confirm_thresholds FOR SELECT USING (business_id = ANY (current_user_businesses()));
CREATE POLICY classification_auto_confirm_thresholds_no_insert ON public.classification_auto_confirm_thresholds FOR INSERT WITH CHECK (false);
CREATE POLICY classification_auto_confirm_thresholds_no_update ON public.classification_auto_confirm_thresholds FOR UPDATE USING (false);
CREATE POLICY classification_auto_confirm_thresholds_no_delete ON public.classification_auto_confirm_thresholds FOR DELETE USING (false);


-- ===== CATEGORY C: per-row via parent FK =====
-- statement_dedup_row_classifications (parent: statement_dedup_runs)
-- statement_parsed_rows (parent: statement_parse_runs)

ALTER TABLE public.statement_dedup_row_classifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.statement_dedup_row_classifications FORCE ROW LEVEL SECURITY;
CREATE POLICY statement_dedup_row_classifications_select ON public.statement_dedup_row_classifications FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM public.statement_dedup_runs p
    WHERE p.id = statement_dedup_row_classifications.dedup_run_id
      AND p.organization_id = current_org()
      AND p.business_id = ANY (current_user_businesses())
  )
);
CREATE POLICY statement_dedup_row_classifications_no_insert ON public.statement_dedup_row_classifications FOR INSERT WITH CHECK (false);
CREATE POLICY statement_dedup_row_classifications_no_update ON public.statement_dedup_row_classifications FOR UPDATE USING (false);
CREATE POLICY statement_dedup_row_classifications_no_delete ON public.statement_dedup_row_classifications FOR DELETE USING (false);

ALTER TABLE public.statement_parsed_rows ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.statement_parsed_rows FORCE ROW LEVEL SECURITY;
CREATE POLICY statement_parsed_rows_select ON public.statement_parsed_rows FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM public.statement_parse_runs p
    WHERE p.id = statement_parsed_rows.parse_run_id
      AND p.organization_id = current_org()
      AND p.business_id = ANY (current_user_businesses())
  )
);
CREATE POLICY statement_parsed_rows_no_insert ON public.statement_parsed_rows FOR INSERT WITH CHECK (false);
CREATE POLICY statement_parsed_rows_no_update ON public.statement_parsed_rows FOR UPDATE USING (false);
CREATE POLICY statement_parsed_rows_no_delete ON public.statement_parsed_rows FOR DELETE USING (false);


-- ===== CATEGORY D: global admin config (deny SELECT to authenticated) =====
-- prompt_deployments, prompt_registry, prompt_test_cases,
-- redaction_active_policy, redaction_policies, tier_3_pricing,
-- statement_parser_registry
-- service_role bypasses RLS so admin scripts/RPCs still work

ALTER TABLE public.prompt_deployments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prompt_deployments FORCE ROW LEVEL SECURITY;
CREATE POLICY prompt_deployments_deny_select ON public.prompt_deployments FOR SELECT USING (false);
CREATE POLICY prompt_deployments_no_insert   ON public.prompt_deployments FOR INSERT WITH CHECK (false);
CREATE POLICY prompt_deployments_no_update   ON public.prompt_deployments FOR UPDATE USING (false);
CREATE POLICY prompt_deployments_no_delete   ON public.prompt_deployments FOR DELETE USING (false);

ALTER TABLE public.prompt_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prompt_registry FORCE ROW LEVEL SECURITY;
CREATE POLICY prompt_registry_deny_select ON public.prompt_registry FOR SELECT USING (false);
CREATE POLICY prompt_registry_no_insert   ON public.prompt_registry FOR INSERT WITH CHECK (false);
CREATE POLICY prompt_registry_no_update   ON public.prompt_registry FOR UPDATE USING (false);
CREATE POLICY prompt_registry_no_delete   ON public.prompt_registry FOR DELETE USING (false);

ALTER TABLE public.prompt_test_cases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prompt_test_cases FORCE ROW LEVEL SECURITY;
CREATE POLICY prompt_test_cases_deny_select ON public.prompt_test_cases FOR SELECT USING (false);
CREATE POLICY prompt_test_cases_no_insert   ON public.prompt_test_cases FOR INSERT WITH CHECK (false);
CREATE POLICY prompt_test_cases_no_update   ON public.prompt_test_cases FOR UPDATE USING (false);
CREATE POLICY prompt_test_cases_no_delete   ON public.prompt_test_cases FOR DELETE USING (false);

ALTER TABLE public.redaction_active_policy ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.redaction_active_policy FORCE ROW LEVEL SECURITY;
CREATE POLICY redaction_active_policy_deny_select ON public.redaction_active_policy FOR SELECT USING (false);
CREATE POLICY redaction_active_policy_no_insert   ON public.redaction_active_policy FOR INSERT WITH CHECK (false);
CREATE POLICY redaction_active_policy_no_update   ON public.redaction_active_policy FOR UPDATE USING (false);
CREATE POLICY redaction_active_policy_no_delete   ON public.redaction_active_policy FOR DELETE USING (false);

ALTER TABLE public.redaction_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.redaction_policies FORCE ROW LEVEL SECURITY;
CREATE POLICY redaction_policies_deny_select ON public.redaction_policies FOR SELECT USING (false);
CREATE POLICY redaction_policies_no_insert   ON public.redaction_policies FOR INSERT WITH CHECK (false);
CREATE POLICY redaction_policies_no_update   ON public.redaction_policies FOR UPDATE USING (false);
CREATE POLICY redaction_policies_no_delete   ON public.redaction_policies FOR DELETE USING (false);

ALTER TABLE public.tier_3_pricing ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tier_3_pricing FORCE ROW LEVEL SECURITY;
CREATE POLICY tier_3_pricing_deny_select ON public.tier_3_pricing FOR SELECT USING (false);
CREATE POLICY tier_3_pricing_no_insert   ON public.tier_3_pricing FOR INSERT WITH CHECK (false);
CREATE POLICY tier_3_pricing_no_update   ON public.tier_3_pricing FOR UPDATE USING (false);
CREATE POLICY tier_3_pricing_no_delete   ON public.tier_3_pricing FOR DELETE USING (false);

ALTER TABLE public.statement_parser_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.statement_parser_registry FORCE ROW LEVEL SECURITY;
CREATE POLICY statement_parser_registry_deny_select ON public.statement_parser_registry FOR SELECT USING (false);
CREATE POLICY statement_parser_registry_no_insert   ON public.statement_parser_registry FOR INSERT WITH CHECK (false);
CREATE POLICY statement_parser_registry_no_update   ON public.statement_parser_registry FOR UPDATE USING (false);
CREATE POLICY statement_parser_registry_no_delete   ON public.statement_parser_registry FOR DELETE USING (false);

COMMIT;
