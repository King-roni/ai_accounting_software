-- =============================================================================
-- Demo dataset seed — "Demo Trading Ltd" (R7.9)
-- =============================================================================
-- Captures the previously ad-hoc demo seed as code and extends it to a realistic
-- multi-period dataset so the full journey + analytics time-series are
-- exercisable end-to-end.
--
-- Idempotent: deterministic IDs + ON CONFLICT DO NOTHING, so it can be re-run
-- safely (re-running restores the baseline). Reversible via
-- scripts/reset_demo_dataset.sql. Run with the service_role connection (bypasses
-- RLS), e.g. via the Supabase SQL editor / psql against the project.
--
-- Fixed identities (seeded earlier):
--   org   0e000000-0000-4000-8000-000000000001
--   biz   0e000000-0000-4000-8000-0000000000b1  (Demo Trading Ltd)
--   bank  0e000000-0000-4000-8000-0000000000a1
--   owner 019e751a-0eda-7c6e-9c79-7e2c4ea9bff7  (admin@admin.com)
--   May-2026 upload 0e000000-0000-4000-8000-0000000000c1 (+ 6 transactions)
--
-- This script adds Feb/Mar/Apr 2026 statements + transactions, two draft
-- invoices, three discovered documents, and clears the c1 "stuck UPLOADED"
-- hazard. All R7.9 rows are tagged for clean teardown:
--   statement_uploads.file_id  LIKE 'seed-r79-%'
--   invoices.invoice_number     LIKE 'INV-DEMO-79%'  (kept DRAFT so deletable)
--   documents.invoice_number    LIKE 'SEED-R79-%'
-- =============================================================================

DO $$
DECLARE
  v_org    uuid := '0e000000-0000-4000-8000-000000000001';
  v_biz    uuid := '0e000000-0000-4000-8000-0000000000b1';
  v_bank   uuid := '0e000000-0000-4000-8000-0000000000a1';
  v_user   uuid := '019e751a-0eda-7c6e-9c79-7e2c4ea9bff7';
  v_client uuid := '019e758a-d363-7ee1-8394-3df37a838dee';
  v_months date[] := ARRAY['2026-02-01','2026-03-01','2026-04-01']::date[];
  v_m       date;
  v_mm      text;
  v_pstart  date;
  v_pend    date;
  v_upl     uuid;
  v_txid    uuid;
  i         int;
  v_row     jsonb;
  -- 6 transactions per month: 3 expenses (OUT, signed negative) + 3 income (IN).
  v_tpl jsonb := '[
    {"dir":"OUT","amt":-42.50,  "cp":"Costa Coffee",            "desc":"Card payment — coffee"},
    {"dir":"OUT","amt":-213.77, "cp":"Amazon Web Services EMEA","desc":"AWS monthly hosting"},
    {"dir":"OUT","amt":-1250.00,"cp":"Nicosia Office Rentals",   "desc":"Office rent"},
    {"dir":"IN", "amt":1800.00, "cp":"Acme Corp",               "desc":"Client payment"},
    {"dir":"IN", "amt":3570.00, "cp":"Olympus Trading Ltd",     "desc":"Invoice settlement"},
    {"dir":"IN", "amt":640.00,  "cp":"Aphrodite Holdings Ltd",  "desc":"Consulting fee"}
  ]'::jsonb;
BEGIN
  -- 0. Clear the c1 stuck-UPLOADED hazard. c1 already has its 6 transactions
  --    directly seeded with no real bytes in raw-uploads, so a continuous parse
  --    worker would poll it forever. Mark it terminal (ACCEPTED = ingested).
  UPDATE public.statement_uploads
     SET upload_status = 'ACCEPTED', updated_at = clock_timestamp()
   WHERE id = '0e000000-0000-4000-8000-0000000000c1'
     AND upload_status = 'UPLOADED';

  -- 1. One statement upload + 6 transactions per prior month.
  FOREACH v_m IN ARRAY v_months LOOP
    v_mm     := to_char(v_m, 'YYYY-MM');
    v_pstart := v_m;
    v_pend   := (date_trunc('month', v_m) + interval '1 month - 1 day')::date;
    v_upl    := md5('seed-r79-upl-' || v_mm)::uuid;

    INSERT INTO public.statement_uploads (
      id, organization_id, business_id, bank_account_id,
      file_id, file_format, provider, original_filename, file_hash,
      declared_period_start, declared_period_end, upload_status,
      parse_warnings, uploaded_by, uploaded_at)
    VALUES (
      v_upl, v_org, v_biz, v_bank,
      'seed-r79-' || v_mm, 'CSV', 'Revolut',
      'demo-statement-' || v_mm || '.csv',
      public._hash_text('seed-r79-filehash-' || v_mm),
      v_pstart, v_pend, 'ACCEPTED',
      '[]'::jsonb, v_user, (v_pstart + interval '2 days'))
    ON CONFLICT (id) DO NOTHING;

    i := 0;
    FOR v_row IN SELECT * FROM jsonb_array_elements(v_tpl) LOOP
      v_txid := md5('seed-r79-tx-' || v_mm || '-' || i)::uuid;
      INSERT INTO public.transactions (
        id, organization_id, business_id, bank_account_id, statement_upload_id,
        source_row_index, source_row_hash, transaction_fingerprint,
        transaction_date, amount, currency, direction, transaction_type,
        normalized_description, counterparty_name, secondary_tags,
        classification_status, match_status, ledger_status, review_status, dedup_status,
        out_workflow_in_scope, in_workflow_in_scope, created_at, updated_at)
      VALUES (
        v_txid, v_org, v_biz, v_bank, v_upl,
        i,
        public._hash_text('seed-r79-srh-' || v_mm || '-' || i),
        public._hash_text('seed-r79-fp-'  || v_mm || '-' || i),
        (v_pstart + make_interval(days => i * 3))::date,
        (v_row->>'amt')::numeric, 'EUR',
        (v_row->>'dir')::public.transaction_direction_enum,
        'UNKNOWN'::public.transaction_type_enum,
        v_row->>'desc', v_row->>'cp', '[]'::jsonb,
        'PENDING'::public.transaction_classification_status_enum,
        'UNMATCHED'::public.transaction_match_status_enum,
        'PENDING'::public.transaction_ledger_status_enum,
        'NONE'::public.transaction_review_status_enum,
        'NEW'::public.transaction_dedup_status_enum,
        false, false, clock_timestamp(), clock_timestamp())
      ON CONFLICT (id) DO NOTHING;
      i := i + 1;
    END LOOP;
  END LOOP;

  -- 2. Two draft invoices across the period (kept DRAFT so the reset path can
  --    delete them — fn_block_invoice_delete_non_draft guards non-draft rows).
  INSERT INTO public.invoices (
    id, organization_id, business_id, client_id, invoice_type, invoice_number,
    issue_date, due_date, currency, subtotal_amount, vat_amount, total_amount,
    vat_treatment_per_line, default_vat_treatment, lifecycle_status,
    lifecycle_status_changed_at, created_at, updated_at)
  VALUES
    (md5('seed-r79-inv-1')::uuid, v_org, v_biz, v_client, 'TAX', 'INV-DEMO-7901',
     '2026-03-12', '2026-04-11', 'EUR', 1000.00, 190.00, 1190.00,
     false, 'DOMESTIC_STANDARD', 'DRAFT', clock_timestamp(), clock_timestamp(), clock_timestamp()),
    (md5('seed-r79-inv-2')::uuid, v_org, v_biz, v_client, 'TAX', 'INV-DEMO-7902',
     '2026-04-09', '2026-05-09', 'EUR', 2500.00, 475.00, 2975.00,
     false, 'DOMESTIC_STANDARD', 'DRAFT', clock_timestamp(), clock_timestamp(), clock_timestamp())
  ON CONFLICT (id) DO NOTHING;

  -- 3. Three discovered documents (evidence the journey would surface).
  INSERT INTO public.documents (
    id, organization_id, business_id, source, document_type, line_items,
    extraction_status, extraction_confidence_per_field,
    supplier_name, supplier_country, invoice_number, invoice_date,
    amount_total, currency, vat_amount, document_hash, created_at, updated_at)
  VALUES
    (md5('seed-r79-doc-0')::uuid, v_org, v_biz,
     'EMAIL'::public.document_source_enum, 'INVOICE'::public.document_type_enum,
     '[{"description":"Office rent","amount":1250.00}]'::jsonb,
     'EXTRACTED'::public.document_extraction_status_enum, '{"amount_total":0.97}'::jsonb,
     'Nicosia Office Rentals', 'CY', 'SEED-R79-RENT-02', '2026-02-03',
     1250.00, 'EUR', 0.00, public._hash_text('seed-r79-doc-0'), clock_timestamp(), clock_timestamp()),
    (md5('seed-r79-doc-1')::uuid, v_org, v_biz,
     'EMAIL'::public.document_source_enum, 'INVOICE'::public.document_type_enum,
     '[{"description":"EC2 compute","amount":149.49},{"description":"S3 storage","amount":64.28}]'::jsonb,
     'EXTRACTED'::public.document_extraction_status_enum, '{"amount_total":0.96}'::jsonb,
     'Amazon Web Services EMEA', 'LU', 'SEED-R79-AWS-03', '2026-03-09',
     213.77, 'EUR', 0.00, public._hash_text('seed-r79-doc-1'), clock_timestamp(), clock_timestamp()),
    (md5('seed-r79-doc-2')::uuid, v_org, v_biz,
     'MANUAL'::public.document_source_enum, 'RECEIPT'::public.document_type_enum,
     '[{"description":"Coffee","amount":42.50}]'::jsonb,
     'EXTRACTED'::public.document_extraction_status_enum, '{"amount_total":0.91}'::jsonb,
     'Costa Coffee', 'CY', 'SEED-R79-COFFEE-04', '2026-04-06',
     42.50, 'EUR', 0.00, public._hash_text('seed-r79-doc-2'), clock_timestamp(), clock_timestamp())
  ON CONFLICT (id) DO NOTHING;
END $$;

-- 4. Refresh analytics so the dashboard time-series picks up the new periods.
SELECT analytics.refresh_business('0e000000-0000-4000-8000-0000000000b1'::uuid);
