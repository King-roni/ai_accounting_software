-- B04·P04 Ledger & Review Schema
-- ============================================================================
-- Three tables:
--   1. workflow_runs — MINIMAL stub so B04·P04 FKs are real. Block 03·P01
--      will extend this with phase_state, status ENUM, principal_snapshot
--      (already a jsonb column here, populated by B02·P09 snapshotter),
--      timestamps for each run-status transition, etc.
--   2. draft_ledger_entries — Block 11 writes here; additive-only
--      adjustments enforced via all-null-or-all-populated CHECK on
--      adjustment_* columns.
--   3. review_issues — every issue-producing block (06, 07, 08, 10, 11,
--      13) targets this table; B14 consumes it. issue_group enum strictly
--      the 5 actionable buckets — "Ready to Finalize" is a queue-state
--      projection, not a row value (per B14·P02 H8 fix).
-- ============================================================================

-- ---- workflow_runs stub --------------------------------------------------
-- Block 03 P01 owns the canonical schema; this stub gives B04 a real FK
-- target. The principal_snapshot column matches B02·P09's contract.

CREATE TYPE public.workflow_run_status_stub_enum AS ENUM (
  'CREATED', 'RUNNING', 'PAUSED', 'REVIEW_HOLD', 'AWAITING_APPROVAL',
  'FINALIZING', 'FINALIZED', 'FAILED', 'CANCELLED', 'COMPENSATING'
);

CREATE TABLE public.workflow_runs (
  id                    uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id       uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  business_id           uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,
  run_type              text NOT NULL,           -- placeholder; B03 will tighten to ENUM
  status                public.workflow_run_status_stub_enum NOT NULL DEFAULT 'CREATED',
  principal_snapshot    jsonb NOT NULL,          -- B02·P09 contract
  started_at            timestamptz,
  finalized_at          timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_workflow_runs_business_status ON public.workflow_runs (business_id, status);
CREATE TRIGGER workflow_runs_set_updated_at BEFORE UPDATE ON public.workflow_runs
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
ALTER TABLE public.workflow_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workflow_runs FORCE  ROW LEVEL SECURITY;
CREATE POLICY workflow_runs_select ON public.workflow_runs
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (organization_id = public.current_org() AND business_id = ANY(public.current_user_businesses()));
CREATE POLICY workflow_runs_no_insert ON public.workflow_runs
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY workflow_runs_no_update ON public.workflow_runs
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY workflow_runs_no_delete ON public.workflow_runs
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

COMMENT ON TABLE public.workflow_runs IS
'B04·P04 MINIMAL STUB. Block 03 Phase 01 owns the canonical schema; this stub gives B04 a real FK target. Extends in B03·P01+ with phase_state, run_type ENUM, timestamps per status transition, etc.';

-- ---- ENUMs (ledger + review) ---------------------------------------------

CREATE TYPE public.ledger_entry_type_enum AS ENUM ('DEBIT', 'CREDIT');

CREATE TYPE public.vat_treatment_enum AS ENUM (
  'DOMESTIC_STANDARD',
  'DOMESTIC_REDUCED',
  'DOMESTIC_ZERO',
  'EU_REVERSE_CHARGE',
  'IMPORT_OR_ACQUISITION',
  'NON_EU_SERVICE',
  'OUTSIDE_SCOPE',
  'UNKNOWN'
);

CREATE TYPE public.ledger_approval_status_enum AS ENUM ('DRAFT', 'APPROVED', 'LOCKED');

-- Strictly the 5 actionable buckets per B14·P02 H8 fix.
-- "Ready to Finalize" is a queue-state projection, NOT a row value.
CREATE TYPE public.review_issue_group_enum AS ENUM (
  'MISSING_DOCUMENTS',
  'NEEDS_CONFIRMATION',
  'POSSIBLE_WRONG_MATCH',
  'POSSIBLE_TAX_VAT_ISSUE',
  'UNUSUAL_TRANSACTION'
);

-- No CRITICAL per the 2026-05-08 amendment.
CREATE TYPE public.review_issue_severity_enum AS ENUM (
  'LOW', 'MEDIUM', 'HIGH', 'BLOCKING'
);

CREATE TYPE public.review_issue_card_content_tier_enum AS ENUM (
  'NONE', 'TIER_2_LOCAL_LLM', 'TIER_3_EXTERNAL_LLM'
);

CREATE TYPE public.review_issue_status_enum AS ENUM (
  'OPEN', 'RESOLVED', 'SNOOZED', 'DISMISSED', 'AUTO_RESOLVED_BY_RESCAN'
);

-- ---- draft_ledger_entries -------------------------------------------------

CREATE TABLE public.draft_ledger_entries (
  id                              uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id                 uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  business_id                     uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,

  workflow_run_id                 uuid NOT NULL REFERENCES public.workflow_runs(id) ON DELETE CASCADE,
  transaction_id                  uuid NOT NULL REFERENCES public.transactions(id) ON DELETE CASCADE,
  match_record_id                 uuid REFERENCES public.match_records(id) ON DELETE SET NULL,

  entry_type                      public.ledger_entry_type_enum NOT NULL,
  account_code                    text NOT NULL,
  account_name                    text NOT NULL,
  chart_of_accounts_version       text NOT NULL,

  debit_amount                    numeric(20, 4),
  credit_amount                   numeric(20, 4),
  currency                        char(3) NOT NULL,

  vat_treatment                   public.vat_treatment_enum NOT NULL DEFAULT 'UNKNOWN',
  input_vat_reclaimable           boolean NOT NULL DEFAULT false,
  output_vat_due                  boolean NOT NULL DEFAULT false,
  reverse_charge_relevant         boolean NOT NULL DEFAULT false,
  vies_relevant                   boolean NOT NULL DEFAULT false,
  vat_amount                      numeric(20, 4),

  requires_invoice                boolean NOT NULL DEFAULT false,
  requires_receipt                boolean NOT NULL DEFAULT false,
  requires_contract               boolean NOT NULL DEFAULT false,
  requires_accountant_review      boolean NOT NULL DEFAULT false,
  accountant_review_reason        text,

  counterparty_country            char(2),
  counterparty_vat_number         text,

  consolidated_from_line_count    integer NOT NULL DEFAULT 1,
  non_deductible_subaccount       text,

  approval_status                 public.ledger_approval_status_enum NOT NULL DEFAULT 'DRAFT',

  -- Adjustment-run fields (additive-only per Stage 1)
  parent_finalized_run_id         uuid REFERENCES public.workflow_runs(id) ON DELETE SET NULL,
  adjustment_reason               text,
  adjustment_delta                jsonb,

  created_at                      timestamptz NOT NULL DEFAULT now(),
  updated_at                      timestamptz NOT NULL DEFAULT now(),

  -- Exactly one of debit_amount / credit_amount populated, > 0, matching entry_type.
  CONSTRAINT draft_ledger_entry_amount_exclusive_chk CHECK (
    (entry_type = 'DEBIT'  AND debit_amount  IS NOT NULL AND debit_amount  > 0 AND credit_amount IS NULL)
    OR
    (entry_type = 'CREDIT' AND credit_amount IS NOT NULL AND credit_amount > 0 AND debit_amount  IS NULL)
  ),
  CONSTRAINT draft_ledger_entry_vat_amount_chk CHECK (
    vat_amount IS NULL OR vat_amount >= 0
  ),
  CONSTRAINT draft_ledger_entry_consolidated_count_chk CHECK (
    consolidated_from_line_count >= 1
  ),
  CONSTRAINT draft_ledger_entry_review_reason_chk CHECK (
    requires_accountant_review = false
    OR (accountant_review_reason IS NOT NULL AND length(trim(accountant_review_reason)) > 0)
  ),
  -- Stage 1 additive-only: adjustment columns all-null or all-populated.
  CONSTRAINT draft_ledger_entry_adjustment_all_or_none_chk CHECK (
    (parent_finalized_run_id IS NULL AND adjustment_reason IS NULL AND adjustment_delta IS NULL)
    OR
    (parent_finalized_run_id IS NOT NULL AND adjustment_reason IS NOT NULL AND adjustment_delta IS NOT NULL)
  )
);

CREATE INDEX idx_draft_ledger_entries_run
  ON public.draft_ledger_entries (workflow_run_id);
CREATE INDEX idx_draft_ledger_entries_business_account
  ON public.draft_ledger_entries (business_id, account_code);
CREATE INDEX idx_draft_ledger_entries_parent_run
  ON public.draft_ledger_entries (parent_finalized_run_id)
  WHERE parent_finalized_run_id IS NOT NULL;
CREATE INDEX idx_draft_ledger_entries_transaction
  ON public.draft_ledger_entries (transaction_id);

CREATE TRIGGER draft_ledger_entries_set_updated_at BEFORE UPDATE ON public.draft_ledger_entries
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.draft_ledger_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.draft_ledger_entries FORCE  ROW LEVEL SECURITY;
CREATE POLICY draft_ledger_entries_select ON public.draft_ledger_entries
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (organization_id = public.current_org() AND business_id = ANY(public.current_user_businesses()));
CREATE POLICY draft_ledger_entries_no_insert ON public.draft_ledger_entries
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY draft_ledger_entries_no_update ON public.draft_ledger_entries
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY draft_ledger_entries_no_delete ON public.draft_ledger_entries
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

-- ---- review_issues --------------------------------------------------------

CREATE TABLE public.review_issues (
  id                                  uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id                     uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  business_id                         uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,

  workflow_run_id                     uuid NOT NULL REFERENCES public.workflow_runs(id) ON DELETE CASCADE,
  transaction_id                      uuid REFERENCES public.transactions(id) ON DELETE CASCADE,
  document_id                         uuid REFERENCES public.documents(id) ON DELETE CASCADE,
  match_record_id                     uuid REFERENCES public.match_records(id) ON DELETE CASCADE,
  draft_ledger_entry_id               uuid REFERENCES public.draft_ledger_entries(id) ON DELETE CASCADE,

  issue_type                          text NOT NULL,    -- internal taxonomy string owned by producing block
  issue_group                         public.review_issue_group_enum NOT NULL,
  severity                            public.review_issue_severity_enum NOT NULL,

  plain_language_title                text NOT NULL,
  plain_language_description          text NOT NULL,
  recommended_action                  text,

  -- Card-content metadata (B14·P03 frozen-card-content rule)
  card_payload_json                   jsonb NOT NULL DEFAULT '{}'::jsonb,
  card_content_generated_at           timestamptz,
  card_content_tier_used              public.review_issue_card_content_tier_enum NOT NULL DEFAULT 'NONE',
  card_content_fallback_applied       boolean NOT NULL DEFAULT false,

  status                              public.review_issue_status_enum NOT NULL DEFAULT 'OPEN',
  resolution_action                   text,   -- B14 will refine to ENUM (13 values)
  resolution_note                     text,

  assigned_to                         uuid REFERENCES public.users(id) ON DELETE SET NULL,
  assigned_by                         uuid REFERENCES public.users(id) ON DELETE SET NULL,
  assigned_at                         timestamptz,
  assignment_notification_sent_at     timestamptz,

  snoozed_at                          timestamptz,
  snoozed_by                          uuid REFERENCES public.users(id) ON DELETE SET NULL,
  snoozed_until                       timestamptz,
  snooze_reason                       text,

  auto_resolution_trigger_issue_id    uuid REFERENCES public.review_issues(id) ON DELETE SET NULL,

  resolved_by                         uuid REFERENCES public.users(id) ON DELETE SET NULL,
  resolved_at                         timestamptz,

  created_at                          timestamptz NOT NULL DEFAULT now(),
  updated_at                          timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT review_issue_at_least_one_entity_chk CHECK (
    transaction_id IS NOT NULL
    OR document_id IS NOT NULL
    OR match_record_id IS NOT NULL
    OR draft_ledger_entry_id IS NOT NULL
  ),
  CONSTRAINT review_issue_snooze_fields_chk CHECK (
    -- SNOOZED status requires snooze_reason + snoozed_at + snoozed_by populated.
    (status <> 'SNOOZED')
    OR (
      snoozed_at IS NOT NULL
      AND snoozed_by IS NOT NULL
      AND snooze_reason IS NOT NULL
      AND length(trim(snooze_reason)) > 0
    )
  ),
  CONSTRAINT review_issue_resolved_consistency_chk CHECK (
    (status NOT IN ('RESOLVED', 'AUTO_RESOLVED_BY_RESCAN'))
    OR (resolved_at IS NOT NULL)
  ),
  CONSTRAINT review_issue_auto_resolved_trigger_chk CHECK (
    (status <> 'AUTO_RESOLVED_BY_RESCAN')
    OR (auto_resolution_trigger_issue_id IS NOT NULL)
  ),
  CONSTRAINT review_issue_assignment_consistency_chk CHECK (
    (assigned_to IS NULL AND assigned_by IS NULL AND assigned_at IS NULL)
    OR (assigned_to IS NOT NULL AND assigned_by IS NOT NULL AND assigned_at IS NOT NULL)
  )
);

CREATE INDEX idx_review_issues_run_status
  ON public.review_issues (workflow_run_id, status);
CREATE INDEX idx_review_issues_business_severity_status
  ON public.review_issues (business_id, severity, status);
CREATE INDEX idx_review_issues_assigned_to_status
  ON public.review_issues (assigned_to, status)
  WHERE assigned_to IS NOT NULL;
CREATE INDEX idx_review_issues_transaction
  ON public.review_issues (transaction_id)
  WHERE transaction_id IS NOT NULL;
CREATE INDEX idx_review_issues_document
  ON public.review_issues (document_id)
  WHERE document_id IS NOT NULL;
CREATE INDEX idx_review_issues_open_per_business
  ON public.review_issues (business_id, severity)
  WHERE status = 'OPEN';

CREATE TRIGGER review_issues_set_updated_at BEFORE UPDATE ON public.review_issues
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.review_issues ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.review_issues FORCE  ROW LEVEL SECURITY;
CREATE POLICY review_issues_select ON public.review_issues
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (organization_id = public.current_org() AND business_id = ANY(public.current_user_businesses()));
CREATE POLICY review_issues_no_insert ON public.review_issues
  AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY review_issues_no_update ON public.review_issues
  AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY review_issues_no_delete ON public.review_issues
  AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

COMMENT ON TABLE public.draft_ledger_entries IS
'B04·P04: B11 writes here. Additive-only adjustments: adjustment_* columns are all-null or all-populated. Direct writes blocked from authenticated; B11 service-role tools own writes.';
COMMENT ON TABLE public.review_issues IS
'B04·P04: review queue backing table. issue_group is strictly the 5 actionable buckets; "Ready to Finalize" is a queue projection. Direct writes blocked from authenticated; producing blocks (06, 07, 08, 10, 11, 13) write via service role; B14 mutates via service-role action handlers.';
