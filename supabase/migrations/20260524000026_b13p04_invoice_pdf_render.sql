-- ============================================================================
-- Block 13 Phase 04 (BOOK-119) — PDF Rendering & VAT-Aware Text
--
-- DB owns: validation contract, structured payload assembly, idempotency hashing,
-- audit wiring. App-layer owns: actual PDF byte rendering + storage to the
-- raw-uploads bucket.
-- ============================================================================

-- ---- 1. render_kind enum + render-register tables ----------------------

CREATE TYPE public.invoice_render_kind_enum AS ENUM ('DRAFT_PREVIEW', 'FINAL');

CREATE TABLE public.invoice_pdf_renders (
  id                    uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  organization_id       uuid NOT NULL,
  business_id           uuid NOT NULL,
  invoice_id            uuid NOT NULL REFERENCES public.invoices(id) ON DELETE CASCADE,
  render_kind           public.invoice_render_kind_enum NOT NULL,
  render_hash           text NOT NULL CHECK (render_hash ~ '^[0-9a-f]{64}$'),
  language_code         text NOT NULL DEFAULT 'en' CHECK (language_code ~ '^[a-z]{2}$'),
  renderer_version      text NOT NULL CHECK (length(renderer_version) BETWEEN 1 AND 64),
  pdf_storage_object_id uuid NULL,
  rendered_at           timestamptz NOT NULL DEFAULT now(),
  rendered_by           uuid NULL,
  rendered_by_system    text NULL,

  CONSTRAINT ipr_final_requires_object_id_chk CHECK (
    render_kind <> 'FINAL' OR pdf_storage_object_id IS NOT NULL
  ),
  CONSTRAINT ipr_actor_chk CHECK (
    (rendered_by IS NOT NULL AND rendered_by_system IS NULL)
    OR (rendered_by IS NULL AND rendered_by_system IS NOT NULL)
  )
);

CREATE UNIQUE INDEX ipr_dedup_uniq
  ON public.invoice_pdf_renders(invoice_id, render_kind, render_hash, language_code, renderer_version);
CREATE INDEX ipr_invoice_kind_idx     ON public.invoice_pdf_renders(invoice_id, render_kind);
CREATE INDEX ipr_business_idx          ON public.invoice_pdf_renders(business_id);

CREATE TABLE public.credit_note_pdf_renders (
  id                    uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  organization_id       uuid NOT NULL,
  business_id           uuid NOT NULL,
  credit_note_id        uuid NOT NULL REFERENCES public.credit_notes(id) ON DELETE CASCADE,
  render_hash           text NOT NULL CHECK (render_hash ~ '^[0-9a-f]{64}$'),
  language_code         text NOT NULL DEFAULT 'en' CHECK (language_code ~ '^[a-z]{2}$'),
  renderer_version      text NOT NULL CHECK (length(renderer_version) BETWEEN 1 AND 64),
  pdf_storage_object_id uuid NOT NULL,
  rendered_at           timestamptz NOT NULL DEFAULT now(),
  rendered_by           uuid NULL,
  rendered_by_system    text NULL,

  CONSTRAINT cnpr_actor_chk CHECK (
    (rendered_by IS NOT NULL AND rendered_by_system IS NULL)
    OR (rendered_by IS NULL AND rendered_by_system IS NOT NULL)
  )
);
CREATE UNIQUE INDEX cnpr_dedup_uniq
  ON public.credit_note_pdf_renders(credit_note_id, render_hash, language_code, renderer_version);
CREATE INDEX cnpr_credit_note_idx ON public.credit_note_pdf_renders(credit_note_id);
CREATE INDEX cnpr_business_idx     ON public.credit_note_pdf_renders(business_id);

ALTER TABLE public.invoice_pdf_renders     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_pdf_renders     FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.credit_note_pdf_renders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_note_pdf_renders FORCE  ROW LEVEL SECURITY;

CREATE POLICY ipr_select_tenant ON public.invoice_pdf_renders
  FOR SELECT TO authenticated USING (business_id = ANY (public.current_user_businesses()));
CREATE POLICY ipr_deny_insert ON public.invoice_pdf_renders FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY ipr_deny_update ON public.invoice_pdf_renders FOR UPDATE TO authenticated USING (false);
CREATE POLICY ipr_deny_delete ON public.invoice_pdf_renders FOR DELETE TO authenticated USING (false);

CREATE POLICY cnpr_select_tenant ON public.credit_note_pdf_renders
  FOR SELECT TO authenticated USING (business_id = ANY (public.current_user_businesses()));
CREATE POLICY cnpr_deny_insert ON public.credit_note_pdf_renders FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY cnpr_deny_update ON public.credit_note_pdf_renders FOR UPDATE TO authenticated USING (false);
CREATE POLICY cnpr_deny_delete ON public.credit_note_pdf_renders FOR DELETE TO authenticated USING (false);

COMMENT ON TABLE public.invoice_pdf_renders IS
  'Block 13 P04 — content-addressable register of rendered invoice PDFs. Idempotency via UNIQUE(invoice_id, render_kind, render_hash, language_code, renderer_version).';
COMMENT ON TABLE public.credit_note_pdf_renders IS
  'Block 13 P04 — content-addressable register of rendered credit-note PDFs.';

-- ---- 2. Cross-block invariant: IMPORT_OR_ACQUISITION is OUT-side only ---

ALTER TABLE public.invoices
  ADD CONSTRAINT invoices_default_vat_treatment_not_acquisition_chk
  CHECK (default_vat_treatment IS NULL OR default_vat_treatment <> 'IMPORT_OR_ACQUISITION');

ALTER TABLE public.invoice_lines
  ADD CONSTRAINT invoice_lines_vat_treatment_not_acquisition_chk
  CHECK (vat_treatment IS NULL OR vat_treatment <> 'IMPORT_OR_ACQUISITION');

COMMENT ON CONSTRAINT invoices_default_vat_treatment_not_acquisition_chk ON public.invoices IS
  'Block 13 P04 — IMPORT_OR_ACQUISITION is OUT-side reverse-charge accounting; no legitimate use on issued invoices.';

-- ---- 3. VAT-aware text helper ------------------------------------------

CREATE OR REPLACE FUNCTION public.invoice_vat_aware_text(
  p_vat_treatment       public.vat_treatment_enum,
  p_language_code       text,
  p_customer_vat_number text
) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $function$
DECLARE v_lang text := COALESCE(p_language_code, 'en');
BEGIN
  IF v_lang <> 'en' THEN v_lang := 'en'; END IF;
  CASE p_vat_treatment
    WHEN 'DOMESTIC_CYPRUS_VAT'   THEN RETURN jsonb_build_object('disclosure_text', NULL, 'requires_customer_vat_display', false);
    WHEN 'DOMESTIC_STANDARD'     THEN RETURN jsonb_build_object('disclosure_text', NULL, 'requires_customer_vat_display', false);
    WHEN 'DOMESTIC_REDUCED'      THEN RETURN jsonb_build_object('disclosure_text', NULL, 'requires_customer_vat_display', false);
    WHEN 'DOMESTIC_ZERO'         THEN RETURN jsonb_build_object('disclosure_text', 'Zero-rated supply.', 'requires_customer_vat_display', false);
    WHEN 'EU_REVERSE_CHARGE'     THEN RETURN jsonb_build_object(
      'disclosure_text', 'Reverse charge — Article 196 of Council Directive 2006/112/EC. The customer is liable for VAT.',
      'requires_customer_vat_display', true);
    WHEN 'NON_EU_SERVICE'        THEN RETURN jsonb_build_object(
      'disclosure_text', 'Outside the scope of Cyprus VAT — supply of services to a non-EU customer.',
      'requires_customer_vat_display', false);
    WHEN 'EXEMPT'                THEN RETURN jsonb_build_object(
      'disclosure_text', 'VAT exempt — [category reference].',
      'requires_customer_vat_display', false);
    WHEN 'NO_VAT'                THEN RETURN jsonb_build_object(
      'disclosure_text', 'No VAT charged.',
      'requires_customer_vat_display', false);
    WHEN 'OUTSIDE_SCOPE'         THEN RETURN jsonb_build_object(
      'disclosure_text', 'Outside the scope of Cyprus VAT.',
      'requires_customer_vat_display', false);
    ELSE RETURN jsonb_build_object('disclosure_text', NULL, 'requires_customer_vat_display', false);
  END CASE;
END;
$function$;

-- ---- 4. Internal helper: emit-render-rejected --------------------------

CREATE OR REPLACE FUNCTION public._emit_invoice_pdf_render_rejected(
  p_invoice_id      uuid,
  p_organization_id uuid,
  p_business_id     uuid,
  p_action          text,
  p_reason_code     text,
  p_actor_user_id   uuid,
  p_context         jsonb
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
BEGIN
  PERFORM audit.emit_audit(
    p_actor_kind      := CASE WHEN p_actor_user_id IS NOT NULL THEN 'USER' ELSE 'SYSTEM' END::audit.actor_kind_enum,
    p_action          := p_action,
    p_subject_type    := 'INVOICE'::audit.subject_type_enum,
    p_subject_id      := p_invoice_id,
    p_actor_user_id   := p_actor_user_id,
    p_actor_role      := NULL,
    p_actor_session_id:= NULL,
    p_actor_system    := CASE WHEN p_actor_user_id IS NULL THEN 'invoice_pdf_renderer' ELSE NULL END,
    p_organization_id := p_organization_id,
    p_business_id     := p_business_id,
    p_before_state    := NULL,
    p_after_state     := jsonb_build_object('reason_code', p_reason_code),
    p_reason          := p_reason_code,
    p_request_context := p_context
  );
END;
$function$;

-- ---- 5. RPC: invoice_compute_pdf_render_payload -------------------------

CREATE OR REPLACE FUNCTION public.invoice_compute_pdf_render_payload(
  p_actor_user_id   uuid,
  p_invoice_id      uuid,
  p_render_kind     public.invoice_render_kind_enum,
  p_language_code   text,
  p_renderer_version text,
  p_context         jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_inv      public.invoices%ROWTYPE;
  v_client   public.clients%ROWTYPE;
  v_decision jsonb;
  v_lines    jsonb;
  v_line_count int;
  v_per_rate jsonb;
  v_header   jsonb;
  v_bill_to  jsonb;
  v_totals   jsonb;
  v_vat_text jsonb;
  v_payload  jsonb;
  v_hash     text;
  v_existing public.invoice_pdf_renders%ROWTYPE;
BEGIN
  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_FOUND');
  END IF;
  v_decision := public.can_perform(p_actor_user_id, 'INVOICE_MANAGE', 'RENDER_PDF',
    jsonb_build_object('invoice_id', p_invoice_id), v_inv.business_id, v_inv.organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision',
      'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;

  IF p_render_kind = 'DRAFT_PREVIEW' AND v_inv.lifecycle_status <> 'DRAFT' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','DRAFT_PREVIEW_REQUIRES_DRAFT');
  END IF;
  IF p_render_kind = 'FINAL' AND v_inv.lifecycle_status = 'DRAFT' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','FINAL_REQUIRES_NON_DRAFT');
  END IF;

  SELECT count(*) INTO v_line_count FROM public.invoice_lines WHERE invoice_id = p_invoice_id;
  IF p_render_kind = 'FINAL' AND v_line_count = 0 THEN
    PERFORM public._emit_invoice_pdf_render_rejected(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      'INVOICE_PDF_RENDER_REJECTED_NO_LINES','NO_LINES', p_actor_user_id, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','NO_LINES');
  END IF;

  IF p_render_kind = 'FINAL' AND v_inv.vat_treatment_per_line = false
     AND v_inv.default_vat_treatment = 'UNKNOWN' THEN
    PERFORM public._emit_invoice_pdf_render_rejected(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      'INVOICE_PDF_RENDER_REJECTED_UNKNOWN_VAT_TREATMENT','UNKNOWN_VAT_TREATMENT', p_actor_user_id, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','UNKNOWN_VAT_TREATMENT');
  END IF;
  IF v_inv.default_vat_treatment = 'IMPORT_OR_ACQUISITION' THEN
    PERFORM public._emit_invoice_pdf_render_rejected(p_invoice_id, v_inv.organization_id, v_inv.business_id,
      'INVOICE_PDF_RENDER_REJECTED_INAPPLICABLE_VAT_TREATMENT','INAPPLICABLE_VAT_TREATMENT', p_actor_user_id, p_context);
    RETURN jsonb_build_object('decision','DENY','reason_code','INAPPLICABLE_VAT_TREATMENT');
  END IF;
  IF p_render_kind = 'FINAL' AND v_inv.vat_treatment_per_line = true THEN
    PERFORM 1 FROM public.invoice_lines
     WHERE invoice_id = p_invoice_id AND vat_treatment = 'UNKNOWN';
    IF FOUND THEN
      PERFORM public._emit_invoice_pdf_render_rejected(p_invoice_id, v_inv.organization_id, v_inv.business_id,
        'INVOICE_PDF_RENDER_REJECTED_UNKNOWN_VAT_TREATMENT','UNKNOWN_VAT_TREATMENT_ON_LINE', p_actor_user_id, p_context);
      RETURN jsonb_build_object('decision','DENY','reason_code','UNKNOWN_VAT_TREATMENT_ON_LINE');
    END IF;
  END IF;

  SELECT * INTO v_client FROM public.clients WHERE id = v_inv.client_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'line_number', il.line_number,
    'description', il.description,
    'quantity',    il.quantity,
    'unit_price',  il.unit_price,
    'subtotal_amount', il.subtotal_amount,
    'vat_treatment', il.vat_treatment::text,
    'vat_rate_pct',  il.vat_rate_pct,
    'vat_amount',    il.vat_amount,
    'total_amount',  il.total_amount
  ) ORDER BY il.line_number), '[]'::jsonb) INTO v_lines
  FROM public.invoice_lines il WHERE il.invoice_id = p_invoice_id;

  IF v_inv.vat_treatment_per_line THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'vat_rate_pct', rate,
      'subtotal',     sub,
      'vat_amount',   vat
    ) ORDER BY rate), '[]'::jsonb)
    INTO v_per_rate
    FROM (
      SELECT COALESCE(vat_rate_pct, 0) AS rate,
             SUM(subtotal_amount)::numeric(18,2) AS sub,
             SUM(COALESCE(vat_amount,0))::numeric(18,2) AS vat
        FROM public.invoice_lines
       WHERE invoice_id = p_invoice_id
       GROUP BY COALESCE(vat_rate_pct, 0)
    ) g;
  ELSE
    v_per_rate := '[]'::jsonb;
  END IF;

  v_vat_text := public.invoice_vat_aware_text(
    COALESCE(v_inv.default_vat_treatment, 'UNKNOWN'::public.vat_treatment_enum),
    p_language_code,
    v_client.vat_number
  );

  v_header := jsonb_build_object(
    'business_id', v_inv.business_id,
    'business_display_name', (SELECT display_name FROM public.business_entities WHERE id = v_inv.business_id)
  );
  v_bill_to := jsonb_build_object(
    'client_id', v_client.id,
    'display_name', v_client.display_name,
    'legal_name', v_client.legal_name,
    'country', v_client.country,
    'vat_number', v_client.vat_number,
    'billing_address_line_1', v_client.billing_address_line_1,
    'billing_address_line_2', v_client.billing_address_line_2,
    'billing_city', v_client.billing_city,
    'billing_postal_code', v_client.billing_postal_code,
    'billing_country', v_client.billing_country,
    'billing_email', v_client.billing_email
  );
  v_totals := jsonb_build_object(
    'subtotal_amount', v_inv.subtotal_amount,
    'vat_amount', v_inv.vat_amount,
    'total_amount', v_inv.total_amount,
    'currency', v_inv.currency,
    'per_rate_breakdown', v_per_rate
  );

  v_payload := jsonb_build_object(
    'invoice_id', v_inv.id,
    'invoice_number', v_inv.invoice_number,
    'invoice_type', v_inv.invoice_type::text,
    'lifecycle_status', v_inv.lifecycle_status::text,
    'issue_date', v_inv.issue_date,
    'supply_date', v_inv.supply_date,
    'due_date', v_inv.due_date,
    'payment_terms_days', GREATEST(0, (v_inv.due_date - v_inv.issue_date)),
    'header', v_header,
    'bill_to', v_bill_to,
    'lines', v_lines,
    'totals', v_totals,
    'vat_aware_text', v_vat_text,
    'is_draft_watermark', p_render_kind = 'DRAFT_PREVIEW',
    'is_pro_forma_watermark', v_inv.invoice_type = 'PRO_FORMA',
    'pro_forma_footer_text', CASE WHEN v_inv.invoice_type = 'PRO_FORMA'
      THEN 'This document is a pro-forma invoice and does not constitute a tax invoice. A tax invoice will be issued upon payment.'
      ELSE NULL END,
    'language_code', COALESCE(p_language_code, 'en'),
    'renderer_version', p_renderer_version
  );

  v_hash := encode(sha256(v_payload::text::bytea), 'hex');

  IF p_render_kind = 'FINAL' THEN
    SELECT * INTO v_existing
      FROM public.invoice_pdf_renders
     WHERE invoice_id = p_invoice_id
       AND render_kind = 'FINAL'
       AND render_hash = v_hash
       AND language_code = COALESCE(p_language_code, 'en')
       AND renderer_version = p_renderer_version
     LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object(
        'decision','ALLOW',
        'idempotent_hit', true,
        'render_hash', v_hash,
        'pdf_storage_object_id', v_existing.pdf_storage_object_id,
        'rendered_at', v_existing.rendered_at,
        'payload', v_payload
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'decision','ALLOW',
    'idempotent_hit', false,
    'render_hash', v_hash,
    'payload', v_payload
  );
END;
$function$;

-- ---- 6. RPC: invoice_register_rendered_pdf -----------------------------

CREATE OR REPLACE FUNCTION public.invoice_register_rendered_pdf(
  p_actor_user_id        uuid,
  p_invoice_id           uuid,
  p_render_kind          public.invoice_render_kind_enum,
  p_render_hash          text,
  p_language_code        text,
  p_renderer_version     text,
  p_pdf_storage_object_id uuid,
  p_context              jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_inv      public.invoices%ROWTYPE;
  v_decision jsonb;
  v_render_id uuid := gen_uuid_v7();
  v_existing public.invoice_pdf_renders%ROWTYPE;
BEGIN
  SELECT * INTO v_inv FROM public.invoices WHERE id = p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','INVOICE_NOT_FOUND'); END IF;
  v_decision := public.can_perform(p_actor_user_id, 'INVOICE_MANAGE', 'REGISTER_PDF',
    jsonb_build_object('invoice_id', p_invoice_id), v_inv.business_id, v_inv.organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision',
      'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;
  IF p_render_hash IS NULL OR p_render_hash !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','INVALID_RENDER_HASH');
  END IF;
  IF p_render_kind = 'FINAL' AND p_pdf_storage_object_id IS NULL THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','FINAL_REQUIRES_STORAGE_OBJECT_ID');
  END IF;

  BEGIN
    INSERT INTO public.invoice_pdf_renders (
      id, organization_id, business_id, invoice_id,
      render_kind, render_hash, language_code, renderer_version,
      pdf_storage_object_id, rendered_by, rendered_by_system
    ) VALUES (
      v_render_id, v_inv.organization_id, v_inv.business_id, p_invoice_id,
      p_render_kind, p_render_hash, COALESCE(p_language_code,'en'), p_renderer_version,
      p_pdf_storage_object_id, p_actor_user_id, NULL
    );
  EXCEPTION WHEN unique_violation THEN
    SELECT * INTO v_existing FROM public.invoice_pdf_renders
     WHERE invoice_id = p_invoice_id
       AND render_kind = p_render_kind
       AND render_hash = p_render_hash
       AND language_code = COALESCE(p_language_code,'en')
       AND renderer_version = p_renderer_version
     LIMIT 1;
    RETURN jsonb_build_object(
      'decision','ALLOW',
      'idempotent', true,
      'render_id', v_existing.id,
      'pdf_storage_object_id', v_existing.pdf_storage_object_id
    );
  END;

  IF p_render_kind = 'FINAL' THEN
    UPDATE public.invoices SET
      pdf_storage_object_id = p_pdf_storage_object_id,
      pdf_rendered_at = now(),
      updated_at = now()
     WHERE id = p_invoice_id;
  END IF;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='INVOICE_PDF_RENDERED',
    p_subject_type:='INVOICE'::audit.subject_type_enum, p_subject_id:=p_invoice_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_inv.organization_id, p_business_id:=v_inv.business_id,
    p_before_state:=NULL,
    p_after_state :=jsonb_build_object(
      'render_id', v_render_id,
      'render_kind', p_render_kind::text,
      'language_code', COALESCE(p_language_code,'en'),
      'renderer_version', p_renderer_version,
      'pdf_storage_object_id', p_pdf_storage_object_id,
      'render_hash', p_render_hash
    ),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object(
    'decision','ALLOW',
    'idempotent', false,
    'render_id', v_render_id,
    'pdf_storage_object_id', p_pdf_storage_object_id
  );
END;
$function$;

-- ---- 7. RPC: credit_note_compute_pdf_render_payload --------------------

CREATE OR REPLACE FUNCTION public.credit_note_compute_pdf_render_payload(
  p_actor_user_id    uuid,
  p_credit_note_id   uuid,
  p_language_code    text,
  p_renderer_version text,
  p_context          jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_cn       public.credit_notes%ROWTYPE;
  v_inv      public.invoices%ROWTYPE;
  v_client   public.clients%ROWTYPE;
  v_decision jsonb;
  v_payload  jsonb;
  v_hash     text;
  v_existing public.credit_note_pdf_renders%ROWTYPE;
BEGIN
  SELECT * INTO v_cn FROM public.credit_notes WHERE id = p_credit_note_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','CREDIT_NOTE_NOT_FOUND');
  END IF;
  SELECT * INTO v_inv FROM public.invoices WHERE id = v_cn.against_invoice_id;
  v_decision := public.can_perform(p_actor_user_id, 'INVOICE_MANAGE', 'RENDER_CN_PDF',
    jsonb_build_object('credit_note_id', p_credit_note_id), v_cn.business_id, v_cn.organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision',
      'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;
  SELECT * INTO v_client FROM public.clients WHERE id = v_inv.client_id;

  v_payload := jsonb_build_object(
    'credit_note_id', v_cn.id,
    'credit_note_number', v_cn.credit_note_number,
    'against_invoice_id', v_cn.against_invoice_id,
    'against_invoice_number', v_inv.invoice_number,
    'issue_date', v_cn.issue_date,
    'currency', v_cn.currency,
    'amount', v_cn.amount,
    'reason', v_cn.reason,
    'bill_to', jsonb_build_object(
      'client_id', v_client.id,
      'display_name', v_client.display_name,
      'legal_name', v_client.legal_name,
      'country', v_client.country,
      'vat_number', v_client.vat_number
    ),
    'language_code', COALESCE(p_language_code,'en'),
    'renderer_version', p_renderer_version
  );
  v_hash := encode(sha256(v_payload::text::bytea), 'hex');

  SELECT * INTO v_existing FROM public.credit_note_pdf_renders
   WHERE credit_note_id = p_credit_note_id
     AND render_hash = v_hash
     AND language_code = COALESCE(p_language_code,'en')
     AND renderer_version = p_renderer_version
   LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'decision','ALLOW','idempotent_hit', true,
      'render_hash', v_hash,
      'pdf_storage_object_id', v_existing.pdf_storage_object_id,
      'payload', v_payload
    );
  END IF;
  RETURN jsonb_build_object(
    'decision','ALLOW','idempotent_hit', false,
    'render_hash', v_hash,
    'payload', v_payload
  );
END;
$function$;

-- ---- 8. RPC: credit_note_register_rendered_pdf --------------------------

CREATE OR REPLACE FUNCTION public.credit_note_register_rendered_pdf(
  p_actor_user_id        uuid,
  p_credit_note_id       uuid,
  p_render_hash          text,
  p_language_code        text,
  p_renderer_version     text,
  p_pdf_storage_object_id uuid,
  p_context              jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_cn       public.credit_notes%ROWTYPE;
  v_decision jsonb;
  v_render_id uuid := gen_uuid_v7();
  v_existing public.credit_note_pdf_renders%ROWTYPE;
BEGIN
  SELECT * INTO v_cn FROM public.credit_notes WHERE id = p_credit_note_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('decision','DENY','reason_code','CREDIT_NOTE_NOT_FOUND'); END IF;
  v_decision := public.can_perform(p_actor_user_id, 'INVOICE_MANAGE', 'REGISTER_CN_PDF',
    jsonb_build_object('credit_note_id', p_credit_note_id), v_cn.business_id, v_cn.organization_id);
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object('decision', v_decision->>'decision',
      'reason_code', COALESCE(v_decision->>'reason_code','PERMISSION_DENIED'));
  END IF;
  IF p_render_hash IS NULL OR p_render_hash !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','INVALID_RENDER_HASH');
  END IF;
  IF p_pdf_storage_object_id IS NULL THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','STORAGE_OBJECT_ID_REQUIRED');
  END IF;

  BEGIN
    INSERT INTO public.credit_note_pdf_renders (
      id, organization_id, business_id, credit_note_id,
      render_hash, language_code, renderer_version,
      pdf_storage_object_id, rendered_by, rendered_by_system
    ) VALUES (
      v_render_id, v_cn.organization_id, v_cn.business_id, p_credit_note_id,
      p_render_hash, COALESCE(p_language_code,'en'), p_renderer_version,
      p_pdf_storage_object_id, p_actor_user_id, NULL
    );
  EXCEPTION WHEN unique_violation THEN
    SELECT * INTO v_existing FROM public.credit_note_pdf_renders
     WHERE credit_note_id = p_credit_note_id
       AND render_hash = p_render_hash
       AND language_code = COALESCE(p_language_code,'en')
       AND renderer_version = p_renderer_version
     LIMIT 1;
    RETURN jsonb_build_object('decision','ALLOW','idempotent', true,
      'render_id', v_existing.id, 'pdf_storage_object_id', v_existing.pdf_storage_object_id);
  END;

  UPDATE public.credit_notes SET
    pdf_storage_object_id = p_pdf_storage_object_id,
    pdf_rendered_at = now()
   WHERE id = p_credit_note_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='USER'::audit.actor_kind_enum, p_action:='CREDIT_NOTE_PDF_RENDERED',
    p_subject_type:='CREDIT_NOTE'::audit.subject_type_enum, p_subject_id:=p_credit_note_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL, p_actor_system:=NULL,
    p_organization_id:=v_cn.organization_id, p_business_id:=v_cn.business_id,
    p_before_state:=NULL,
    p_after_state :=jsonb_build_object(
      'render_id', v_render_id,
      'language_code', COALESCE(p_language_code,'en'),
      'renderer_version', p_renderer_version,
      'pdf_storage_object_id', p_pdf_storage_object_id,
      'render_hash', p_render_hash
    ),
    p_reason:=NULL, p_request_context:=p_context);

  RETURN jsonb_build_object('decision','ALLOW',  'idempotent', false,
    'render_id', v_render_id, 'pdf_storage_object_id', p_pdf_storage_object_id);
END;
$function$;
