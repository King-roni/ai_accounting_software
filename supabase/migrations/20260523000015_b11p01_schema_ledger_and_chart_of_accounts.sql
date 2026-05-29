-- B11·P01 — Schema for Ledger Entries & Chart of Accounts
-- =====================================================================
-- Pure schema scaffolding for Block 11 (RPCs land in Phase 03/07/08/09).
-- The existing draft_ledger_entries (Block 04 Phase 04 placeholder; 0 rows,
-- only review_issues FK) diverged materially from the spec shape — dropped
-- and recreated to the canonical B11·P01 form, and the review_issues FK is
-- re-added.
--
-- Naming alignment with existing DB:
--   * vat_treatment_enum already exists (8 values from Phase 05 pre-seed):
--     DOMESTIC_STANDARD, DOMESTIC_REDUCED, DOMESTIC_ZERO, EU_REVERSE_CHARGE,
--     IMPORT_OR_ACQUISITION, NON_EU_SERVICE, OUTSIDE_SCOPE, UNKNOWN — reused.
--   * ledger_entry_type_enum {DEBIT, CREDIT} already exists (was the old
--     placeholder's entry_type discriminator). Reused as the
--     direction column of chart_of_accounts_mappings.
--
-- New enums:
--   ledger_entry_kind_enum: PRIMARY, VAT_RECLAIM, VAT_OUTPUT, ROUNDING, FX_DELTA
--   ledger_entry_status_enum: DRAFT, READY_FOR_FINALIZATION, LOCKED
--   account_class_enum: ASSET, LIABILITY, EQUITY, REVENUE, EXPENSE, CONTRA
--   account_deductibility_enum: DEDUCTIBLE, NON_DEDUCTIBLE, MIXED, NA
--
-- Tables: chart_of_accounts, chart_of_accounts_mapping_versions,
-- chart_of_accounts_mappings, draft_ledger_entries (rebuilt).
--
-- RLS: all four tables, SELECT-only via current_org/current_user_businesses;
-- writes blocked → go through SECURITY DEFINER RPCs in later phases.
--
-- Trigger: coam_block_when_version_frozen — UPDATE/DELETE on a mapping rule
-- whose version has frozen_at set is rejected. (Block 15 sets frozen_at.)
-- =====================================================================

BEGIN;

-- 0. Drop placeholder + dependent FK ---------------------------------------

ALTER TABLE public.review_issues
  DROP CONSTRAINT IF EXISTS review_issues_draft_ledger_entry_id_fkey;
DROP TABLE IF EXISTS public.draft_ledger_entries;


-- 1. New enums --------------------------------------------------------------

CREATE TYPE public.ledger_entry_kind_enum AS ENUM (
  'PRIMARY','VAT_RECLAIM','VAT_OUTPUT','ROUNDING','FX_DELTA'
);
CREATE TYPE public.ledger_entry_status_enum AS ENUM (
  'DRAFT','READY_FOR_FINALIZATION','LOCKED'
);
CREATE TYPE public.account_class_enum AS ENUM (
  'ASSET','LIABILITY','EQUITY','REVENUE','EXPENSE','CONTRA'
);
CREATE TYPE public.account_deductibility_enum AS ENUM (
  'DEDUCTIBLE','NON_DEDUCTIBLE','MIXED','NA'
);


-- 2. chart_of_accounts -----------------------------------------------------

CREATE TABLE public.chart_of_accounts (
  id              uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id uuid NOT NULL,
  business_id     uuid NOT NULL,
  code            text NOT NULL,
  name            text NOT NULL,
  account_class   public.account_class_enum NOT NULL,
  parent_code     text,
  category        text,
  deductibility   public.account_deductibility_enum NOT NULL DEFAULT 'NA',
  is_seeded       boolean NOT NULL DEFAULT false,
  disabled_at     timestamptz,
  created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT coa_unique_per_business UNIQUE (business_id, code),
  CONSTRAINT coa_code_format_chk CHECK (length(trim(code)) > 0),
  CONSTRAINT coa_parent_self_fk FOREIGN KEY (business_id, parent_code)
    REFERENCES public.chart_of_accounts (business_id, code) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX coa_business_class_idx    ON public.chart_of_accounts (business_id, account_class);
CREATE INDEX coa_business_category_idx ON public.chart_of_accounts (business_id, category);

COMMENT ON TABLE public.chart_of_accounts IS
  'Per-business chart catalog (B11·P01). Soft-delete via disabled_at; rows cannot be deleted while referenced by draft_ledger_entries (FK protects).';


-- 3. chart_of_accounts_mapping_versions ------------------------------------

CREATE TABLE public.chart_of_accounts_mapping_versions (
  id              uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id uuid NOT NULL,
  business_id     uuid NOT NULL,
  version_number  int NOT NULL,
  effective_from  timestamptz NOT NULL,
  created_by      uuid,
  created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
  frozen_at       timestamptz,
  CONSTRAINT coamv_unique_version_per_business UNIQUE (business_id, version_number),
  CONSTRAINT coamv_version_positive CHECK (version_number > 0)
);
CREATE INDEX coamv_business_effective_idx
  ON public.chart_of_accounts_mapping_versions (business_id, effective_from DESC);

COMMENT ON TABLE public.chart_of_accounts_mapping_versions IS
  'Version-pin row Phase 03 increments on every customization; Block 15 sets frozen_at when a finalized period pins the version.';


-- 4. chart_of_accounts_mappings --------------------------------------------

CREATE TABLE public.chart_of_accounts_mappings (
  id                  uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id     uuid NOT NULL,
  business_id         uuid NOT NULL,
  mapping_version_id  uuid NOT NULL REFERENCES public.chart_of_accounts_mapping_versions(id),
  transaction_type    public.transaction_type_enum,
  tag                 text,
  vat_treatment       public.vat_treatment_enum,
  entry_kind          public.ledger_entry_kind_enum NOT NULL DEFAULT 'PRIMARY',
  direction           public.ledger_entry_type_enum NOT NULL,
  account_code        text NOT NULL,
  priority            int NOT NULL DEFAULT 100,
  is_seeded           boolean NOT NULL DEFAULT false,
  created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT coam_account_fk FOREIGN KEY (business_id, account_code)
    REFERENCES public.chart_of_accounts (business_id, code) DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT coam_priority_nonneg CHECK (priority >= 0)
);
CREATE INDEX coam_resolution_idx ON public.chart_of_accounts_mappings
  (business_id, transaction_type, tag, vat_treatment, entry_kind, priority DESC);

COMMENT ON TABLE public.chart_of_accounts_mappings IS
  '(transaction_type, tag, vat_treatment, entry_kind) → (direction, account_code) rules with priority ordering (Phase 03 owns customization).';


-- 5. draft_ledger_entries (canonical B11·P01 shape) ------------------------

CREATE TABLE public.draft_ledger_entries (
  id                          uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id             uuid NOT NULL,
  business_id                 uuid NOT NULL,
  parent_transaction_id       uuid REFERENCES public.transactions(id),
  match_record_id             uuid REFERENCES public.match_records(id),
  entry_kind                  public.ledger_entry_kind_enum NOT NULL,
  debit_account_code          text,
  credit_account_code         text,
  debit_amount                numeric,
  credit_amount               numeric,
  currency                    text NOT NULL,
  entry_period                date NOT NULL,
  -- 11 compliance fields
  counterparty_country        char(2),
  counterparty_vat_number     text,
  vat_treatment               public.vat_treatment_enum NOT NULL DEFAULT 'UNKNOWN',
  input_vat_reclaimable_flag  boolean NOT NULL DEFAULT false,
  input_vat_reclaimable_amount numeric,
  output_vat_due_flag         boolean NOT NULL DEFAULT false,
  output_vat_due_amount       numeric,
  reverse_charge_relevant     boolean NOT NULL DEFAULT false,
  vies_relevant               boolean NOT NULL DEFAULT false,
  requires_contract           boolean NOT NULL DEFAULT false,
  requires_invoice            boolean NOT NULL DEFAULT false,
  requires_receipt            boolean NOT NULL DEFAULT false,
  requires_accountant_review  boolean NOT NULL DEFAULT false,
  accountant_review_reason    text,
  -- Versioning + status
  chart_mapping_version_id    uuid NOT NULL REFERENCES public.chart_of_accounts_mapping_versions(id),
  vat_rate_table_version      text,
  status                      public.ledger_entry_status_enum NOT NULL DEFAULT 'DRAFT',
  created_at                  timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_recomputed_at          timestamptz,
  -- Cross-currency fields
  entry_currency_original     text,
  entry_amount_original       numeric,
  -- VIES export fields
  vies_period                 text,
  vies_value_basis_eur        numeric,
  -- Plain-language explanation (Phase 09)
  vat_treatment_explanation   text,
  -- Manual-override fields
  manual_override_by          uuid REFERENCES public.users(id),
  manual_override_reason      text,
  manual_override_at          timestamptz,
  CONSTRAINT dle_debit_account_fk FOREIGN KEY (business_id, debit_account_code)
    REFERENCES public.chart_of_accounts (business_id, code) DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT dle_credit_account_fk FOREIGN KEY (business_id, credit_account_code)
    REFERENCES public.chart_of_accounts (business_id, code) DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT dle_exactly_one_side_chk
    CHECK ((debit_amount IS NOT NULL AND credit_amount IS NULL AND debit_account_code IS NOT NULL AND credit_account_code IS NULL)
        OR (credit_amount IS NOT NULL AND debit_amount IS NULL AND credit_account_code IS NOT NULL AND debit_account_code IS NULL)),
  CONSTRAINT dle_amounts_positive_chk
    CHECK ((debit_amount IS NULL OR debit_amount > 0) AND (credit_amount IS NULL OR credit_amount > 0)),
  CONSTRAINT dle_review_reason_when_flagged
    CHECK (NOT requires_accountant_review OR accountant_review_reason IS NOT NULL),
  CONSTRAINT dle_manual_override_triple_consistency
    CHECK ((manual_override_by IS NULL AND manual_override_reason IS NULL AND manual_override_at IS NULL)
        OR (manual_override_by IS NOT NULL AND manual_override_reason IS NOT NULL AND manual_override_at IS NOT NULL))
);
CREATE INDEX dle_business_period_idx ON public.draft_ledger_entries (business_id, entry_period);
CREATE INDEX dle_business_vat_idx    ON public.draft_ledger_entries (business_id, vat_treatment);
CREATE INDEX dle_business_review_idx ON public.draft_ledger_entries (business_id, requires_accountant_review)
  WHERE requires_accountant_review = true;
CREATE INDEX dle_parent_transaction_idx ON public.draft_ledger_entries (parent_transaction_id)
  WHERE parent_transaction_id IS NOT NULL;
CREATE INDEX dle_match_record_idx       ON public.draft_ledger_entries (match_record_id)
  WHERE match_record_id IS NOT NULL;

COMMENT ON TABLE public.draft_ledger_entries IS
  'Operational ledger row (B11·P01 canonical). One transaction can produce multiple PRIMARY rows (multi-line invoices, FX legs). LOCKED transitions are owned by Block 15.';


-- 6. Restore the review_issues FK ------------------------------------------

ALTER TABLE public.review_issues
  ADD CONSTRAINT review_issues_draft_ledger_entry_id_fkey
  FOREIGN KEY (draft_ledger_entry_id) REFERENCES public.draft_ledger_entries(id);


-- 7. Trigger: frozen mapping versions block mapping rule edits -------------

CREATE OR REPLACE FUNCTION public.coam_block_when_version_frozen()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_frozen_at timestamptz;
BEGIN
  SELECT frozen_at INTO v_frozen_at
    FROM public.chart_of_accounts_mapping_versions
   WHERE id = COALESCE(NEW.mapping_version_id, OLD.mapping_version_id);
  IF v_frozen_at IS NOT NULL THEN
    RAISE EXCEPTION 'MAPPING_VERSION_FROZEN' USING errcode='check_violation';
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER coam_block_when_version_frozen_trg
  BEFORE UPDATE OR DELETE ON public.chart_of_accounts_mappings
  FOR EACH ROW EXECUTE FUNCTION public.coam_block_when_version_frozen();


-- 8. RLS --------------------------------------------------------------------

ALTER TABLE public.chart_of_accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY coa_select ON public.chart_of_accounts FOR SELECT
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
CREATE POLICY coa_no_insert ON public.chart_of_accounts FOR INSERT WITH CHECK (false);
CREATE POLICY coa_no_update ON public.chart_of_accounts FOR UPDATE USING (false);
CREATE POLICY coa_no_delete ON public.chart_of_accounts FOR DELETE USING (false);

ALTER TABLE public.chart_of_accounts_mapping_versions ENABLE ROW LEVEL SECURITY;
CREATE POLICY coamv_select ON public.chart_of_accounts_mapping_versions FOR SELECT
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
CREATE POLICY coamv_no_insert ON public.chart_of_accounts_mapping_versions FOR INSERT WITH CHECK (false);
CREATE POLICY coamv_no_update ON public.chart_of_accounts_mapping_versions FOR UPDATE USING (false);
CREATE POLICY coamv_no_delete ON public.chart_of_accounts_mapping_versions FOR DELETE USING (false);

ALTER TABLE public.chart_of_accounts_mappings ENABLE ROW LEVEL SECURITY;
CREATE POLICY coam_select ON public.chart_of_accounts_mappings FOR SELECT
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
CREATE POLICY coam_no_insert ON public.chart_of_accounts_mappings FOR INSERT WITH CHECK (false);
CREATE POLICY coam_no_update ON public.chart_of_accounts_mappings FOR UPDATE USING (false);
CREATE POLICY coam_no_delete ON public.chart_of_accounts_mappings FOR DELETE USING (false);

ALTER TABLE public.draft_ledger_entries ENABLE ROW LEVEL SECURITY;
CREATE POLICY dle_select ON public.draft_ledger_entries FOR SELECT
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
CREATE POLICY dle_no_insert ON public.draft_ledger_entries FOR INSERT WITH CHECK (false);
CREATE POLICY dle_no_update ON public.draft_ledger_entries FOR UPDATE USING (false);
CREATE POLICY dle_no_delete ON public.draft_ledger_entries FOR DELETE USING (false);

COMMIT;
