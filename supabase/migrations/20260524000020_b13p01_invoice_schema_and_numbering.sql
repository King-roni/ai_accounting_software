-- ============================================================================
-- Block 13 Phase 01 (BOOK-116) — Invoice Schema & Numbering
--
-- Provisions the operational-DB schema for the Invoice Generator:
--   * 4 enums: invoice_type, invoice_lifecycle_status, income_outcome, invoice_sequence_kind
--   * 4 tables: invoices, invoice_lines, credit_notes, invoice_sequence_counters
--   * Cross-block ALTER on match_records: drop document_id NOT NULL,
--     add invoice_id + income_outcome + mutex CHECK
--   * Per-business sequence allocators (INV/PRO/CN) — row-locked, gap-free,
--     idempotent on re-allocation
--   * Void-via-credit-note rule (non-DRAFT delete blocker trigger)
--   * Cumulative-credit-cap concurrency invariant (FOR UPDATE on source invoice)
--   * Gap-detection RPC (called by Block 03 P09 scheduled integrity job)
--   * RLS+FORCE on all 4 tables (per-tenant SELECT; direct writes denied)
--   * Permission matrix seeded for INVOICE_CREATE + CREDIT_NOTE_ISSUE
-- ============================================================================

-- ---- 1. ENUMS -------------------------------------------------------------

CREATE TYPE public.invoice_type_enum AS ENUM ('PRO_FORMA', 'TAX');

CREATE TYPE public.invoice_lifecycle_status_enum AS ENUM (
  'DRAFT',
  'SENT',
  'PAYMENT_EXPECTED',
  'PARTIALLY_PAID',
  'PAID',
  'OVERPAID',
  'REFUNDED',
  'WRITTEN_OFF',
  'CREDITED',
  'CONVERTED_TO_TAX_INVOICE',
  'FINALIZED'
);

CREATE TYPE public.income_outcome_enum AS ENUM (
  'FULL_MATCH',
  'PARTIAL_PAYMENT',
  'OVERPAYMENT',
  'MULTIPLE_INVOICES_ONE_PAYMENT',
  'ONE_INVOICE_MULTIPLE_PAYMENTS',
  'NO_MATCH',
  'POSSIBLE_REFUND_OR_TRANSFER'
);

CREATE TYPE public.invoice_sequence_kind_enum AS ENUM ('INV', 'PRO', 'CN');

-- ---- 2. invoice_sequence_counters ----------------------------------------
-- One row per (business, sequence_kind, year). Atomic allocation via
-- SELECT … FOR UPDATE.

CREATE TABLE public.invoice_sequence_counters (
  business_id     uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,
  sequence_kind   public.invoice_sequence_kind_enum NOT NULL,
  year            int  NOT NULL CHECK (year BETWEEN 2000 AND 2200),
  last_allocated  int  NOT NULL DEFAULT 0 CHECK (last_allocated >= 0 AND last_allocated <= 9999),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (business_id, sequence_kind, year)
);

CREATE INDEX invoice_sequence_counters_business_idx ON public.invoice_sequence_counters(business_id);

-- ---- 3. invoices ----------------------------------------------------------

CREATE TABLE public.invoices (
  id              uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  organization_id uuid NOT NULL,
  business_id     uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE RESTRICT,
  client_id       uuid NOT NULL, -- FK to clients added in Block 13 Phase 02

  invoice_type     public.invoice_type_enum NOT NULL,
  invoice_number   text NULL, -- allocated on first transition out of DRAFT

  issue_date       date NOT NULL,
  supply_date      date NULL,
  due_date         date NOT NULL,

  currency         text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  subtotal_amount  numeric(18,2) NOT NULL DEFAULT 0,
  vat_amount       numeric(18,2) NOT NULL DEFAULT 0,
  total_amount     numeric(18,2) NOT NULL DEFAULT 0,

  vat_treatment_per_line boolean NOT NULL DEFAULT false,
  default_vat_treatment  public.vat_treatment_enum NULL,

  lifecycle_status            public.invoice_lifecycle_status_enum NOT NULL DEFAULT 'DRAFT',
  lifecycle_status_changed_at timestamptz NOT NULL DEFAULT now(),
  lifecycle_status_changed_by uuid NULL,

  converted_from_pro_forma_id uuid NULL REFERENCES public.invoices(id) ON DELETE RESTRICT,
  converted_to_tax_invoice_id uuid NULL REFERENCES public.invoices(id) ON DELETE RESTRICT,

  pdf_storage_object_id uuid NULL,
  pdf_rendered_at       timestamptz NULL,

  finalized_in_run_id uuid NULL REFERENCES public.workflow_runs(id) ON DELETE SET NULL,
  finalized_at        timestamptz NULL,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  -- vat_treatment shape: per-line XOR default
  CONSTRAINT invoices_vat_treatment_shape_chk CHECK (
    (vat_treatment_per_line = false AND default_vat_treatment IS NOT NULL)
    OR (vat_treatment_per_line = true AND default_vat_treatment IS NULL)
  ),
  -- finalized state coherence
  CONSTRAINT invoices_finalized_coherence_chk CHECK (
    (finalized_in_run_id IS NULL) = (finalized_at IS NULL)
  ),
  -- conversion linkage: at most one direction populated
  CONSTRAINT invoices_conversion_one_way_chk CHECK (
    NOT (converted_from_pro_forma_id IS NOT NULL AND converted_to_tax_invoice_id IS NOT NULL)
  ),
  -- conversion type sanity: from_pro_forma only on TAX; to_tax_invoice only on PRO_FORMA
  CONSTRAINT invoices_conversion_type_chk CHECK (
    (converted_from_pro_forma_id IS NULL OR invoice_type = 'TAX')
    AND (converted_to_tax_invoice_id IS NULL OR invoice_type = 'PRO_FORMA')
  ),
  -- pdf coherence
  CONSTRAINT invoices_pdf_coherence_chk CHECK (
    (pdf_storage_object_id IS NULL) = (pdf_rendered_at IS NULL)
  ),
  -- amount sanity
  CONSTRAINT invoices_amounts_nonneg_chk CHECK (
    subtotal_amount >= 0 AND vat_amount >= 0 AND total_amount >= 0
  ),
  -- supply_date defaults to issue_date semantically; if both set, supply >= issue not required by spec
  -- due_date >= issue_date
  CONSTRAINT invoices_dates_chk CHECK (due_date >= issue_date)
);

-- Unique invoice_number per (business, invoice_type) when set
CREATE UNIQUE INDEX invoices_business_type_number_uniq
  ON public.invoices(business_id, invoice_type, invoice_number)
  WHERE invoice_number IS NOT NULL;

CREATE INDEX invoices_business_lifecycle_idx ON public.invoices(business_id, lifecycle_status);
CREATE INDEX invoices_client_idx              ON public.invoices(client_id);
CREATE INDEX invoices_business_issue_date_idx ON public.invoices(business_id, issue_date);
CREATE INDEX invoices_converted_from_idx      ON public.invoices(converted_from_pro_forma_id) WHERE converted_from_pro_forma_id IS NOT NULL;
CREATE INDEX invoices_converted_to_idx        ON public.invoices(converted_to_tax_invoice_id) WHERE converted_to_tax_invoice_id IS NOT NULL;
CREATE INDEX invoices_finalized_run_idx       ON public.invoices(finalized_in_run_id) WHERE finalized_in_run_id IS NOT NULL;

-- ---- 4. invoice_lines -----------------------------------------------------

CREATE TABLE public.invoice_lines (
  id              uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  organization_id uuid NOT NULL,
  business_id     uuid NOT NULL,
  invoice_id      uuid NOT NULL REFERENCES public.invoices(id) ON DELETE CASCADE,
  line_number     int  NOT NULL CHECK (line_number >= 1),
  description     text NOT NULL,
  quantity        numeric(18,4) NOT NULL,
  unit_price      numeric(18,4) NOT NULL,
  currency        text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  subtotal_amount numeric(18,2) NOT NULL,
  vat_treatment   public.vat_treatment_enum NULL,
  vat_rate_pct    numeric(6,3) NULL CHECK (vat_rate_pct IS NULL OR (vat_rate_pct >= 0 AND vat_rate_pct <= 100)),
  vat_amount      numeric(18,2) NULL,
  total_amount    numeric(18,2) NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX invoice_lines_invoice_line_uniq ON public.invoice_lines(invoice_id, line_number);
CREATE INDEX invoice_lines_business_idx             ON public.invoice_lines(business_id);

-- ---- 5. credit_notes ------------------------------------------------------

CREATE TABLE public.credit_notes (
  id                 uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  organization_id    uuid NOT NULL,
  business_id        uuid NOT NULL,
  credit_note_number text NULL, -- allocated on issuance
  against_invoice_id uuid NOT NULL REFERENCES public.invoices(id) ON DELETE RESTRICT,
  issue_date         date NOT NULL,
  currency           text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  amount             numeric(18,2) NOT NULL CHECK (amount > 0),
  reason             text NOT NULL CHECK (length(trim(reason)) > 0 AND length(reason) <= 4000),
  issued_by          uuid NULL,
  pdf_storage_object_id uuid NULL,
  pdf_rendered_at       timestamptz NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT credit_notes_pdf_coherence_chk CHECK (
    (pdf_storage_object_id IS NULL) = (pdf_rendered_at IS NULL)
  )
);

CREATE UNIQUE INDEX credit_notes_business_number_uniq
  ON public.credit_notes(business_id, credit_note_number)
  WHERE credit_note_number IS NOT NULL;
CREATE INDEX credit_notes_against_invoice_idx ON public.credit_notes(against_invoice_id);
CREATE INDEX credit_notes_business_idx        ON public.credit_notes(business_id);
CREATE INDEX credit_notes_issued_by_idx       ON public.credit_notes(issued_by) WHERE issued_by IS NOT NULL;

-- ---- 6. CROSS-BLOCK: match_records additions ------------------------------
-- Block 04 Phase 03 owns the table; Block 13 Phase 01 spec declares these as
-- the IN-side additions. Until applied, IN-side matching cannot persist.

ALTER TABLE public.match_records ALTER COLUMN document_id DROP NOT NULL;

ALTER TABLE public.match_records
  ADD COLUMN invoice_id uuid NULL REFERENCES public.invoices(id) ON DELETE RESTRICT,
  ADD COLUMN income_outcome public.income_outcome_enum NULL;

-- Exactly one of document_id / invoice_id non-null per row.
ALTER TABLE public.match_records
  ADD CONSTRAINT match_records_doc_xor_invoice_chk
    CHECK ((document_id IS NULL) <> (invoice_id IS NULL));

CREATE INDEX match_records_invoice_idx ON public.match_records(invoice_id) WHERE invoice_id IS NOT NULL;

-- ---- 7. RLS ---------------------------------------------------------------

ALTER TABLE public.invoices                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoices                  FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.invoice_lines             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_lines             FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.credit_notes              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_notes              FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.invoice_sequence_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_sequence_counters FORCE  ROW LEVEL SECURITY;

-- Per-tenant SELECT
CREATE POLICY invoices_select_tenant ON public.invoices
  FOR SELECT TO authenticated
  USING (business_id = ANY (public.current_user_businesses()));

CREATE POLICY invoice_lines_select_tenant ON public.invoice_lines
  FOR SELECT TO authenticated
  USING (business_id = ANY (public.current_user_businesses()));

CREATE POLICY credit_notes_select_tenant ON public.credit_notes
  FOR SELECT TO authenticated
  USING (business_id = ANY (public.current_user_businesses()));

CREATE POLICY invoice_sequence_counters_select_tenant ON public.invoice_sequence_counters
  FOR SELECT TO authenticated
  USING (business_id = ANY (public.current_user_businesses()));

-- Deny direct writes (SECURITY DEFINER RPCs are the only writers)
CREATE POLICY invoices_deny_insert ON public.invoices FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY invoices_deny_update ON public.invoices FOR UPDATE TO authenticated USING (false);
CREATE POLICY invoices_deny_delete ON public.invoices FOR DELETE TO authenticated USING (false);

CREATE POLICY invoice_lines_deny_insert ON public.invoice_lines FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY invoice_lines_deny_update ON public.invoice_lines FOR UPDATE TO authenticated USING (false);
CREATE POLICY invoice_lines_deny_delete ON public.invoice_lines FOR DELETE TO authenticated USING (false);

CREATE POLICY credit_notes_deny_insert ON public.credit_notes FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY credit_notes_deny_update ON public.credit_notes FOR UPDATE TO authenticated USING (false);
CREATE POLICY credit_notes_deny_delete ON public.credit_notes FOR DELETE TO authenticated USING (false);

CREATE POLICY invoice_sequence_counters_deny_insert ON public.invoice_sequence_counters FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY invoice_sequence_counters_deny_update ON public.invoice_sequence_counters FOR UPDATE TO authenticated USING (false);
CREATE POLICY invoice_sequence_counters_deny_delete ON public.invoice_sequence_counters FOR DELETE TO authenticated USING (false);

-- ---- 8. PERMISSION MATRIX SEED -------------------------------------------

INSERT INTO public.permission_matrix (role, surface, decision) VALUES
  ('OWNER',      'INVOICE_CREATE',     'ALLOW'),
  ('ADMIN',      'INVOICE_CREATE',     'ALLOW'),
  ('BOOKKEEPER', 'INVOICE_CREATE',     'ALLOW'),
  ('ACCOUNTANT', 'INVOICE_CREATE',     'DENY'),
  ('REVIEWER',   'INVOICE_CREATE',     'DENY'),
  ('READ_ONLY',  'INVOICE_CREATE',     'DENY'),
  ('OWNER',      'CREDIT_NOTE_ISSUE',  'ALLOW'),
  ('ADMIN',      'CREDIT_NOTE_ISSUE',  'ALLOW'),
  ('BOOKKEEPER', 'CREDIT_NOTE_ISSUE',  'ALLOW'),
  ('ACCOUNTANT', 'CREDIT_NOTE_ISSUE',  'DENY'),
  ('REVIEWER',   'CREDIT_NOTE_ISSUE',  'DENY'),
  ('READ_ONLY',  'CREDIT_NOTE_ISSUE',  'DENY')
ON CONFLICT (role, surface) DO NOTHING;

-- ---- 9. Non-DRAFT delete blocker -----------------------------------------

CREATE OR REPLACE FUNCTION public.fn_block_invoice_delete_non_draft()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.lifecycle_status <> 'DRAFT' THEN
    RAISE EXCEPTION 'Cannot delete invoice id=% in lifecycle_status=% (only DRAFT may be deleted; void via credit note)',
      OLD.id, OLD.lifecycle_status
      USING ERRCODE = 'P0001';
  END IF;
  RETURN OLD;
END;
$function$;

CREATE TRIGGER trg_block_invoice_delete_non_draft
  BEFORE DELETE ON public.invoices
  FOR EACH ROW EXECUTE FUNCTION public.fn_block_invoice_delete_non_draft();

-- ---- 10. RPC: invoice_create_draft ---------------------------------------
-- Creates a DRAFT invoice with its lines. Does NOT allocate a number.
-- Permission gated via can_perform('INVOICE_CREATE'); Mitigation A on DENY
-- (return jsonb envelope, no audit-then-raise).

CREATE OR REPLACE FUNCTION public.invoice_create_draft(
  p_organization_id  uuid,
  p_business_id      uuid,
  p_actor_user_id    uuid,
  p_client_id        uuid,
  p_invoice_type     public.invoice_type_enum,
  p_issue_date       date,
  p_supply_date      date,
  p_due_date         date,
  p_currency         text,
  p_vat_treatment_per_line boolean,
  p_default_vat_treatment  public.vat_treatment_enum,
  p_lines            jsonb,
  p_context          jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_decision   jsonb;
  v_invoice_id uuid := gen_uuid_v7();
  v_line       jsonb;
  v_line_no    int := 0;
  v_subtotal   numeric(18,2) := 0;
  v_vat_total  numeric(18,2) := 0;
  v_total      numeric(18,2) := 0;
  v_line_sub   numeric(18,2);
  v_line_vat   numeric(18,2);
  v_line_tot   numeric(18,2);
BEGIN
  v_decision := public.can_perform(
    p_actor_user_id := p_actor_user_id,
    p_surface       := 'INVOICE_CREATE',
    p_action        := 'CREATE_DRAFT',
    p_resource      := jsonb_build_object('invoice_type', p_invoice_type::text),
    p_business_id   := p_business_id,
    p_organization_id := p_organization_id
  );

  IF (v_decision->>'decision') <> 'ALLOW' THEN
    -- Mitigation A: envelope return, no audit-then-raise.
    RETURN jsonb_build_object(
      'decision', v_decision->>'decision',
      'reason_code', COALESCE(v_decision->>'reason_code', 'PERMISSION_DENIED'),
      'invoice_id', NULL
    );
  END IF;

  -- Shape validation
  IF p_vat_treatment_per_line = false AND p_default_vat_treatment IS NULL THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','MISSING_DEFAULT_VAT_TREATMENT','invoice_id', NULL);
  END IF;
  IF p_vat_treatment_per_line = true AND p_default_vat_treatment IS NOT NULL THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','DEFAULT_VAT_NOT_ALLOWED_WHEN_PER_LINE','invoice_id', NULL);
  END IF;
  IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','LINES_REQUIRED','invoice_id', NULL);
  END IF;

  -- Lines: validate currency match + accumulate totals
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    IF (v_line->>'currency') <> p_currency THEN
      RETURN jsonb_build_object('decision','DENY','reason_code','LINE_CURRENCY_MISMATCH','invoice_id', NULL);
    END IF;
    v_line_sub := ((v_line->>'quantity')::numeric * (v_line->>'unit_price')::numeric)::numeric(18,2);
    v_line_vat := COALESCE(NULLIF(v_line->>'vat_amount','')::numeric, 0)::numeric(18,2);
    v_line_tot := (v_line_sub + v_line_vat)::numeric(18,2);
    v_subtotal := v_subtotal + v_line_sub;
    v_vat_total := v_vat_total + v_line_vat;
    v_total := v_total + v_line_tot;
  END LOOP;

  -- Insert invoice
  INSERT INTO public.invoices (
    id, organization_id, business_id, client_id,
    invoice_type, invoice_number,
    issue_date, supply_date, due_date,
    currency, subtotal_amount, vat_amount, total_amount,
    vat_treatment_per_line, default_vat_treatment,
    lifecycle_status, lifecycle_status_changed_at, lifecycle_status_changed_by
  ) VALUES (
    v_invoice_id, p_organization_id, p_business_id, p_client_id,
    p_invoice_type, NULL,
    p_issue_date, p_supply_date, p_due_date,
    p_currency, v_subtotal, v_vat_total, v_total,
    p_vat_treatment_per_line, p_default_vat_treatment,
    'DRAFT', now(), p_actor_user_id
  );

  -- Insert lines
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_line_no := v_line_no + 1;
    v_line_sub := ((v_line->>'quantity')::numeric * (v_line->>'unit_price')::numeric)::numeric(18,2);
    v_line_vat := COALESCE(NULLIF(v_line->>'vat_amount','')::numeric, 0)::numeric(18,2);
    v_line_tot := (v_line_sub + v_line_vat)::numeric(18,2);
    INSERT INTO public.invoice_lines (
      organization_id, business_id, invoice_id, line_number,
      description, quantity, unit_price, currency,
      subtotal_amount, vat_treatment, vat_rate_pct, vat_amount, total_amount
    ) VALUES (
      p_organization_id, p_business_id, v_invoice_id, v_line_no,
      v_line->>'description',
      (v_line->>'quantity')::numeric,
      (v_line->>'unit_price')::numeric,
      v_line->>'currency',
      v_line_sub,
      NULLIF(v_line->>'vat_treatment','')::public.vat_treatment_enum,
      NULLIF(v_line->>'vat_rate_pct','')::numeric,
      NULLIF(v_line->>'vat_amount','')::numeric,
      v_line_tot
    );
  END LOOP;

  PERFORM audit.emit_audit(
    p_actor_kind      := 'USER'::audit.actor_kind_enum,
    p_action          := 'INVOICE_CREATED',
    p_subject_type    := 'INVOICE'::audit.subject_type_enum,
    p_subject_id      := v_invoice_id,
    p_actor_user_id   := p_actor_user_id,
    p_actor_role      := NULL,
    p_actor_session_id:= NULL,
    p_actor_system    := NULL,
    p_organization_id := p_organization_id,
    p_business_id     := p_business_id,
    p_before_state    := NULL,
    p_after_state     := jsonb_build_object(
      'invoice_id', v_invoice_id,
      'invoice_type', p_invoice_type::text,
      'lifecycle_status', 'DRAFT',
      'subtotal_amount', v_subtotal,
      'vat_amount', v_vat_total,
      'total_amount', v_total,
      'line_count', v_line_no
    ),
    p_reason          := NULL,
    p_request_context := p_context
  );

  RETURN jsonb_build_object(
    'decision', 'ALLOW',
    'invoice_id', v_invoice_id,
    'invoice_number', NULL,
    'lifecycle_status', 'DRAFT'
  );
END;
$function$;

-- ---- 11. RPC: allocate_invoice_number ------------------------------------
-- Idempotent. Locks the sequence_counters row FOR UPDATE, increments, formats.
-- Returns existing number if already allocated (no fresh consume, no audit re-emit).

CREATE OR REPLACE FUNCTION public.allocate_invoice_number(
  p_invoice_id uuid,
  p_context    jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_invoice       public.invoices%ROWTYPE;
  v_seq_kind      public.invoice_sequence_kind_enum;
  v_year          int;
  v_prefix        text;
  v_next          int;
  v_number        text;
BEGIN
  SELECT * INTO v_invoice FROM public.invoices WHERE id = p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invoice not found: %', p_invoice_id USING ERRCODE='P0002';
  END IF;

  -- Idempotency: if already allocated, return the existing number, no side effects.
  IF v_invoice.invoice_number IS NOT NULL THEN
    RETURN jsonb_build_object(
      'allocated', false,
      'invoice_id', v_invoice.id,
      'invoice_number', v_invoice.invoice_number,
      'reason_code', 'ALREADY_ALLOCATED'
    );
  END IF;

  v_seq_kind := CASE v_invoice.invoice_type
                  WHEN 'TAX'       THEN 'INV'::public.invoice_sequence_kind_enum
                  WHEN 'PRO_FORMA' THEN 'PRO'::public.invoice_sequence_kind_enum
                END;
  v_year   := EXTRACT(YEAR FROM v_invoice.issue_date)::int;
  v_prefix := v_seq_kind::text;

  -- Atomic counter bump under row-lock.
  INSERT INTO public.invoice_sequence_counters (business_id, sequence_kind, year, last_allocated)
    VALUES (v_invoice.business_id, v_seq_kind, v_year, 0)
    ON CONFLICT (business_id, sequence_kind, year) DO NOTHING;

  UPDATE public.invoice_sequence_counters
     SET last_allocated = last_allocated + 1,
         updated_at = now()
   WHERE business_id = v_invoice.business_id
     AND sequence_kind = v_seq_kind
     AND year = v_year
   RETURNING last_allocated INTO v_next;

  IF v_next > 9999 THEN
    RAISE EXCEPTION 'Sequence exhausted for (%, %, %)', v_invoice.business_id, v_seq_kind, v_year
      USING ERRCODE='P0001';
  END IF;

  v_number := format('%s-%s-%s', v_prefix, v_year::text, lpad(v_next::text, 4, '0'));

  UPDATE public.invoices
     SET invoice_number = v_number,
         updated_at = now()
   WHERE id = v_invoice.id;

  PERFORM audit.emit_audit(
    p_actor_kind      := 'SYSTEM'::audit.actor_kind_enum,
    p_action          := 'INVOICE_NUMBER_ALLOCATED',
    p_subject_type    := 'INVOICE'::audit.subject_type_enum,
    p_subject_id      := v_invoice.id,
    p_actor_user_id   := NULL,
    p_actor_role      := NULL,
    p_actor_session_id:= NULL,
    p_actor_system    := 'invoice_numbering',
    p_organization_id := v_invoice.organization_id,
    p_business_id     := v_invoice.business_id,
    p_before_state    := jsonb_build_object('invoice_number', NULL),
    p_after_state     := jsonb_build_object(
      'invoice_number', v_number,
      'sequence_kind',  v_seq_kind::text,
      'year',           v_year,
      'allocated_number', v_next
    ),
    p_reason          := NULL,
    p_request_context := p_context
  );

  RETURN jsonb_build_object(
    'allocated', true,
    'invoice_id', v_invoice.id,
    'invoice_number', v_number,
    'sequence_kind', v_seq_kind::text,
    'year', v_year,
    'allocated_number', v_next
  );
END;
$function$;

-- ---- 12. RPC: credit_note_issue ------------------------------------------
-- Permission-gated. Locks source invoice FOR UPDATE, validates type=TAX,
-- enforces cumulative-credit-cap, allocates CN-YYYY-NNNN, inserts row.

CREATE OR REPLACE FUNCTION public.credit_note_issue(
  p_organization_id  uuid,
  p_business_id      uuid,
  p_actor_user_id    uuid,
  p_against_invoice_id uuid,
  p_amount           numeric,
  p_reason           text,
  p_issue_date       date,
  p_context          jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_decision      jsonb;
  v_source        public.invoices%ROWTYPE;
  v_prior_sum     numeric(18,2);
  v_year          int;
  v_next          int;
  v_number        text;
  v_credit_note_id uuid := gen_uuid_v7();
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

  -- Lock the source invoice row; concurrent issuers serialize here.
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

  -- Cumulative-credit-cap
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

  -- Allocate CN-YYYY-NNNN
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
      'new_cumulative_sum', (v_prior_sum + p_amount)
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

  RETURN jsonb_build_object(
    'decision', 'ALLOW',
    'credit_note_id', v_credit_note_id,
    'credit_note_number', v_number,
    'amount', p_amount,
    'new_cumulative_sum', (v_prior_sum + p_amount)
  );
END;
$function$;

-- ---- 13. RPC: detect_invoice_number_gaps ---------------------------------
-- Scheduled by Block 03 P09's integrity-job runner; takes p_workflow_run_id
-- because review_issues.workflow_run_id is NOT NULL. For each gap, inserts
-- a HIGH-severity review_issue under POSSIBLE_WRONG_MATCH and emits one
-- INVOICE_NUMBER_GAP_DETECTED audit event per gap.

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
  v_last_allocated  int;
  v_prefix          text;
  v_gap_number      int;
  v_missing_label   text;
  v_gaps            int[] := '{}';
  v_review_issue_id uuid;
  v_table_label     text;
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

  v_prefix := p_sequence_kind::text;
  v_table_label := CASE p_sequence_kind WHEN 'CN' THEN 'credit_notes' ELSE 'invoices' END;

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
    INSERT INTO public.review_issues (
      organization_id, business_id, workflow_run_id,
      issue_type, issue_group, severity,
      plain_language_title, plain_language_description, recommended_action,
      card_payload_json
    ) VALUES (
      p_organization_id, p_business_id, p_workflow_run_id,
      'invoice_numbering.gap_detected',
      'POSSIBLE_WRONG_MATCH'::public.review_issue_group_enum,
      'HIGH'::public.review_issue_severity_enum,
      format('Missing %s number %s', v_prefix, v_missing_label),
      format('The %s sequence for business shows that number %s was allocated but no corresponding row exists in %s. This may indicate a deleted or skipped issuance and should be investigated.',
        v_prefix, v_missing_label, v_table_label),
      'Investigate the gap and either restore the missing record or document the cause.',
      jsonb_build_object(
        'sequence_kind', v_prefix,
        'year', p_year,
        'missing_number', v_gap_number,
        'missing_label', v_missing_label
      )
    ) RETURNING id INTO v_review_issue_id;

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
        'review_issue_id', v_review_issue_id
      ),
      p_reason          := NULL,
      p_request_context := p_context
    );
  END LOOP;

  RETURN jsonb_build_object(
    'decision', 'RAN',
    'gaps_detected', array_length(v_gaps, 1),
    'missing_numbers', to_jsonb(v_gaps)
  );
END;
$function$;

-- ---- 14. COMMENTS --------------------------------------------------------

COMMENT ON TABLE public.invoices IS
  'Block 13 P01 — canonical invoice record. Pro-forma (PRO-YYYY-NNNN) and tax (INV-YYYY-NNNN) share this table, discriminated by invoice_type. Lifecycle owns DRAFT through FINALIZED. Numbers allocated atomically once at first transition out of DRAFT.';
COMMENT ON COLUMN public.invoices.client_id IS
  'FK to public.clients added in Block 13 P02 (currently a free uuid column).';
COMMENT ON TABLE public.invoice_lines IS
  'Block 13 P01 — line items composing an invoice. Per-line VAT treatment active only when invoices.vat_treatment_per_line = true.';
COMMENT ON TABLE public.credit_notes IS
  'Block 13 P01 — credit notes issued against a TAX invoice. Cumulative cap enforced by credit_note_issue RPC under row-lock on source invoice.';
COMMENT ON TABLE public.invoice_sequence_counters IS
  'Block 13 P01 — per-business, per-kind, per-year sequence counters. Atomic allocation via SELECT … FOR UPDATE inside allocate_invoice_number / credit_note_issue.';
COMMENT ON CONSTRAINT match_records_doc_xor_invoice_chk ON public.match_records IS
  'Block 13 P01 — exactly one of document_id (OUT-side) or invoice_id (IN-side) per row.';
