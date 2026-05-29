-- ============================================================================
-- Block 13 Phase 06 (BOOK-121) — Pro-Forma Conversion, Credit Notes & Write-Off
--
-- 4 RPCs:
--   * invoice_convert_pro_forma_to_tax_invoice — composite atomic conversion
--   * credit_note_issue (CREATE OR REPLACE) — adds auto-mark_credited on full credit
--   * prepare_invoice_lifecycle_entries — cross-block B11·P07 contract landing pad
--   * invoice_mark_written_off (CREATE OR REPLACE) — wires bad-debt ledger bridge
-- ============================================================================

-- ---- 1. RPC: invoice_convert_pro_forma_to_tax_invoice -------------------

CREATE OR REPLACE FUNCTION public.invoice_convert_pro_forma_to_tax_invoice(
  p_actor_user_id        uuid,
  p_pro_forma_invoice_id uuid,
  p_issue_date           date DEFAULT NULL,
  p_context              jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_src      public.invoices%ROWTYPE;
  v_decision jsonb;
  v_new_id   uuid := gen_uuid_v7();
  v_iss_date date := COALESCE(p_issue_date, CURRENT_DATE);
  v_mark_sent jsonb;
  v_mark_conv jsonb;
  v_line_count int;
BEGIN
  SELECT * INTO v_src FROM public.invoices WHERE id = p_pro_forma_invoice_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_FOUND');
  END IF;
  v_decision := public.can_perform(p_actor_user_id,'INVOICE_MANAGE','CONVERT_PRO_FORMA_TO_TAX',
    jsonb_build_object('pro_forma_invoice_id', p_pro_forma_invoice_id),
    v_src.business_id, v_src.organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision',
      'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;

  IF v_src.invoice_type <> 'PRO_FORMA' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','NOT_PRO_FORMA');
  END IF;
  IF v_src.converted_to_tax_invoice_id IS NOT NULL THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','ALREADY_CONVERTED',
      'existing_tax_invoice_id', v_src.converted_to_tax_invoice_id);
  END IF;
  IF v_src.lifecycle_status NOT IN ('DRAFT','SENT') THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','ILLEGAL_TRANSITION',
      'current_status', v_src.lifecycle_status::text);
  END IF;

  INSERT INTO public.invoices (
    id, organization_id, business_id, client_id,
    invoice_type, invoice_number,
    issue_date, supply_date, due_date,
    currency, subtotal_amount, vat_amount, total_amount,
    vat_treatment_per_line, default_vat_treatment,
    lifecycle_status, lifecycle_status_changed_at, lifecycle_status_changed_by,
    converted_from_pro_forma_id
  ) VALUES (
    v_new_id, v_src.organization_id, v_src.business_id, v_src.client_id,
    'TAX', NULL,
    v_iss_date, v_src.supply_date,
    GREATEST(v_iss_date, v_iss_date + 30),
    v_src.currency, 0, 0, 0,
    v_src.vat_treatment_per_line, v_src.default_vat_treatment,
    'DRAFT', now(), p_actor_user_id,
    p_pro_forma_invoice_id
  );

  INSERT INTO public.invoice_lines (
    organization_id, business_id, invoice_id, line_number,
    description, quantity, unit_price, currency,
    subtotal_amount, vat_treatment, vat_rate_pct, vat_amount, total_amount
  )
  SELECT
    v_src.organization_id, v_src.business_id, v_new_id, line_number,
    description, quantity, unit_price, currency,
    subtotal_amount, vat_treatment, vat_rate_pct, vat_amount, total_amount
   FROM public.invoice_lines
   WHERE invoice_id = p_pro_forma_invoice_id
   ORDER BY line_number;

  GET DIAGNOSTICS v_line_count = ROW_COUNT;

  PERFORM public.invoice_recompute_totals(v_new_id, p_context);

  v_mark_sent := public.invoice_mark_sent(p_actor_user_id, v_new_id, now(), p_context);
  IF (v_mark_sent->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','INTERNAL_MARK_SENT_FAILED',
      'detail', v_mark_sent);
  END IF;

  v_mark_conv := public.invoice_mark_converted_to_tax_invoice(
    p_actor_user_id, p_pro_forma_invoice_id, v_new_id, now(), p_context);
  IF (v_mark_conv->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','INTERNAL_MARK_CONVERTED_FAILED',
      'detail', v_mark_conv);
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='INVOICE_CREATED',
    p_subject_type:='INVOICE'::audit.subject_type_enum, p_subject_id:=v_new_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_src.organization_id, p_business_id:=v_src.business_id,
    p_before_state:=NULL,
    p_after_state :=jsonb_build_object(
      'invoice_id', v_new_id,
      'invoice_type', 'TAX',
      'lifecycle_status', 'SENT',
      'invoice_number', v_mark_sent->'invoice_number',
      'converted_from_pro_forma_id', p_pro_forma_invoice_id,
      'line_count', v_line_count,
      'via', 'pro_forma_conversion'
    ),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'decision','ALLOW',
    'tax_invoice_id', v_new_id,
    'pro_forma_invoice_id', p_pro_forma_invoice_id,
    'invoice_number', v_mark_sent->'invoice_number',
    'line_count', v_line_count
  );
END;
$function$;

-- ---- 2. CREATE OR REPLACE: credit_note_issue ----------------------------
-- Extends P01: after insert, auto-call invoice_mark_credited if cumulative
-- credit hits invoice.total_amount (full credit).

CREATE OR REPLACE FUNCTION public.credit_note_issue(
  p_organization_id    uuid,
  p_business_id        uuid,
  p_actor_user_id      uuid,
  p_against_invoice_id uuid,
  p_amount             numeric,
  p_reason             text,
  p_issue_date         date,
  p_context            jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_decision      jsonb;
  v_source        public.invoices%ROWTYPE;
  v_prior_sum     numeric(18,2);
  v_new_cumulative numeric(18,2);
  v_year          int;
  v_next          int;
  v_number        text;
  v_credit_note_id uuid := gen_uuid_v7();
  v_mark_credited jsonb;
  v_tolerance     numeric := 0.01;
BEGIN
  v_decision := public.can_perform(
    p_actor_user_id := p_actor_user_id,
    p_surface       := 'CREDIT_NOTE_ISSUE',
    p_action        := 'ISSUE',
    p_resource      := jsonb_build_object('against_invoice_id', p_against_invoice_id),
    p_business_id   := p_business_id,
    p_organization_id := p_organization_id
  );
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object(
      'decision', v_decision->>'decision',
      'reason_code', COALESCE(v_decision->>'reason_code', 'PERMISSION_DENIED'),
      'credit_note_id', NULL
    );
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','INVALID_AMOUNT','credit_note_id', NULL);
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','REASON_REQUIRED','credit_note_id', NULL);
  END IF;

  SELECT * INTO v_source FROM public.invoices WHERE id = p_against_invoice_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_FOUND','credit_note_id', NULL);
  END IF;
  IF v_source.business_id <> p_business_id OR v_source.organization_id <> p_organization_id THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','BUSINESS_MISMATCH','credit_note_id', NULL);
  END IF;
  IF v_source.invoice_type <> 'TAX' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','SOURCE_NOT_TAX_INVOICE','credit_note_id', NULL);
  END IF;

  SELECT COALESCE(SUM(amount), 0)::numeric(18,2)
    INTO v_prior_sum
    FROM public.credit_notes
   WHERE against_invoice_id = p_against_invoice_id;

  IF (v_prior_sum + p_amount) > v_source.total_amount THEN
    RETURN jsonb_build_object(
      'decision','DENY',
      'reason_code','EXCEEDS_INVOICE_TOTAL',
      'credit_note_id', NULL,
      'prior_credit_sum', v_prior_sum,
      'requested_amount', p_amount,
      'invoice_total', v_source.total_amount
    );
  END IF;

  v_year := EXTRACT(YEAR FROM p_issue_date)::int;
  INSERT INTO public.invoice_sequence_counters (business_id, sequence_kind, year, last_allocated)
    VALUES (p_business_id, 'CN', v_year, 0)
    ON CONFLICT (business_id, sequence_kind, year) DO NOTHING;
  UPDATE public.invoice_sequence_counters
     SET last_allocated = last_allocated + 1,
         updated_at = now()
   WHERE business_id = p_business_id AND sequence_kind = 'CN' AND year = v_year
   RETURNING last_allocated INTO v_next;
  IF v_next > 9999 THEN
    RAISE EXCEPTION 'CN sequence exhausted for (%, %)', p_business_id, v_year USING ERRCODE='P0001';
  END IF;
  v_number := format('CN-%s-%s', v_year::text, lpad(v_next::text, 4, '0'));

  INSERT INTO public.credit_notes (
    id, organization_id, business_id, credit_note_number,
    against_invoice_id, issue_date, currency, amount, reason, issued_by
  ) VALUES (
    v_credit_note_id, p_organization_id, p_business_id, v_number,
    p_against_invoice_id, p_issue_date, v_source.currency, p_amount, p_reason, p_actor_user_id
  );

  v_new_cumulative := (v_prior_sum + p_amount)::numeric(18,2);

  PERFORM audit.emit_audit(
    p_actor_kind      := 'USER'::audit.actor_kind_enum,
    p_action          := 'CREDIT_NOTE_CREATED',
    p_subject_type    := 'CREDIT_NOTE'::audit.subject_type_enum,
    p_subject_id      := v_credit_note_id,
    p_actor_user_id   := p_actor_user_id,
    p_actor_role      := NULL,
    p_actor_session_id:= NULL,
    p_actor_system    := NULL,
    p_organization_id := p_organization_id,
    p_business_id     := p_business_id,
    p_before_state    := jsonb_build_object('prior_credit_sum', v_prior_sum),
    p_after_state     := jsonb_build_object(
      'credit_note_id', v_credit_note_id,
      'against_invoice_id', p_against_invoice_id,
      'amount', p_amount,
      'currency', v_source.currency,
      'new_cumulative_sum', v_new_cumulative
    ),
    p_reason          := NULL,
    p_request_context := p_context
  );

  PERFORM audit.emit_audit(
    p_actor_kind      := 'SYSTEM'::audit.actor_kind_enum,
    p_action          := 'CREDIT_NOTE_NUMBER_ALLOCATED',
    p_subject_type    := 'CREDIT_NOTE'::audit.subject_type_enum,
    p_subject_id      := v_credit_note_id,
    p_actor_user_id   := NULL,
    p_actor_role      := NULL,
    p_actor_session_id:= NULL,
    p_actor_system    := 'invoice_numbering',
    p_organization_id := p_organization_id,
    p_business_id     := p_business_id,
    p_before_state    := NULL,
    p_after_state     := jsonb_build_object(
      'credit_note_number', v_number,
      'sequence_kind', 'CN',
      'year', v_year,
      'allocated_number', v_next
    ),
    p_reason          := NULL,
    p_request_context := p_context
  );

  -- B13·P06 addition: auto-mark CREDITED on full credit
  IF v_new_cumulative >= (v_source.total_amount - v_tolerance) THEN
    v_mark_credited := public.invoice_mark_credited(
      p_against_invoice_id, v_credit_note_id, now(), p_actor_user_id, NULL, p_context);
  END IF;

  RETURN jsonb_build_object(
    'decision', 'ALLOW',
    'credit_note_id', v_credit_note_id,
    'credit_note_number', v_number,
    'amount', p_amount,
    'new_cumulative_sum', v_new_cumulative,
    'auto_marked_credited', (v_new_cumulative >= (v_source.total_amount - v_tolerance)),
    'mark_credited_result', v_mark_credited
  );
END;
$function$;

-- ---- 3. RPC: prepare_invoice_lifecycle_entries --------------------------

CREATE OR REPLACE FUNCTION public.prepare_invoice_lifecycle_entries(
  p_invoice_id            uuid,
  p_lifecycle_transition  text,
  p_actor_user_id         uuid DEFAULT NULL,
  p_actor_system          text DEFAULT 'invoice_lifecycle_ledger',
  p_context               jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_inv         public.invoices%ROWTYPE;
  v_residual    numeric(18,2);
  v_cumulative  numeric(18,2);
  v_bad_debts_code text;
  v_recv_code      text;
  v_entries        jsonb;
  v_reason_code    text;
BEGIN
  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_FOUND');
  END IF;

  IF p_lifecycle_transition <> 'WRITTEN_OFF' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','UNSUPPORTED_TRANSITION',
      'lifecycle_transition', p_lifecycle_transition);
  END IF;

  SELECT COALESCE(SUM(allocated_amount), 0)::numeric(18,2) INTO v_cumulative
    FROM public.invoice_payment_allocations
   WHERE invoice_id = p_invoice_id
     AND allocation_kind NOT IN ('REFUND','OVERPAYMENT_SURPLUS');
  v_residual := GREATEST(v_inv.total_amount - v_cumulative, 0)::numeric(18,2);

  SELECT code INTO v_bad_debts_code FROM public.chart_of_accounts
   WHERE business_id = v_inv.business_id
     AND disabled_at IS NULL
     AND name ILIKE 'Bad Debts%'
   ORDER BY code LIMIT 1;
  SELECT code INTO v_recv_code FROM public.chart_of_accounts
   WHERE business_id = v_inv.business_id
     AND disabled_at IS NULL
     AND (name ILIKE 'Trade Debtors%' OR name ILIKE 'Accounts Receivable%')
   ORDER BY code LIMIT 1;

  IF v_bad_debts_code IS NULL OR v_recv_code IS NULL THEN
    v_reason_code := 'ACCOUNTS_NOT_CONFIGURED';
    v_entries := '[]'::jsonb;
  ELSE
    v_reason_code := NULL;
    v_entries := jsonb_build_array(
      jsonb_build_object(
        'debit_account_code', v_bad_debts_code,
        'credit_account_code', NULL,
        'amount', v_residual,
        'currency', v_inv.currency,
        'entry_period', v_inv.issue_date,
        'purpose', 'BAD_DEBTS_EXPENSE'),
      jsonb_build_object(
        'debit_account_code', NULL,
        'credit_account_code', v_recv_code,
        'amount', v_residual,
        'currency', v_inv.currency,
        'entry_period', v_inv.issue_date,
        'purpose', 'TRADE_DEBTORS_OFFSET')
    );
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind      := CASE WHEN p_actor_user_id IS NOT NULL THEN 'USER' ELSE 'SYSTEM' END::audit.actor_kind_enum,
    p_action          := 'INVOICE_BAD_DEBT_EXPENSE_LEDGER_REQUESTED',
    p_subject_type    := 'INVOICE'::audit.subject_type_enum,
    p_subject_id      := p_invoice_id,
    p_actor_user_id   := p_actor_user_id,
    p_actor_role      := NULL,
    p_actor_session_id:= NULL,
    p_actor_system    := p_actor_system,
    p_organization_id := v_inv.organization_id,
    p_business_id     := v_inv.business_id,
    p_before_state    := NULL,
    p_after_state     := jsonb_build_object(
      'lifecycle_transition', p_lifecycle_transition,
      'residual_amount', v_residual,
      'currency', v_inv.currency,
      'entries', v_entries,
      'reason_code', v_reason_code
    ),
    p_reason          := v_reason_code,
    p_request_context := p_context
  );

  RETURN jsonb_build_object(
    'decision', 'ALLOW',
    'invoice_id', p_invoice_id,
    'lifecycle_transition', p_lifecycle_transition,
    'residual_amount', v_residual,
    'currency', v_inv.currency,
    'entries', v_entries,
    'reason_code', v_reason_code
  );
END;
$function$;

-- ---- 4. CREATE OR REPLACE: invoice_mark_written_off ---------------------

CREATE OR REPLACE FUNCTION public.invoice_mark_written_off(
  p_actor_user_id uuid,
  p_invoice_id    uuid,
  p_reason        text,
  p_written_off_at timestamptz DEFAULT NULL,
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_inv public.invoices%ROWTYPE;
  v_decision jsonb;
  v_when timestamptz := COALESCE(p_written_off_at, now());
  v_ledger_payload jsonb;
BEGIN
  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_FOUND'); END IF;
  v_decision := public.can_perform(p_actor_user_id,'INVOICE_MANAGE','MARK_WRITTEN_OFF',
    jsonb_build_object('invoice_id', p_invoice_id), v_inv.business_id, v_inv.organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision', 'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;
  IF v_inv.invoice_type = 'PRO_FORMA' THEN
    PERFORM public._emit_invoice_transition_failed(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text,'WRITTEN_OFF','PRO_FORMA_NOT_PAYABLE', p_actor_user_id, NULL, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','PRO_FORMA_NOT_PAYABLE');
  END IF;
  IF v_inv.lifecycle_status NOT IN ('PAYMENT_EXPECTED','PARTIALLY_PAID','SENT') THEN
    PERFORM public._emit_invoice_transition_failed(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text,'WRITTEN_OFF','ILLEGAL_TRANSITION', p_actor_user_id, NULL, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','ILLEGAL_TRANSITION','current_status', v_inv.lifecycle_status::text);
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','REASON_REQUIRED');
  END IF;
  UPDATE public.invoices SET
    lifecycle_status='WRITTEN_OFF', lifecycle_status_changed_at=now(),
    lifecycle_status_changed_by=p_actor_user_id,
    written_off_at = v_when, written_off_by = p_actor_user_id, written_off_reason = p_reason,
    updated_at=now()
   WHERE id = p_invoice_id;
  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='INVOICE_MARKED_WRITTEN_OFF',
    p_subject_type:='INVOICE'::audit.subject_type_enum, p_subject_id:=p_invoice_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_inv.organization_id, p_business_id:=v_inv.business_id,
    p_before_state:=jsonb_build_object('lifecycle_status', v_inv.lifecycle_status::text),
    p_after_state :=jsonb_build_object('lifecycle_status','WRITTEN_OFF','written_off_at', v_when, 'reason', p_reason),
    p_reason:=p_reason, p_request_context:=p_context);

  v_ledger_payload := public.prepare_invoice_lifecycle_entries(
    p_invoice_id, 'WRITTEN_OFF', p_actor_user_id, NULL, p_context);

  RETURN jsonb_build_object('decision','ALLOW','lifecycle_status','WRITTEN_OFF',
    'written_off_at', v_when, 'ledger_payload', v_ledger_payload);
END;
$function$;
