-- B13·P01 fix-up: review_issues needs an invoice_id anchor so the gap detector
-- can raise issues without abusing the document_id/match_record_id columns.
-- This extends the at-least-one-entity CHECK to recognize invoice_id as a
-- valid entity. Forward-only.

ALTER TABLE public.review_issues
  ADD COLUMN invoice_id uuid NULL REFERENCES public.invoices(id) ON DELETE SET NULL;

CREATE INDEX review_issues_invoice_idx ON public.review_issues(invoice_id) WHERE invoice_id IS NOT NULL;

ALTER TABLE public.review_issues
  DROP CONSTRAINT review_issue_at_least_one_entity_chk;

ALTER TABLE public.review_issues
  ADD CONSTRAINT review_issue_at_least_one_entity_chk CHECK (
    transaction_id IS NOT NULL
    OR document_id IS NOT NULL
    OR match_record_id IS NOT NULL
    OR draft_ledger_entry_id IS NOT NULL
    OR invoice_id IS NOT NULL
  );

COMMENT ON COLUMN public.review_issues.invoice_id IS
  'Block 13 P01 fix-up — invoice anchor for IN-side / invoice-numbering review issues. Recognized as a valid entity by review_issue_at_least_one_entity_chk.';

-- Rewire the gap detector to anchor each issue on the highest-numbered
-- existing invoice (or credit_note) in the same (business, sequence_kind, year).
-- If no anchor exists (deletion edge case), the gap is recorded in the audit
-- log only; no review_issue is raised for that gap.

CREATE OR REPLACE FUNCTION public.detect_invoice_number_gaps(
  p_organization_id  uuid,
  p_business_id      uuid,
  p_sequence_kind    public.invoice_sequence_kind_enum,
  p_year             int,
  p_workflow_run_id  uuid,
  p_context          jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_last_allocated   int;
  v_prefix           text;
  v_table_label      text;
  v_anchor_invoice   uuid;
  v_anchor_label     text;
  v_gap_number       int;
  v_missing_label    text;
  v_gaps             int[] := '{}';
  v_review_issue_id  uuid;
  v_issues_raised    int := 0;
BEGIN
  SELECT last_allocated
    INTO v_last_allocated
    FROM public.invoice_sequence_counters
   WHERE business_id = p_business_id
     AND sequence_kind = p_sequence_kind
     AND year = p_year;
  IF NOT FOUND OR v_last_allocated = 0 THEN
    RETURN jsonb_build_object('decision','RAN','gaps_detected', 0, 'missing_numbers', jsonb_build_array());
  END IF;

  v_prefix      := p_sequence_kind::text;
  v_table_label := CASE p_sequence_kind WHEN 'CN' THEN 'credit_notes' ELSE 'invoices' END;

  -- Anchor: highest-numbered existing invoice in the (business, sequence_kind, year).
  -- Credit-note sequences anchor on the source invoice of the highest-numbered CN row.
  IF p_sequence_kind = 'CN' THEN
    SELECT cn.against_invoice_id, cn.credit_note_number
      INTO v_anchor_invoice, v_anchor_label
      FROM public.credit_notes cn
     WHERE cn.business_id = p_business_id
       AND cn.credit_note_number LIKE format('CN-%s-%%', p_year::text)
     ORDER BY cn.credit_note_number DESC
     LIMIT 1;
  ELSE
    SELECT inv.id, inv.invoice_number
      INTO v_anchor_invoice, v_anchor_label
      FROM public.invoices inv
     WHERE inv.business_id = p_business_id
       AND inv.invoice_type = (CASE p_sequence_kind WHEN 'INV' THEN 'TAX' ELSE 'PRO_FORMA' END)::public.invoice_type_enum
       AND inv.invoice_number LIKE format('%s-%s-%%', v_prefix, p_year::text)
     ORDER BY inv.invoice_number DESC
     LIMIT 1;
  END IF;

  FOR v_gap_number IN 1 .. v_last_allocated LOOP
    v_missing_label := format('%s-%s-%s', v_prefix, p_year::text, lpad(v_gap_number::text, 4, '0'));
    IF p_sequence_kind = 'CN' THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.credit_notes
         WHERE business_id = p_business_id
           AND credit_note_number = v_missing_label
      ) THEN
        v_gaps := v_gaps || v_gap_number;
      END IF;
    ELSE
      IF NOT EXISTS (
        SELECT 1 FROM public.invoices
         WHERE business_id = p_business_id
           AND invoice_number = v_missing_label
      ) THEN
        v_gaps := v_gaps || v_gap_number;
      END IF;
    END IF;
  END LOOP;

  FOREACH v_gap_number IN ARRAY v_gaps LOOP
    v_missing_label := format('%s-%s-%s', v_prefix, p_year::text, lpad(v_gap_number::text, 4, '0'));

    IF v_anchor_invoice IS NOT NULL THEN
      INSERT INTO public.review_issues (
        organization_id, business_id, workflow_run_id, invoice_id,
        issue_type, issue_group, severity,
        plain_language_title, plain_language_description, recommended_action,
        card_payload_json
      ) VALUES (
        p_organization_id, p_business_id, p_workflow_run_id, v_anchor_invoice,
        'invoice_numbering.gap_detected',
        'POSSIBLE_WRONG_MATCH'::public.review_issue_group_enum,
        'HIGH'::public.review_issue_severity_enum,
        format('Missing %s number %s', v_prefix, v_missing_label),
        format('The %s sequence shows that number %s was allocated but no corresponding row exists in %s. The anchor reference is the most recent existing record (%s). Investigate whether this gap reflects a deleted issuance or a skipped allocation.',
          v_prefix, v_missing_label, v_table_label, v_anchor_label),
        'Investigate the gap; either restore the missing record or document the cause.',
        jsonb_build_object(
          'sequence_kind', v_prefix,
          'year', p_year,
          'missing_number', v_gap_number,
          'missing_label', v_missing_label,
          'anchor_label', v_anchor_label
        )
      ) RETURNING id INTO v_review_issue_id;
      v_issues_raised := v_issues_raised + 1;
    ELSE
      v_review_issue_id := NULL;
    END IF;

    PERFORM audit.emit_audit(
      p_actor_kind      := 'SYSTEM'::audit.actor_kind_enum,
      p_action          := 'INVOICE_NUMBER_GAP_DETECTED',
      p_subject_type    := 'WORKFLOW_RUN'::audit.subject_type_enum,
      p_subject_id      := p_workflow_run_id,
      p_actor_user_id   := NULL,
      p_actor_role      := NULL,
      p_actor_session_id:= NULL,
      p_actor_system    := 'invoice_numbering_integrity',
      p_organization_id := p_organization_id,
      p_business_id     := p_business_id,
      p_before_state    := NULL,
      p_after_state     := jsonb_build_object(
        'sequence_kind', v_prefix,
        'year', p_year,
        'missing_number', v_gap_number,
        'missing_label', v_missing_label,
        'review_issue_id', v_review_issue_id,
        'anchor_invoice_id', v_anchor_invoice
      ),
      p_reason          := NULL,
      p_request_context := p_context
    );
  END LOOP;

  RETURN jsonb_build_object(
    'decision', 'RAN',
    'gaps_detected', COALESCE(array_length(v_gaps, 1), 0),
    'issues_raised', v_issues_raised,
    'missing_numbers', to_jsonb(v_gaps)
  );
END;
$function$;
