-- ============================================================================
-- Block 13 Phase 02 (BOOK-117) — Client Database
--
--   * clients table + indexes + unique partial on (business_id, vat_number)
--   * RLS+FORCE; SECURITY DEFINER RPCs only for writes
--   * Cross-block: backfill the deferred invoices.client_id FK
--   * review_issues 6th entity slot (client_id) + relax workflow_run_id NOT NULL
--     (config-scope review issues from CLIENT_VAT_NUMBER_FORMAT_INVALID_DETECTED
--      have no workflow run context)
--   * permission_matrix surface CLIENT_MANAGE
--   * 8 RPCs: client_create, client_update, client_disable, client_get,
--     client_list, get_client_by_name, get_client_by_vat_number,
--     touch_client_last_seen
--   * 3 deterministic suggest helpers: vat_treatment, reverse_charge_applicable,
--     payment_terms (rules-only, no AI)
-- ============================================================================

-- ---- 1. clients table ----------------------------------------------------

CREATE TABLE public.clients (
  id              uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  organization_id uuid NOT NULL,
  business_id     uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE RESTRICT,

  display_name    text NOT NULL CHECK (length(trim(display_name)) > 0 AND length(display_name) <= 256),
  legal_name      text NULL CHECK (legal_name IS NULL OR length(trim(legal_name)) > 0),

  -- Counterparty identification
  country                    char(2) NULL CHECK (country IS NULL OR country ~ '^[A-Z]{2}$'),
  vat_number                 text NULL,
  vat_number_format_valid    boolean NOT NULL DEFAULT false,

  -- Billing
  billing_address_line_1 text NULL,
  billing_address_line_2 text NULL,
  billing_city           text NULL,
  billing_postal_code    text NULL,
  billing_country        char(2) NULL CHECK (billing_country IS NULL OR billing_country ~ '^[A-Z]{2}$'),
  billing_email          text NULL CHECK (billing_email IS NULL OR billing_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),

  -- Defaults pulled into new invoices
  default_currency                   text NOT NULL CHECK (default_currency ~ '^[A-Z]{3}$'),
  default_payment_terms_days         int  NOT NULL DEFAULT 30 CHECK (default_payment_terms_days BETWEEN 1 AND 365),
  default_reverse_charge_applicable  boolean NOT NULL DEFAULT false,
  default_vat_treatment              public.vat_treatment_enum NULL,

  -- Soft-delete lifecycle
  disabled_at timestamptz NULL,
  disabled_by uuid NULL,

  -- Recurring-client memory (B11·P04 write-back)
  last_seen_at timestamptz NULL,

  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid NULL,

  CONSTRAINT clients_disabled_consistency_chk CHECK (
    (disabled_at IS NULL) = (disabled_by IS NULL)
  ),
  CONSTRAINT clients_vat_canonical_shape_chk CHECK (
    vat_number IS NULL
    OR (length(vat_number) BETWEEN 4 AND 32 AND vat_number = upper(regexp_replace(vat_number, '\s', '', 'g')))
  )
);

CREATE INDEX clients_business_display_name_idx ON public.clients(business_id, display_name);
CREATE INDEX clients_business_country_vat_idx  ON public.clients(business_id, country, vat_number);
CREATE INDEX clients_business_disabled_idx     ON public.clients(business_id, disabled_at);
CREATE INDEX clients_business_last_seen_idx    ON public.clients(business_id, last_seen_at DESC NULLS LAST);
CREATE UNIQUE INDEX clients_business_vat_uniq
  ON public.clients(business_id, vat_number)
  WHERE vat_number IS NOT NULL;

COMMENT ON TABLE public.clients IS
  'Block 13 P02 — IN-side counterparty registry. Defaults pulled into new invoices by Block 13 P03. Lookup helpers (get_client_by_name / by_vat_number) consumed by Block 11 P04 on IN-side runs.';

-- ---- 2. RLS --------------------------------------------------------------

ALTER TABLE public.clients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clients FORCE  ROW LEVEL SECURITY;

CREATE POLICY clients_select_tenant ON public.clients FOR SELECT TO authenticated
  USING (business_id = ANY (public.current_user_businesses()));
CREATE POLICY clients_deny_insert ON public.clients FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY clients_deny_update ON public.clients FOR UPDATE TO authenticated USING (false);
CREATE POLICY clients_deny_delete ON public.clients FOR DELETE TO authenticated USING (false);

-- ---- 3. Permission matrix seed ------------------------------------------

INSERT INTO public.permission_matrix (role, surface, decision) VALUES
  ('OWNER',      'CLIENT_MANAGE', 'ALLOW'),
  ('ADMIN',      'CLIENT_MANAGE', 'ALLOW'),
  ('BOOKKEEPER', 'CLIENT_MANAGE', 'ALLOW'),
  ('ACCOUNTANT', 'CLIENT_MANAGE', 'DENY'),
  ('REVIEWER',   'CLIENT_MANAGE', 'DENY'),
  ('READ_ONLY',  'CLIENT_MANAGE', 'DENY')
ON CONFLICT (role, surface) DO NOTHING;

-- ---- 4. Cross-block: invoices.client_id FK (deferred from P01) ----------
-- DB has no production invoices yet; safe to add the FK directly.

ALTER TABLE public.invoices
  ADD CONSTRAINT invoices_client_id_fkey
    FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE RESTRICT;

COMMENT ON COLUMN public.invoices.client_id IS
  'FK to public.clients (added in Block 13 P02).';

-- ---- 5. Cross-block: review_issues 6th entity + relax workflow_run_id ----
-- CLIENT_VAT_NUMBER_FORMAT_INVALID_DETECTED issues happen outside any workflow
-- run context (during client CRUD). Relax NOT NULL on workflow_run_id and add
-- client_id as a 6th valid entity in the at-least-one-entity CHECK.

ALTER TABLE public.review_issues
  ALTER COLUMN workflow_run_id DROP NOT NULL;

ALTER TABLE public.review_issues
  ADD COLUMN client_id uuid NULL REFERENCES public.clients(id) ON DELETE SET NULL;

CREATE INDEX review_issues_client_idx ON public.review_issues(client_id) WHERE client_id IS NOT NULL;

ALTER TABLE public.review_issues
  DROP CONSTRAINT review_issue_at_least_one_entity_chk;

ALTER TABLE public.review_issues
  ADD CONSTRAINT review_issue_at_least_one_entity_chk CHECK (
    transaction_id IS NOT NULL
    OR document_id IS NOT NULL
    OR match_record_id IS NOT NULL
    OR draft_ledger_entry_id IS NOT NULL
    OR invoice_id IS NOT NULL
    OR client_id IS NOT NULL
  );

COMMENT ON COLUMN public.review_issues.client_id IS
  'Block 13 P02 — client anchor (config-scope issues from client CRUD; recognized as 6th entity in at-least-one-entity CHECK).';
COMMENT ON COLUMN public.review_issues.workflow_run_id IS
  'Workflow run that surfaced the issue. NULLable as of Block 13 P02 — config-scope issues (e.g. CLIENT_VAT_NUMBER_FORMAT_INVALID_DETECTED) have no run context.';

-- ---- 6. Deterministic suggest helpers (rules-only, no AI) ----------------

-- EU-27 ISO codes (Stage 1 hardcoded; no countries registry exists yet).
CREATE OR REPLACE FUNCTION public.fn_is_eu_country(p_country char(2))
RETURNS boolean LANGUAGE sql IMMUTABLE
AS $$
  SELECT p_country IS NOT NULL AND p_country = ANY (ARRAY[
    'AT','BE','BG','HR','CY','CZ','DK','EE','FI','FR','DE','GR','HU','IE',
    'IT','LV','LT','LU','MT','NL','PL','PT','RO','SK','SI','ES','SE'
  ]::char(2)[]);
$$;

-- suggest_vat_treatment: replicates the OUT-side classifier logic at the
-- IN-side counterparty defaulting point.
CREATE OR REPLACE FUNCTION public.suggest_vat_treatment(
  p_country               char(2),
  p_vat_number_format_valid boolean,
  p_business_country      char(2)
) RETURNS public.vat_treatment_enum
LANGUAGE plpgsql STABLE
AS $$
BEGIN
  -- Same country as business: domestic
  IF p_country IS NOT NULL AND p_business_country IS NOT NULL AND p_country = p_business_country THEN
    IF p_business_country = 'CY' THEN
      RETURN 'DOMESTIC_CYPRUS_VAT'::public.vat_treatment_enum;
    END IF;
    RETURN 'DOMESTIC_STANDARD'::public.vat_treatment_enum;
  END IF;
  -- EU counterpart with valid VAT → reverse charge
  IF public.fn_is_eu_country(p_country) AND COALESCE(p_vat_number_format_valid, false) = true THEN
    RETURN 'EU_REVERSE_CHARGE'::public.vat_treatment_enum;
  END IF;
  -- EU counterpart, no valid VAT → treat as DOMESTIC_STANDARD (B2C-ish)
  IF public.fn_is_eu_country(p_country) THEN
    RETURN 'DOMESTIC_STANDARD'::public.vat_treatment_enum;
  END IF;
  -- Non-EU → outside scope (Stage 1 default; sub-doc may split into NON_EU_SERVICE for services)
  IF p_country IS NOT NULL THEN
    RETURN 'OUTSIDE_SCOPE'::public.vat_treatment_enum;
  END IF;
  RETURN 'UNKNOWN'::public.vat_treatment_enum;
END;
$$;

CREATE OR REPLACE FUNCTION public.suggest_reverse_charge_applicable(
  p_country                  char(2),
  p_vat_number_format_valid  boolean
) RETURNS boolean
LANGUAGE sql STABLE
AS $$
  SELECT public.fn_is_eu_country(p_country) AND COALESCE(p_vat_number_format_valid, false);
$$;

CREATE OR REPLACE FUNCTION public.suggest_payment_terms(
  p_country               char(2),
  p_business_default_days int
) RETURNS int
LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(p_business_default_days, 30);
$$;

-- ---- 7. RPC: client_create ----------------------------------------------

CREATE OR REPLACE FUNCTION public.client_create(
  p_organization_id  uuid,
  p_business_id      uuid,
  p_actor_user_id    uuid,
  p_display_name     text,
  p_legal_name       text,
  p_country          char(2),
  p_vat_number_raw   text,
  p_billing_address_line_1 text,
  p_billing_address_line_2 text,
  p_billing_city           text,
  p_billing_postal_code    text,
  p_billing_country        char(2),
  p_billing_email          text,
  p_default_currency               text,
  p_default_payment_terms_days     int,
  p_default_reverse_charge_applicable boolean,
  p_default_vat_treatment          public.vat_treatment_enum,
  p_context          jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_decision        jsonb;
  v_client_id       uuid := gen_uuid_v7();
  v_vat_canonical   text;
  v_vat_valid       boolean := false;
  v_review_issue_id uuid;
BEGIN
  v_decision := public.can_perform(
    p_actor_user_id := p_actor_user_id,
    p_surface       := 'CLIENT_MANAGE',
    p_action        := 'CREATE',
    p_resource      := jsonb_build_object('display_name', p_display_name),
    p_business_id   := p_business_id,
    p_organization_id := p_organization_id
  );
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object(
      'decision', v_decision->>'decision',
      'reason_code', COALESCE(v_decision->>'reason_code', 'PERMISSION_DENIED'),
      'client_id', NULL
    );
  END IF;

  IF p_display_name IS NULL OR length(trim(p_display_name)) = 0 THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','DISPLAY_NAME_REQUIRED','client_id', NULL);
  END IF;
  IF p_default_currency IS NULL OR p_default_currency !~ '^[A-Z]{3}$' THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','INVALID_DEFAULT_CURRENCY','client_id', NULL);
  END IF;

  IF p_vat_number_raw IS NOT NULL AND length(trim(p_vat_number_raw)) > 0 THEN
    v_vat_canonical := public.canonicalize_vat_number(p_country, p_vat_number_raw);
    v_vat_valid     := public.validate_vat_number_format(p_country, v_vat_canonical);
  END IF;

  BEGIN
    INSERT INTO public.clients (
      id, organization_id, business_id,
      display_name, legal_name,
      country, vat_number, vat_number_format_valid,
      billing_address_line_1, billing_address_line_2, billing_city,
      billing_postal_code, billing_country, billing_email,
      default_currency, default_payment_terms_days,
      default_reverse_charge_applicable, default_vat_treatment,
      created_by, updated_by
    ) VALUES (
      v_client_id, p_organization_id, p_business_id,
      p_display_name, p_legal_name,
      p_country, v_vat_canonical, v_vat_valid,
      p_billing_address_line_1, p_billing_address_line_2, p_billing_city,
      p_billing_postal_code, p_billing_country, p_billing_email,
      p_default_currency, COALESCE(p_default_payment_terms_days, 30),
      COALESCE(p_default_reverse_charge_applicable, false), p_default_vat_treatment,
      p_actor_user_id, p_actor_user_id
    );
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object(
      'decision','DENY','reason_code','DUPLICATE_VAT_NUMBER',
      'client_id', NULL, 'vat_number', v_vat_canonical
    );
  END;

  PERFORM audit.emit_audit(
    p_actor_kind      := 'USER'::audit.actor_kind_enum,
    p_action          := 'CLIENT_CREATED',
    p_subject_type    := 'CLIENT'::audit.subject_type_enum,
    p_subject_id      := v_client_id,
    p_actor_user_id   := p_actor_user_id,
    p_actor_role      := NULL,
    p_actor_session_id:= NULL,
    p_actor_system    := NULL,
    p_organization_id := p_organization_id,
    p_business_id     := p_business_id,
    p_before_state    := NULL,
    p_after_state     := jsonb_build_object(
      'client_id', v_client_id,
      'display_name', p_display_name,
      'country', p_country,
      'vat_number', v_vat_canonical,
      'vat_number_format_valid', v_vat_valid,
      'default_currency', p_default_currency
    ),
    p_reason          := NULL,
    p_request_context := p_context
  );

  -- VAT-format-invalid: emit explicit audit + raise a review issue anchored on the client
  IF v_vat_canonical IS NOT NULL AND v_vat_valid = false THEN
    INSERT INTO public.review_issues (
      organization_id, business_id, workflow_run_id, client_id,
      issue_type, issue_group, severity,
      plain_language_title, plain_language_description, recommended_action,
      card_payload_json
    ) VALUES (
      p_organization_id, p_business_id, NULL, v_client_id,
      'client.vat_number_format_invalid',
      'POSSIBLE_TAX_VAT_ISSUE'::public.review_issue_group_enum,
      'HIGH'::public.review_issue_severity_enum,
      format('Client %s has an invalid VAT number format', p_display_name),
      format('The VAT number "%s" for country %s does not match the expected format. Invoices issued to this client may be classified incorrectly for VAT purposes until the number is fixed.',
        v_vat_canonical, COALESCE(p_country, '(unknown)')),
      'Correct the VAT number on the client record or remove it if not applicable.',
      jsonb_build_object(
        'client_id', v_client_id,
        'country', p_country,
        'vat_number', v_vat_canonical
      )
    ) RETURNING id INTO v_review_issue_id;

    PERFORM audit.emit_audit(
      p_actor_kind      := 'SYSTEM'::audit.actor_kind_enum,
      p_action          := 'CLIENT_VAT_NUMBER_FORMAT_INVALID_DETECTED',
      p_subject_type    := 'CLIENT'::audit.subject_type_enum,
      p_subject_id      := v_client_id,
      p_actor_user_id   := NULL,
      p_actor_role      := NULL,
      p_actor_session_id:= NULL,
      p_actor_system    := 'client_validator',
      p_organization_id := p_organization_id,
      p_business_id     := p_business_id,
      p_before_state    := NULL,
      p_after_state     := jsonb_build_object(
        'client_id', v_client_id,
        'country', p_country,
        'vat_number', v_vat_canonical,
        'review_issue_id', v_review_issue_id
      ),
      p_reason          := NULL,
      p_request_context := p_context
    );
  END IF;

  RETURN jsonb_build_object(
    'decision', 'ALLOW',
    'client_id', v_client_id,
    'vat_number', v_vat_canonical,
    'vat_number_format_valid', v_vat_valid
  );
END;
$function$;

-- ---- 8. RPC: client_update ----------------------------------------------
-- Field-level diff in CLIENT_UPDATED's after_state.diff jsonb.

CREATE OR REPLACE FUNCTION public.client_update(
  p_actor_user_id    uuid,
  p_client_id        uuid,
  p_display_name     text DEFAULT NULL,
  p_legal_name       text DEFAULT NULL,
  p_country          char(2) DEFAULT NULL,
  p_vat_number_raw   text DEFAULT NULL,
  p_billing_address_line_1 text DEFAULT NULL,
  p_billing_address_line_2 text DEFAULT NULL,
  p_billing_city           text DEFAULT NULL,
  p_billing_postal_code    text DEFAULT NULL,
  p_billing_country        char(2) DEFAULT NULL,
  p_billing_email          text DEFAULT NULL,
  p_default_currency               text DEFAULT NULL,
  p_default_payment_terms_days     int DEFAULT NULL,
  p_default_reverse_charge_applicable boolean DEFAULT NULL,
  p_default_vat_treatment          public.vat_treatment_enum DEFAULT NULL,
  p_clear_country boolean DEFAULT false,
  p_clear_vat_number boolean DEFAULT false,
  p_context          jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_decision        jsonb;
  v_client          public.clients%ROWTYPE;
  v_diff            jsonb := '{}'::jsonb;
  v_new_country     char(2);
  v_new_vat_canonical text;
  v_new_vat_valid   boolean;
  v_review_issue_id uuid;
BEGIN
  SELECT * INTO v_client FROM public.clients WHERE id = p_client_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','CLIENT_NOT_FOUND','client_id', NULL);
  END IF;

  v_decision := public.can_perform(
    p_actor_user_id := p_actor_user_id,
    p_surface       := 'CLIENT_MANAGE',
    p_action        := 'UPDATE',
    p_resource      := jsonb_build_object('client_id', p_client_id),
    p_business_id   := v_client.business_id,
    p_organization_id := v_client.organization_id
  );
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object(
      'decision', v_decision->>'decision',
      'reason_code', COALESCE(v_decision->>'reason_code', 'PERMISSION_DENIED'),
      'client_id', p_client_id
    );
  END IF;

  IF v_client.disabled_at IS NOT NULL THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','CLIENT_DISABLED','client_id', p_client_id);
  END IF;

  -- VAT canonicalization with clear-flag semantics
  v_new_country := CASE WHEN p_clear_country THEN NULL ELSE COALESCE(p_country, v_client.country) END;
  IF p_clear_vat_number THEN
    v_new_vat_canonical := NULL;
    v_new_vat_valid := false;
  ELSIF p_vat_number_raw IS NOT NULL THEN
    v_new_vat_canonical := public.canonicalize_vat_number(v_new_country, p_vat_number_raw);
    v_new_vat_valid     := public.validate_vat_number_format(v_new_country, v_new_vat_canonical);
  ELSE
    v_new_vat_canonical := v_client.vat_number;
    v_new_vat_valid     := v_client.vat_number_format_valid;
  END IF;

  -- Build field-level diff (only changed fields appear)
  IF p_display_name IS NOT NULL AND p_display_name <> v_client.display_name THEN
    v_diff := v_diff || jsonb_build_object('display_name', jsonb_build_object('old', v_client.display_name, 'new', p_display_name));
  END IF;
  IF (p_legal_name IS NOT NULL AND p_legal_name IS DISTINCT FROM v_client.legal_name) THEN
    v_diff := v_diff || jsonb_build_object('legal_name', jsonb_build_object('old', v_client.legal_name, 'new', p_legal_name));
  END IF;
  IF v_new_country IS DISTINCT FROM v_client.country THEN
    v_diff := v_diff || jsonb_build_object('country', jsonb_build_object('old', v_client.country, 'new', v_new_country));
  END IF;
  IF v_new_vat_canonical IS DISTINCT FROM v_client.vat_number THEN
    v_diff := v_diff || jsonb_build_object('vat_number', jsonb_build_object('old', v_client.vat_number, 'new', v_new_vat_canonical));
  END IF;
  IF v_new_vat_valid IS DISTINCT FROM v_client.vat_number_format_valid THEN
    v_diff := v_diff || jsonb_build_object('vat_number_format_valid', jsonb_build_object('old', v_client.vat_number_format_valid, 'new', v_new_vat_valid));
  END IF;
  IF p_default_currency IS NOT NULL AND p_default_currency IS DISTINCT FROM v_client.default_currency THEN
    v_diff := v_diff || jsonb_build_object('default_currency', jsonb_build_object('old', v_client.default_currency, 'new', p_default_currency));
  END IF;
  IF p_default_payment_terms_days IS NOT NULL AND p_default_payment_terms_days IS DISTINCT FROM v_client.default_payment_terms_days THEN
    v_diff := v_diff || jsonb_build_object('default_payment_terms_days', jsonb_build_object('old', v_client.default_payment_terms_days, 'new', p_default_payment_terms_days));
  END IF;
  IF p_default_reverse_charge_applicable IS NOT NULL AND p_default_reverse_charge_applicable IS DISTINCT FROM v_client.default_reverse_charge_applicable THEN
    v_diff := v_diff || jsonb_build_object('default_reverse_charge_applicable', jsonb_build_object('old', v_client.default_reverse_charge_applicable, 'new', p_default_reverse_charge_applicable));
  END IF;
  IF p_default_vat_treatment IS NOT NULL AND p_default_vat_treatment IS DISTINCT FROM v_client.default_vat_treatment THEN
    v_diff := v_diff || jsonb_build_object('default_vat_treatment',
      jsonb_build_object('old', v_client.default_vat_treatment::text, 'new', p_default_vat_treatment::text));
  END IF;

  -- Apply update if anything changed
  IF v_diff <> '{}'::jsonb THEN
    BEGIN
      UPDATE public.clients SET
        display_name = COALESCE(p_display_name, display_name),
        legal_name = CASE WHEN p_legal_name IS NOT NULL THEN p_legal_name ELSE legal_name END,
        country = v_new_country,
        vat_number = v_new_vat_canonical,
        vat_number_format_valid = v_new_vat_valid,
        billing_address_line_1 = COALESCE(p_billing_address_line_1, billing_address_line_1),
        billing_address_line_2 = COALESCE(p_billing_address_line_2, billing_address_line_2),
        billing_city           = COALESCE(p_billing_city, billing_city),
        billing_postal_code    = COALESCE(p_billing_postal_code, billing_postal_code),
        billing_country        = COALESCE(p_billing_country, billing_country),
        billing_email          = COALESCE(p_billing_email, billing_email),
        default_currency = COALESCE(p_default_currency, default_currency),
        default_payment_terms_days = COALESCE(p_default_payment_terms_days, default_payment_terms_days),
        default_reverse_charge_applicable = COALESCE(p_default_reverse_charge_applicable, default_reverse_charge_applicable),
        default_vat_treatment  = COALESCE(p_default_vat_treatment, default_vat_treatment),
        updated_at = now(),
        updated_by = p_actor_user_id
      WHERE id = p_client_id;
    EXCEPTION WHEN unique_violation THEN
      RETURN jsonb_build_object(
        'decision','DENY','reason_code','DUPLICATE_VAT_NUMBER',
        'client_id', p_client_id, 'vat_number', v_new_vat_canonical
      );
    END;

    PERFORM audit.emit_audit(
      p_actor_kind      := 'USER'::audit.actor_kind_enum,
      p_action          := 'CLIENT_UPDATED',
      p_subject_type    := 'CLIENT'::audit.subject_type_enum,
      p_subject_id      := p_client_id,
      p_actor_user_id   := p_actor_user_id,
      p_actor_role      := NULL,
      p_actor_session_id:= NULL,
      p_actor_system    := NULL,
      p_organization_id := v_client.organization_id,
      p_business_id     := v_client.business_id,
      p_before_state    := NULL,
      p_after_state     := jsonb_build_object('diff', v_diff),
      p_reason          := NULL,
      p_request_context := p_context
    );

    -- VAT-format-invalid on UPDATE: same review-issue + audit pattern as CREATE
    IF v_new_vat_canonical IS NOT NULL AND v_new_vat_valid = false
       AND (v_client.vat_number IS DISTINCT FROM v_new_vat_canonical
            OR v_client.vat_number_format_valid IS DISTINCT FROM v_new_vat_valid) THEN
      INSERT INTO public.review_issues (
        organization_id, business_id, workflow_run_id, client_id,
        issue_type, issue_group, severity,
        plain_language_title, plain_language_description, recommended_action,
        card_payload_json
      ) VALUES (
        v_client.organization_id, v_client.business_id, NULL, p_client_id,
        'client.vat_number_format_invalid',
        'POSSIBLE_TAX_VAT_ISSUE'::public.review_issue_group_enum,
        'HIGH'::public.review_issue_severity_enum,
        format('Client %s has an invalid VAT number format', COALESCE(p_display_name, v_client.display_name)),
        format('The updated VAT number "%s" for country %s does not match the expected format.', v_new_vat_canonical, COALESCE(v_new_country, '(unknown)')),
        'Correct the VAT number on the client record or remove it.',
        jsonb_build_object('client_id', p_client_id, 'country', v_new_country, 'vat_number', v_new_vat_canonical)
      ) RETURNING id INTO v_review_issue_id;
      PERFORM audit.emit_audit(
        p_actor_kind      := 'SYSTEM'::audit.actor_kind_enum,
        p_action          := 'CLIENT_VAT_NUMBER_FORMAT_INVALID_DETECTED',
        p_subject_type    := 'CLIENT'::audit.subject_type_enum,
        p_subject_id      := p_client_id,
        p_actor_user_id   := NULL,
        p_actor_role      := NULL,
        p_actor_session_id:= NULL,
        p_actor_system    := 'client_validator',
        p_organization_id := v_client.organization_id,
        p_business_id     := v_client.business_id,
        p_before_state    := NULL,
        p_after_state     := jsonb_build_object('client_id', p_client_id, 'country', v_new_country, 'vat_number', v_new_vat_canonical, 'review_issue_id', v_review_issue_id),
        p_reason          := NULL,
        p_request_context := p_context
      );
    END IF;
  END IF;

  RETURN jsonb_build_object('decision','ALLOW','client_id', p_client_id, 'diff', v_diff);
END;
$function$;

-- ---- 9. RPC: client_disable ---------------------------------------------

CREATE OR REPLACE FUNCTION public.client_disable(
  p_actor_user_id  uuid,
  p_client_id      uuid,
  p_context        jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_client    public.clients%ROWTYPE;
  v_decision  jsonb;
BEGIN
  SELECT * INTO v_client FROM public.clients WHERE id = p_client_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','CLIENT_NOT_FOUND','client_id', NULL);
  END IF;
  v_decision := public.can_perform(
    p_actor_user_id := p_actor_user_id,
    p_surface       := 'CLIENT_MANAGE',
    p_action        := 'DISABLE',
    p_resource      := jsonb_build_object('client_id', p_client_id),
    p_business_id   := v_client.business_id,
    p_organization_id := v_client.organization_id
  );
  IF (v_decision->>'decision') <> 'ALLOW' THEN
    RETURN jsonb_build_object(
      'decision', v_decision->>'decision',
      'reason_code', COALESCE(v_decision->>'reason_code', 'PERMISSION_DENIED'),
      'client_id', p_client_id
    );
  END IF;
  IF v_client.disabled_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'decision','ALLOW','client_id', p_client_id,
      'reason_code','ALREADY_DISABLED',
      'disabled_at', v_client.disabled_at
    );
  END IF;

  UPDATE public.clients
     SET disabled_at = now(),
         disabled_by = p_actor_user_id,
         updated_at = now(),
         updated_by = p_actor_user_id
   WHERE id = p_client_id;

  PERFORM audit.emit_audit(
    p_actor_kind      := 'USER'::audit.actor_kind_enum,
    p_action          := 'CLIENT_DISABLED',
    p_subject_type    := 'CLIENT'::audit.subject_type_enum,
    p_subject_id      := p_client_id,
    p_actor_user_id   := p_actor_user_id,
    p_actor_role      := NULL,
    p_actor_session_id:= NULL,
    p_actor_system    := NULL,
    p_organization_id := v_client.organization_id,
    p_business_id     := v_client.business_id,
    p_before_state    := jsonb_build_object('disabled_at', NULL),
    p_after_state     := jsonb_build_object('disabled_at', now(), 'disabled_by', p_actor_user_id),
    p_reason          := NULL,
    p_request_context := p_context
  );

  RETURN jsonb_build_object('decision','ALLOW','client_id', p_client_id, 'disabled_at', now());
END;
$function$;

-- ---- 10. RPC: client_get ------------------------------------------------

CREATE OR REPLACE FUNCTION public.client_get(p_client_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_row jsonb;
BEGIN
  SELECT to_jsonb(c) INTO v_row FROM public.clients c WHERE c.id = p_client_id;
  IF v_row IS NULL THEN
    RETURN jsonb_build_object('decision','DENY','reason_code','CLIENT_NOT_FOUND');
  END IF;
  RETURN jsonb_build_object('decision','ALLOW','client', v_row);
END;
$function$;

-- ---- 11. RPC: client_list -----------------------------------------------

CREATE OR REPLACE FUNCTION public.client_list(
  p_business_id      uuid,
  p_include_disabled boolean DEFAULT false,
  p_limit            int DEFAULT 100,
  p_offset           int DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_rows jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.display_name), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT *
        FROM public.clients
       WHERE business_id = p_business_id
         AND (p_include_disabled OR disabled_at IS NULL)
       ORDER BY display_name
       LIMIT GREATEST(1, LEAST(p_limit, 500))
       OFFSET GREATEST(0, p_offset)
    ) c;
  RETURN jsonb_build_object('decision','ALLOW','clients', v_rows);
END;
$function$;

-- ---- 12. RPC: get_client_by_name (Block 11 P04 contract) ----------------
-- Exact display_name match → HIGH; lowercase fuzzy match → MEDIUM.

CREATE OR REPLACE FUNCTION public.get_client_by_name(
  p_business_id           uuid,
  p_normalized_client_name text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_id   uuid;
  v_name text;
BEGIN
  IF p_normalized_client_name IS NULL OR length(trim(p_normalized_client_name)) = 0 THEN
    RETURN jsonb_build_object('client_id', NULL, 'confidence', NULL);
  END IF;
  -- Exact match (case-sensitive)
  SELECT id, display_name INTO v_id, v_name
    FROM public.clients
   WHERE business_id = p_business_id
     AND disabled_at IS NULL
     AND display_name = p_normalized_client_name
   LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN jsonb_build_object('client_id', v_id, 'confidence', 'HIGH', 'matched_display_name', v_name);
  END IF;
  -- Fuzzy: case-insensitive trimmed match
  SELECT id, display_name INTO v_id, v_name
    FROM public.clients
   WHERE business_id = p_business_id
     AND disabled_at IS NULL
     AND lower(trim(display_name)) = lower(trim(p_normalized_client_name))
   LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN jsonb_build_object('client_id', v_id, 'confidence', 'MEDIUM', 'matched_display_name', v_name);
  END IF;
  RETURN jsonb_build_object('client_id', NULL, 'confidence', NULL);
END;
$function$;

-- ---- 13. RPC: get_client_by_vat_number (Block 11 P04 contract) -----------

CREATE OR REPLACE FUNCTION public.get_client_by_vat_number(
  p_business_id    uuid,
  p_vat_number_raw text,
  p_country        char(2) DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, audit, pg_temp
AS $function$
DECLARE
  v_id        uuid;
  v_canonical text;
BEGIN
  IF p_vat_number_raw IS NULL OR length(trim(p_vat_number_raw)) = 0 THEN
    RETURN jsonb_build_object('client_id', NULL, 'confidence', NULL);
  END IF;
  v_canonical := public.canonicalize_vat_number(p_country, p_vat_number_raw);
  SELECT id INTO v_id
    FROM public.clients
   WHERE business_id = p_business_id
     AND disabled_at IS NULL
     AND vat_number = v_canonical
   LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN jsonb_build_object('client_id', v_id, 'confidence', 'MEDIUM', 'matched_vat', v_canonical);
  END IF;
  RETURN jsonb_build_object('client_id', NULL, 'confidence', NULL, 'matched_vat', v_canonical);
END;
$function$;

-- ---- 14. RPC: touch_client_last_seen (B11·P04 ranking hook) -------------

CREATE OR REPLACE FUNCTION public.touch_client_last_seen(p_client_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  UPDATE public.clients
     SET last_seen_at = now()
   WHERE id = p_client_id;
$function$;
