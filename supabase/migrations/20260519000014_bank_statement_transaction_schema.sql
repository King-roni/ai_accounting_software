-- B04·P02 Bank Statement & Transaction Schema
-- ============================================================================
-- Three tables: statement_uploads, transactions, evidence_pdfs.
-- 9 ENUMs covering the transaction lifecycle (type, direction, dedup,
-- classification, match, ledger, review, upload status, file format).
--
-- RLS: type-b template (org + business membership) for SELECT. All write
-- operations are RESTRICTIVE-denied from `authenticated` — per the block
-- doc's "Workflow-First" rule, writes happen through Block 03's tool
-- invocations running in service-role context, never via direct user
-- INSERT. SECURITY DEFINER RPCs land alongside Block 03/07 phases.
-- ============================================================================

-- ---- ENUMs ----------------------------------------------------------------

CREATE TYPE public.transaction_type_enum AS ENUM (
  'OUT_EXPENSE',
  'IN_INCOME',
  'INTERNAL_TRANSFER',
  'FX_EXCHANGE',
  'BANK_FEE',
  'REFUND_IN',
  'REFUND_OUT',
  'CHARGEBACK',
  'LOAN_OR_SHAREHOLDER_MOVEMENT',
  'PAYROLL_OR_TEAM_PAYMENT',
  'TAX_PAYMENT',
  'UNKNOWN'
);

CREATE TYPE public.transaction_direction_enum AS ENUM ('IN', 'OUT', 'BOTH');

CREATE TYPE public.statement_file_format_enum AS ENUM ('CSV', 'PDF');

CREATE TYPE public.statement_upload_status_enum AS ENUM (
  'UPLOADED', 'PARSING', 'PARSED', 'FAILED', 'ACCEPTED'
);

CREATE TYPE public.transaction_dedup_status_enum AS ENUM (
  'NEW', 'DUPLICATE_EXACT', 'DUPLICATE_PROBABLE', 'NEEDS_REVIEW'
);

CREATE TYPE public.transaction_classification_status_enum AS ENUM (
  'PENDING', 'NEEDS_CONFIRMATION', 'CONFIRMED', 'FAILED'
);

-- Denormalised per-transaction match state (distinct from match_records'
-- per-pair status). Per Block 12 Phase 06.
CREATE TYPE public.transaction_match_status_enum AS ENUM (
  'UNMATCHED',
  'MATCHED_PROPOSED',
  'MATCHED_CONFIRMED',
  'MATCHED_AUTO_CONFIRMED',
  'NO_MATCH_REQUIRED',
  'EXCEPTION_DOCUMENTED'
);

CREATE TYPE public.transaction_ledger_status_enum AS ENUM (
  'NOT_APPLICABLE', 'PENDING', 'PREPARED', 'FINALIZED'
);

CREATE TYPE public.transaction_review_status_enum AS ENUM (
  'NONE', 'NEEDS_REVIEW', 'IN_REVIEW', 'RESOLVED'
);

-- ---- statement_uploads ----------------------------------------------------

CREATE TABLE public.statement_uploads (
  id                          uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id             uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  business_id                 uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,
  bank_account_id             uuid NOT NULL REFERENCES public.bank_accounts(id) ON DELETE RESTRICT,

  file_id                     text NOT NULL,
  file_format                 public.statement_file_format_enum NOT NULL,
  provider                    text NOT NULL,

  original_filename           text NOT NULL,
  file_hash                   text NOT NULL,

  statement_period_start      date,
  statement_period_end        date,
  declared_period_start       date NOT NULL,
  declared_period_end         date NOT NULL,

  upload_status               public.statement_upload_status_enum NOT NULL DEFAULT 'UPLOADED',
  parse_warnings              jsonb NOT NULL DEFAULT '[]'::jsonb,

  uploaded_by                 uuid NOT NULL REFERENCES public.users(id),
  uploaded_at                 timestamptz NOT NULL DEFAULT now(),
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT statement_uploads_declared_period_chk
    CHECK (declared_period_end >= declared_period_start),
  CONSTRAINT statement_uploads_observed_period_chk
    CHECK (
      statement_period_start IS NULL
      OR statement_period_end IS NULL
      OR statement_period_end >= statement_period_start
    ),
  CONSTRAINT statement_uploads_file_hash_format_chk
    CHECK (file_hash ~ '^[0-9a-f]{64}$')
);

CREATE INDEX idx_statement_uploads_business_account_period
  ON public.statement_uploads (business_id, bank_account_id, statement_period_start);
CREATE INDEX idx_statement_uploads_file_hash
  ON public.statement_uploads (business_id, file_hash);

CREATE TRIGGER statement_uploads_set_updated_at
  BEFORE UPDATE ON public.statement_uploads
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.statement_uploads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.statement_uploads FORCE  ROW LEVEL SECURITY;

CREATE POLICY statement_uploads_select ON public.statement_uploads
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    AND business_id = ANY(public.current_user_businesses())
  );
CREATE POLICY statement_uploads_no_insert ON public.statement_uploads
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY statement_uploads_no_update ON public.statement_uploads
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY statement_uploads_no_delete ON public.statement_uploads
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ---- transactions ---------------------------------------------------------

CREATE TABLE public.transactions (
  id                              uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id                 uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  business_id                     uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,
  bank_account_id                 uuid NOT NULL REFERENCES public.bank_accounts(id) ON DELETE RESTRICT,
  statement_upload_id             uuid NOT NULL REFERENCES public.statement_uploads(id) ON DELETE CASCADE,

  -- B07 dedup keys (computed via Phase-01 helpers)
  source_row_index                integer NOT NULL,
  source_row_hash                 text NOT NULL,
  transaction_fingerprint         text NOT NULL,

  -- Monetary fields
  transaction_date                date NOT NULL,
  booking_date                    date,
  amount                          numeric(20, 4) NOT NULL,
  currency                        char(3) NOT NULL,
  direction                       public.transaction_direction_enum NOT NULL,

  -- Classification
  transaction_type                public.transaction_type_enum NOT NULL DEFAULT 'UNKNOWN',

  -- Descriptions
  raw_description                 text,
  raw_description_encrypted       bytea,
  normalized_description          text,

  -- Counterparty
  counterparty_name               text,
  counterparty_country            char(2),
  counterparty_identifier_masked  text,
  counterparty_identifier_encrypted bytea,

  -- Bank metadata
  reference                       text,
  bank_category_original          text,

  -- Tags
  system_tag                      text,
  user_tag                        text,
  secondary_tags                  jsonb NOT NULL DEFAULT '[]'::jsonb,

  -- Lifecycle status columns
  classification_status           public.transaction_classification_status_enum NOT NULL DEFAULT 'PENDING',
  classification_confidence       numeric(5, 4),
  match_status                    public.transaction_match_status_enum NOT NULL DEFAULT 'UNMATCHED',
  ledger_status                   public.transaction_ledger_status_enum NOT NULL DEFAULT 'PENDING',
  review_status                   public.transaction_review_status_enum NOT NULL DEFAULT 'NONE',

  -- FX paired-legs structured payload (B11)
  fx_paired_legs                  jsonb,

  -- Dedup
  dedup_status                    public.transaction_dedup_status_enum NOT NULL DEFAULT 'NEW',

  created_at                      timestamptz NOT NULL DEFAULT now(),
  updated_at                      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT transactions_amount_nonzero_chk CHECK (amount <> 0),
  CONSTRAINT transactions_amount_direction_chk CHECK (
    (direction = 'IN'   AND amount > 0)
    OR (direction = 'OUT' AND amount < 0)
    OR (direction = 'BOTH')
  ),
  CONSTRAINT transactions_source_row_hash_format_chk
    CHECK (source_row_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT transactions_fingerprint_format_chk
    CHECK (transaction_fingerprint ~ '^[0-9a-f]{64}$'),
  CONSTRAINT transactions_confidence_range_chk
    CHECK (classification_confidence IS NULL
           OR (classification_confidence >= 0 AND classification_confidence <= 1)),
  CONSTRAINT transactions_fx_legs_for_fx_only_chk CHECK (
    (transaction_type = 'FX_EXCHANGE') = (fx_paired_legs IS NOT NULL)
  )
);

CREATE INDEX idx_transactions_business_date
  ON public.transactions (business_id, transaction_date);
CREATE INDEX idx_transactions_statement_upload_row_hash
  ON public.transactions (statement_upload_id, source_row_hash);
CREATE INDEX idx_transactions_business_fingerprint
  ON public.transactions (business_id, transaction_fingerprint);
CREATE INDEX idx_transactions_workflow_filters
  ON public.transactions (business_id, transaction_type, classification_status, match_status);
CREATE INDEX idx_transactions_review_queue
  ON public.transactions (business_id, review_status, transaction_date)
  WHERE review_status <> 'NONE';

CREATE TRIGGER transactions_set_updated_at
  BEFORE UPDATE ON public.transactions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transactions FORCE  ROW LEVEL SECURITY;

CREATE POLICY transactions_select ON public.transactions
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    AND business_id = ANY(public.current_user_businesses())
  );
CREATE POLICY transactions_no_insert ON public.transactions
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY transactions_no_update ON public.transactions
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY transactions_no_delete ON public.transactions
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ---- evidence_pdfs --------------------------------------------------------

CREATE TABLE public.evidence_pdfs (
  id                                    uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id                       uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  business_id                           uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,
  transaction_id                        uuid NOT NULL REFERENCES public.transactions(id) ON DELETE CASCADE,

  file_id                               text NOT NULL,
  file_hash                             text NOT NULL,

  generated_from_transaction_version    bigint NOT NULL,

  generated_at                          timestamptz NOT NULL DEFAULT now(),
  created_at                            timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT evidence_pdfs_file_hash_format_chk
    CHECK (file_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT evidence_pdfs_transaction_file_hash_unique
    UNIQUE (transaction_id, file_hash)
);

CREATE INDEX idx_evidence_pdfs_transaction
  ON public.evidence_pdfs (transaction_id);

ALTER TABLE public.evidence_pdfs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.evidence_pdfs FORCE  ROW LEVEL SECURITY;

CREATE POLICY evidence_pdfs_select ON public.evidence_pdfs
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    organization_id = public.current_org()
    AND business_id = ANY(public.current_user_businesses())
  );
CREATE POLICY evidence_pdfs_no_insert ON public.evidence_pdfs
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY evidence_pdfs_no_update ON public.evidence_pdfs
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY evidence_pdfs_no_delete ON public.evidence_pdfs
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

COMMENT ON TABLE public.statement_uploads IS
'B04·P02: raw bank-statement upload row. file_hash links to the Raw Upload zone (B04·P05). Direct writes blocked from authenticated; Block 03 / Block 07 tools insert via service role.';
COMMENT ON TABLE public.transactions IS
'B04·P02: normalized bank-account transactions. source_row_hash + transaction_fingerprint feed the B07 dedup engine. Direct writes blocked from authenticated.';
COMMENT ON TABLE public.evidence_pdfs IS
'B04·P02: generated evidence PDFs per transaction. file_hash unique within a transaction. Direct writes blocked from authenticated; Block 03 generation tool writes via service role.';
