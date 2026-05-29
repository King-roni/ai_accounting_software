-- B04·P03 Document & Matching Schema
-- ============================================================================
-- 2 tables: documents, match_records. 6 ENUMs covering source, document
-- type, extraction lifecycle, match level, match method, and the
-- per-pair match record status. Stage-1 rejection-memory rule (pair-
-- scoped, not global) is enforced by a partial UNIQUE on
-- (transaction_id, document_id) WHERE match_status != 'REJECTED_MATCH'.
--
-- RLS: type-b SELECT (org + business membership). All writes RESTRICTIVE-
-- denied from authenticated; Block 09 (intake) and Block 10 (matching)
-- own SECURITY DEFINER write paths.
-- ============================================================================

-- ---- ENUMs ---------------------------------------------------------------

CREATE TYPE public.document_source_enum AS ENUM (
  'EMAIL', 'DRIVE', 'MANUAL', 'INVOICE_GENERATOR'
);

CREATE TYPE public.document_type_enum AS ENUM (
  'INVOICE', 'RECEIPT', 'CONTRACT', 'PROOF_OF_PAYMENT', 'BANK_EVIDENCE',
  'STUB', 'OTHER'
);

CREATE TYPE public.document_extraction_status_enum AS ENUM (
  'DISCOVERED', 'INGESTED', 'EXTRACTED', 'LINKED_CANDIDATE',
  'MATCHED', 'DISMISSED'
);

CREATE TYPE public.match_level_enum AS ENUM (
  'EXACT', 'STRONG_PROBABLE', 'WEAK_POSSIBLE'
);

CREATE TYPE public.match_method_enum AS ENUM (
  'DETERMINISTIC_RULE', 'AI_FALLBACK'
);

CREATE TYPE public.match_record_status_enum AS ENUM (
  'MATCHED_CONFIRMED',
  'MATCHED_AUTO_HIGH_CONFIDENCE',
  'MATCHED_NEEDS_CONFIRMATION',
  'POSSIBLE_MATCH',
  'NO_MATCH',
  'REJECTED_MATCH'
);

-- ---- documents -----------------------------------------------------------

CREATE TABLE public.documents (
  id                              uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id                 uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  business_id                     uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,

  source                          public.document_source_enum NOT NULL,
  source_location                 text,
  file_id                         text,  -- nullable for STUB documents
  original_filename               text,
  document_hash                   text,
  document_type                   public.document_type_enum NOT NULL DEFAULT 'OTHER',

  -- Extracted invoice/receipt fields (denormalized; counterparty
  -- canonicalization lives in B11)
  supplier_name                   text,
  supplier_address                text,
  supplier_country                char(2),
  supplier_vat_number             text,
  invoice_number                  text,
  invoice_date                    date,
  due_date                        date,
  service_period_start            date,
  service_period_end              date,
  amount_subtotal                 numeric(20, 4),
  amount_total                    numeric(20, 4),
  currency                        char(3),
  vat_amount                      numeric(20, 4),
  vat_rate                        numeric(5, 2),
  payment_reference               text,
  client_name                     text,

  -- Multi-line invoice detail; B11 consolidation owns the shape.
  line_items                      jsonb NOT NULL DEFAULT '[]'::jsonb,

  -- Lifecycle + provenance
  extraction_status               public.document_extraction_status_enum NOT NULL DEFAULT 'DISCOVERED',
  extraction_confidence_per_field jsonb NOT NULL DEFAULT '{}'::jsonb,
  ocr_text_reference              text,
  discovery_reason                text,

  created_at                      timestamptz NOT NULL DEFAULT now(),
  updated_at                      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT documents_hash_format_chk CHECK (
    document_hash IS NULL OR document_hash ~ '^[0-9a-f]{64}$'
  ),
  CONSTRAINT documents_stub_no_file_chk CHECK (
    (document_type = 'STUB' AND file_id IS NULL)
    OR (document_type <> 'STUB')
  ),
  CONSTRAINT documents_service_period_chk CHECK (
    service_period_start IS NULL
    OR service_period_end IS NULL
    OR service_period_end >= service_period_start
  ),
  CONSTRAINT documents_amount_total_positive_chk CHECK (
    amount_total IS NULL OR amount_total >= 0
  ),
  CONSTRAINT documents_vat_rate_chk CHECK (
    vat_rate IS NULL OR (vat_rate >= 0 AND vat_rate <= 100)
  )
);

CREATE INDEX idx_documents_business_supplier_vat
  ON public.documents (business_id, supplier_vat_number)
  WHERE supplier_vat_number IS NOT NULL;

CREATE INDEX idx_documents_business_invoice_date
  ON public.documents (business_id, invoice_date)
  WHERE invoice_date IS NOT NULL;

CREATE INDEX idx_documents_hash_global
  ON public.documents (document_hash)
  WHERE document_hash IS NOT NULL;

CREATE INDEX idx_documents_business_hash
  ON public.documents (business_id, document_hash)
  WHERE document_hash IS NOT NULL;

CREATE INDEX idx_documents_business_extraction_status
  ON public.documents (business_id, extraction_status);

CREATE TRIGGER documents_set_updated_at
  BEFORE UPDATE ON public.documents
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.documents FORCE  ROW LEVEL SECURITY;

CREATE POLICY documents_select ON public.documents
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    AND business_id = ANY(public.current_user_businesses())
  );
CREATE POLICY documents_no_insert ON public.documents
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY documents_no_update ON public.documents
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY documents_no_delete ON public.documents
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ---- match_records --------------------------------------------------------

CREATE TABLE public.match_records (
  id                          uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id             uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  business_id                 uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,

  transaction_id              uuid NOT NULL REFERENCES public.transactions(id) ON DELETE CASCADE,
  document_id                 uuid NOT NULL REFERENCES public.documents(id) ON DELETE CASCADE,

  match_level                 public.match_level_enum NOT NULL,
  match_method                public.match_method_enum NOT NULL,
  match_score                 numeric(6, 4) NOT NULL,
  match_signals               jsonb NOT NULL DEFAULT '{}'::jsonb,
  match_reason_plain_language text,

  match_status                public.match_record_status_enum NOT NULL DEFAULT 'POSSIBLE_MATCH',

  split_payment_flag          boolean NOT NULL DEFAULT false,
  split_payment_group_id      uuid,

  matched_by_user_id          uuid REFERENCES public.users(id),
  matched_by_system           text,

  requires_user_confirmation  boolean NOT NULL DEFAULT false,
  user_confirmation_status    text,
  confirmed_by                uuid REFERENCES public.users(id),
  confirmed_at                timestamptz,

  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT match_records_score_range_chk CHECK (
    match_score >= 0 AND match_score <= 1
  ),
  CONSTRAINT match_records_matched_by_exclusive_chk CHECK (
    (matched_by_user_id IS NOT NULL AND matched_by_system IS NULL)
    OR (matched_by_user_id IS NULL AND matched_by_system IS NOT NULL)
  ),
  CONSTRAINT match_records_split_payment_group_requires_flag_chk CHECK (
    (split_payment_group_id IS NULL)
    OR (split_payment_flag = true)
  ),
  CONSTRAINT match_records_confirmed_consistency_chk CHECK (
    (confirmed_by IS NULL AND confirmed_at IS NULL)
    OR (confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL)
  )
);

-- Stage-1 rejection-memory rule: at most one NON-rejected match row per
-- (transaction, document) pair; REJECTED_MATCH rows can stack as history.
CREATE UNIQUE INDEX idx_match_records_unique_active_pair
  ON public.match_records (transaction_id, document_id)
  WHERE match_status <> 'REJECTED_MATCH';

CREATE INDEX idx_match_records_transaction
  ON public.match_records (transaction_id);

CREATE INDEX idx_match_records_document
  ON public.match_records (document_id);

CREATE INDEX idx_match_records_business_status
  ON public.match_records (business_id, match_status);

CREATE INDEX idx_match_records_split_group
  ON public.match_records (split_payment_group_id)
  WHERE split_payment_group_id IS NOT NULL;

CREATE TRIGGER match_records_set_updated_at
  BEFORE UPDATE ON public.match_records
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.match_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.match_records FORCE  ROW LEVEL SECURITY;

CREATE POLICY match_records_select ON public.match_records
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    AND business_id = ANY(public.current_user_businesses())
  );
CREATE POLICY match_records_no_insert ON public.match_records
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY match_records_no_update ON public.match_records
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY match_records_no_delete ON public.match_records
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

COMMENT ON TABLE public.documents IS
'B04·P03: invoices, receipts, contracts, etc. Source provenance + extracted fields + line_items jsonb consumed by B11. Direct writes blocked from authenticated; B09 ingest + extraction tools write via service role.';
COMMENT ON TABLE public.match_records IS
'B04·P03: per-pair transaction↔document match. Stage-1 rejection memory enforced via partial UNIQUE: one non-rejected row per pair, REJECTED_MATCH stacks as history. Direct writes blocked from authenticated; B10 matching engine writes via service role.';
