-- B04·P02 follow-up: add FK-covering indexes for the new tables. The
-- audit-only audit-column FKs (uploaded_by, etc.) stay unindexed because
-- they're rarely queried; the indexes below cover the FKs that gate
-- cascade-delete + business-level browse queries, plus two single-column
-- indexes the phase spec calls for verbatim.

CREATE INDEX IF NOT EXISTS idx_statement_uploads_bank_account
  ON public.statement_uploads (bank_account_id);

CREATE INDEX IF NOT EXISTS idx_transactions_bank_account
  ON public.transactions (bank_account_id);

CREATE INDEX IF NOT EXISTS idx_evidence_pdfs_business
  ON public.evidence_pdfs (business_id);

CREATE INDEX IF NOT EXISTS idx_transactions_fingerprint_global
  ON public.transactions (transaction_fingerprint);

CREATE INDEX IF NOT EXISTS idx_statement_uploads_file_hash_global
  ON public.statement_uploads (file_hash);
