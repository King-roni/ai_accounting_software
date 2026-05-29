-- B12·P02 — OUT_MONTHLY Workflow Type Definition (full spec rebuild)
-- =====================================================================
-- Reorders + renames OUT_MONTHLY phases to the spec's canonical 11-phase
-- sequence. Critical reorder: CLASSIFICATION moves from old position 7 to
-- position 2 (so transaction types are known before evidence discovery).
--
-- Final OUT_MONTHLY sequence:
--   1  INGESTION                (renamed from INGEST_STATEMENT)
--   2  CLASSIFICATION           (renamed from CLASSIFY; REORDERED from 7→2)
--   3  OUT_FILTER               (NEW — Block 12 P03 owns)
--   4  EVIDENCE_DISCOVERY_EMAIL (renamed from EVIDENCE_DISCOVERY_GMAIL)
--   5  EVIDENCE_DISCOVERY_DRIVE (unchanged name; reordered)
--   6  MATCHING                 (renamed from MATCH)
--   7  MANUAL_UPLOAD_HOLD       (NEW side phase — Block 12 P06)
--   8  LEDGER_PREPARATION       (renamed from LEDGER_DRAFT)
--   9  AI_END_SCAN              (NEW — Block 06)
--   10 HUMAN_REVIEW_HOLD        (NEW side phase — Block 12 P07)
--   11 FINALIZATION             (renamed from ARCHIVE_PROMOTION; Block 15)
--
-- Obsolete phases dropped: PARSE_TRANSACTIONS, EVIDENCE_DISCOVERY_LOCAL,
-- REVIEW_QUEUE_GATE, USER_REVIEW.
--
-- Dependent phase_tool_expectations + phase_gate_assignments rows for
-- renamed phases are updated to match (B09·P09 + B10·P09 + B11·P09
-- registrations carry forward under the new names).
--
-- IN_MONTHLY phase definitions are untouched here — Block 13 owns those.
-- IN_MONTHLY.LEDGER_DRAFT / EVIDENCE_DISCOVERY_GMAIL / etc. stay as-is
-- until B13 ships its alignment.
--
-- Gotcha resolved:
--   * workflow_phase_definitions has BOTH unique(workflow_type, phase_order)
--     AND unique(workflow_type, phase_name) constraints.
--   * Trigger fn_check_phase_in_registry on phase_tool_expectations validates
--     phase_name against workflow_phase_definitions on INSERT/UPDATE.
--   * Rename order: workflow_phase_definitions first (no validation against
--     dependents), then dependents (now the new names exist), then delete
--     obsoletes, then shift+reposition + insert new.
-- =====================================================================

BEGIN;

-- Step 1: Rename phase_names in workflow_phase_definitions
UPDATE public.workflow_phase_definitions
   SET phase_name = CASE phase_name
     WHEN 'INGEST_STATEMENT'         THEN 'INGESTION'
     WHEN 'CLASSIFY'                 THEN 'CLASSIFICATION'
     WHEN 'EVIDENCE_DISCOVERY_GMAIL' THEN 'EVIDENCE_DISCOVERY_EMAIL'
     WHEN 'MATCH'                    THEN 'MATCHING'
     WHEN 'LEDGER_DRAFT'             THEN 'LEDGER_PREPARATION'
     WHEN 'ARCHIVE_PROMOTION'        THEN 'FINALIZATION'
   END
 WHERE workflow_type = 'OUT_MONTHLY'
   AND phase_name IN ('INGEST_STATEMENT','CLASSIFY','EVIDENCE_DISCOVERY_GMAIL','MATCH','LEDGER_DRAFT','ARCHIVE_PROMOTION');

-- Step 2: Rename phase_names in dependent tables (now the new names exist)
UPDATE public.phase_tool_expectations
   SET phase_name = CASE phase_name
     WHEN 'INGEST_STATEMENT'         THEN 'INGESTION'
     WHEN 'CLASSIFY'                 THEN 'CLASSIFICATION'
     WHEN 'EVIDENCE_DISCOVERY_GMAIL' THEN 'EVIDENCE_DISCOVERY_EMAIL'
     WHEN 'MATCH'                    THEN 'MATCHING'
     WHEN 'LEDGER_DRAFT'             THEN 'LEDGER_PREPARATION'
     WHEN 'ARCHIVE_PROMOTION'        THEN 'FINALIZATION'
   END
 WHERE workflow_type = 'OUT_MONTHLY'
   AND phase_name IN ('INGEST_STATEMENT','CLASSIFY','EVIDENCE_DISCOVERY_GMAIL','MATCH','LEDGER_DRAFT','ARCHIVE_PROMOTION');

UPDATE public.phase_gate_assignments
   SET phase_name = CASE phase_name
     WHEN 'INGEST_STATEMENT'         THEN 'INGESTION'
     WHEN 'CLASSIFY'                 THEN 'CLASSIFICATION'
     WHEN 'EVIDENCE_DISCOVERY_GMAIL' THEN 'EVIDENCE_DISCOVERY_EMAIL'
     WHEN 'MATCH'                    THEN 'MATCHING'
     WHEN 'LEDGER_DRAFT'             THEN 'LEDGER_PREPARATION'
     WHEN 'ARCHIVE_PROMOTION'        THEN 'FINALIZATION'
   END
 WHERE workflow_type = 'OUT_MONTHLY'
   AND phase_name IN ('INGEST_STATEMENT','CLASSIFY','EVIDENCE_DISCOVERY_GMAIL','MATCH','LEDGER_DRAFT','ARCHIVE_PROMOTION');

-- Step 3: Delete dependent rows for obsolete OUT_MONTHLY phases
DELETE FROM public.phase_tool_expectations
 WHERE workflow_type='OUT_MONTHLY'
   AND phase_name IN ('PARSE_TRANSACTIONS','EVIDENCE_DISCOVERY_LOCAL','REVIEW_QUEUE_GATE','USER_REVIEW');
DELETE FROM public.phase_gate_assignments
 WHERE workflow_type='OUT_MONTHLY'
   AND phase_name IN ('PARSE_TRANSACTIONS','EVIDENCE_DISCOVERY_LOCAL','REVIEW_QUEUE_GATE','USER_REVIEW');

-- Step 4: Delete obsolete workflow_phase_definitions
DELETE FROM public.workflow_phase_definitions
 WHERE workflow_type='OUT_MONTHLY'
   AND phase_name IN ('PARSE_TRANSACTIONS','EVIDENCE_DISCOVERY_LOCAL','REVIEW_QUEUE_GATE','USER_REVIEW');

-- Step 5: Shift remaining OUT_MONTHLY phase_orders by +100 to free up positions
UPDATE public.workflow_phase_definitions SET phase_order = phase_order + 100
 WHERE workflow_type='OUT_MONTHLY';

-- Step 6: INSERT 4 new phases at their spec positions
INSERT INTO public.workflow_phase_definitions (workflow_type, phase_order, phase_name, optional, description, is_shared_with_pair) VALUES
  ('OUT_MONTHLY',  3, 'OUT_FILTER',         false, 'Block 12 P03 — filter to OUT-side transactions per type-aware evidence rules',     false),
  ('OUT_MONTHLY',  7, 'MANUAL_UPLOAD_HOLD', true,  'Block 12 P06 — side phase entered when manual evidence upload is required',        false),
  ('OUT_MONTHLY',  9, 'AI_END_SCAN',        false, 'Block 06 — end-of-run AI sanity scan',                                              false),
  ('OUT_MONTHLY', 10, 'HUMAN_REVIEW_HOLD',  true,  'Block 12 P07 — side phase for human review approval',                              false);

-- Step 7: Reposition the renamed (shifted) rows to their spec positions
UPDATE public.workflow_phase_definitions SET phase_order = 1  WHERE workflow_type='OUT_MONTHLY' AND phase_name='INGESTION';
UPDATE public.workflow_phase_definitions SET phase_order = 2  WHERE workflow_type='OUT_MONTHLY' AND phase_name='CLASSIFICATION';
UPDATE public.workflow_phase_definitions SET phase_order = 4  WHERE workflow_type='OUT_MONTHLY' AND phase_name='EVIDENCE_DISCOVERY_EMAIL';
UPDATE public.workflow_phase_definitions SET phase_order = 5  WHERE workflow_type='OUT_MONTHLY' AND phase_name='EVIDENCE_DISCOVERY_DRIVE';
UPDATE public.workflow_phase_definitions SET phase_order = 6  WHERE workflow_type='OUT_MONTHLY' AND phase_name='MATCHING';
UPDATE public.workflow_phase_definitions SET phase_order = 8  WHERE workflow_type='OUT_MONTHLY' AND phase_name='LEDGER_PREPARATION';
UPDATE public.workflow_phase_definitions SET phase_order = 11 WHERE workflow_type='OUT_MONTHLY' AND phase_name='FINALIZATION';


-- 8. Type-aware evidence rules table -----------------------------------
CREATE TABLE public.out_workflow_evidence_rules (
  id                   uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  transaction_type     public.transaction_type_enum NOT NULL,
  direction            public.transaction_direction_enum,
  out_filter_includes  boolean NOT NULL,
  evidence_required    text NOT NULL,
  notes                text,
  created_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT out_workflow_evidence_rules_unique UNIQUE (transaction_type, direction)
);
COMMENT ON TABLE public.out_workflow_evidence_rules IS
  'Type-aware evidence rules consumed by OUT_FILTER (Phase 03) and the OUT-side gate library (Phase 05). The direction column distinguishes LOAN_OR_SHAREHOLDER_MOVEMENT OUT vs IN direction.';

INSERT INTO public.out_workflow_evidence_rules (transaction_type, direction, out_filter_includes, evidence_required, notes) VALUES
  ('OUT_EXPENSE',                  'OUT',  true,  'Invoice or receipt; OR documented exception with reason', NULL),
  ('INTERNAL_TRANSFER',            NULL,   true,  'None',                                                     'Also handled by IN_FILTER — dedup at Phase 04'),
  ('FX_EXCHANGE',                  NULL,   true,  'Bank-generated FX evidence (auto-derived)',                NULL),
  ('BANK_FEE',                     NULL,   true,  'Bank-generated evidence (auto-generated)',                 NULL),
  ('REFUND_OUT',                   'OUT',  true,  'Reference to original transaction being refunded',         NULL),
  ('PAYROLL_OR_TEAM_PAYMENT',      'OUT',  true,  'Invoice OR contract OR payroll record',                    NULL),
  ('TAX_PAYMENT',                  'OUT',  true,  'Tax authority confirmation OR documented as expected payment', NULL),
  ('LOAN_OR_SHAREHOLDER_MOVEMENT', 'OUT',  true,  'Contract or shareholder agreement',                        'OUT direction = outgoing loan / capital return'),
  ('LOAN_OR_SHAREHOLDER_MOVEMENT', 'IN',   false, '—',                                                        'IN direction = capital injection / loan receipt; handled by IN_FILTER (Block 13)'),
  ('CHARGEBACK',                   NULL,   true,  'Bank-generated evidence + dispute record',                 NULL),
  ('IN_INCOME',                    NULL,   false, '—',                                                        'Handled by IN_FILTER (Block 13)'),
  ('REFUND_IN',                    NULL,   false, '—',                                                        'Handled by IN_FILTER (Block 13)'),
  ('UNKNOWN',                      NULL,   true,  'Cannot advance',                                           'Raised as blocking issue — must be reclassified before advance');

ALTER TABLE public.out_workflow_evidence_rules ENABLE ROW LEVEL SECURITY;
CREATE POLICY owe_select ON public.out_workflow_evidence_rules FOR SELECT USING (true);
CREATE POLICY owe_no_insert ON public.out_workflow_evidence_rules FOR INSERT WITH CHECK (false);
CREATE POLICY owe_no_update ON public.out_workflow_evidence_rules FOR UPDATE USING (false);
CREATE POLICY owe_no_delete ON public.out_workflow_evidence_rules FOR DELETE USING (false);


-- 9. Replace register_out_monthly_type stub with the real implementation
CREATE OR REPLACE FUNCTION public.register_out_monthly_type(
  p_actor_user_id uuid DEFAULT NULL, p_context jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_phase_count int;
  v_evidence_rule_count int;
  v_phases jsonb;
BEGIN
  SELECT count(*) INTO v_phase_count FROM public.workflow_phase_definitions WHERE workflow_type='OUT_MONTHLY';
  SELECT count(*) INTO v_evidence_rule_count FROM public.out_workflow_evidence_rules;
  SELECT jsonb_agg(jsonb_build_object('phase_order',phase_order,'phase_name',phase_name,'optional',optional)
                   ORDER BY phase_order)
    INTO v_phases FROM public.workflow_phase_definitions WHERE workflow_type='OUT_MONTHLY';

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='OUT_WORKFLOW_TYPE_REGISTERED',
    p_subject_type:='WORKFLOW_CONFIG'::audit.subject_type_enum, p_subject_id:=NULL,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='out_workflow_boot',
    p_organization_id:=NULL, p_business_id:=NULL,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('workflow_type','OUT_MONTHLY',
                                       'phase_count', v_phase_count,
                                       'evidence_rule_count', v_evidence_rule_count,
                                       'phases', v_phases),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','REGISTERED','workflow_type','OUT_MONTHLY',
                            'phase_count', v_phase_count, 'evidence_rule_count', v_evidence_rule_count);
END;
$$;


-- 10. STABLE evidence-rules lookup helper
CREATE OR REPLACE FUNCTION public.get_out_workflow_evidence_rule(
  p_transaction_type public.transaction_type_enum,
  p_direction public.transaction_direction_enum
) RETURNS jsonb LANGUAGE sql STABLE
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'transaction_type', r.transaction_type,
    'direction',        r.direction,
    'out_filter_includes', r.out_filter_includes,
    'evidence_required',   r.evidence_required,
    'notes',               r.notes)
    FROM public.out_workflow_evidence_rules r
   WHERE r.transaction_type = p_transaction_type
     AND (r.direction IS NULL OR r.direction = p_direction)
   ORDER BY (CASE WHEN r.direction IS NULL THEN 0 ELSE 1 END) DESC
   LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.get_out_workflow_evidence_rule(public.transaction_type_enum, public.transaction_direction_enum) TO authenticated, service_role, anon;

COMMIT;
