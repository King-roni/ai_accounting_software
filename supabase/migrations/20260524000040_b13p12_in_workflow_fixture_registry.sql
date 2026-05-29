-- B13·P12 — End-to-End IN Workflow & Invoice Generator Fixture Registry
-- =====================================================================
-- DB-side fixture catalogue for the Block 13 sub-systems: Invoice Generator
-- (P01–P06), IN_MONTHLY (P07–P10), and IN_ADJUSTMENT (P11). Mirrors B12·P10
-- exactly — table + list RPC + stub runner; the real test executor lives in
-- the app-layer engine (TS).
--
-- 3 audit actions:
--   IN_WORKFLOW_FIXTURE_RAN     (stub-emitted by run_fixture)
--   IN_WORKFLOW_FIXTURE_PASSED  (reserved for app-layer runner)
--   IN_WORKFLOW_FIXTURE_FAILED  (reserved for app-layer runner)
-- =====================================================================

CREATE TABLE public.in_workflow_fixture_registry (
  id                        uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  fixture_name              text NOT NULL UNIQUE,
  category                  text NOT NULL,
  description               text NOT NULL,
  workflow_type             public.workflow_type_enum,
  expected_terminal_state   public.workflow_run_status_enum,
  expected_audit_actions    text[] NOT NULL DEFAULT '{}',
  covers_phase_names        text[] NOT NULL DEFAULT '{}',
  covers_invariants         text[] NOT NULL DEFAULT '{}',
  fixture_paths             jsonb  NOT NULL DEFAULT '{}'::jsonb,
  notes                     text,
  created_at                timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT in_workflow_fixture_registry_category_chk CHECK (
    category IN ('invoice_generator','pdf_rendering','in_monthly',
                 'paired_out_in','triggers_and_idempotency',
                 'in_adjustment','end_scan_in')),
  CONSTRAINT in_workflow_fixture_registry_paths_chk CHECK (
    fixture_paths <> '{}'::jsonb),
  CONSTRAINT in_workflow_fixture_registry_audits_chk CHECK (
    array_length(expected_audit_actions, 1) >= 1),
  CONSTRAINT in_workflow_fixture_registry_wf_type_nullable_chk CHECK (
    (category IN ('invoice_generator','pdf_rendering') AND workflow_type IS NULL)
    OR (category NOT IN ('invoice_generator','pdf_rendering') AND workflow_type IS NOT NULL))
);

CREATE INDEX in_workflow_fixture_registry_category_idx
  ON public.in_workflow_fixture_registry (category);

COMMENT ON TABLE public.in_workflow_fixture_registry IS
  'B13·P12 fixture catalogue: every IN-side regression fixture (Invoice Generator + IN_MONTHLY + IN_ADJUSTMENT) has one row pinning expected audits, terminal run state, invariants, and the JSON file paths the app-layer runner loads.';


CREATE OR REPLACE FUNCTION public.list_in_workflow_fixtures(p_category text DEFAULT NULL)
RETURNS SETOF public.in_workflow_fixture_registry LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT * FROM public.in_workflow_fixture_registry
   WHERE p_category IS NULL OR category = p_category
   ORDER BY category, fixture_name;
$$;
REVOKE EXECUTE ON FUNCTION public.list_in_workflow_fixtures(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.list_in_workflow_fixtures(text) TO service_role, authenticated;


CREATE OR REPLACE VIEW public.v_in_workflow_fixture_coverage AS
  SELECT category,
         count(*)                                           AS fixture_count,
         count(*) FILTER (WHERE workflow_type IS NOT NULL)  AS workflow_fixture_count,
         count(DISTINCT workflow_type)                      AS distinct_workflow_types,
         count(*) FILTER (
           WHERE expected_terminal_state = 'FINALIZED'::public.workflow_run_status_enum
         )                                                  AS finalizing_fixture_count
    FROM public.in_workflow_fixture_registry
   GROUP BY category
   ORDER BY category;

COMMENT ON VIEW public.v_in_workflow_fixture_coverage IS
  'B13·P12 coverage rollup: fixture counts per subsystem category.';


CREATE OR REPLACE FUNCTION public.in_workflow_run_fixture(
  p_fixture_name text,
  p_organization_id uuid DEFAULT NULL,
  p_actor_user_id uuid DEFAULT NULL,
  p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_row public.in_workflow_fixture_registry%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM public.in_workflow_fixture_registry
   WHERE fixture_name = p_fixture_name;
  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'in_workflow.run_fixture: unknown fixture %', p_fixture_name USING ERRCODE='02000';
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='IN_WORKFLOW_FIXTURE_RAN',
    p_subject_type:='BUSINESS'::audit.subject_type_enum,
    p_subject_id:=COALESCE(p_organization_id, v_row.id),
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='in_workflow_fixture_runner',
    p_organization_id:=p_organization_id, p_business_id:=NULL,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'fixture_name', v_row.fixture_name,
      'category', v_row.category,
      'workflow_type', v_row.workflow_type::text,
      'expected_terminal_state', v_row.expected_terminal_state::text,
      'covers_invariants', v_row.covers_invariants,
      'initiating_user_id', p_actor_user_id),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'status','PENDING_IMPLEMENTATION',
    'reason','runtime executor lives in Block 03 app-layer engine (TS); DB-side stub records the audit only',
    'fixture_name', v_row.fixture_name,
    'category', v_row.category,
    'workflow_type', v_row.workflow_type::text,
    'expected_terminal_state', v_row.expected_terminal_state::text,
    'expected_audit_actions', v_row.expected_audit_actions);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.in_workflow_run_fixture(text,uuid,uuid,jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.in_workflow_run_fixture(text,uuid,uuid,jsonb) TO service_role;


-- =====================================================================
-- Seed: 59 fixtures across 7 categories
-- =====================================================================

INSERT INTO public.in_workflow_fixture_registry
  (fixture_name, category, description, workflow_type, expected_terminal_state,
   expected_audit_actions, covers_phase_names, covers_invariants, fixture_paths)
VALUES
('invoice_create_simple_tax_invoice','invoice_generator',
 'User composes a 3-line invoice; totals compute correctly; DRAFT→SENT; INV-YYYY-NNNN allocates atomically; PDF renders with VAT-treatment text',
 NULL, NULL,
 ARRAY['INVOICE_CREATED','INVOICE_SENT','INVOICE_NUMBER_ALLOCATED','INVOICE_PDF_RENDERED'],
 ARRAY['INVOICE_COMPOSITION','INVOICE_LIFECYCLE','PDF_RENDER'],
 ARRAY['ATOMIC_NUMBERING','VAT_TREATMENT_DERIVED','TOTALS_COMPUTED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_invoice_actions.json'],'expected',ARRAY['expected_invoice_state.json','expected_pdf_hashes.json'])),
('invoice_currency_lock_immutable','invoice_generator',
 'Invoice issued in EUR; attempt to change currency post-creation is rejected',
 NULL, NULL,
 ARRAY['INVOICE_CREATED','INVOICE_CURRENCY_CHANGE_REJECTED'],
 ARRAY['INVOICE_COMPOSITION'],
 ARRAY['CURRENCY_IMMUTABLE'],
 jsonb_build_object('input',ARRAY['business_state.json','input_invoice_actions.json'],'expected',ARRAY['expected_invoice_state.json'])),
('invoice_numbering_gap_detected','invoice_generator',
 'Artificially injected gap in INV-YYYY-NNNN sequence; daily integrity job raises HIGH review issue INVOICE_NUMBER_GAP_DETECTED',
 NULL, NULL,
 ARRAY['INVOICE_NUMBER_GAP_DETECTED','REVIEW_ISSUE_CREATED'],
 ARRAY['INVOICE_NUMBERING'],
 ARRAY['SEQUENCE_GAP_DETECTION','HIGH_SEVERITY_RAISED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_invoice_actions.json'],'expected',ARRAY['expected_invoice_state.json'])),
('invoice_void_via_credit_note','invoice_generator',
 'Issued invoice cannot be deleted; user issues full-amount credit note; source invoice→CREDITED; CN-YYYY-NNNN from separate sequence',
 NULL, NULL,
 ARRAY['INVOICE_DELETE_REJECTED','CREDIT_NOTE_CREATED','INVOICE_TRANSITIONED_CREDITED'],
 ARRAY['INVOICE_LIFECYCLE','CREDIT_NOTE'],
 ARRAY['NO_DELETE_AFTER_ISSUE','SEPARATE_CN_SEQUENCE','VOID_VIA_CN_PATTERN'],
 jsonb_build_object('input',ARRAY['business_state.json','input_invoice_actions.json'],'expected',ARRAY['expected_invoice_state.json'])),
('pro_forma_create_and_render','invoice_generator',
 'PRO-YYYY-NNNN allocates from pro-forma sequence; PDF renders with watermark; restricted lifecycle (cannot reach PAID)',
 NULL, NULL,
 ARRAY['INVOICE_CREATED','INVOICE_PDF_RENDERED','INVOICE_LIFECYCLE_RESTRICTED'],
 ARRAY['INVOICE_COMPOSITION','PDF_RENDER'],
 ARRAY['PRO_FORMA_SEPARATE_SEQUENCE','PRO_FORMA_WATERMARK','PRO_FORMA_NO_PAID'],
 jsonb_build_object('input',ARRAY['business_state.json','input_invoice_actions.json'],'expected',ARRAY['expected_invoice_state.json','expected_pdf_hashes.json'])),
('pro_forma_to_tax_invoice_conversion','invoice_generator',
 'User converts sent pro-forma; fresh INV-YYYY-NNNN; line items copy; pro-forma→CONVERTED_TO_TAX_INVOICE; both PDFs queryable',
 NULL, NULL,
 ARRAY['INVOICE_CONVERTED_FROM_PRO_FORMA','INVOICE_CREATED','INVOICE_PDF_RENDERED'],
 ARRAY['INVOICE_LIFECYCLE','INVOICE_NUMBERING','PDF_RENDER'],
 ARRAY['CONVERSION_COPIES_LINES','BOTH_PDFS_PRESERVED','FRESH_TAX_INVOICE_NUMBER'],
 jsonb_build_object('input',ARRAY['business_state.json','input_invoice_actions.json'],'expected',ARRAY['expected_invoice_state.json','expected_pdf_hashes.json'])),
('pro_forma_re_conversion_rejected','invoice_generator',
 'Attempting to re-convert an already-converted pro-forma is rejected',
 NULL, NULL,
 ARRAY['INVOICE_CONVERSION_REJECTED'],
 ARRAY['INVOICE_LIFECYCLE'],
 ARRAY['NO_DOUBLE_CONVERSION'],
 jsonb_build_object('input',ARRAY['business_state.json','input_invoice_actions.json'],'expected',ARRAY['expected_invoice_state.json'])),
('credit_note_partial','invoice_generator',
 'EUR 50 credit note against EUR 200 invoice; source lifecycle stays SENT (partial); cumulative cap correctly checked on next CN',
 NULL, NULL,
 ARRAY['CREDIT_NOTE_CREATED'],
 ARRAY['CREDIT_NOTE','INVOICE_LIFECYCLE'],
 ARRAY['PARTIAL_NO_LIFECYCLE_TRANSITION','CUMULATIVE_CAP_ENFORCED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_invoice_actions.json'],'expected',ARRAY['expected_invoice_state.json'])),
('credit_note_full','invoice_generator',
 'Full-amount credit note transitions source to CREDITED; Block 11·P07 negative-side ledger entry produced',
 NULL, NULL,
 ARRAY['CREDIT_NOTE_CREATED','INVOICE_TRANSITIONED_CREDITED','LEDGER_PREP_NEGATIVE_SIDE_EMITTED'],
 ARRAY['CREDIT_NOTE','INVOICE_LIFECYCLE','LEDGER_PREPARATION'],
 ARRAY['FULL_CN_FLIPS_LIFECYCLE','REVERSAL_LEDGER_ENTRY'],
 jsonb_build_object('input',ARRAY['business_state.json','input_invoice_actions.json'],'expected',ARRAY['expected_invoice_state.json'])),
('credit_note_against_pro_forma_rejected','invoice_generator',
 'Credit notes can only be issued against TAX invoices; FK constraint enforces',
 NULL, NULL,
 ARRAY['CREDIT_NOTE_REJECTED_NON_TAX_PARENT'],
 ARRAY['CREDIT_NOTE'],
 ARRAY['TAX_PARENT_REQUIRED','FK_ENFORCED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_invoice_actions.json'],'expected',ARRAY['expected_invoice_state.json'])),
('invoice_write_off_bad_debt','invoice_generator',
 'User writes off SENT invoice with mandatory reason; lifecycle=WRITTEN_OFF; bad-debt-expense path invokes; receivable offset',
 NULL, NULL,
 ARRAY['INVOICE_WRITTEN_OFF','LEDGER_PREP_BAD_DEBT_EMITTED'],
 ARRAY['INVOICE_LIFECYCLE','LEDGER_PREPARATION'],
 ARRAY['REASON_MANDATORY','BAD_DEBT_PATH','RECEIVABLE_OFFSET'],
 jsonb_build_object('input',ARRAY['business_state.json','input_invoice_actions.json'],'expected',ARRAY['expected_invoice_state.json'])),
('invoice_write_off_paid_rejected','invoice_generator',
 'PAID invoice cannot be written off; rejected',
 NULL, NULL,
 ARRAY['INVOICE_WRITE_OFF_REJECTED'],
 ARRAY['INVOICE_LIFECYCLE'],
 ARRAY['PAID_NO_WRITE_OFF'],
 jsonb_build_object('input',ARRAY['business_state.json','input_invoice_actions.json'],'expected',ARRAY['expected_invoice_state.json'])),
('recurring_template_monthly_generates_invoice','invoice_generator',
 'Daily scheduler runs on monthly anchor day; produces DRAFT invoice; next_due_date advances; idempotent re-run',
 NULL, NULL,
 ARRAY['RECURRING_TEMPLATE_RAN','INVOICE_CREATED','RECURRING_TEMPLATE_ADVANCED'],
 ARRAY['RECURRING_SCHEDULER','INVOICE_COMPOSITION'],
 ARRAY['ANCHOR_DAY_TRIGGERS','SCHEDULER_IDEMPOTENT'],
 jsonb_build_object('input',ARRAY['business_state.json','input_recurring_templates.json'],'expected',ARRAY['expected_invoice_state.json'])),
('recurring_template_auto_send_immediate_inv_allocation','invoice_generator',
 'auto_send=true; generated invoice immediately transitions to SENT; INV-YYYY-NNNN allocates',
 NULL, NULL,
 ARRAY['RECURRING_TEMPLATE_RAN','INVOICE_CREATED','INVOICE_SENT','INVOICE_NUMBER_ALLOCATED'],
 ARRAY['RECURRING_SCHEDULER','INVOICE_LIFECYCLE'],
 ARRAY['AUTO_SEND_FLIPS_DRAFT_TO_SENT'],
 jsonb_build_object('input',ARRAY['business_state.json','input_recurring_templates.json'],'expected',ARRAY['expected_invoice_state.json'])),
('recurring_template_weekly_mid_month','invoice_generator',
 'Weekly Monday cadence produces invoices regardless of IN_MONTHLY period boundaries',
 NULL, NULL,
 ARRAY['RECURRING_TEMPLATE_RAN','INVOICE_CREATED'],
 ARRAY['RECURRING_SCHEDULER'],
 ARRAY['CADENCE_PERIOD_INDEPENDENT'],
 jsonb_build_object('input',ARRAY['business_state.json','input_recurring_templates.json'],'expected',ARRAY['expected_invoice_state.json'])),
('recurring_template_end_date_transitions_to_ended','invoice_generator',
 'next_due_date > end_date correctly transitions template to ENDED',
 NULL, NULL,
 ARRAY['RECURRING_TEMPLATE_ENDED'],
 ARRAY['RECURRING_SCHEDULER'],
 ARRAY['END_DATE_TRIGGERS_TERMINAL_STATE'],
 jsonb_build_object('input',ARRAY['business_state.json','input_recurring_templates.json'],'expected',ARRAY['expected_invoice_state.json'])),
('recurring_template_failure_isolation','invoice_generator',
 'One template fails generation; others in the daily run continue; failed template retries next day; persistent failure raises HIGH review issue',
 NULL, NULL,
 ARRAY['RECURRING_TEMPLATE_RAN','RECURRING_TEMPLATE_GENERATION_FAILED','REVIEW_ISSUE_CREATED'],
 ARRAY['RECURRING_SCHEDULER'],
 ARRAY['FAILURE_ISOLATION','BOUNDED_RETRY','HIGH_ON_PERSISTENT_FAILURE'],
 jsonb_build_object('input',ARRAY['business_state.json','input_recurring_templates.json'],'expected',ARRAY['expected_invoice_state.json'])),
('recurring_pro_forma_template','invoice_generator',
 'Pro-forma recurring template generates pro-formas with restricted lifecycle',
 NULL, NULL,
 ARRAY['RECURRING_TEMPLATE_RAN','INVOICE_CREATED'],
 ARRAY['RECURRING_SCHEDULER','INVOICE_LIFECYCLE'],
 ARRAY['PRO_FORMA_TEMPLATE_GENERATES_PRO_FORMA'],
 jsonb_build_object('input',ARRAY['business_state.json','input_recurring_templates.json'],'expected',ARRAY['expected_invoice_state.json']));

INSERT INTO public.in_workflow_fixture_registry
  (fixture_name, category, description, workflow_type, expected_terminal_state,
   expected_audit_actions, covers_phase_names, covers_invariants, fixture_paths)
VALUES
('pdf_render_each_vat_treatment','pdf_rendering',
 'One fixture per Block 11·P05 VAT treatment; PDF carries the right disclosure text; expected_pdf_hashes.json confirms deterministic rendering',
 NULL, NULL,
 ARRAY['INVOICE_PDF_RENDERED'],
 ARRAY['PDF_RENDER'],
 ARRAY['VAT_TREATMENT_TEXT_PER_VARIANT','DETERMINISTIC_HASH'],
 jsonb_build_object('input',ARRAY['business_state.json','input_invoice_actions.json'],'expected',ARRAY['expected_pdf_hashes.json'])),
('pdf_render_pro_forma_watermark','pdf_rendering',
 'Pro-forma PDF carries the watermark and footer text',
 NULL, NULL,
 ARRAY['INVOICE_PDF_RENDERED'],
 ARRAY['PDF_RENDER'],
 ARRAY['PRO_FORMA_WATERMARK_PRESENT'],
 jsonb_build_object('input',ARRAY['business_state.json','input_invoice_actions.json'],'expected',ARRAY['expected_pdf_hashes.json'])),
('pdf_render_mixed_rate_invoice','pdf_rendering',
 'Multi-rate invoice renders per-rate breakdown',
 NULL, NULL,
 ARRAY['INVOICE_PDF_RENDERED'],
 ARRAY['PDF_RENDER'],
 ARRAY['PER_RATE_BREAKDOWN_RENDERED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_invoice_actions.json'],'expected',ARRAY['expected_pdf_hashes.json'])),
('pdf_render_unknown_vat_rejected','pdf_rendering',
 'vat_treatment=UNKNOWN invoice rejected from FINAL render with the right audit event',
 NULL, NULL,
 ARRAY['INVOICE_PDF_RENDER_REJECTED_UNKNOWN_VAT'],
 ARRAY['PDF_RENDER'],
 ARRAY['UNKNOWN_VAT_BLOCKS_FINAL_PDF'],
 jsonb_build_object('input',ARRAY['business_state.json','input_invoice_actions.json'],'expected',ARRAY['expected_invoice_state.json'])),
('pdf_render_idempotent_unchanged','pdf_rendering',
 'Re-rendering an unchanged invoice reuses the stored PDF',
 NULL, NULL,
 ARRAY['INVOICE_PDF_RENDER_CACHED'],
 ARRAY['PDF_RENDER'],
 ARRAY['IDEMPOTENT_RENDER','PDF_REUSE'],
 jsonb_build_object('input',ARRAY['business_state.json','input_invoice_actions.json'],'expected',ARRAY['expected_pdf_hashes.json']));

INSERT INTO public.in_workflow_fixture_registry
  (fixture_name, category, description, workflow_type, expected_terminal_state,
   expected_audit_actions, covers_phase_names, covers_invariants, fixture_paths)
VALUES
('in_monthly_clean_happy_path','in_monthly',
 '30 IN-side transactions all matched cleanly, no review issues, user approves, run finalizes; lifecycle=FINALIZED on every affected invoice',
 'IN_MONTHLY','FINALIZED',
 ARRAY['IN_WORKFLOW_RUN_STARTED_MANUALLY','IN_GATE_EVALUATED','IN_HUMAN_REVIEW_HOLD_ENTERED','IN_HUMAN_REVIEW_APPROVAL_RECORDED','IN_HUMAN_REVIEW_HOLD_CLEARED'],
 ARRAY['INGESTION','CLASSIFICATION','IN_FILTER','INCOME_MATCHING','LEDGER_PREPARATION','AI_END_SCAN','HUMAN_REVIEW_HOLD','FINALIZATION'],
 ARRAY['NO_BLOCK09_EVIDENCE_DISCOVERY','STATE_MACHINE_CLEAN_RUN'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','recorded_ai_responses.json'],'expected',ARRAY['expected_workflow_run_state_machine.json','expected_phase_outputs.json','expected_archive_bundle_manifest.json'])),
('in_monthly_full_match_with_invoice_number_reference','in_monthly',
 'IN_INCOME payment with invoice-number reference → FULL_MATCH auto-confirms; invoice.markPaid fires',
 'IN_MONTHLY','FINALIZED',
 ARRAY['INCOME_MATCH_FULL_MATCH','INVOICE_MARKED_PAID'],
 ARRAY['INCOME_MATCHING','LEDGER_PREPARATION'],
 ARRAY['INVOICE_NUMBER_REF_HIGH_CONFIDENCE','AUTO_CONFIRM_PATH'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_invoices.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_monthly_partial_payment_user_confirms','in_monthly',
 'Partial payment routes to MATCHED_NEEDS_CONFIRMATION; user confirms; invoice.markPartiallyPaid fires; allocation row created',
 'IN_MONTHLY','FINALIZED',
 ARRAY['INCOME_MATCH_NEEDS_CONFIRMATION','INVOICE_MARKED_PARTIALLY_PAID','INVOICE_PAYMENT_ALLOCATION_CREATED'],
 ARRAY['INCOME_MATCHING','HUMAN_REVIEW_HOLD'],
 ARRAY['PARTIAL_REQUIRES_CONFIRMATION'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_invoices.json','input_user_actions.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_monthly_overpayment_routes_credit_note_prompt','in_monthly',
 'Overpayment routes to MATCHED_NEEDS_CONFIRMATION + Possible Tax/VAT Issue prompting credit-note for surplus',
 'IN_MONTHLY', NULL,
 ARRAY['INCOME_MATCH_NEEDS_CONFIRMATION','REVIEW_ISSUE_CREATED'],
 ARRAY['INCOME_MATCHING','HUMAN_REVIEW_HOLD'],
 ARRAY['OVERPAYMENT_PROMPTS_CN'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_invoices.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_monthly_multiple_invoices_one_payment_user_confirms_proposal','in_monthly',
 'Payment matches sum of two invoices; MULTIPLE_INVOICES_ONE_PAYMENT; review issue; user confirms proposed; per-invoice transitions fire',
 'IN_MONTHLY','FINALIZED',
 ARRAY['INCOME_MATCH_MULTIPLE_INVOICES_ONE_PAYMENT','REVIEW_ISSUE_CREATED','INVOICE_MARKED_PAID'],
 ARRAY['INCOME_MATCHING','HUMAN_REVIEW_HOLD'],
 ARRAY['MULTI_INVOICE_MANDATORY_CONFIRMATION','PER_INVOICE_TRANSITIONS'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_invoices.json','input_user_actions.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_monthly_multiple_invoices_one_payment_user_edits_allocation','in_monthly',
 'Same fixture; user edits allocation amounts; invariants enforced; per-invoice transitions fire with edited amounts',
 'IN_MONTHLY','FINALIZED',
 ARRAY['INCOME_MATCH_MULTIPLE_INVOICES_ONE_PAYMENT','INVOICE_PAYMENT_ALLOCATION_CREATED'],
 ARRAY['INCOME_MATCHING','HUMAN_REVIEW_HOLD'],
 ARRAY['ALLOCATION_USER_EDITABLE','INVARIANTS_ENFORCED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_invoices.json','input_user_actions.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_monthly_multiple_invoices_one_payment_user_rejects','in_monthly',
 'Same fixture; user rejects all proposed; match_records→REJECTED_MATCH; rejection feeds Block 10·P06 rejection memory; transaction reverts to NO_MATCH',
 'IN_MONTHLY', NULL,
 ARRAY['INCOME_MATCH_REJECTED','MATCH_REJECTION_MEMORIZED'],
 ARRAY['INCOME_MATCHING','HUMAN_REVIEW_HOLD'],
 ARRAY['REJECT_FEEDS_REJECTION_MEMORY'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_invoices.json','input_user_actions.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_monthly_one_invoice_multiple_payments_running_total','in_monthly',
 'Three sequential partial payments accumulate; cumulative reaches total_amount → automatic invoice.markPaid',
 'IN_MONTHLY','FINALIZED',
 ARRAY['INVOICE_MARKED_PARTIALLY_PAID','INVOICE_MARKED_PAID'],
 ARRAY['INCOME_MATCHING','LEDGER_PREPARATION'],
 ARRAY['RUNNING_TOTAL_TRIGGERS_PAID'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_invoices.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_monthly_no_match_payment_with_pro_forma_reference_offers_conversion','in_monthly',
 'Payment descriptor carries PRO-YYYY-NNNN; matcher returns NO_MATCH; review issue recommends conversion; user converts; re-run produces FULL_MATCH',
 'IN_MONTHLY','FINALIZED',
 ARRAY['INCOME_MATCH_NO_MATCH','REVIEW_ISSUE_CREATED','INVOICE_CONVERTED_FROM_PRO_FORMA','INCOME_MATCH_FULL_MATCH'],
 ARRAY['INCOME_MATCHING','HUMAN_REVIEW_HOLD'],
 ARRAY['PRO_FORMA_REF_TRIGGERS_CONVERSION_PROMPT'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_invoices.json','input_user_actions.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_monthly_pro_forma_excluded_from_candidates','in_monthly',
 'Pro-forma invoices in candidate pool NEVER considered by matcher; verified by inspecting matcher input',
 'IN_MONTHLY', NULL,
 ARRAY['INCOME_MATCH_CANDIDATE_POOL_FILTERED'],
 ARRAY['INCOME_MATCHING'],
 ARRAY['PRO_FORMA_EXCLUDED_FROM_MATCHING'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_invoices.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_monthly_written_off_excluded_from_candidates','in_monthly',
 'Written-off invoices excluded from matcher input',
 'IN_MONTHLY', NULL,
 ARRAY['INCOME_MATCH_CANDIDATE_POOL_FILTERED'],
 ARRAY['INCOME_MATCHING'],
 ARRAY['WRITTEN_OFF_EXCLUDED_FROM_MATCHING'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_invoices.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_monthly_possible_refund_or_transfer_reclassification','in_monthly',
 'Incoming payment matches prior outgoing; outcome=POSSIBLE_REFUND_OR_TRANSFER; review issue suggests REFUND_IN or INTERNAL_TRANSFER; user reclassifies; re-run produces clean match',
 'IN_MONTHLY','FINALIZED',
 ARRAY['INCOME_MATCH_POSSIBLE_REFUND_OR_TRANSFER','REVIEW_ISSUE_CREATED','TRANSACTION_RECLASSIFIED'],
 ARRAY['INCOME_MATCHING','HUMAN_REVIEW_HOLD'],
 ARRAY['REFUND_RECLASSIFICATION_PATH'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_user_actions.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_monthly_human_review_hold_blocking_high','in_monthly',
 'AI_END_SCAN HIGH (missing client VAT on VIES-relevant invoice); HUMAN_REVIEW_HOLD; user resolves + approves; finalizes',
 'IN_MONTHLY','FINALIZED',
 ARRAY['IN_GATE_ROUTED_TO_SIDE_PHASE','IN_HUMAN_REVIEW_HOLD_ENTERED','IN_HUMAN_REVIEW_APPROVAL_RECORDED','IN_HUMAN_REVIEW_HOLD_CLEARED'],
 ARRAY['AI_END_SCAN','HUMAN_REVIEW_HOLD','FINALIZATION'],
 ARRAY['ROUTE_ON_HIGH','APPROVAL_REQUIRED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','recorded_ai_responses.json','input_user_actions.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_monthly_approval_required_with_zero_issues','in_monthly',
 'No issues; run still enters HUMAN_REVIEW_HOLD; approval required; on approval finalizes',
 'IN_MONTHLY','FINALIZED',
 ARRAY['IN_HUMAN_REVIEW_HOLD_ENTERED','IN_HUMAN_REVIEW_APPROVAL_RECORDED','IN_HUMAN_REVIEW_HOLD_CLEARED'],
 ARRAY['HUMAN_REVIEW_HOLD','FINALIZATION'],
 ARRAY['APPROVAL_ALWAYS_REQUIRED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_monthly_approval_revoked_re_holds','in_monthly',
 'User approves then revokes; gate flips back to HOLD',
 'IN_MONTHLY', NULL,
 ARRAY['IN_HUMAN_REVIEW_APPROVAL_RECORDED','IN_HUMAN_REVIEW_APPROVAL_REVOKED'],
 ARRAY['HUMAN_REVIEW_HOLD'],
 ARRAY['REVOKE_REOPENS_GATE'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_user_actions.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_monthly_approval_staleness_after_new_blocking_issue','in_monthly',
 'User approves; AI_END_SCAN re-runs and produces new HIGH; gate flips back; IN_HUMAN_REVIEW_APPROVAL_STALENESS_DETECTED fires',
 'IN_MONTHLY', NULL,
 ARRAY['IN_HUMAN_REVIEW_APPROVAL_RECORDED','IN_HUMAN_REVIEW_APPROVAL_STALENESS_DETECTED'],
 ARRAY['HUMAN_REVIEW_HOLD','AI_END_SCAN'],
 ARRAY['STALENESS_DETECTION'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','recorded_ai_responses.json'],'expected',ARRAY['expected_phase_outputs.json']));

INSERT INTO public.in_workflow_fixture_registry
  (fixture_name, category, description, workflow_type, expected_terminal_state,
   expected_audit_actions, covers_phase_names, covers_invariants, fixture_paths)
VALUES
('paired_out_in_internal_transfer_dedup','paired_out_in',
 'Same as Block 12·P10 fixture, verified from the IN side; INTERNAL_TRANSFER produces exactly one PRIMARY draft_ledger_entries row across both runs',
 'IN_MONTHLY','FINALIZED',
 ARRAY['IN_FILTER_INCLUDED_TRANSACTION'],
 ARRAY['IN_FILTER','LEDGER_PREPARATION'],
 ARRAY['INTERNAL_TRANSFER_DEDUP','BLOCK11_DISPATCHER_DEDUPES'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_internal_transfer_fixture.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('paired_out_in_loan_in_direction_routes_to_in','paired_out_in',
 'LOAN_OR_SHAREHOLDER_MOVEMENT IN direction passes through IN_FILTER only; OUT direction passes through OUT_FILTER only; verified',
 'IN_MONTHLY','FINALIZED',
 ARRAY['IN_FILTER_INCLUDED_TRANSACTION'],
 ARRAY['IN_FILTER','OUT_FILTER'],
 ARRAY['DIRECTION_AWARE_FILTER_ROUTING'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('paired_in_finalizes_independently_of_out','paired_out_in',
 'IN finalizes while OUT is in MANUAL_UPLOAD_HOLD; verified independence',
 'IN_MONTHLY','FINALIZED',
 ARRAY['IN_HUMAN_REVIEW_HOLD_CLEARED'],
 ARRAY['FINALIZATION'],
 ARRAY['NO_CROSS_RUN_GATE','INDEPENDENT_FINALIZATION'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json'],'expected',ARRAY['expected_phase_outputs.json']));

INSERT INTO public.in_workflow_fixture_registry
  (fixture_name, category, description, workflow_type, expected_terminal_state,
   expected_audit_actions, covers_phase_names, covers_invariants, fixture_paths)
VALUES
('in_manual_trigger_duplicate_rejected','triggers_and_idempotency',
 'Second start while first is active returns IN_WORKFLOW_RUN_ALREADY_ACTIVE_REJECTED',
 'IN_MONTHLY', NULL,
 ARRAY['IN_WORKFLOW_RUN_STARTED_MANUALLY','IN_WORKFLOW_RUN_ALREADY_ACTIVE_REJECTED'],
 ARRAY['INGESTION'],
 ARRAY['ACTIVE_RUN_DEDUP'],
 jsonb_build_object('input',ARRAY['business_state.json','input_user_actions.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_event_trigger_dedup_on_duplicate_event','triggers_and_idempotency',
 'Same STATEMENT_UPLOAD_COMPLETED arrives twice; only 1 IN run created; IN_WORKFLOW_EVENT_TRIGGER_DEDUPLICATED fires',
 'IN_MONTHLY', NULL,
 ARRAY['IN_WORKFLOW_RUN_STARTED_BY_EVENT','IN_WORKFLOW_EVENT_TRIGGER_DEDUPLICATED'],
 ARRAY['INGESTION'],
 ARRAY['EVENT_REPLAY_DEDUP'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_event_replay.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_manual_trigger_for_finalized_period_rejected','triggers_and_idempotency',
 'Already-finalized period rejected with IN_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED',
 'IN_MONTHLY', NULL,
 ARRAY['IN_WORKFLOW_RUN_REJECTED_PERIOD_FINALIZED'],
 ARRAY['INGESTION'],
 ARRAY['PERIOD_FINALIZED_BLOCKS_RESTART'],
 jsonb_build_object('input',ARRAY['business_state.json','input_prior_finalized_run.json','input_user_actions.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_auto_start_disabled_suppresses_event_trigger','triggers_and_idempotency',
 'auto_start_on_statement_upload=false suppresses IN run on event arrival',
 'IN_MONTHLY', NULL,
 ARRAY['IN_WORKFLOW_AUTO_START_SUPPRESSED'],
 ARRAY['INGESTION'],
 ARRAY['SUPPRESSION_HONORS_CONFIG'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','input_in_config.json'],'expected',ARRAY['expected_phase_outputs.json']));

INSERT INTO public.in_workflow_fixture_registry
  (fixture_name, category, description, workflow_type, expected_terminal_state,
   expected_audit_actions, covers_phase_names, covers_invariants, fixture_paths)
VALUES
('in_adjustment_retroactive_credit_note','in_adjustment',
 'Finalized period + PAID invoice; user initiates adjustment with delta_kind=RETROACTIVE_CREDIT_NOTE; CN issues with current-year CN-YYYY-NNNN; ledger reverses revenue; original invoice lifecycle untouched',
 'IN_ADJUSTMENT','FINALIZED',
 ARRAY['IN_ADJUSTMENT_RUN_CREATED','IN_ADJUSTMENT_INTAKE_COMPLETED','CREDIT_NOTE_CREATED','LEDGER_PREP_NEGATIVE_SIDE_EMITTED'],
 ARRAY['ADJUSTMENT_INTAKE','ADJUSTMENT_LEDGER_PREP','ADJUSTMENT_AI_REVIEW','ADJUSTMENT_HUMAN_REVIEW','ADJUSTMENT_FINALIZATION'],
 ARRAY['CURRENT_YEAR_CN_NUMBER','REVENUE_REVERSAL','ORIGINAL_UNCHANGED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_prior_finalized_run.json','input_user_actions.json'],'expected',ARRAY['expected_invoice_state.json','expected_phase_outputs.json','expected_archive_bundle_manifest.json'])),
('in_adjustment_correct_payment_allocation','in_adjustment',
 'Finalized period with MULTIPLE_INVOICES_ONE_PAYMENT allocation later realized wrong; adjustment re-allocates; new allocation rows created; original allocations remain in audit',
 'IN_ADJUSTMENT','FINALIZED',
 ARRAY['IN_ADJUSTMENT_RUN_CREATED','INVOICE_PAYMENT_ALLOCATION_CREATED'],
 ARRAY['ADJUSTMENT_INTAKE','ADJUSTMENT_LEDGER_PREP','ADJUSTMENT_FINALIZATION'],
 ARRAY['REALLOCATION_ADDITIVE','ORIGINAL_AUDIT_PRESERVED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_prior_finalized_run.json','input_user_actions.json'],'expected',ARRAY['expected_invoice_state.json','expected_phase_outputs.json'])),
('in_adjustment_mark_invoice_written_off','in_adjustment',
 'Retroactive write-off via adjustment; bad-debt-expense routing fires; original lifecycle stays FINALIZED; v_invoices_with_adjustments surfaces new state',
 'IN_ADJUSTMENT','FINALIZED',
 ARRAY['IN_ADJUSTMENT_RUN_CREATED','INVOICE_WRITTEN_OFF','LEDGER_PREP_BAD_DEBT_EMITTED'],
 ARRAY['ADJUSTMENT_INTAKE','ADJUSTMENT_LEDGER_PREP','ADJUSTMENT_FINALIZATION'],
 ARRAY['OVERLAY_NOT_MUTATION','BAD_DEBT_PATH'],
 jsonb_build_object('input',ARRAY['business_state.json','input_prior_finalized_run.json','input_user_actions.json'],'expected',ARRAY['expected_invoice_state.json','expected_phase_outputs.json'])),
('in_adjustment_other_kind_mandatory_human_review','in_adjustment',
 'delta_kind=OTHER always sets requires_accountant_review=true; ADJUSTMENT_HUMAN_REVIEW cannot fast-path',
 'IN_ADJUSTMENT', NULL,
 ARRAY['IN_ADJUSTMENT_RUN_CREATED','IN_HUMAN_REVIEW_HOLD_ENTERED'],
 ARRAY['ADJUSTMENT_INTAKE','ADJUSTMENT_HUMAN_REVIEW'],
 ARRAY['OTHER_KIND_FORCES_REVIEW'],
 jsonb_build_object('input',ARRAY['business_state.json','input_prior_finalized_run.json','input_user_actions.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_adjustment_concurrent_with_monthly_run','in_adjustment',
 'IN_ADJUSTMENT for period 1 + IN_MONTHLY for period 3 both active; both progress; both run ids recorded on touched entries',
 'IN_ADJUSTMENT','FINALIZED',
 ARRAY['IN_ADJUSTMENT_RUN_CREATED','IN_WORKFLOW_RUN_STARTED_MANUALLY'],
 ARRAY['ADJUSTMENT_INTAKE','INGESTION'],
 ARRAY['CONCURRENCY_PER_TYPE_PERIOD','BOTH_RUN_IDS_TRACEABLE'],
 jsonb_build_object('input',ARRAY['business_state.json','input_prior_finalized_run.json','input_statement_upload.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_adjustment_rejected_for_retention_expired','in_adjustment',
 '7-year-old period rejected with IN_ADJUSTMENT_REJECTED_RETENTION_EXPIRED',
 'IN_ADJUSTMENT', NULL,
 ARRAY['IN_ADJUSTMENT_REJECTED_RETENTION_EXPIRED'],
 ARRAY['ADJUSTMENT_INTAKE'],
 ARRAY['SIX_YEAR_RETENTION_CAP'],
 jsonb_build_object('input',ARRAY['business_state.json','input_prior_finalized_run.json','input_user_actions.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('in_adjustment_does_not_modify_originals','in_adjustment',
 'Hash comparison verifies no original invoices, invoice_lines, draft_ledger_entries, invoice_payment_allocations rows modified',
 'IN_ADJUSTMENT','FINALIZED',
 ARRAY['IN_ADJUSTMENT_RUN_CREATED'],
 ARRAY['ADJUSTMENT_LEDGER_PREP','ADJUSTMENT_FINALIZATION'],
 ARRAY['ADDITIVE_ONLY','ORIGINAL_HASH_UNCHANGED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_prior_finalized_run.json'],'expected',ARRAY['expected_phase_outputs.json','expected_original_hash_unchanged.json']));

INSERT INTO public.in_workflow_fixture_registry
  (fixture_name, category, description, workflow_type, expected_terminal_state,
   expected_audit_actions, covers_phase_names, covers_invariants, fixture_paths)
VALUES
('end_scan_invoice_unpaid_past_due_date','end_scan_in',
 'Invoice unpaid past due_date flagged with right severity and bucket',
 'IN_MONTHLY', NULL,
 ARRAY['IN_AI_END_SCAN_REVIEW_ISSUE_RAISED'],
 ARRAY['AI_END_SCAN'],
 ARRAY['DUE_DATE_AWARE'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','recorded_ai_responses.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('end_scan_payment_received_without_invoice','end_scan_in',
 'Payment with NO_MATCH surfaces as Missing Documents HIGH',
 'IN_MONTHLY', NULL,
 ARRAY['IN_AI_END_SCAN_REVIEW_ISSUE_RAISED'],
 ARRAY['AI_END_SCAN'],
 ARRAY['NO_MATCH_FLAGS_MISSING_DOCS'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','recorded_ai_responses.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('end_scan_missing_client_vat_on_vies_relevant','end_scan_in',
 'VIES-relevant invoice without client VAT flagged as Possible Tax/VAT Issue HIGH',
 'IN_MONTHLY', NULL,
 ARRAY['IN_AI_END_SCAN_REVIEW_ISSUE_RAISED'],
 ARRAY['AI_END_SCAN'],
 ARRAY['VIES_VAT_REQUIRED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','recorded_ai_responses.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('end_scan_reverse_charge_text_missing','end_scan_in',
 'Reverse-charge mandatory text missing on PDF flagged',
 'IN_MONTHLY', NULL,
 ARRAY['IN_AI_END_SCAN_REVIEW_ISSUE_RAISED'],
 ARRAY['AI_END_SCAN'],
 ARRAY['REVERSE_CHARGE_TEXT_REQUIRED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','recorded_ai_responses.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('end_scan_duplicate_payment_against_same_invoice','end_scan_in',
 'Duplicate payment against same invoice flagged as Possible Wrong Match',
 'IN_MONTHLY', NULL,
 ARRAY['IN_AI_END_SCAN_REVIEW_ISSUE_RAISED'],
 ARRAY['AI_END_SCAN'],
 ARRAY['DUPLICATE_PAYMENT_DETECTED'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','recorded_ai_responses.json'],'expected',ARRAY['expected_phase_outputs.json'])),
('end_scan_late_payment_past_due_date','end_scan_in',
 'Late payment past due_date flagged informational',
 'IN_MONTHLY', NULL,
 ARRAY['IN_AI_END_SCAN_REVIEW_ISSUE_RAISED'],
 ARRAY['AI_END_SCAN'],
 ARRAY['LATE_PAYMENT_INFORMATIONAL'],
 jsonb_build_object('input',ARRAY['business_state.json','input_statement_upload.json','recorded_ai_responses.json'],'expected',ARRAY['expected_phase_outputs.json']));
