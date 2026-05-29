-- B14·P02 — Issue Groups, Routing & Severity
-- =====================================================================
-- Pins the canonical taxonomies:
--   - review_issue_group_enum: 5 values (already in place from prior phases)
--   - review_issue_severity_enum: 4 values incl. BLOCKING (already in place)
-- Ships:
--   1. register_issue_type RPC — idempotent UPSERT + audit on changes
--   2. Seed of ~40 issue_type rows covering every namespaced type emitted
--      by Blocks 06-13 + spec's Stage 1 catalog
--   3. DEFERRABLE FK review_issues.issue_type → issue_type_registry
--   4. v_blocking_issues view — canonical predicate for finalize gates
--   5. v_ready_to_finalize_runs view — UI projection
--   6. v_issue_type_coverage view — per-block rollup
-- =====================================================================


-- 1. register_issue_type RPC -------------------------------------------

CREATE OR REPLACE FUNCTION public.register_issue_type(
  p_issue_type                  text,
  p_default_group               public.review_issue_group_enum,
  p_default_severity            public.review_issue_severity_enum,
  p_allowed_resolution_actions  text[],
  p_producing_block             text,
  p_plain_language_template_ref text DEFAULT NULL,
  p_validity_check_fn_ref       text DEFAULT NULL,
  p_context                     jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_before public.issue_type_registry%ROWTYPE;
  v_after  public.issue_type_registry%ROWTYPE;
  v_changed boolean := false;
BEGIN
  IF p_issue_type IS NULL OR length(trim(p_issue_type)) = 0 THEN
    RAISE EXCEPTION 'register_issue_type: issue_type required' USING ERRCODE = '22023';
  END IF;
  IF p_producing_block IS NULL OR length(trim(p_producing_block)) = 0 THEN
    RAISE EXCEPTION 'register_issue_type: producing_block required' USING ERRCODE = '22023';
  END IF;
  IF p_allowed_resolution_actions IS NULL OR cardinality(p_allowed_resolution_actions) < 1 THEN
    RAISE EXCEPTION 'register_issue_type: allowed_resolution_actions must be non-empty' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_before FROM public.issue_type_registry WHERE issue_type = p_issue_type;

  INSERT INTO public.issue_type_registry (
    issue_type, default_group, default_severity, allowed_resolution_actions,
    producing_block, plain_language_template_ref, validity_check_fn_ref
  ) VALUES (
    p_issue_type, p_default_group, p_default_severity, p_allowed_resolution_actions,
    p_producing_block, p_plain_language_template_ref, p_validity_check_fn_ref
  )
  ON CONFLICT (issue_type) DO UPDATE
     SET default_group               = EXCLUDED.default_group,
         default_severity            = EXCLUDED.default_severity,
         allowed_resolution_actions  = EXCLUDED.allowed_resolution_actions,
         producing_block             = EXCLUDED.producing_block,
         plain_language_template_ref = EXCLUDED.plain_language_template_ref,
         validity_check_fn_ref       = EXCLUDED.validity_check_fn_ref
  RETURNING * INTO v_after;

  v_changed := v_before.issue_type IS NULL
            OR v_before.default_group               IS DISTINCT FROM v_after.default_group
            OR v_before.default_severity            IS DISTINCT FROM v_after.default_severity
            OR v_before.allowed_resolution_actions  IS DISTINCT FROM v_after.allowed_resolution_actions
            OR v_before.producing_block             IS DISTINCT FROM v_after.producing_block
            OR v_before.plain_language_template_ref IS DISTINCT FROM v_after.plain_language_template_ref
            OR v_before.validity_check_fn_ref       IS DISTINCT FROM v_after.validity_check_fn_ref;

  IF v_changed THEN
    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='REVIEW_ISSUE_TYPE_REGISTERED',
      p_subject_type:='ACCESS_DECISION'::audit.subject_type_enum,
      p_subject_id:=public.gen_uuid_v7(),
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='issue_type_registry',
      p_organization_id:=NULL, p_business_id:=NULL,
      p_before_state:=CASE WHEN v_before.issue_type IS NULL THEN NULL ELSE row_to_json(v_before)::jsonb END,
      p_after_state:=row_to_json(v_after)::jsonb,
      p_reason:=NULL, p_request_context:=p_context);
  END IF;

  RETURN jsonb_build_object(
    'decision', 'ALLOW',
    'issue_type', p_issue_type,
    'changed', v_changed,
    'was_insert', v_before.issue_type IS NULL);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.register_issue_type(text, public.review_issue_group_enum, public.review_issue_severity_enum, text[], text, text, text, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.register_issue_type(text, public.review_issue_group_enum, public.review_issue_severity_enum, text[], text, text, text, jsonb) TO service_role;

COMMENT ON FUNCTION public.register_issue_type(text, public.review_issue_group_enum, public.review_issue_severity_enum, text[], text, text, text, jsonb) IS
  'B14·P02: idempotent UPSERT into issue_type_registry; emits REVIEW_ISSUE_TYPE_REGISTERED audit on insert OR meaningful change. Service-role only; called at migration time by producing blocks.';


-- 2. Seed canonical set -----------------------------------------------

DO $$
DECLARE
  v_actions_common text[] := ARRAY['ACKNOWLEDGE','MARK_REVIEWED'];
BEGIN
  PERFORM public.register_issue_type('bank_pipeline.declared_period_mismatch',     'POSSIBLE_WRONG_MATCH', 'HIGH',    v_actions_common, 'bank_pipeline');
  PERFORM public.register_issue_type('bank_pipeline.evidence_pdf_generation_failed','MISSING_DOCUMENTS',    'HIGH',    v_actions_common, 'bank_pipeline');
  PERFORM public.register_issue_type('bank_pipeline.partial_upload',                'MISSING_DOCUMENTS',    'HIGH',    v_actions_common, 'bank_pipeline');
  PERFORM public.register_issue_type('bank_pipeline.row_outside_declared_period',   'POSSIBLE_WRONG_MATCH', 'MEDIUM',  v_actions_common, 'bank_pipeline');

  PERFORM public.register_issue_type('classification.ai_fallback_failed',  'NEEDS_CONFIRMATION',   'HIGH',     v_actions_common, 'classification');
  PERFORM public.register_issue_type('classification.layer_disagreement',  'POSSIBLE_WRONG_MATCH', 'MEDIUM',   v_actions_common, 'classification');
  PERFORM public.register_issue_type('classification.needs_confirmation',  'NEEDS_CONFIRMATION',   'MEDIUM',   v_actions_common, 'classification');
  PERFORM public.register_issue_type('classification.rule_conflict',       'POSSIBLE_WRONG_MATCH', 'HIGH',     v_actions_common, 'classification');
  PERFORM public.register_issue_type('classification.unknown_type',        'POSSIBLE_WRONG_MATCH', 'BLOCKING', v_actions_common, 'classification');

  PERFORM public.register_issue_type('client.vat_number_format_invalid',   'POSSIBLE_TAX_VAT_ISSUE','MEDIUM',  v_actions_common, 'client');

  PERFORM public.register_issue_type('counterparty.country_disagreement',  'POSSIBLE_WRONG_MATCH', 'MEDIUM',   v_actions_common, 'counterparty');
  PERFORM public.register_issue_type('counterparty.vat_number_invalid',    'POSSIBLE_TAX_VAT_ISSUE','MEDIUM',  v_actions_common, 'counterparty');

  PERFORM public.register_issue_type('dedup.possible_duplicate',           'POSSIBLE_WRONG_MATCH', 'MEDIUM',   v_actions_common, 'dedup');
  PERFORM public.register_issue_type('dedup.needs_review',                 'POSSIBLE_WRONG_MATCH', 'MEDIUM',   v_actions_common, 'dedup');

  PERFORM public.register_issue_type('document.extraction_failed',         'MISSING_DOCUMENTS',    'HIGH',     v_actions_common, 'document');
  PERFORM public.register_issue_type('document.field_validation_failed',   'NEEDS_CONFIRMATION',   'MEDIUM',   v_actions_common, 'document');

  PERFORM public.register_issue_type('drive.folder_naming_non_convention', 'NEEDS_CONFIRMATION',   'LOW',      v_actions_common, 'drive');

  PERFORM public.register_issue_type('endscan.unusual_amount',             'UNUSUAL_TRANSACTION',  'MEDIUM',   v_actions_common, 'endscan');
  PERFORM public.register_issue_type('endscan.large_outlier',              'UNUSUAL_TRANSACTION',  'HIGH',     v_actions_common, 'endscan');

  PERFORM public.register_issue_type('in_filter.unknown_positive_blocker', 'POSSIBLE_WRONG_MATCH', 'HIGH',     v_actions_common, 'in_filter');

  PERFORM public.register_issue_type('income_matching.invoice_lifecycle_failed',       'POSSIBLE_WRONG_MATCH',  'HIGH',   v_actions_common, 'income_matching');
  PERFORM public.register_issue_type('income_matching.multiple_invoices_one_payment',  'POSSIBLE_WRONG_MATCH',  'MEDIUM', v_actions_common, 'income_matching');
  PERFORM public.register_issue_type('income_matching.no_match',                       'MISSING_DOCUMENTS',     'HIGH',   v_actions_common, 'income_matching');
  PERFORM public.register_issue_type('income_matching.overpayment_credit_note_required','POSSIBLE_TAX_VAT_ISSUE','MEDIUM', v_actions_common, 'income_matching');
  PERFORM public.register_issue_type('income_matching.possible_refund_or_transfer',    'POSSIBLE_WRONG_MATCH',  'MEDIUM', v_actions_common, 'income_matching');

  PERFORM public.register_issue_type('invoice.numbering_gap_detected',                   'POSSIBLE_WRONG_MATCH','HIGH',    v_actions_common, 'invoice');
  PERFORM public.register_issue_type('invoice.duplicate_payment_against_same_invoice',   'POSSIBLE_WRONG_MATCH','MEDIUM',  v_actions_common, 'invoice');
  PERFORM public.register_issue_type('invoice.duplicate_invoice_claim_across_transactions','POSSIBLE_WRONG_MATCH','BLOCKING',v_actions_common, 'invoice');

  PERFORM public.register_issue_type('invoice_numbering.gap_detected',     'POSSIBLE_WRONG_MATCH', 'HIGH',     v_actions_common, 'invoice_numbering');

  PERFORM public.register_issue_type('ledger.accountant_review_unknown_treatment', 'POSSIBLE_TAX_VAT_ISSUE','HIGH',     v_actions_common, 'ledger');
  PERFORM public.register_issue_type('ledger.held_pending_classification',         'NEEDS_CONFIRMATION',    'HIGH',     v_actions_common, 'ledger');
  PERFORM public.register_issue_type('ledger.missing_required_evidence',           'MISSING_DOCUMENTS',     'HIGH',     v_actions_common, 'ledger');
  PERFORM public.register_issue_type('ledger.requires_accountant_review',          'POSSIBLE_TAX_VAT_ISSUE','HIGH',     v_actions_common, 'ledger');
  PERFORM public.register_issue_type('ledger.tag_mismatch_detected',               'POSSIBLE_TAX_VAT_ISSUE','MEDIUM',   v_actions_common, 'ledger');
  PERFORM public.register_issue_type('ledger.vies_vat_number_missing',             'POSSIBLE_TAX_VAT_ISSUE','MEDIUM',   v_actions_common, 'ledger');

  PERFORM public.register_issue_type('match.missing_documents',       'MISSING_DOCUMENTS',    'HIGH',     v_actions_common, 'matching');
  PERFORM public.register_issue_type('match.needs_confirmation',      'NEEDS_CONFIRMATION',   'MEDIUM',   v_actions_common, 'matching');
  PERFORM public.register_issue_type('match.possible_weak',           'POSSIBLE_WRONG_MATCH', 'MEDIUM',   v_actions_common, 'matching');

  PERFORM public.register_issue_type('matching.no_match_out_expense',            'MISSING_DOCUMENTS',     'HIGH',    v_actions_common, 'matching');
  PERFORM public.register_issue_type('matching.possible_match',                  'NEEDS_CONFIRMATION',    'MEDIUM',  v_actions_common, 'matching');
  PERFORM public.register_issue_type('matching.matched_needs_confirmation',      'NEEDS_CONFIRMATION',    'MEDIUM',  v_actions_common, 'matching');
  PERFORM public.register_issue_type('matching.split_payment_proposal',          'POSSIBLE_WRONG_MATCH',  'MEDIUM',  v_actions_common, 'matching');
  PERFORM public.register_issue_type('matching.document_used_multiple_times',    'POSSIBLE_WRONG_MATCH',  'HIGH',    v_actions_common, 'matching');
  PERFORM public.register_issue_type('matching.transaction_multi_match',         'POSSIBLE_WRONG_MATCH',  'HIGH',    v_actions_common, 'matching');
  PERFORM public.register_issue_type('matching.multi_invoice_one_payment',       'POSSIBLE_WRONG_MATCH',  'MEDIUM',  v_actions_common, 'matching');
  PERFORM public.register_issue_type('matching.possible_refund_or_transfer',     'POSSIBLE_WRONG_MATCH',  'MEDIUM',  v_actions_common, 'matching');
  PERFORM public.register_issue_type('matching.reason_fallback_applied',         'NEEDS_CONFIRMATION',    'LOW',     v_actions_common, 'matching');
  PERFORM public.register_issue_type('matching.duplicate_invoice_claim_across_transactions','POSSIBLE_WRONG_MATCH','BLOCKING',v_actions_common, 'matching');

  PERFORM public.register_issue_type('out_filter.unknown_blocker',       'POSSIBLE_WRONG_MATCH', 'HIGH',    v_actions_common, 'out_filter');
END $$;


-- 3. DEFERRABLE FK review_issues.issue_type → issue_type_registry ------

ALTER TABLE public.review_issues
  ADD CONSTRAINT review_issues_issue_type_fkey
  FOREIGN KEY (issue_type) REFERENCES public.issue_type_registry(issue_type)
  ON DELETE RESTRICT
  DEFERRABLE INITIALLY DEFERRED;


-- 4. v_blocking_issues view --------------------------------------------

CREATE OR REPLACE VIEW public.v_blocking_issues AS
  SELECT *
    FROM public.review_issues
   WHERE severity IN ('HIGH'::public.review_issue_severity_enum,
                      'BLOCKING'::public.review_issue_severity_enum)
     AND status = 'OPEN'::public.review_issue_status_enum;

COMMENT ON VIEW public.v_blocking_issues IS
  'B14·P02 canonical predicate for finalize gates: severity IN (HIGH, BLOCKING) AND status=OPEN. Block 12·P05 and Block 13·P09 gates inline this predicate; this view is the single source-of-truth reference.';


-- 5. v_ready_to_finalize_runs view -------------------------------------

CREATE OR REPLACE VIEW public.v_ready_to_finalize_runs AS
  SELECT wr.id              AS workflow_run_id,
         wr.organization_id,
         wr.business_id,
         wr.workflow_type,
         wr.status          AS workflow_run_status,
         wr.period_start,
         wr.period_end,
         (NOT EXISTS (
           SELECT 1 FROM public.v_blocking_issues bi
            WHERE bi.workflow_run_id = wr.id
         ))                  AS is_ready_to_finalize,
         (SELECT count(*)::int FROM public.v_blocking_issues bi
            WHERE bi.workflow_run_id = wr.id) AS blocking_issue_count
    FROM public.workflow_runs wr;

COMMENT ON VIEW public.v_ready_to_finalize_runs IS
  'B14·P02 UI projection: per workflow_run, is_ready_to_finalize=true iff no v_blocking_issues. The Ready to Finalize card is rendered from this projection (NOT a review_issues row).';


-- 6. v_issue_type_coverage view ----------------------------------------

CREATE OR REPLACE VIEW public.v_issue_type_coverage AS
  SELECT producing_block,
         count(*)                                                          AS issue_type_count,
         count(*) FILTER (WHERE default_severity = 'BLOCKING')              AS blocking_count,
         count(*) FILTER (WHERE default_severity = 'HIGH')                  AS high_count,
         count(*) FILTER (WHERE default_severity = 'MEDIUM')                AS medium_count,
         count(*) FILTER (WHERE default_severity = 'LOW')                   AS low_count,
         array_agg(DISTINCT default_group::text ORDER BY default_group::text) AS distinct_groups
    FROM public.issue_type_registry
   GROUP BY producing_block
   ORDER BY producing_block;

COMMENT ON VIEW public.v_issue_type_coverage IS
  'B14·P02 diagnostic rollup: per-producing_block issue_type counts and severity distribution.';
