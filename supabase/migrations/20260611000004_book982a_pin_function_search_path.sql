-- =============================================================================
-- BOOK-982 (a) — pin search_path on 35 SECURITY INVOKER helper functions.
-- =============================================================================
-- The security advisor flags function_search_path_mutable for 35 helper functions
-- (round_half_up, is_eu_member_state, canonicalize_*, compute_*, suggest_*, the
-- fn_block_* / *_tg triggers, etc.). All are SECURITY INVOKER (verified — none are
-- DEFINER), so a mutable search_path is not an escalation vector, but pinning it is
-- best practice and clears the advisor. None reference audit/archive/keys/secrets
-- (verified), so 'public', 'pg_temp' is sufficient (pg_catalog is searched first
-- implicitly). Applied to every overload of each name.
-- =============================================================================

DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
    WHERE p.proname = ANY (ARRAY[
      '_check_form_factor_guard','ai_gateway_minimize_payload','ai_tier_canonical_label',
      'build_match_reason_fallback','calibrate_ai_classification_confidence','canonicalize_country_alpha2',
      'canonicalize_vat_number','coam_block_when_version_frozen','compute_amount_exact_match',
      'compute_date_proximity','compute_income_match_outcome','compute_invoice_number_match',
      'cyprus_vat_rate_for_category','fn_block_invoice_currency_change','fn_block_invoice_delete_non_draft',
      'fn_default_pro_forma_expires_at','fn_is_eu_country','get_in_workflow_evidence_rule',
      'infer_evidence_flags','infer_service_or_goods','invoice_vat_aware_text','is_eu_member_state',
      'is_exempt_category','is_outside_scope_transaction_type','merge_layer_confidence','model_id_for_tier',
      'recurring_template_compute_next_due_date','resolve_tag_name','round_half_up','suggest_payment_terms',
      'suggest_reverse_charge_applicable','suggest_vat_treatment','validate_vat_number_format',
      'vendor_memory_confidence_for_count','workflow_runs_snapshot_immutable_tg'
    ])
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = %L, %L', r.sig, 'public', 'pg_temp');
  END LOOP;
END $$;
