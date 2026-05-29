-- B11·P03 — Per-Business Chart Customization & Versioning
-- =====================================================================
-- Customization API (Owner/Admin only); each call bumps the mapping version
-- (or reuses an active batch version). Block 15 calls
-- chart_freeze_version_for_period on period finalization to lock the version.
--
-- Audit events (declared in P01, emitted here):
--   CHART_ACCOUNT_CREATED, CHART_ACCOUNT_DISABLED, CHART_ACCOUNT_UPDATED
--   CHART_MAPPING_RULE_CREATED, CHART_MAPPING_RULE_DISABLED
--   CHART_MAPPING_VERSION_CREATED, CHART_MAPPING_VERSION_FROZEN
--
-- Permission gate: Owner/Admin only (BOOKKEEPER, ACCOUNTANT, REVIEWER,
-- READ_ONLY denied via _chart_assert_owner_or_admin raising INSUFFICIENT_PRIVILEGE).
--
-- Deferred to later phases / Stage 2+:
--   * Phase 07 picks up chart_resolve_mapping_version on entry creation
--   * Phase 08 raises requires_accountant_review when resolved rule points
--     at a disabled account
--   * Backdated effective_from (Stage 2+)
-- =====================================================================

BEGIN;

-- 0. Soft-delete column on mapping rules + active-only resolution index
ALTER TABLE public.chart_of_accounts_mappings
  ADD COLUMN disabled_at timestamptz;
CREATE INDEX coam_active_resolution_idx ON public.chart_of_accounts_mappings
  (business_id, transaction_type, tag, vat_treatment, entry_kind, priority DESC)
  WHERE disabled_at IS NULL;
COMMENT ON COLUMN public.chart_of_accounts_mappings.disabled_at IS
  'Soft-delete: existing draft_ledger_entries pinned to this rule via mapping_version_id remain resolvable; new resolutions skip disabled rules.';


-- 1. Permission gate helper (private; raises INSUFFICIENT_PRIVILEGE if not OWNER/ADMIN)
CREATE OR REPLACE FUNCTION public._chart_assert_owner_or_admin(
  p_actor_user_id uuid, p_business_id uuid
) RETURNS public.user_role LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_role public.user_role;
BEGIN
  SELECT role INTO v_role FROM public.business_user_roles
   WHERE user_id = p_actor_user_id AND business_id = p_business_id AND status = 'ACTIVE'
   LIMIT 1;
  IF v_role IS NULL OR v_role NOT IN ('OWNER','ADMIN') THEN
    RAISE EXCEPTION 'INSUFFICIENT_PRIVILEGE' USING errcode='42501';
  END IF;
  RETURN v_role;
END;
$$;


-- 2. STABLE resolver — version with largest effective_from <= period_start
CREATE OR REPLACE FUNCTION public.chart_resolve_mapping_version(
  p_business_id uuid, p_period_start timestamptz
) RETURNS uuid LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT id FROM public.chart_of_accounts_mapping_versions
   WHERE business_id = p_business_id AND effective_from <= p_period_start
   ORDER BY effective_from DESC, version_number DESC
   LIMIT 1;
$$;


-- 3. Internal helper: reuse provided active version (if non-frozen) or
-- create a new one (version_number=prev+1, effective_from=now) and emit
-- CHART_MAPPING_VERSION_CREATED.
CREATE OR REPLACE FUNCTION public._chart_get_or_create_active_version(
  p_organization_id uuid, p_business_id uuid,
  p_active_version_id uuid, p_actor_user_id uuid, p_actor_role public.user_role,
  p_context jsonb
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_version_id  uuid;
  v_prev_number int;
  v_frozen_at   timestamptz;
BEGIN
  IF p_active_version_id IS NOT NULL THEN
    SELECT frozen_at INTO v_frozen_at FROM public.chart_of_accounts_mapping_versions
      WHERE id = p_active_version_id AND business_id = p_business_id;
    IF v_frozen_at IS NULL AND FOUND THEN
      RETURN p_active_version_id;
    END IF;
  END IF;

  SELECT COALESCE(max(version_number), 0) INTO v_prev_number
    FROM public.chart_of_accounts_mapping_versions WHERE business_id = p_business_id;
  v_version_id := public.gen_uuid_v7();
  INSERT INTO public.chart_of_accounts_mapping_versions
    (id, organization_id, business_id, version_number, effective_from, created_by)
  VALUES (v_version_id, p_organization_id, p_business_id, v_prev_number + 1,
          clock_timestamp(), p_actor_user_id);

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='CHART_MAPPING_VERSION_CREATED',
    p_subject_type:='CHART_MAPPING_VERSION'::audit.subject_type_enum,
    p_subject_id:=v_version_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=p_actor_role, p_actor_session_id:=NULL,
    p_actor_system:=NULL,
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('version_number', v_prev_number + 1),
    p_reason:=NULL, p_request_context:=p_context
  );
  RETURN v_version_id;
END;
$$;


-- 4. chart_begin_batch — open a single new version for multiple edits ------
CREATE OR REPLACE FUNCTION public.chart_begin_batch(
  p_organization_id uuid, p_business_id uuid, p_actor_user_id uuid,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_role public.user_role;
BEGIN
  v_role := public._chart_assert_owner_or_admin(p_actor_user_id, p_business_id);
  RETURN public._chart_get_or_create_active_version(
    p_organization_id, p_business_id, NULL, p_actor_user_id, v_role, p_context);
END;
$$;


-- 5. chart_add_account ----------------------------------------------------
CREATE OR REPLACE FUNCTION public.chart_add_account(
  p_organization_id uuid, p_business_id uuid,
  p_code text, p_name text, p_account_class text,
  p_parent_code text DEFAULT NULL, p_category text DEFAULT NULL,
  p_deductibility text DEFAULT 'NA',
  p_actor_user_id uuid DEFAULT NULL,
  p_active_version_id uuid DEFAULT NULL,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_role public.user_role;
  v_version_id uuid;
  v_account_id uuid;
BEGIN
  v_role := public._chart_assert_owner_or_admin(p_actor_user_id, p_business_id);
  v_version_id := public._chart_get_or_create_active_version(
    p_organization_id, p_business_id, p_active_version_id, p_actor_user_id, v_role, p_context);

  v_account_id := public.gen_uuid_v7();
  INSERT INTO public.chart_of_accounts
    (id, organization_id, business_id, code, name, account_class, parent_code, category, deductibility, is_seeded)
  VALUES (v_account_id, p_organization_id, p_business_id,
          p_code, p_name, p_account_class::public.account_class_enum,
          p_parent_code, p_category, p_deductibility::public.account_deductibility_enum, false);

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='CHART_ACCOUNT_CREATED',
    p_subject_type:='CHART_OF_ACCOUNTS_ENTRY'::audit.subject_type_enum,
    p_subject_id:=v_account_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=v_role, p_actor_session_id:=NULL,
    p_actor_system:=NULL,
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('code',p_code,'name',p_name,
                                       'account_class',p_account_class,
                                       'deductibility',p_deductibility,
                                       'mapping_version_id',v_version_id),
    p_reason:=NULL, p_request_context:=p_context
  );
  RETURN v_account_id;
END;
$$;


-- 6. chart_rename_account -------------------------------------------------
CREATE OR REPLACE FUNCTION public.chart_rename_account(
  p_organization_id uuid, p_business_id uuid, p_code text, p_new_name text,
  p_actor_user_id uuid, p_active_version_id uuid DEFAULT NULL,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_role public.user_role;
  v_version_id uuid;
  v_account_id uuid;
  v_old_name text;
BEGIN
  v_role := public._chart_assert_owner_or_admin(p_actor_user_id, p_business_id);
  v_version_id := public._chart_get_or_create_active_version(
    p_organization_id, p_business_id, p_active_version_id, p_actor_user_id, v_role, p_context);

  SELECT id, name INTO v_account_id, v_old_name FROM public.chart_of_accounts
   WHERE business_id = p_business_id AND code = p_code FOR UPDATE;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'ACCOUNT_NOT_FOUND' USING errcode='check_violation';
  END IF;

  UPDATE public.chart_of_accounts SET name = p_new_name, updated_at = clock_timestamp()
    WHERE id = v_account_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='CHART_ACCOUNT_UPDATED',
    p_subject_type:='CHART_OF_ACCOUNTS_ENTRY'::audit.subject_type_enum,
    p_subject_id:=v_account_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=v_role, p_actor_session_id:=NULL,
    p_actor_system:=NULL,
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=jsonb_build_object('name', v_old_name),
    p_after_state:=jsonb_build_object('name', p_new_name, 'mapping_version_id', v_version_id),
    p_reason:=NULL, p_request_context:=p_context
  );
  RETURN v_account_id;
END;
$$;


-- 7. chart_disable_account ------------------------------------------------
CREATE OR REPLACE FUNCTION public.chart_disable_account(
  p_organization_id uuid, p_business_id uuid, p_code text,
  p_actor_user_id uuid, p_active_version_id uuid DEFAULT NULL,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_role public.user_role;
  v_version_id uuid;
  v_account_id uuid;
BEGIN
  v_role := public._chart_assert_owner_or_admin(p_actor_user_id, p_business_id);
  v_version_id := public._chart_get_or_create_active_version(
    p_organization_id, p_business_id, p_active_version_id, p_actor_user_id, v_role, p_context);

  SELECT id INTO v_account_id FROM public.chart_of_accounts
   WHERE business_id = p_business_id AND code = p_code FOR UPDATE;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'ACCOUNT_NOT_FOUND' USING errcode='check_violation';
  END IF;

  UPDATE public.chart_of_accounts SET disabled_at = clock_timestamp(), updated_at = clock_timestamp()
    WHERE id = v_account_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='CHART_ACCOUNT_DISABLED',
    p_subject_type:='CHART_OF_ACCOUNTS_ENTRY'::audit.subject_type_enum,
    p_subject_id:=v_account_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=v_role, p_actor_session_id:=NULL,
    p_actor_system:=NULL,
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('code', p_code, 'mapping_version_id', v_version_id),
    p_reason:=NULL, p_request_context:=p_context
  );
  RETURN v_account_id;
END;
$$;


-- 8. chart_add_mapping_rule -----------------------------------------------
CREATE OR REPLACE FUNCTION public.chart_add_mapping_rule(
  p_organization_id uuid, p_business_id uuid,
  p_transaction_type text, p_tag text, p_vat_treatment text, p_entry_kind text,
  p_direction text, p_account_code text, p_priority int,
  p_actor_user_id uuid, p_active_version_id uuid DEFAULT NULL,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_role public.user_role;
  v_version_id uuid;
  v_mapping_id uuid;
  v_acct_disabled timestamptz;
BEGIN
  v_role := public._chart_assert_owner_or_admin(p_actor_user_id, p_business_id);

  SELECT disabled_at INTO v_acct_disabled FROM public.chart_of_accounts
   WHERE business_id = p_business_id AND code = p_account_code;
  IF v_acct_disabled IS NOT NULL THEN
    RAISE EXCEPTION 'ACCOUNT_DISABLED' USING errcode='check_violation';
  END IF;

  v_version_id := public._chart_get_or_create_active_version(
    p_organization_id, p_business_id, p_active_version_id, p_actor_user_id, v_role, p_context);

  v_mapping_id := public.gen_uuid_v7();
  INSERT INTO public.chart_of_accounts_mappings
    (id, organization_id, business_id, mapping_version_id,
     transaction_type, tag, vat_treatment, entry_kind, direction, account_code, priority, is_seeded)
  VALUES (v_mapping_id, p_organization_id, p_business_id, v_version_id,
          p_transaction_type::public.transaction_type_enum,
          p_tag,
          p_vat_treatment::public.vat_treatment_enum,
          COALESCE(p_entry_kind, 'PRIMARY')::public.ledger_entry_kind_enum,
          p_direction::public.ledger_entry_type_enum,
          p_account_code, COALESCE(p_priority, 100), false);

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='CHART_MAPPING_RULE_CREATED',
    p_subject_type:='CHART_MAPPING_RULE'::audit.subject_type_enum,
    p_subject_id:=v_mapping_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=v_role, p_actor_session_id:=NULL,
    p_actor_system:=NULL,
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('transaction_type',p_transaction_type,'tag',p_tag,
                                       'vat_treatment',p_vat_treatment,'direction',p_direction,
                                       'account_code',p_account_code,'priority',p_priority,
                                       'mapping_version_id',v_version_id),
    p_reason:=NULL, p_request_context:=p_context
  );
  RETURN v_mapping_id;
END;
$$;


-- 9. chart_disable_mapping_rule -------------------------------------------
-- The existing coam_block_when_version_frozen trigger (from P01) blocks
-- this UPDATE automatically if the rule's version is frozen.
CREATE OR REPLACE FUNCTION public.chart_disable_mapping_rule(
  p_organization_id uuid, p_business_id uuid, p_mapping_rule_id uuid,
  p_actor_user_id uuid, p_active_version_id uuid DEFAULT NULL,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_role public.user_role;
  v_version_id uuid;
BEGIN
  v_role := public._chart_assert_owner_or_admin(p_actor_user_id, p_business_id);
  v_version_id := public._chart_get_or_create_active_version(
    p_organization_id, p_business_id, p_active_version_id, p_actor_user_id, v_role, p_context);

  UPDATE public.chart_of_accounts_mappings
    SET disabled_at = clock_timestamp(), updated_at = clock_timestamp()
   WHERE id = p_mapping_rule_id AND business_id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'MAPPING_RULE_NOT_FOUND' USING errcode='check_violation';
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum,
    p_action:='CHART_MAPPING_RULE_DISABLED',
    p_subject_type:='CHART_MAPPING_RULE'::audit.subject_type_enum,
    p_subject_id:=p_mapping_rule_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=v_role, p_actor_session_id:=NULL,
    p_actor_system:=NULL,
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('mapping_rule_id', p_mapping_rule_id, 'mapping_version_id', v_version_id),
    p_reason:=NULL, p_request_context:=p_context
  );
  RETURN p_mapping_rule_id;
END;
$$;


-- 10. chart_freeze_version_for_period (Block 15 calls this) ---------------
CREATE OR REPLACE FUNCTION public.chart_freeze_version_for_period(
  p_organization_id uuid, p_business_id uuid, p_mapping_version_id uuid,
  p_actor_user_id uuid DEFAULT NULL, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_already timestamptz;
BEGIN
  SELECT frozen_at INTO v_already FROM public.chart_of_accounts_mapping_versions
   WHERE id = p_mapping_version_id AND business_id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'MAPPING_VERSION_NOT_FOUND' USING errcode='check_violation';
  END IF;
  IF v_already IS NOT NULL THEN
    RETURN jsonb_build_object('decision','NOOP','reason','already_frozen',
                              'mapping_version_id', p_mapping_version_id, 'frozen_at', v_already);
  END IF;

  UPDATE public.chart_of_accounts_mapping_versions
    SET frozen_at = clock_timestamp() WHERE id = p_mapping_version_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='CHART_MAPPING_VERSION_FROZEN',
    p_subject_type:='CHART_MAPPING_VERSION'::audit.subject_type_enum,
    p_subject_id:=p_mapping_version_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='block_15_finalizer',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('mapping_version_id', p_mapping_version_id,
                                       'initiating_user_id', p_actor_user_id),
    p_reason:=NULL, p_request_context:=p_context
  );
  RETURN jsonb_build_object('decision','FROZEN', 'mapping_version_id', p_mapping_version_id);
END;
$$;


-- 11. Privileges ----------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public._chart_assert_owner_or_admin(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._chart_get_or_create_active_version(uuid, uuid, uuid, uuid, public.user_role, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.chart_begin_batch(uuid, uuid, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.chart_add_account(uuid, uuid, text, text, text, text, text, text, uuid, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.chart_rename_account(uuid, uuid, text, text, uuid, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.chart_disable_account(uuid, uuid, text, uuid, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.chart_add_mapping_rule(uuid, uuid, text, text, text, text, text, text, int, uuid, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.chart_disable_mapping_rule(uuid, uuid, uuid, uuid, uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.chart_freeze_version_for_period(uuid, uuid, uuid, uuid, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.chart_resolve_mapping_version(uuid, timestamptz) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.chart_begin_batch(uuid, uuid, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.chart_add_account(uuid, uuid, text, text, text, text, text, text, uuid, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.chart_rename_account(uuid, uuid, text, text, uuid, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.chart_disable_account(uuid, uuid, text, uuid, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.chart_add_mapping_rule(uuid, uuid, text, text, text, text, text, text, int, uuid, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.chart_disable_mapping_rule(uuid, uuid, uuid, uuid, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.chart_freeze_version_for_period(uuid, uuid, uuid, uuid, jsonb) TO authenticated, service_role;

COMMIT;
