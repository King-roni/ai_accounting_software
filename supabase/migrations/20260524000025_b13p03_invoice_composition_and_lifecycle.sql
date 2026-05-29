-- ============================================================================
-- Block 13 Phase 03 (BOOK-118) — Invoice Composition & Lifecycle State Machine
-- ============================================================================

-- ---- 1. allocation_kind enum + table ------------------------------------

CREATE TYPE public.invoice_payment_allocation_kind_enum AS ENUM (
  'FULL',
  'PARTIAL',
  'OVERPAYMENT_PRIMARY',
  'OVERPAYMENT_SURPLUS',
  'REFUND',
  'MULTI_INVOICE_USER_CONFIRMED'
);

CREATE TABLE public.invoice_payment_allocations (
  id              uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  organization_id uuid NOT NULL,
  business_id     uuid NOT NULL,
  invoice_id      uuid NOT NULL REFERENCES public.invoices(id)        ON DELETE RESTRICT,
  transaction_id  uuid NOT NULL REFERENCES public.transactions(id)    ON DELETE RESTRICT,
  match_record_id uuid NULL     REFERENCES public.match_records(id)   ON DELETE SET NULL,
  allocated_amount numeric(18,2) NOT NULL,
  allocation_kind  public.invoice_payment_allocation_kind_enum NOT NULL,
  allocated_at    timestamptz NOT NULL DEFAULT now(),
  allocated_by    uuid NULL,
  allocated_by_system text NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT ipa_refund_sign_chk CHECK (
    (allocation_kind = 'REFUND' AND allocated_amount < 0)
    OR (allocation_kind <> 'REFUND' AND allocated_amount >= 0)
  ),
  CONSTRAINT ipa_actor_chk CHECK (
    (allocated_by IS NOT NULL AND allocated_by_system IS NULL)
    OR (allocated_by IS NULL AND allocated_by_system IS NOT NULL)
  )
);

CREATE INDEX ipa_invoice_allocated_at_idx ON public.invoice_payment_allocations(invoice_id, allocated_at);
CREATE INDEX ipa_transaction_idx           ON public.invoice_payment_allocations(transaction_id);
CREATE INDEX ipa_match_record_idx          ON public.invoice_payment_allocations(match_record_id) WHERE match_record_id IS NOT NULL;
CREATE INDEX ipa_business_idx              ON public.invoice_payment_allocations(business_id);

ALTER TABLE public.invoice_payment_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_payment_allocations FORCE  ROW LEVEL SECURITY;

CREATE POLICY ipa_select_tenant ON public.invoice_payment_allocations
  FOR SELECT TO authenticated USING (business_id = ANY (public.current_user_businesses()));
CREATE POLICY ipa_deny_insert ON public.invoice_payment_allocations FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY ipa_deny_update ON public.invoice_payment_allocations FOR UPDATE TO authenticated USING (false);
CREATE POLICY ipa_deny_delete ON public.invoice_payment_allocations FOR DELETE TO authenticated USING (false);

COMMENT ON TABLE public.invoice_payment_allocations IS
  'Block 13 P03 — per-row payment allocations against an invoice. Sum of non-REFUND non-OVERPAYMENT_SURPLUS amounts is the cumulative paid total; REFUND rows carry a negative amount.';

-- ---- 2. invoices: new lifecycle-timing columns --------------------------

ALTER TABLE public.invoices
  ADD COLUMN sent_at           timestamptz NULL,
  ADD COLUMN sent_by            uuid        NULL,
  ADD COLUMN written_off_at     timestamptz NULL,
  ADD COLUMN written_off_by     uuid        NULL,
  ADD COLUMN written_off_reason text        NULL;

ALTER TABLE public.invoices
  ADD CONSTRAINT invoices_sent_xor_chk CHECK (
    (sent_at IS NULL) = (sent_by IS NULL)
  );
ALTER TABLE public.invoices
  ADD CONSTRAINT invoices_written_off_xor_chk CHECK (
    ((written_off_at IS NULL) AND (written_off_by IS NULL) AND (written_off_reason IS NULL))
    OR ((written_off_at IS NOT NULL) AND (written_off_by IS NOT NULL) AND (written_off_reason IS NOT NULL))
  );
ALTER TABLE public.invoices
  ADD CONSTRAINT invoices_written_off_reason_len_chk CHECK (
    written_off_reason IS NULL OR length(written_off_reason) <= 4000
  );

-- ---- 3. Currency-lock trigger ------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_block_invoice_currency_change()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.currency IS DISTINCT FROM NEW.currency THEN
    RAISE EXCEPTION 'invoices.currency is immutable after creation (was %, attempted %)',
      OLD.currency, NEW.currency
      USING ERRCODE='P0001';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_block_invoice_currency_change
  BEFORE UPDATE OF currency ON public.invoices
  FOR EACH ROW EXECUTE FUNCTION public.fn_block_invoice_currency_change();

-- ---- 4. Permission matrix seed: INVOICE_MANAGE --------------------------

INSERT INTO public.permission_matrix (role, surface, decision) VALUES
  ('OWNER',      'INVOICE_MANAGE', 'ALLOW'),
  ('ADMIN',      'INVOICE_MANAGE', 'ALLOW'),
  ('BOOKKEEPER', 'INVOICE_MANAGE', 'ALLOW'),
  ('ACCOUNTANT', 'INVOICE_MANAGE', 'DENY'),
  ('REVIEWER',   'INVOICE_MANAGE', 'DENY'),
  ('READ_ONLY',  'INVOICE_MANAGE', 'DENY')
ON CONFLICT (role, surface) DO NOTHING;

-- ---- 5. Internal helper: emit lifecycle-transition-failed audit ---------

CREATE OR REPLACE FUNCTION public._emit_invoice_transition_failed(
  p_invoice_id      uuid,
  p_organization_id uuid,
  p_business_id     uuid,
  p_current_status  text,
  p_attempted_target text,
  p_reason_code     text,
  p_actor_user_id   uuid,
  p_actor_system    text,
  p_context         jsonb
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
BEGIN
  PERFORM audit.emit_audit(
    p_actor_kind      := CASE WHEN p_actor_user_id IS NOT NULL THEN 'USER' ELSE 'SYSTEM' END::audit.actor_kind_enum,
    p_action          := 'INVOICE_LIFECYCLE_TRANSITION_FAILED',
    p_subject_type    := 'INVOICE'::audit.subject_type_enum,
    p_subject_id      := p_invoice_id,
    p_actor_user_id   := p_actor_user_id,
    p_actor_role      := NULL,
    p_actor_session_id:= NULL,
    p_actor_system    := p_actor_system,
    p_organization_id := p_organization_id,
    p_business_id     := p_business_id,
    p_before_state    := jsonb_build_object('lifecycle_status', p_current_status),
    p_after_state     := jsonb_build_object(
      'attempted_target', p_attempted_target,
      'reason_code', p_reason_code
    ),
    p_reason          := p_reason_code,
    p_request_context := p_context
  );
END;
$function$;

-- ---- 6. Composition RPCs ------------------------------------------------

-- 6a. invoice_recompute_totals (internal + user-callable)
CREATE OR REPLACE FUNCTION public.invoice_recompute_totals(
  p_invoice_id uuid,
  p_context    jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_inv         public.invoices%ROWTYPE;
  v_subtotal    numeric(18,2);
  v_vat         numeric(18,2);
  v_total       numeric(18,2);
BEGIN
  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_FOUND','invoice_id',NULL);
  END IF;
  SELECT
    COALESCE(SUM(subtotal_amount), 0)::numeric(18,2),
    COALESCE(SUM(COALESCE(vat_amount, 0)), 0)::numeric(18,2),
    COALESCE(SUM(total_amount), 0)::numeric(18,2)
    INTO v_subtotal, v_vat, v_total
    FROM public.invoice_lines WHERE invoice_id = p_invoice_id;
  UPDATE public.invoices
     SET subtotal_amount = v_subtotal,
         vat_amount = v_vat,
         total_amount = v_total,
         updated_at = now()
   WHERE id = p_invoice_id;
  PERFORM audit.emit_audit(
    p_actor_kind      := 'SYSTEM'::audit.actor_kind_enum,
    p_action          := 'INVOICE_TOTALS_RECOMPUTED',
    p_subject_type    := 'INVOICE'::audit.subject_type_enum,
    p_subject_id      := p_invoice_id,
    p_actor_user_id   := NULL,
    p_actor_role      := NULL,
    p_actor_session_id:= NULL,
    p_actor_system    := 'invoice_composition',
    p_organization_id := v_inv.organization_id,
    p_business_id     := v_inv.business_id,
    p_before_state    := jsonb_build_object(
      'subtotal_amount', v_inv.subtotal_amount,
      'vat_amount', v_inv.vat_amount,
      'total_amount', v_inv.total_amount
    ),
    p_after_state     := jsonb_build_object(
      'subtotal_amount', v_subtotal,
      'vat_amount', v_vat,
      'total_amount', v_total
    ),
    p_reason          := NULL,
    p_request_context := p_context
  );
  RETURN jsonb_build_object(
    'decision','ALLOW',
    'invoice_id', p_invoice_id,
    'subtotal_amount', v_subtotal,
    'vat_amount', v_vat,
    'total_amount', v_total
  );
END;
$function$;

-- 6b. invoice_add_line (DRAFT only)
CREATE OR REPLACE FUNCTION public.invoice_add_line(
  p_actor_user_id uuid,
  p_invoice_id    uuid,
  p_description   text,
  p_quantity      numeric,
  p_unit_price    numeric,
  p_vat_treatment public.vat_treatment_enum,
  p_vat_rate_pct  numeric,
  p_vat_amount    numeric,
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_inv      public.invoices%ROWTYPE;
  v_decision jsonb;
  v_next_no  int;
  v_sub      numeric(18,2);
  v_total    numeric(18,2);
  v_line_id  uuid := gen_uuid_v7();
BEGIN
  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_FOUND','line_id',NULL);
  END IF;
  v_decision := public.can_perform(
    p_actor_user_id := p_actor_user_id,
    p_surface       := 'INVOICE_MANAGE',
    p_action        := 'ADD_LINE',
    p_resource      := jsonb_build_object('invoice_id', p_invoice_id),
    p_business_id   := v_inv.business_id,
    p_organization_id := v_inv.organization_id
  );
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision', 'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'),'line_id',NULL);
  END IF;
  IF v_inv.lifecycle_status <> 'DRAFT' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','NOT_DRAFT','line_id',NULL,'lifecycle_status', v_inv.lifecycle_status::text);
  END IF;
  IF p_quantity IS NULL OR p_quantity <= 0 OR p_unit_price IS NULL OR p_unit_price < 0 THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','INVALID_QUANTITY_OR_PRICE','line_id',NULL);
  END IF;

  SELECT COALESCE(MAX(line_number),0) + 1 INTO v_next_no
    FROM public.invoice_lines WHERE invoice_id = p_invoice_id;
  v_sub   := (p_quantity * p_unit_price)::numeric(18,2);
  v_total := (v_sub + COALESCE(p_vat_amount, 0))::numeric(18,2);
  INSERT INTO public.invoice_lines (
    id, organization_id, business_id, invoice_id, line_number,
    description, quantity, unit_price, currency,
    subtotal_amount, vat_treatment, vat_rate_pct, vat_amount, total_amount
  ) VALUES (
    v_line_id, v_inv.organization_id, v_inv.business_id, p_invoice_id, v_next_no,
    p_description, p_quantity, p_unit_price, v_inv.currency,
    v_sub, p_vat_treatment, p_vat_rate_pct, p_vat_amount, v_total
  );

  PERFORM audit.emit_audit(
    p_actor_kind      := 'USER'::audit.actor_kind_enum,
    p_action          := 'INVOICE_LINE_ADDED',
    p_subject_type    := 'INVOICE_LINE'::audit.subject_type_enum,
    p_subject_id      := v_line_id,
    p_actor_user_id   := p_actor_user_id,
    p_actor_role      := NULL, p_actor_session_id := NULL, p_actor_system := NULL,
    p_organization_id := v_inv.organization_id, p_business_id := v_inv.business_id,
    p_before_state    := NULL,
    p_after_state     := jsonb_build_object('invoice_id', p_invoice_id, 'line_id', v_line_id, 'line_number', v_next_no, 'total_amount', v_total),
    p_reason := NULL, p_request_context := p_context
  );
  PERFORM public.invoice_recompute_totals(p_invoice_id, p_context);
  RETURN jsonb_build_object('decision','ALLOW','line_id', v_line_id, 'line_number', v_next_no, 'total_amount', v_total);
END;
$function$;

-- 6c. invoice_update_line (DRAFT only)
CREATE OR REPLACE FUNCTION public.invoice_update_line(
  p_actor_user_id  uuid,
  p_invoice_line_id uuid,
  p_description    text DEFAULT NULL,
  p_quantity       numeric DEFAULT NULL,
  p_unit_price     numeric DEFAULT NULL,
  p_vat_treatment  public.vat_treatment_enum DEFAULT NULL,
  p_vat_rate_pct   numeric DEFAULT NULL,
  p_vat_amount     numeric DEFAULT NULL,
  p_context        jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_line public.invoice_lines%ROWTYPE;
  v_inv  public.invoices%ROWTYPE;
  v_decision jsonb;
  v_new_qty  numeric;
  v_new_price numeric;
  v_new_vat  numeric;
  v_sub      numeric(18,2);
  v_total    numeric(18,2);
BEGIN
  SELECT * INTO v_line FROM public.invoice_lines WHERE id = p_invoice_line_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','LINE_NOT_FOUND'); END IF;
  SELECT * INTO v_inv FROM public.invoices WHERE id = v_line.invoice_id FOR UPDATE;
  v_decision := public.can_perform(p_actor_user_id, 'INVOICE_MANAGE', 'UPDATE_LINE',
    jsonb_build_object('invoice_id', v_line.invoice_id, 'line_id', p_invoice_line_id),
    v_inv.business_id, v_inv.organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision', 'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;
  IF v_inv.lifecycle_status <> 'DRAFT' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','NOT_DRAFT','lifecycle_status', v_inv.lifecycle_status::text);
  END IF;

  v_new_qty   := COALESCE(p_quantity, v_line.quantity);
  v_new_price := COALESCE(p_unit_price, v_line.unit_price);
  v_new_vat   := CASE WHEN p_vat_amount IS NOT NULL THEN p_vat_amount ELSE v_line.vat_amount END;
  v_sub   := (v_new_qty * v_new_price)::numeric(18,2);
  v_total := (v_sub + COALESCE(v_new_vat, 0))::numeric(18,2);

  UPDATE public.invoice_lines SET
    description = COALESCE(p_description, description),
    quantity = v_new_qty,
    unit_price = v_new_price,
    vat_treatment = COALESCE(p_vat_treatment, vat_treatment),
    vat_rate_pct  = COALESCE(p_vat_rate_pct, vat_rate_pct),
    vat_amount    = v_new_vat,
    subtotal_amount = v_sub,
    total_amount    = v_total
  WHERE id = p_invoice_line_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='INVOICE_LINE_UPDATED',
    p_subject_type:='INVOICE_LINE'::audit.subject_type_enum, p_subject_id:=p_invoice_line_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_inv.organization_id, p_business_id:=v_inv.business_id,
    p_before_state:=jsonb_build_object('quantity', v_line.quantity, 'unit_price', v_line.unit_price, 'total_amount', v_line.total_amount),
    p_after_state :=jsonb_build_object('quantity', v_new_qty,        'unit_price', v_new_price,       'total_amount', v_total),
    p_reason:=NULL, p_request_context:=p_context);
  PERFORM public.invoice_recompute_totals(v_line.invoice_id, p_context);
  RETURN jsonb_build_object('decision','ALLOW','line_id', p_invoice_line_id, 'total_amount', v_total);
END;
$function$;

-- 6d. invoice_remove_line (DRAFT only — renumbers subsequent lines)
CREATE OR REPLACE FUNCTION public.invoice_remove_line(
  p_actor_user_id   uuid,
  p_invoice_line_id uuid,
  p_context         jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_line public.invoice_lines%ROWTYPE;
  v_inv  public.invoices%ROWTYPE;
  v_decision jsonb;
  v_removed_no int;
BEGIN
  SELECT * INTO v_line FROM public.invoice_lines WHERE id = p_invoice_line_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','LINE_NOT_FOUND'); END IF;
  SELECT * INTO v_inv FROM public.invoices WHERE id = v_line.invoice_id FOR UPDATE;
  v_decision := public.can_perform(p_actor_user_id, 'INVOICE_MANAGE', 'REMOVE_LINE',
    jsonb_build_object('invoice_id', v_line.invoice_id, 'line_id', p_invoice_line_id),
    v_inv.business_id, v_inv.organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision', 'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;
  IF v_inv.lifecycle_status <> 'DRAFT' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','NOT_DRAFT','lifecycle_status', v_inv.lifecycle_status::text);
  END IF;
  v_removed_no := v_line.line_number;
  DELETE FROM public.invoice_lines WHERE id = p_invoice_line_id;
  UPDATE public.invoice_lines SET line_number = line_number - 1
   WHERE invoice_id = v_line.invoice_id AND line_number > v_removed_no;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='INVOICE_LINE_REMOVED',
    p_subject_type:='INVOICE_LINE'::audit.subject_type_enum, p_subject_id:=p_invoice_line_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_inv.organization_id, p_business_id:=v_inv.business_id,
    p_before_state:=jsonb_build_object('line_number', v_removed_no, 'total_amount', v_line.total_amount),
    p_after_state :=jsonb_build_object('invoice_id', v_line.invoice_id, 'removed_line_id', p_invoice_line_id),
    p_reason:=NULL, p_request_context:=p_context);
  PERFORM public.invoice_recompute_totals(v_line.invoice_id, p_context);
  RETURN jsonb_build_object('decision','ALLOW','removed_line_id', p_invoice_line_id);
END;
$function$;

-- ---- 7. Lifecycle RPCs --------------------------------------------------

-- 7a. invoice_mark_sent (DRAFT → SENT). User-initiated.
CREATE OR REPLACE FUNCTION public.invoice_mark_sent(
  p_actor_user_id uuid,
  p_invoice_id    uuid,
  p_sent_at       timestamptz DEFAULT NULL,
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_inv public.invoices%ROWTYPE;
  v_decision jsonb;
  v_alloc    jsonb;
  v_sent_at  timestamptz := COALESCE(p_sent_at, now());
BEGIN
  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_FOUND'); END IF;
  v_decision := public.can_perform(p_actor_user_id,'INVOICE_MANAGE','MARK_SENT',
    jsonb_build_object('invoice_id', p_invoice_id), v_inv.business_id, v_inv.organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision', 'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;
  IF v_inv.lifecycle_status <> 'DRAFT' THEN
    PERFORM public._emit_invoice_transition_failed(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text, 'SENT','ILLEGAL_TRANSITION', p_actor_user_id, NULL, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','ILLEGAL_TRANSITION','current_status', v_inv.lifecycle_status::text);
  END IF;
  v_alloc := public.allocate_invoice_number(p_invoice_id, p_context);
  UPDATE public.invoices
     SET lifecycle_status = 'SENT',
         lifecycle_status_changed_at = now(),
         lifecycle_status_changed_by = p_actor_user_id,
         sent_at = v_sent_at,
         sent_by = p_actor_user_id,
         updated_at = now()
   WHERE id = p_invoice_id;
  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='INVOICE_SENT',
    p_subject_type:='INVOICE'::audit.subject_type_enum, p_subject_id:=p_invoice_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_inv.organization_id, p_business_id:=v_inv.business_id,
    p_before_state:=jsonb_build_object('lifecycle_status','DRAFT'),
    p_after_state :=jsonb_build_object('lifecycle_status','SENT', 'sent_at', v_sent_at, 'invoice_number', v_alloc->'invoice_number'),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','ALLOW','lifecycle_status','SENT','sent_at', v_sent_at, 'invoice_number', v_alloc->'invoice_number');
END;
$function$;

-- 7b. invoice_mark_payment_expected (SENT → PAYMENT_EXPECTED). System-callable.
CREATE OR REPLACE FUNCTION public.invoice_mark_payment_expected(
  p_invoice_id   uuid,
  p_actor_system text DEFAULT 'payment_expected_scheduler',
  p_context      jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE v_inv public.invoices%ROWTYPE;
BEGIN
  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_FOUND'); END IF;
  IF v_inv.lifecycle_status <> 'SENT' THEN
    PERFORM public._emit_invoice_transition_failed(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text,'PAYMENT_EXPECTED','ILLEGAL_TRANSITION', NULL, p_actor_system, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','ILLEGAL_TRANSITION','current_status', v_inv.lifecycle_status::text);
  END IF;
  UPDATE public.invoices
     SET lifecycle_status='PAYMENT_EXPECTED', lifecycle_status_changed_at=now(), updated_at=now()
   WHERE id = p_invoice_id;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='INVOICE_PAYMENT_EXPECTED',
    p_subject_type:='INVOICE'::audit.subject_type_enum, p_subject_id:=p_invoice_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
    p_organization_id:=v_inv.organization_id, p_business_id:=v_inv.business_id,
    p_before_state:=jsonb_build_object('lifecycle_status','SENT'),
    p_after_state :=jsonb_build_object('lifecycle_status','PAYMENT_EXPECTED'),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','ALLOW','lifecycle_status','PAYMENT_EXPECTED');
END;
$function$;

-- Internal helper: insert one allocation row + emit audit
CREATE OR REPLACE FUNCTION public._insert_invoice_payment_allocation(
  p_invoice_id     uuid,
  p_organization_id uuid,
  p_business_id    uuid,
  p_transaction_id uuid,
  p_match_record_id uuid,
  p_amount         numeric,
  p_kind           public.invoice_payment_allocation_kind_enum,
  p_allocated_at   timestamptz,
  p_actor_user_id  uuid,
  p_actor_system   text,
  p_context        jsonb
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE v_id uuid := gen_uuid_v7();
BEGIN
  INSERT INTO public.invoice_payment_allocations (
    id, organization_id, business_id, invoice_id, transaction_id, match_record_id,
    allocated_amount, allocation_kind, allocated_at, allocated_by, allocated_by_system
  ) VALUES (
    v_id, p_organization_id, p_business_id, p_invoice_id, p_transaction_id, p_match_record_id,
    p_amount, p_kind, p_allocated_at, p_actor_user_id, p_actor_system
  );
  PERFORM audit.emit_audit(
    p_actor_kind:=CASE WHEN p_actor_user_id IS NOT NULL THEN 'USER' ELSE 'SYSTEM' END::audit.actor_kind_enum,
    p_action:='INVOICE_PAYMENT_ALLOCATION_CREATED',
    p_subject_type:='INVOICE_PAYMENT_ALLOCATION'::audit.subject_type_enum, p_subject_id:=v_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state :=jsonb_build_object('invoice_id', p_invoice_id, 'transaction_id', p_transaction_id,
                                       'amount', p_amount, 'kind', p_kind::text, 'allocation_id', v_id),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN v_id;
END;
$function$;

-- 7c. invoice_mark_paid
CREATE OR REPLACE FUNCTION public.invoice_mark_paid(
  p_invoice_id       uuid,
  p_transaction_id   uuid,
  p_paid_amount      numeric,
  p_paid_at          timestamptz,
  p_match_record_id  uuid DEFAULT NULL,
  p_actor_user_id    uuid DEFAULT NULL,
  p_actor_system     text DEFAULT 'income_matcher',
  p_context          jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_inv public.invoices%ROWTYPE;
  v_alloc_id uuid;
BEGIN
  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_FOUND'); END IF;
  IF v_inv.invoice_type = 'PRO_FORMA' THEN
    PERFORM public._emit_invoice_transition_failed(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text,'PAID','PRO_FORMA_NOT_PAYABLE', p_actor_user_id, p_actor_system, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','PRO_FORMA_NOT_PAYABLE');
  END IF;
  IF v_inv.lifecycle_status NOT IN ('PAYMENT_EXPECTED','PARTIALLY_PAID','SENT') THEN
    PERFORM public._emit_invoice_transition_failed(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text,'PAID','ILLEGAL_TRANSITION', p_actor_user_id, p_actor_system, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','ILLEGAL_TRANSITION','current_status', v_inv.lifecycle_status::text);
  END IF;
  v_alloc_id := public._insert_invoice_payment_allocation(
    p_invoice_id, v_inv.organization_id, v_inv.business_id,
    p_transaction_id, p_match_record_id, p_paid_amount,
    'FULL'::public.invoice_payment_allocation_kind_enum,
    COALESCE(p_paid_at, now()), p_actor_user_id, p_actor_system, p_context);
  UPDATE public.invoices
     SET lifecycle_status='PAID', lifecycle_status_changed_at=now(),
         lifecycle_status_changed_by=p_actor_user_id, updated_at=now()
   WHERE id = p_invoice_id;
  PERFORM audit.emit_audit(
    p_actor_kind:=CASE WHEN p_actor_user_id IS NOT NULL THEN 'USER' ELSE 'SYSTEM' END::audit.actor_kind_enum,
    p_action:='INVOICE_MARKED_PAID',
    p_subject_type:='INVOICE'::audit.subject_type_enum, p_subject_id:=p_invoice_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
    p_organization_id:=v_inv.organization_id, p_business_id:=v_inv.business_id,
    p_before_state:=jsonb_build_object('lifecycle_status', v_inv.lifecycle_status::text),
    p_after_state :=jsonb_build_object('lifecycle_status','PAID', 'allocation_id', v_alloc_id, 'paid_amount', p_paid_amount),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','ALLOW','lifecycle_status','PAID','allocation_id', v_alloc_id);
END;
$function$;

-- 7d. invoice_mark_partially_paid (with auto-promotion to PAID when cumulative hits total)
CREATE OR REPLACE FUNCTION public.invoice_mark_partially_paid(
  p_invoice_id       uuid,
  p_transaction_id   uuid,
  p_partial_amount   numeric,
  p_paid_at          timestamptz,
  p_match_record_id  uuid DEFAULT NULL,
  p_actor_user_id    uuid DEFAULT NULL,
  p_actor_system     text DEFAULT 'income_matcher',
  p_context          jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_inv public.invoices%ROWTYPE;
  v_alloc_id uuid;
  v_cumulative numeric(18,2);
  v_auto_promote boolean := false;
  v_tolerance numeric := 0.01;
BEGIN
  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_FOUND'); END IF;
  IF v_inv.invoice_type = 'PRO_FORMA' THEN
    PERFORM public._emit_invoice_transition_failed(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text,'PARTIALLY_PAID','PRO_FORMA_NOT_PAYABLE', p_actor_user_id, p_actor_system, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','PRO_FORMA_NOT_PAYABLE');
  END IF;
  IF v_inv.lifecycle_status NOT IN ('PAYMENT_EXPECTED','PARTIALLY_PAID','SENT') THEN
    PERFORM public._emit_invoice_transition_failed(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text,'PARTIALLY_PAID','ILLEGAL_TRANSITION', p_actor_user_id, p_actor_system, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','ILLEGAL_TRANSITION','current_status', v_inv.lifecycle_status::text);
  END IF;
  IF p_partial_amount IS NULL OR p_partial_amount <= 0 THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','INVALID_AMOUNT');
  END IF;

  v_alloc_id := public._insert_invoice_payment_allocation(
    p_invoice_id, v_inv.organization_id, v_inv.business_id,
    p_transaction_id, p_match_record_id, p_partial_amount,
    'PARTIAL'::public.invoice_payment_allocation_kind_enum,
    COALESCE(p_paid_at, now()), p_actor_user_id, p_actor_system, p_context);

  SELECT COALESCE(SUM(allocated_amount), 0)::numeric(18,2) INTO v_cumulative
    FROM public.invoice_payment_allocations
   WHERE invoice_id = p_invoice_id
     AND allocation_kind NOT IN ('REFUND','OVERPAYMENT_SURPLUS');
  v_auto_promote := v_cumulative >= (v_inv.total_amount - v_tolerance);

  IF v_auto_promote THEN
    UPDATE public.invoices SET
      lifecycle_status='PAID', lifecycle_status_changed_at=now(),
      lifecycle_status_changed_by=p_actor_user_id, updated_at=now()
     WHERE id = p_invoice_id;
    PERFORM audit.emit_audit(
      p_actor_kind:=CASE WHEN p_actor_user_id IS NOT NULL THEN 'USER' ELSE 'SYSTEM' END::audit.actor_kind_enum,
      p_action:='INVOICE_MARKED_PAID',
      p_subject_type:='INVOICE'::audit.subject_type_enum, p_subject_id:=p_invoice_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
      p_organization_id:=v_inv.organization_id, p_business_id:=v_inv.business_id,
      p_before_state:=jsonb_build_object('lifecycle_status', v_inv.lifecycle_status::text, 'cumulative_paid', v_cumulative - p_partial_amount),
      p_after_state :=jsonb_build_object('lifecycle_status','PAID', 'cumulative_paid', v_cumulative, 'auto_promoted_from_partial', true),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','ALLOW','lifecycle_status','PAID','allocation_id', v_alloc_id, 'cumulative_paid', v_cumulative, 'auto_promoted', true);
  ELSE
    UPDATE public.invoices SET
      lifecycle_status='PARTIALLY_PAID', lifecycle_status_changed_at=now(),
      lifecycle_status_changed_by=p_actor_user_id, updated_at=now()
     WHERE id = p_invoice_id;
    PERFORM audit.emit_audit(
      p_actor_kind:=CASE WHEN p_actor_user_id IS NOT NULL THEN 'USER' ELSE 'SYSTEM' END::audit.actor_kind_enum,
      p_action:='INVOICE_MARKED_PARTIALLY_PAID',
      p_subject_type:='INVOICE'::audit.subject_type_enum, p_subject_id:=p_invoice_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
      p_organization_id:=v_inv.organization_id, p_business_id:=v_inv.business_id,
      p_before_state:=jsonb_build_object('lifecycle_status', v_inv.lifecycle_status::text),
      p_after_state :=jsonb_build_object('lifecycle_status','PARTIALLY_PAID', 'allocation_id', v_alloc_id, 'partial_amount', p_partial_amount, 'cumulative_paid', v_cumulative),
      p_reason:=NULL, p_request_context:=p_context);
    RETURN jsonb_build_object('decision','ALLOW','lifecycle_status','PARTIALLY_PAID','allocation_id', v_alloc_id, 'cumulative_paid', v_cumulative);
  END IF;
END;
$function$;

-- 7e. invoice_mark_overpaid (paired allocation rows)
CREATE OR REPLACE FUNCTION public.invoice_mark_overpaid(
  p_invoice_id       uuid,
  p_transaction_id   uuid,
  p_paid_amount      numeric,
  p_paid_at          timestamptz,
  p_match_record_id  uuid DEFAULT NULL,
  p_actor_user_id    uuid DEFAULT NULL,
  p_actor_system     text DEFAULT 'income_matcher',
  p_context          jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_inv public.invoices%ROWTYPE;
  v_primary_id uuid;
  v_surplus_id uuid;
  v_surplus numeric(18,2);
  v_paid_at timestamptz := COALESCE(p_paid_at, now());
BEGIN
  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_FOUND'); END IF;
  IF v_inv.invoice_type = 'PRO_FORMA' THEN
    PERFORM public._emit_invoice_transition_failed(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text,'OVERPAID','PRO_FORMA_NOT_PAYABLE', p_actor_user_id, p_actor_system, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','PRO_FORMA_NOT_PAYABLE');
  END IF;
  IF v_inv.lifecycle_status NOT IN ('PAYMENT_EXPECTED','SENT','PARTIALLY_PAID') THEN
    PERFORM public._emit_invoice_transition_failed(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text,'OVERPAID','ILLEGAL_TRANSITION', p_actor_user_id, p_actor_system, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','ILLEGAL_TRANSITION','current_status', v_inv.lifecycle_status::text);
  END IF;
  IF p_paid_amount IS NULL OR p_paid_amount <= v_inv.total_amount THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','NOT_AN_OVERPAYMENT','total_amount', v_inv.total_amount);
  END IF;
  v_surplus := (p_paid_amount - v_inv.total_amount)::numeric(18,2);

  v_primary_id := public._insert_invoice_payment_allocation(
    p_invoice_id, v_inv.organization_id, v_inv.business_id,
    p_transaction_id, p_match_record_id, v_inv.total_amount,
    'OVERPAYMENT_PRIMARY'::public.invoice_payment_allocation_kind_enum,
    v_paid_at, p_actor_user_id, p_actor_system, p_context);
  v_surplus_id := public._insert_invoice_payment_allocation(
    p_invoice_id, v_inv.organization_id, v_inv.business_id,
    p_transaction_id, p_match_record_id, v_surplus,
    'OVERPAYMENT_SURPLUS'::public.invoice_payment_allocation_kind_enum,
    v_paid_at, p_actor_user_id, p_actor_system, p_context);

  UPDATE public.invoices SET
    lifecycle_status='OVERPAID', lifecycle_status_changed_at=now(),
    lifecycle_status_changed_by=p_actor_user_id, updated_at=now()
   WHERE id = p_invoice_id;
  PERFORM audit.emit_audit(
    p_actor_kind:=CASE WHEN p_actor_user_id IS NOT NULL THEN 'USER' ELSE 'SYSTEM' END::audit.actor_kind_enum,
    p_action:='INVOICE_MARKED_OVERPAID',
    p_subject_type:='INVOICE'::audit.subject_type_enum, p_subject_id:=p_invoice_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
    p_organization_id:=v_inv.organization_id, p_business_id:=v_inv.business_id,
    p_before_state:=jsonb_build_object('lifecycle_status', v_inv.lifecycle_status::text),
    p_after_state :=jsonb_build_object('lifecycle_status','OVERPAID', 'paid_amount', p_paid_amount,
                                        'total_amount', v_inv.total_amount, 'surplus_amount', v_surplus,
                                        'primary_allocation_id', v_primary_id, 'surplus_allocation_id', v_surplus_id),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','ALLOW','lifecycle_status','OVERPAID',
    'primary_allocation_id', v_primary_id, 'surplus_allocation_id', v_surplus_id, 'surplus_amount', v_surplus);
END;
$function$;

-- 7f. invoice_mark_refunded
CREATE OR REPLACE FUNCTION public.invoice_mark_refunded(
  p_invoice_id           uuid,
  p_refund_transaction_id uuid,
  p_refund_amount        numeric,
  p_refunded_at          timestamptz,
  p_match_record_id      uuid DEFAULT NULL,
  p_actor_user_id        uuid DEFAULT NULL,
  p_actor_system         text DEFAULT 'income_matcher',
  p_context              jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE v_inv public.invoices%ROWTYPE; v_alloc_id uuid;
BEGIN
  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_FOUND'); END IF;
  IF v_inv.invoice_type = 'PRO_FORMA' THEN
    PERFORM public._emit_invoice_transition_failed(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text,'REFUNDED','PRO_FORMA_NOT_PAYABLE', p_actor_user_id, p_actor_system, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','PRO_FORMA_NOT_PAYABLE');
  END IF;
  IF v_inv.lifecycle_status NOT IN ('PAYMENT_EXPECTED','PARTIALLY_PAID','PAID','OVERPAID') THEN
    PERFORM public._emit_invoice_transition_failed(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text,'REFUNDED','ILLEGAL_TRANSITION', p_actor_user_id, p_actor_system, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','ILLEGAL_TRANSITION','current_status', v_inv.lifecycle_status::text);
  END IF;
  IF p_refund_amount IS NULL OR p_refund_amount <= 0 THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','INVALID_AMOUNT');
  END IF;
  v_alloc_id := public._insert_invoice_payment_allocation(
    p_invoice_id, v_inv.organization_id, v_inv.business_id,
    p_refund_transaction_id, p_match_record_id, -p_refund_amount,
    'REFUND'::public.invoice_payment_allocation_kind_enum,
    COALESCE(p_refunded_at, now()), p_actor_user_id, p_actor_system, p_context);
  UPDATE public.invoices SET
    lifecycle_status='REFUNDED', lifecycle_status_changed_at=now(),
    lifecycle_status_changed_by=p_actor_user_id, updated_at=now()
   WHERE id = p_invoice_id;
  PERFORM audit.emit_audit(
    p_actor_kind:=CASE WHEN p_actor_user_id IS NOT NULL THEN 'USER' ELSE 'SYSTEM' END::audit.actor_kind_enum,
    p_action:='INVOICE_MARKED_REFUNDED',
    p_subject_type:='INVOICE'::audit.subject_type_enum, p_subject_id:=p_invoice_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
    p_organization_id:=v_inv.organization_id, p_business_id:=v_inv.business_id,
    p_before_state:=jsonb_build_object('lifecycle_status', v_inv.lifecycle_status::text),
    p_after_state :=jsonb_build_object('lifecycle_status','REFUNDED','refund_amount', p_refund_amount, 'allocation_id', v_alloc_id),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','ALLOW','lifecycle_status','REFUNDED','allocation_id', v_alloc_id);
END;
$function$;

-- 7g. invoice_mark_written_off (user-initiated)
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
  RETURN jsonb_build_object('decision','ALLOW','lifecycle_status','WRITTEN_OFF','written_off_at', v_when);
END;
$function$;

-- 7h. invoice_mark_credited
CREATE OR REPLACE FUNCTION public.invoice_mark_credited(
  p_invoice_id    uuid,
  p_credit_note_id uuid,
  p_credited_at   timestamptz,
  p_actor_user_id uuid DEFAULT NULL,
  p_actor_system  text DEFAULT 'credit_note_issuer',
  p_context       jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE v_inv public.invoices%ROWTYPE;
BEGIN
  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_FOUND'); END IF;
  IF v_inv.invoice_type = 'PRO_FORMA' THEN
    PERFORM public._emit_invoice_transition_failed(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text,'CREDITED','PRO_FORMA_NOT_PAYABLE', p_actor_user_id, p_actor_system, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','PRO_FORMA_NOT_PAYABLE');
  END IF;
  IF v_inv.lifecycle_status NOT IN ('PAYMENT_EXPECTED','PARTIALLY_PAID','OVERPAID','SENT','PAID') THEN
    PERFORM public._emit_invoice_transition_failed(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text,'CREDITED','ILLEGAL_TRANSITION', p_actor_user_id, p_actor_system, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','ILLEGAL_TRANSITION','current_status', v_inv.lifecycle_status::text);
  END IF;
  UPDATE public.invoices SET
    lifecycle_status='CREDITED', lifecycle_status_changed_at=now(),
    lifecycle_status_changed_by=p_actor_user_id, updated_at=now()
   WHERE id = p_invoice_id;
  PERFORM audit.emit_audit(
    p_actor_kind:=CASE WHEN p_actor_user_id IS NOT NULL THEN 'USER' ELSE 'SYSTEM' END::audit.actor_kind_enum,
    p_action:='INVOICE_MARKED_CREDITED',
    p_subject_type:='INVOICE'::audit.subject_type_enum, p_subject_id:=p_invoice_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
    p_organization_id:=v_inv.organization_id, p_business_id:=v_inv.business_id,
    p_before_state:=jsonb_build_object('lifecycle_status', v_inv.lifecycle_status::text),
    p_after_state :=jsonb_build_object('lifecycle_status','CREDITED','credit_note_id', p_credit_note_id, 'credited_at', COALESCE(p_credited_at, now())),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','ALLOW','lifecycle_status','CREDITED');
END;
$function$;

-- 7i. invoice_mark_finalized (Block 15 caller; terminal)
CREATE OR REPLACE FUNCTION public.invoice_mark_finalized(
  p_invoice_id        uuid,
  p_finalized_in_run_id uuid,
  p_finalized_at      timestamptz,
  p_actor_system      text DEFAULT 'finalization_pipeline',
  p_context           jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE v_inv public.invoices%ROWTYPE;
BEGIN
  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_FOUND'); END IF;
  IF v_inv.lifecycle_status = 'FINALIZED' THEN
    PERFORM public._emit_invoice_transition_failed(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text,'FINALIZED','ALREADY_FINALIZED', NULL, p_actor_system, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','ALREADY_FINALIZED');
  END IF;
  IF v_inv.lifecycle_status = 'DRAFT' THEN
    PERFORM public._emit_invoice_transition_failed(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text,'FINALIZED','ILLEGAL_TRANSITION', NULL, p_actor_system, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','ILLEGAL_TRANSITION','current_status','DRAFT');
  END IF;
  UPDATE public.invoices SET
    lifecycle_status='FINALIZED', lifecycle_status_changed_at=now(),
    finalized_in_run_id = p_finalized_in_run_id, finalized_at = COALESCE(p_finalized_at, now()),
    updated_at=now()
   WHERE id = p_invoice_id;
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='INVOICE_FINALIZED',
    p_subject_type:='INVOICE'::audit.subject_type_enum, p_subject_id:=p_invoice_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=p_actor_system,
    p_organization_id:=v_inv.organization_id, p_business_id:=v_inv.business_id,
    p_before_state:=jsonb_build_object('lifecycle_status', v_inv.lifecycle_status::text),
    p_after_state :=jsonb_build_object('lifecycle_status','FINALIZED','finalized_in_run_id', p_finalized_in_run_id),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','ALLOW','lifecycle_status','FINALIZED');
END;
$function$;

-- 7j. invoice_mark_converted_to_tax_invoice (pro-forma → CONVERTED_TO_TAX_INVOICE)
CREATE OR REPLACE FUNCTION public.invoice_mark_converted_to_tax_invoice(
  p_actor_user_id       uuid,
  p_pro_forma_invoice_id uuid,
  p_tax_invoice_id      uuid,
  p_converted_at        timestamptz DEFAULT NULL,
  p_context             jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_inv public.invoices%ROWTYPE;
  v_decision jsonb;
  v_when timestamptz := COALESCE(p_converted_at, now());
BEGIN
  SELECT * INTO v_inv FROM public.invoices WHERE id = p_pro_forma_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_FOUND'); END IF;
  v_decision := public.can_perform(p_actor_user_id,'INVOICE_MANAGE','CONVERT_TO_TAX',
    jsonb_build_object('pro_forma_invoice_id', p_pro_forma_invoice_id, 'tax_invoice_id', p_tax_invoice_id),
    v_inv.business_id, v_inv.organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision', 'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;
  IF v_inv.invoice_type <> 'PRO_FORMA' THEN
    PERFORM public._emit_invoice_transition_failed(p_pro_forma_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text,'CONVERTED_TO_TAX_INVOICE','NOT_PRO_FORMA', p_actor_user_id, NULL, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','NOT_PRO_FORMA');
  END IF;
  IF v_inv.lifecycle_status NOT IN ('DRAFT','SENT') THEN
    PERFORM public._emit_invoice_transition_failed(p_pro_forma_invoice_id, v_inv.organization_id, v_inv.business_id,
      v_inv.lifecycle_status::text,'CONVERTED_TO_TAX_INVOICE','ILLEGAL_TRANSITION', p_actor_user_id, NULL, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','ILLEGAL_TRANSITION','current_status', v_inv.lifecycle_status::text);
  END IF;
  UPDATE public.invoices SET
    lifecycle_status='CONVERTED_TO_TAX_INVOICE', lifecycle_status_changed_at=now(),
    lifecycle_status_changed_by=p_actor_user_id,
    converted_to_tax_invoice_id = p_tax_invoice_id,
    updated_at=now()
   WHERE id = p_pro_forma_invoice_id;
  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='INVOICE_PRO_FORMA_CONVERTED_TO_TAX',
    p_subject_type:='INVOICE'::audit.subject_type_enum, p_subject_id:=p_pro_forma_invoice_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_inv.organization_id, p_business_id:=v_inv.business_id,
    p_before_state:=jsonb_build_object('lifecycle_status', v_inv.lifecycle_status::text),
    p_after_state :=jsonb_build_object('lifecycle_status','CONVERTED_TO_TAX_INVOICE',
                                        'converted_to_tax_invoice_id', p_tax_invoice_id,
                                        'converted_at', v_when),
    p_reason:=NULL, p_request_context:=p_context);
  RETURN jsonb_build_object('decision','ALLOW','lifecycle_status','CONVERTED_TO_TAX_INVOICE','converted_to_tax_invoice_id', p_tax_invoice_id);
END;
$function$;
