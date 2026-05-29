-- B11·P01 follow-up — chart_of_accounts FKs from mappings and
-- draft_ledger_entries were DEFERRABLE INITIALLY DEFERRED. That makes
-- delete-while-referenced appear to succeed until commit, which broke the
-- B11·P01 lifecycle test's "FK blocks delete" assertion. Recreate as
-- immediate (default). The self-ref parent_code FK on chart_of_accounts
-- stays DEFERRABLE for hierarchical insert flexibility.

BEGIN;

ALTER TABLE public.chart_of_accounts_mappings DROP CONSTRAINT coam_account_fk;
ALTER TABLE public.chart_of_accounts_mappings
  ADD CONSTRAINT coam_account_fk FOREIGN KEY (business_id, account_code)
  REFERENCES public.chart_of_accounts (business_id, code);

ALTER TABLE public.draft_ledger_entries DROP CONSTRAINT dle_debit_account_fk;
ALTER TABLE public.draft_ledger_entries
  ADD CONSTRAINT dle_debit_account_fk FOREIGN KEY (business_id, debit_account_code)
  REFERENCES public.chart_of_accounts (business_id, code);

ALTER TABLE public.draft_ledger_entries DROP CONSTRAINT dle_credit_account_fk;
ALTER TABLE public.draft_ledger_entries
  ADD CONSTRAINT dle_credit_account_fk FOREIGN KEY (business_id, credit_account_code)
  REFERENCES public.chart_of_accounts (business_id, code);

COMMIT;
