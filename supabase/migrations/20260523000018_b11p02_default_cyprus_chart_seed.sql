-- B11·P02 part 2 of 2 — Default Cyprus-Friendly Chart of Accounts seed loader
-- =====================================================================
-- Seed catalog version: cyprus_default_chart_v1
-- Inserts ~41 accounts + ~27 mapping rules + 1 mapping_version row per
-- business; idempotent NOOP on re-run if any chart_of_accounts row already
-- exists for the business.
--
-- Audit events emitted (subject_type in parentheses):
--   * CHART_MAPPING_VERSION_CREATED   (CHART_MAPPING_VERSION)
--   * CHART_ACCOUNT_CREATED           (CHART_OF_ACCOUNTS_ENTRY)  — 1 per account
--   * CHART_MAPPING_RULE_CREATED      (CHART_MAPPING_RULE)       — 1 per rule
--   * CHART_DEFAULT_SEEDED            (BUSINESS)                 — 1 per business
--
-- Catalog coverage (representative; sub-doc will finalize Cyprus-specific codes):
--   Assets (6), Liabilities (6 incl Director's/Shareholder Loan), Equity (3 incl
--   Shareholder Capital), Revenue (5), Expense (16 incl Travel/Meals dedu+non-dedu
--   pairs), Contra (5 incl Input/Output VAT, FX gains/losses, Rounding).
--   Mapping rules: 12 transaction types × 2 sides (DEBIT+CREDIT) + 2 tag-based
--   extras + 1 VAT-treatment branch = 27.
-- =====================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.load_default_chart_for_business(
  p_organization_id uuid,
  p_business_id     uuid,
  p_actor_user_id   uuid DEFAULT NULL,
  p_context         jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_catalog_version constant text := 'cyprus_default_chart_v1';
  v_existing_n      int;
  v_version_id      uuid;
  v_account_id      uuid;
  v_mapping_id      uuid;
  v_accounts_n      int := 0;
  v_mappings_n      int := 0;
  v_acct            record;
  v_map             record;
BEGIN
  SELECT count(*) INTO v_existing_n FROM public.chart_of_accounts WHERE business_id = p_business_id;
  IF v_existing_n > 0 THEN
    RETURN jsonb_build_object('decision','NOOP','reason','already_seeded','business_id',p_business_id,
                              'existing_account_count',v_existing_n);
  END IF;

  -- 1. mapping version row (version_number=1)
  v_version_id := public.gen_uuid_v7();
  INSERT INTO public.chart_of_accounts_mapping_versions
    (id, organization_id, business_id, version_number, effective_from, created_by)
  VALUES (v_version_id, p_organization_id, p_business_id, 1, clock_timestamp(), p_actor_user_id);

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='CHART_MAPPING_VERSION_CREATED',
    p_subject_type:='CHART_MAPPING_VERSION'::audit.subject_type_enum,
    p_subject_id:=v_version_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='chart_seed_loader',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('version_number',1,'catalog_version',v_catalog_version),
    p_reason:=NULL, p_request_context:=p_context
  );

  -- 2. Account seed (41 rows; ordered so parents come before children)
  FOR v_acct IN
    SELECT * FROM (VALUES
      ('1000','Bank Accounts','ASSET',NULL::text,NULL::text,'NA'),
      ('1100','Trade Debtors','ASSET',NULL,'TRADE_DEBTORS','NA'),
      ('1110','Other Debtors','ASSET',NULL,'OTHER_DEBTORS','NA'),
      ('1200','VAT Receivable','ASSET',NULL,'VAT_RECEIVABLE','NA'),
      ('1300','Prepaid Expenses','ASSET',NULL,'PREPAID','NA'),
      ('1500','Fixed Assets','ASSET',NULL,'FIXED_ASSETS','NA'),
      ('2000','Trade Creditors','LIABILITY',NULL,'TRADE_CREDITORS','NA'),
      ('2010','Other Creditors','LIABILITY',NULL,'OTHER_CREDITORS','NA'),
      ('2100','VAT Payable','LIABILITY',NULL,'VAT_PAYABLE','NA'),
      ('2200','Accrued Expenses','LIABILITY',NULL,'ACCRUALS','NA'),
      ('2500','Director''s Loan Account','LIABILITY',NULL,'DIRECTORS_LOAN','NA'),
      ('2510','Shareholder Loan Account','LIABILITY',NULL,'SHAREHOLDER_LOAN','NA'),
      ('3000','Shareholder Capital','EQUITY',NULL,'SHAREHOLDER_CAPITAL','NA'),
      ('3100','Retained Earnings','EQUITY',NULL,'RETAINED_EARNINGS','NA'),
      ('3200','Current Year Earnings','EQUITY',NULL,'CURRENT_YEAR','NA'),
      ('4000','Sales — Cyprus','REVENUE',NULL,'SALES_CYPRUS','NA'),
      ('4100','Sales — EU','REVENUE',NULL,'SALES_EU','NA'),
      ('4200','Sales — Non-EU','REVENUE',NULL,'SALES_NON_EU','NA'),
      ('4500','Other Income','REVENUE',NULL,'OTHER_INCOME','NA'),
      ('4900','Refunds Received','REVENUE',NULL,'REFUNDS_IN','NA'),
      ('6010','Travel — deductible','EXPENSE',NULL,'TRAVEL','DEDUCTIBLE'),
      ('6019','Travel — non-deductible','EXPENSE','6010','TRAVEL','NON_DEDUCTIBLE'),
      ('6020','Meals & Entertainment — deductible','EXPENSE',NULL,'MEALS','DEDUCTIBLE'),
      ('6029','Meals & Entertainment — non-deductible','EXPENSE','6020','MEALS','NON_DEDUCTIBLE'),
      ('6030','IT & Software','EXPENSE',NULL,'IT_SOFTWARE','DEDUCTIBLE'),
      ('6040','Professional Fees','EXPENSE',NULL,'PROFESSIONAL_FEES','DEDUCTIBLE'),
      ('6050','Office Supplies','EXPENSE',NULL,'OFFICE_SUPPLIES','DEDUCTIBLE'),
      ('6060','Rent','EXPENSE',NULL,'RENT','DEDUCTIBLE'),
      ('6070','Utilities','EXPENSE',NULL,'UTILITIES','DEDUCTIBLE'),
      ('6080','Bank Charges','EXPENSE',NULL,'BANK_CHARGES','DEDUCTIBLE'),
      ('6090','Marketing','EXPENSE',NULL,'MARKETING','DEDUCTIBLE'),
      ('6100','Subscriptions','EXPENSE',NULL,'SUBSCRIPTIONS','DEDUCTIBLE'),
      ('6110','Salaries & Wages','EXPENSE',NULL,'SALARIES','DEDUCTIBLE'),
      ('6120','Contractor Payments','EXPENSE',NULL,'CONTRACTORS','DEDUCTIBLE'),
      ('6130','Tax Payments','EXPENSE',NULL,'TAX_PAYMENTS','NON_DEDUCTIBLE'),
      ('6900','Other Expenses','EXPENSE',NULL,'OTHER_EXPENSES','DEDUCTIBLE'),
      ('8000','Input VAT','CONTRA',NULL,'INPUT_VAT','NA'),
      ('8010','Output VAT','CONTRA',NULL,'OUTPUT_VAT','NA'),
      ('8100','FX Gains','CONTRA',NULL,'FX_GAINS','NA'),
      ('8110','FX Losses','CONTRA',NULL,'FX_LOSSES','NA'),
      ('8200','Rounding','CONTRA',NULL,'ROUNDING','NA')
    ) AS t(code,name,account_class,parent_code,category,deductibility)
    ORDER BY code
  LOOP
    v_account_id := public.gen_uuid_v7();
    INSERT INTO public.chart_of_accounts
      (id, organization_id, business_id, code, name, account_class, parent_code, category, deductibility, is_seeded)
    VALUES (v_account_id, p_organization_id, p_business_id,
            v_acct.code, v_acct.name,
            v_acct.account_class::public.account_class_enum,
            v_acct.parent_code, v_acct.category,
            v_acct.deductibility::public.account_deductibility_enum, true);

    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='CHART_ACCOUNT_CREATED',
      p_subject_type:='CHART_OF_ACCOUNTS_ENTRY'::audit.subject_type_enum,
      p_subject_id:=v_account_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='chart_seed_loader',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('code',v_acct.code,'name',v_acct.name,
                                         'account_class',v_acct.account_class,
                                         'deductibility',v_acct.deductibility,
                                         'catalog_version',v_catalog_version),
      p_reason:=NULL, p_request_context:=p_context
    );
    v_accounts_n := v_accounts_n + 1;
  END LOOP;

  -- 3. Mapping rules seed (27 rows: 24 per-type + 2 tag + 1 VAT branch)
  FOR v_map IN
    SELECT * FROM (VALUES
      -- 12 transaction types × 2 sides (DEBIT + CREDIT) — Phase 07 dispatcher always finds a rule
      ('OUT_EXPENSE',NULL::text,NULL::text,'DEBIT', '6900',100),
      ('OUT_EXPENSE',NULL,NULL,'CREDIT','2000',100),
      ('IN_INCOME',NULL,NULL,'DEBIT', '1100',100),
      ('IN_INCOME',NULL,NULL,'CREDIT','4000',100),
      ('INTERNAL_TRANSFER',NULL,NULL,'DEBIT', '1000',100),
      ('INTERNAL_TRANSFER',NULL,NULL,'CREDIT','1000',100),
      ('FX_EXCHANGE',NULL,NULL,'DEBIT', '8100',100),
      ('FX_EXCHANGE',NULL,NULL,'CREDIT','8110',100),
      ('BANK_FEE',NULL,NULL,'DEBIT', '6080',100),
      ('BANK_FEE',NULL,NULL,'CREDIT','2010',100),
      ('REFUND_IN',NULL,NULL,'DEBIT', '1100',100),
      ('REFUND_IN',NULL,NULL,'CREDIT','4900',100),
      ('REFUND_OUT',NULL,NULL,'DEBIT', '4900',100),
      ('REFUND_OUT',NULL,NULL,'CREDIT','2000',100),
      ('CHARGEBACK',NULL,NULL,'DEBIT', '2010',100),
      ('CHARGEBACK',NULL,NULL,'CREDIT','1100',100),
      ('LOAN_OR_SHAREHOLDER_MOVEMENT',NULL,NULL,'DEBIT', '2500',100),
      ('LOAN_OR_SHAREHOLDER_MOVEMENT',NULL,NULL,'CREDIT','1000',100),
      ('PAYROLL_OR_TEAM_PAYMENT',NULL,NULL,'DEBIT', '6110',100),
      ('PAYROLL_OR_TEAM_PAYMENT',NULL,NULL,'CREDIT','2000',100),
      ('TAX_PAYMENT',NULL,NULL,'DEBIT', '6130',100),
      ('TAX_PAYMENT',NULL,NULL,'CREDIT','2010',100),
      ('UNKNOWN',NULL,NULL,'DEBIT', '6900',100),
      ('UNKNOWN',NULL,NULL,'CREDIT','2010',100),
      -- Tag-based extras (priority 200 wins over per-type defaults)
      ('OUT_EXPENSE','saas_subscription',NULL,'DEBIT','6030',200),
      ('OUT_EXPENSE','client_dinner',NULL,'DEBIT','6029',200),
      -- VAT-treatment branch (priority 150)
      ('IN_INCOME',NULL,'EU_REVERSE_CHARGE','CREDIT','4100',150)
    ) AS t(transaction_type,tag,vat_treatment,direction,account_code,priority)
  LOOP
    v_mapping_id := public.gen_uuid_v7();
    INSERT INTO public.chart_of_accounts_mappings
      (id, organization_id, business_id, mapping_version_id,
       transaction_type, tag, vat_treatment, entry_kind, direction, account_code, priority, is_seeded)
    VALUES (v_mapping_id, p_organization_id, p_business_id, v_version_id,
            v_map.transaction_type::public.transaction_type_enum,
            v_map.tag,
            v_map.vat_treatment::public.vat_treatment_enum,
            'PRIMARY'::public.ledger_entry_kind_enum,
            v_map.direction::public.ledger_entry_type_enum,
            v_map.account_code, v_map.priority, true);

    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='CHART_MAPPING_RULE_CREATED',
      p_subject_type:='CHART_MAPPING_RULE'::audit.subject_type_enum,
      p_subject_id:=v_mapping_id,
      p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='chart_seed_loader',
      p_organization_id:=p_organization_id, p_business_id:=p_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object('transaction_type',v_map.transaction_type,'tag',v_map.tag,
                                         'vat_treatment',v_map.vat_treatment,'direction',v_map.direction,
                                         'account_code',v_map.account_code,'priority',v_map.priority,
                                         'catalog_version',v_catalog_version),
      p_reason:=NULL, p_request_context:=p_context
    );
    v_mappings_n := v_mappings_n + 1;
  END LOOP;

  -- 4. CHART_DEFAULT_SEEDED (one per business)
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='CHART_DEFAULT_SEEDED',
    p_subject_type:='BUSINESS'::audit.subject_type_enum,
    p_subject_id:=p_business_id,
    p_actor_user_id:=p_actor_user_id, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='chart_seed_loader',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object('catalog_version',v_catalog_version,
                                       'accounts_count',v_accounts_n,
                                       'mappings_count',v_mappings_n,
                                       'mapping_version_id',v_version_id),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','SEEDED',
    'business_id',p_business_id,
    'catalog_version',v_catalog_version,
    'accounts_count',v_accounts_n,
    'mappings_count',v_mappings_n,
    'mapping_version_id',v_version_id
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.load_default_chart_for_business(uuid, uuid, uuid, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.load_default_chart_for_business(uuid, uuid, uuid, jsonb) TO authenticated, service_role;

COMMIT;
