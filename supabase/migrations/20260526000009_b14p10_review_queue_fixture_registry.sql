-- B14·P10 — End-to-End Review Queue Fixture Registry
-- =====================================================================
-- DB-side catalog for the 80 regression fixtures that bookend Block 14.
-- Mirrors B12·P10 and B13·P12 — registry + stub runner + view.
-- The real test executor lives in the app-layer engine (Stage 6).
-- =====================================================================

CREATE TABLE public.review_queue_fixture_registry (
  id                      uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  fixture_name            text NOT NULL UNIQUE,
  category                text NOT NULL,
  description             text NOT NULL,
  expected_audit_actions  text[] NOT NULL DEFAULT '{}',
  covers_phases           text[] NOT NULL DEFAULT '{}',
  covers_invariants       text[] NOT NULL DEFAULT '{}',
  fixture_paths           jsonb  NOT NULL DEFAULT '{}'::jsonb,
  notes                   text,
  created_at              timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT review_queue_fixture_registry_category_chk CHECK (
    category IN ('issue_routing','severity_gating','card_rendering',
                 'resolution_action','bulk_action','notes_and_assignment',
                 'snooze','rescan_on_resolution','mobile_read_only',
                 'cross_cutting')),
  CONSTRAINT review_queue_fixture_registry_paths_chk CHECK (
    fixture_paths <> '{}'::jsonb),
  CONSTRAINT review_queue_fixture_registry_audits_chk CHECK (
    cardinality(expected_audit_actions) >= 1),
  CONSTRAINT review_queue_fixture_registry_phases_chk CHECK (
    cardinality(covers_phases) >= 1)
);

CREATE INDEX review_queue_fixture_registry_category_idx
  ON public.review_queue_fixture_registry (category);

COMMENT ON TABLE public.review_queue_fixture_registry IS
  'B14·P10 fixture catalog: every Block 14 regression fixture has one row pinning the expected audit actions, the B14 phases it exercises, invariants verified, and the JSON file paths the app-layer runner loads.';


CREATE OR REPLACE FUNCTION public.list_review_queue_fixtures(p_category text DEFAULT NULL)
RETURNS SETOF public.review_queue_fixture_registry LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT * FROM public.review_queue_fixture_registry
   WHERE p_category IS NULL OR category = p_category
   ORDER BY category, fixture_name;
$$;
REVOKE EXECUTE ON FUNCTION public.list_review_queue_fixtures(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.list_review_queue_fixtures(text) TO service_role, authenticated;


CREATE OR REPLACE VIEW public.v_review_queue_fixture_coverage AS
  SELECT category,
         count(*)                                                          AS fixture_count,
         array_agg(DISTINCT p ORDER BY p) FILTER (WHERE p IS NOT NULL)     AS distinct_phases,
         count(*) FILTER (WHERE 'P02' = ANY(covers_phases))                 AS covers_p02,
         count(*) FILTER (WHERE 'P03' = ANY(covers_phases))                 AS covers_p03,
         count(*) FILTER (WHERE 'P04' = ANY(covers_phases))                 AS covers_p04,
         count(*) FILTER (WHERE 'P05' = ANY(covers_phases))                 AS covers_p05,
         count(*) FILTER (WHERE 'P06' = ANY(covers_phases))                 AS covers_p06,
         count(*) FILTER (WHERE 'P07' = ANY(covers_phases))                 AS covers_p07,
         count(*) FILTER (WHERE 'P08' = ANY(covers_phases))                 AS covers_p08,
         count(*) FILTER (WHERE 'P09' = ANY(covers_phases))                 AS covers_p09
    FROM public.review_queue_fixture_registry,
         LATERAL unnest(covers_phases) AS p
   GROUP BY category
   ORDER BY category;

COMMENT ON VIEW public.v_review_queue_fixture_coverage IS
  'B14·P10 coverage rollup: per-category fixture_count + per-B14-phase coverage counts.';


CREATE OR REPLACE FUNCTION public.review_queue_run_fixture(
  p_fixture_name    text,
  p_organization_id uuid DEFAULT NULL,
  p_actor_user_id   uuid DEFAULT NULL,
  p_context         jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE v_row public.review_queue_fixture_registry%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM public.review_queue_fixture_registry
   WHERE fixture_name = p_fixture_name;
  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'review_queue.run_fixture: unknown fixture %', p_fixture_name USING ERRCODE='02000';
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='REVIEW_QUEUE_FIXTURE_RAN',
    p_subject_type:='ACCESS_DECISION'::audit.subject_type_enum,
    p_subject_id:=COALESCE(p_organization_id, v_row.id),
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='review_queue_fixture_runner',
    p_organization_id:=p_organization_id, p_business_id:=NULL,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'fixture_name', v_row.fixture_name,
      'category', v_row.category,
      'covers_phases', v_row.covers_phases,
      'covers_invariants', v_row.covers_invariants,
      'initiating_user_id', p_actor_user_id),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'status','PENDING_IMPLEMENTATION',
    'reason','runtime executor lives in app-layer engine (Stage 6); DB-side stub records the audit only',
    'fixture_name', v_row.fixture_name,
    'category', v_row.category,
    'covers_phases', v_row.covers_phases,
    'expected_audit_actions', v_row.expected_audit_actions);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.review_queue_run_fixture(text,uuid,uuid,jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.review_queue_run_fixture(text,uuid,uuid,jsonb) TO service_role;


-- =====================================================================
-- Seed: 80 fixtures across 10 categories. The full INSERT body (six
-- multi-row INSERTs per category, naming every fixture with its
-- expected_audit_actions / covers_phases / covers_invariants /
-- fixture_paths) was applied on 2026-05-26 via the apply_migration
-- tool with name b14p10_review_queue_fixture_registry. Per-category
-- inventory below; full row content lives in the DB.
--
--   issue_routing (6):
--     routing_endscan_unusual_amount
--     routing_matching_no_match_out_expense
--     routing_classification_unknown_type
--     routing_ledger_accountant_review_unknown_treatment
--     routing_invoice_numbering_gap_detected
--     routing_unregistered_issue_type_rejected
--
--   severity_gating (5):
--     severity_high_blocks_finalization_gate
--     severity_medium_does_not_block
--     severity_blocking_blocks_even_with_approval
--     severity_critical_value_rejected
--     severity_critical_drift_lint_check
--
--   card_rendering (7):
--     card_content_tier_2_default
--     card_content_tier_3_escalation_blocking
--     card_content_tier_3_escalation_cross_currency
--     card_content_ai_failure_fallback
--     card_content_cache_hit_in_run
--     card_content_immutable_after_creation
--     card_content_regenerate_owner_only
--
--   resolution_action (16): one per closed 13-action + 3 edge cases
--     (idempotent_on_already_closed, disallowed_action_rejected,
--     permission_denied_for_reviewer).
--
--   bulk_action (7): preview_then_apply · partial_success ·
--     severity_blocking_skipped · cross_bucket_rejected · expired_token ·
--     filter_based_selection · triggers_gate_re_evaluation_once.
--
--   notes_and_assignment (11): notes_update_succeeds · notes_reviewer_denied
--     · 4 assignment-success paths · 4 assignment-rejection paths ·
--     non_assignee_resolves · email_opt_out · notification_failure_raises.
--
--   snooze (9): snooze_medium · snooze_high/blocking_rejected ·
--     empty_reason · manual_unsnooze · carry_forward · severity_elevated_clears
--     · persists_through_finalization · bulk_snooze_skips_high.
--
--   rescan_on_resolution (9): affected_set_one_hop · auto_resolves ·
--     severity_demotion_persists_snooze · severity_elevation_clears_snooze ·
--     surfaces_new_issue · revalidation_failure_no_rollback · manual_wider ·
--     gate_re_evaluates_after · bulk_resolution_debounced.
--
--   mobile_read_only (8): view_queue · resolution_disabled_soft_prompt ·
--     copy_link · send_to_my_inbox · form_factor_write_rejected ·
--     notes_read_only · assignment_read_only · settings_redirect.
--
--   cross_cutting (2):
--     ready_to_finalize_state_when_all_buckets_empty
--     human_review_hold_phase_name_vs_run_state
--
-- Total: 80 fixtures. Forward-only mirror — re-running this file as the
-- only source would create the schema + RPCs + view but not the seed
-- rows; the canonical seed is in the applied migration.
