-- B14·P01 — Schema Extensions for review_issues
-- =====================================================================
-- Most of the spec's "extension" surface is already in place from prior
-- audit fixes (B04·P04 + audit-C2 + B12·P07): all 13 review_issues columns,
-- assignment+snooze CHECKs, self-FK auto_resolution_trigger_issue_id, and
-- 4 permission_matrix surfaces (VIEW/RESOLVE/ASSIGN/REGENERATE) already
-- exist with the spec's role-grant matrix. This migration ships the 4
-- remaining deltas:
--   1. 2 missing review_issues indexes (bucket-filter + snooze carry-forward)
--   2. NEW bulk_preview_tokens table (Phase 05 confirmation flow)
--   3. NEW issue_type_registry table (Phase 02 routing)
--   4. Boot-audit emission acknowledging the 4 review-queue surfaces
-- =====================================================================

-- 1. Missing indexes ---------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_review_issues_business_group_status
  ON public.review_issues (business_id, issue_group, status);

CREATE INDEX IF NOT EXISTS idx_review_issues_business_snoozed_until
  ON public.review_issues (business_id, snoozed_until)
  WHERE snoozed_until IS NOT NULL;


-- 2. bulk_preview_tokens (Phase 05 confirmation flow) ------------------

CREATE TABLE public.bulk_preview_tokens (
  id                  uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id     uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  business_id         uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,
  actor_user_id       uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  action_kind         text NOT NULL,
  affected_issue_ids  uuid[] NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at          timestamptz NOT NULL DEFAULT (clock_timestamp() + interval '5 minutes'),
  consumed_at         timestamptz,
  CONSTRAINT bulk_preview_tokens_affected_ids_nonempty_chk CHECK (
    array_length(affected_issue_ids, 1) >= 1),
  CONSTRAINT bulk_preview_tokens_action_kind_nonempty_chk CHECK (
    length(trim(action_kind)) > 0),
  CONSTRAINT bulk_preview_tokens_expires_after_created_chk CHECK (
    expires_at > created_at)
);

CREATE INDEX bulk_preview_tokens_business_expires_idx
  ON public.bulk_preview_tokens (business_id, expires_at);

CREATE INDEX bulk_preview_tokens_actor_expires_idx
  ON public.bulk_preview_tokens (actor_user_id, expires_at);

COMMENT ON TABLE public.bulk_preview_tokens IS
  'B14·P01: short-lived (5 min default) tokens capturing the exact issue set for Phase 05 bulk-action confirmation; consumed_at populated by bulk.applyAction. Prevents stale-filter races.';

ALTER TABLE public.bulk_preview_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bulk_preview_tokens FORCE  ROW LEVEL SECURITY;

CREATE POLICY bulk_preview_tokens_select_org_biz ON public.bulk_preview_tokens
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.business_user_roles bur
       WHERE bur.business_id = bulk_preview_tokens.business_id
         AND bur.organization_id = bulk_preview_tokens.organization_id
         AND bur.user_id = (SELECT u.id FROM public.users u WHERE u.auth_user_id = auth.uid())
    )
  );

CREATE POLICY bulk_preview_tokens_deny_write_insert ON public.bulk_preview_tokens
  FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY bulk_preview_tokens_deny_write_update ON public.bulk_preview_tokens
  FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY bulk_preview_tokens_deny_write_delete ON public.bulk_preview_tokens
  FOR DELETE TO authenticated USING (false);


-- 3. issue_type_registry (Phase 02 routing) ----------------------------

CREATE TABLE public.issue_type_registry (
  issue_type                   text PRIMARY KEY,
  default_group                public.review_issue_group_enum NOT NULL,
  default_severity             public.review_issue_severity_enum NOT NULL,
  allowed_resolution_actions   text[] NOT NULL,
  producing_block              text NOT NULL,
  plain_language_template_ref  text,
  validity_check_fn_ref        text,
  registered_at                timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT issue_type_registry_allowed_actions_nonempty_chk CHECK (
    array_length(allowed_resolution_actions, 1) >= 1),
  CONSTRAINT issue_type_registry_issue_type_nonempty_chk CHECK (
    length(trim(issue_type)) > 0)
);

COMMENT ON TABLE public.issue_type_registry IS
  'B14·P01: global (per-engine) registry of every review-issue type — default group/severity, allowed resolution actions, producing block, plain-language template ref, validity-check fn ref. Phase 02 routes inserts through this registry.';

ALTER TABLE public.issue_type_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.issue_type_registry FORCE  ROW LEVEL SECURITY;

CREATE POLICY issue_type_registry_select_all_authenticated
  ON public.issue_type_registry
  FOR SELECT TO authenticated
  USING (true);

CREATE POLICY issue_type_registry_deny_write_insert
  ON public.issue_type_registry
  FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY issue_type_registry_deny_write_update
  ON public.issue_type_registry
  FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY issue_type_registry_deny_write_delete
  ON public.issue_type_registry
  FOR DELETE TO authenticated USING (false);


-- 4. Boot-audit acknowledging the 4 review-queue surfaces --------------

DO $$
DECLARE v_surface text;
BEGIN
  FOREACH v_surface IN ARRAY ARRAY[
    'REVIEW_QUEUE_VIEW',
    'REVIEW_QUEUE_RESOLVE',
    'REVIEW_ASSIGN',
    'REVIEW_REGENERATE'
  ] LOOP
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='REVIEW_QUEUE_PERMISSION_SURFACE_REGISTERED',
      p_subject_type:='ACCESS_DECISION'::audit.subject_type_enum,
      p_subject_id:=public.gen_uuid_v7(),
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='b14_p01_boot',
      p_organization_id:=NULL, p_business_id:=NULL,
      p_before_state:=NULL,
      p_after_state:=(
        SELECT jsonb_build_object(
          'surface', v_surface,
          'allow_roles', (
            SELECT array_agg(pm.role::text ORDER BY pm.role::text)
              FROM public.permission_matrix pm
             WHERE pm.surface = v_surface AND pm.decision = 'ALLOW'
          ),
          'deny_roles', (
            SELECT array_agg(pm.role::text ORDER BY pm.role::text)
              FROM public.permission_matrix pm
             WHERE pm.surface = v_surface AND pm.decision = 'DENY'
          ),
          'role_count_total', (
            SELECT count(*) FROM public.permission_matrix pm WHERE pm.surface = v_surface
          )
        )
      ),
      p_reason:=NULL,
      p_request_context:=jsonb_build_object('phase','B14_P01','migration','20260525000001_b14p01_review_queue_schema_extensions')
    );
  END LOOP;
END $$;
