-- B15·P06 — Manifest Versioning for Adjustments
-- Adjustment-finalization sequence: additive to an existing archive_packages
-- row. Writes manifest_vN, N≥2, alongside v1. No edits to prior versions;
-- promotes only adjustment-period dle rows that have not yet been promoted.

CREATE OR REPLACE FUNCTION public._compose_ledger_entries_adjustment_json(
  p_business_id uuid, p_archive_package_id uuid, p_period_start date, p_period_end date
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, archive, pg_temp
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', dle.id, 'parent_transaction_id', dle.parent_transaction_id,
    'match_record_id', dle.match_record_id, 'entry_kind', dle.entry_kind,
    'debit_account_code', dle.debit_account_code, 'credit_account_code', dle.credit_account_code,
    'debit_amount', dle.debit_amount, 'credit_amount', dle.credit_amount,
    'currency', dle.currency, 'entry_period', dle.entry_period,
    'vat_treatment', dle.vat_treatment,
    'input_vat_reclaimable_amount', dle.input_vat_reclaimable_amount,
    'output_vat_due_amount', dle.output_vat_due_amount,
    'vies_relevant', dle.vies_relevant, 'status', dle.status
  ) ORDER BY dle.id), '[]'::jsonb)
  FROM public.draft_ledger_entries dle
  JOIN public.transactions t ON t.id = dle.parent_transaction_id
 WHERE t.business_id = p_business_id
   AND t.transaction_date BETWEEN p_period_start AND p_period_end
   AND NOT EXISTS (
     SELECT 1 FROM archive.locked_ledger_entries lle
      WHERE lle.id = dle.id AND lle.archive_package_id = p_archive_package_id);
$$;

CREATE OR REPLACE FUNCTION public._compose_adjustment_records_json(p_adjustment_run_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', ar.id, 'run_id', ar.run_id, 'parent_run_id', ar.parent_run_id,
    'parent_period_start', ar.parent_period_start,
    'parent_period_end', ar.parent_period_end,
    'reason', ar.reason, 'delta_kind', ar.delta_kind,
    'delta_payload', ar.delta_payload,
    'requesting_user_id', ar.requesting_user_id,
    'created_at', ar.created_at
  ) ORDER BY ar.id), '[]'::jsonb)
  FROM public.adjustment_records ar WHERE ar.run_id = p_adjustment_run_id;
$$;

CREATE OR REPLACE FUNCTION public._compose_review_issues_adjustment_json(p_adjustment_run_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', ri.id, 'issue_type', ri.issue_type,
    'severity', ri.severity, 'status', ri.status,
    'plain_language_title', ri.plain_language_title,
    'resolved_at', ri.resolved_at, 'snoozed_until', ri.snoozed_until
  ) ORDER BY ri.id), '[]'::jsonb)
  FROM public.review_issues ri WHERE ri.workflow_run_id = p_adjustment_run_id;
$$;

CREATE OR REPLACE FUNCTION public._compose_manifest_vN_json(
  p_run_id uuid, p_archive_package_id uuid, p_version int, p_supersedes int,
  p_internal_file_hashes jsonb, p_bundle_hash_anchor text,
  p_delta_kinds text[], p_evidence_inherited int[]
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_run public.workflow_runs;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  RETURN jsonb_build_object(
    'manifest_version_number', p_version,
    'supersedes_manifest_version', p_supersedes,
    'archive_package_id', p_archive_package_id,
    'business_id', v_run.business_id,
    'organization_id', v_run.organization_id,
    'produced_by_run_id', v_run.id,
    'period_start', v_run.period_start::date,
    'period_end', v_run.period_end::date,
    'bundle_hash_anchor', p_bundle_hash_anchor,
    'internal_file_hashes', p_internal_file_hashes,
    'delta_kinds_applied', to_jsonb(COALESCE(p_delta_kinds, ARRAY[]::text[])),
    'evidence_inherited_from_versions', to_jsonb(COALESCE(p_evidence_inherited, ARRAY[]::int[])));
END;
$$;

CREATE OR REPLACE FUNCTION public._promote_adjustment_to_locked_ledger(
  p_business_id uuid, p_organization_id uuid, p_archive_package_id uuid,
  p_period_start date, p_period_end date, p_manifest_version int
) RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, archive, pg_temp
AS $$
DECLARE v_count int;
BEGIN
  PERFORM set_config('app.adjustment_lock_active', '1', true);
  WITH dle_to_promote AS (
    SELECT dle.* FROM public.draft_ledger_entries dle
      JOIN public.transactions t ON t.id = dle.parent_transaction_id
     WHERE t.business_id = p_business_id
       AND t.transaction_date BETWEEN p_period_start AND p_period_end
       AND NOT EXISTS (
         SELECT 1 FROM archive.locked_ledger_entries lle
          WHERE lle.id = dle.id AND lle.archive_package_id = p_archive_package_id)
  ),
  ins AS (
    INSERT INTO archive.locked_ledger_entries (
      id, organization_id, business_id, parent_transaction_id, match_record_id,
      entry_kind, debit_account_code, credit_account_code, debit_amount, credit_amount,
      currency, entry_period, counterparty_country, counterparty_vat_number, vat_treatment,
      input_vat_reclaimable_flag, input_vat_reclaimable_amount, output_vat_due_flag,
      output_vat_due_amount, reverse_charge_relevant, vies_relevant, requires_contract,
      requires_invoice, requires_receipt, requires_accountant_review, accountant_review_reason,
      chart_mapping_version_id, vat_rate_table_version, status, created_at, last_recomputed_at,
      entry_currency_original, entry_amount_original, vies_period, vies_value_basis_eur,
      vat_treatment_explanation, manual_override_by, manual_override_reason, manual_override_at,
      archive_package_id, archive_manifest_version)
    SELECT id, organization_id, business_id, parent_transaction_id, match_record_id,
           entry_kind, debit_account_code, credit_account_code, debit_amount, credit_amount,
           currency, entry_period, counterparty_country, counterparty_vat_number, vat_treatment,
           input_vat_reclaimable_flag, input_vat_reclaimable_amount, output_vat_due_flag,
           output_vat_due_amount, reverse_charge_relevant, vies_relevant, requires_contract,
           requires_invoice, requires_receipt, requires_accountant_review, accountant_review_reason,
           chart_mapping_version_id, vat_rate_table_version, status, created_at, last_recomputed_at,
           entry_currency_original, entry_amount_original, vies_period, vies_value_basis_eur,
           vat_treatment_explanation, manual_override_by, manual_override_reason, manual_override_at,
           p_archive_package_id, p_manifest_version
      FROM dle_to_promote
    RETURNING 1
  )
  SELECT count(*) INTO v_count FROM ins;
  PERFORM set_config('app.adjustment_lock_active', '0', true);
  RETURN v_count;
END;
$$;

-- The full execute_adjustment_lock_sequence RPC and tool_registry insert are
-- in the DB (applied via apply_migration b15p06_manifest_versioning_for_adjustments).
