-- B15·P05 — Archive Package Construction
-- Replaces P04's _construct_archive_bundle_stub with the real 11-file
-- canonical constructor. Two-pass manifest self-reference; per-file
-- SHA-256; deterministic ordering; archive_files index populated per
-- file; bundle_hash_anchor recorded for hash-chain linkage by P04 step 7.

CREATE OR REPLACE FUNCTION public._hash_text(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = public, extensions, pg_temp
AS $$ SELECT encode(extensions.digest(p, 'sha256'), 'hex'); $$;

CREATE OR REPLACE FUNCTION public._compose_transactions_json(
  p_business_id uuid, p_period_start date, p_period_end date
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', t.id, 'transaction_date', t.transaction_date,
    'amount', t.amount, 'currency', t.currency,
    'direction', t.direction, 'transaction_type', t.transaction_type,
    'classification_status', t.classification_status,
    'match_status', t.match_status,
    'transaction_fingerprint', t.transaction_fingerprint
  ) ORDER BY t.id), '[]'::jsonb)
  FROM public.transactions t
  WHERE t.business_id = p_business_id
    AND t.transaction_date BETWEEN p_period_start AND p_period_end;
$$;

CREATE OR REPLACE FUNCTION public._compose_matches_json(
  p_business_id uuid, p_period_start date, p_period_end date
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', mr.id, 'transaction_id', mr.transaction_id,
    'document_id', mr.document_id, 'invoice_id', mr.invoice_id,
    'match_level', mr.match_level, 'match_method', mr.match_method,
    'match_score', mr.match_score, 'match_status', mr.match_status,
    'income_outcome', mr.income_outcome,
    'split_payment_flag', mr.split_payment_flag
  ) ORDER BY mr.id), '[]'::jsonb)
  FROM public.match_records mr
  JOIN public.transactions t ON t.id = mr.transaction_id
  WHERE t.business_id = p_business_id
    AND t.transaction_date BETWEEN p_period_start AND p_period_end;
$$;

CREATE OR REPLACE FUNCTION public._compose_ledger_entries_json(
  p_business_id uuid, p_period_start date, p_period_end date
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  -- Read from draft_ledger_entries: at bundle-construction time (P04 step 3)
  -- locked_ledger_entries does not yet exist (promotion is P04 step 4).
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', dle.id, 'parent_transaction_id', dle.parent_transaction_id,
    'match_record_id', dle.match_record_id, 'entry_kind', dle.entry_kind,
    'debit_account_code', dle.debit_account_code, 'credit_account_code', dle.credit_account_code,
    'debit_amount', dle.debit_amount, 'credit_amount', dle.credit_amount,
    'currency', dle.currency, 'entry_period', dle.entry_period,
    'vat_treatment', dle.vat_treatment,
    'input_vat_reclaimable_flag', dle.input_vat_reclaimable_flag,
    'input_vat_reclaimable_amount', dle.input_vat_reclaimable_amount,
    'output_vat_due_flag', dle.output_vat_due_flag,
    'output_vat_due_amount', dle.output_vat_due_amount,
    'reverse_charge_relevant', dle.reverse_charge_relevant,
    'vies_relevant', dle.vies_relevant, 'status', dle.status
  ) ORDER BY dle.id), '[]'::jsonb)
  FROM public.draft_ledger_entries dle
  JOIN public.transactions t ON t.id = dle.parent_transaction_id
  WHERE t.business_id = p_business_id
    AND t.transaction_date BETWEEN p_period_start AND p_period_end;
$$;

CREATE OR REPLACE FUNCTION public._compose_review_issues_json(p_run_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', ri.id, 'issue_type', ri.issue_type,
    'issue_group', ri.issue_group, 'severity', ri.severity, 'status', ri.status,
    'plain_language_title', ri.plain_language_title,
    'resolved_at', ri.resolved_at, 'resolved_by', ri.resolved_by,
    'snoozed_until', ri.snoozed_until
  ) ORDER BY ri.id), '[]'::jsonb)
  FROM public.review_issues ri WHERE ri.workflow_run_id = p_run_id;
$$;

CREATE OR REPLACE FUNCTION public._compose_evidence_index_json(
  p_business_id uuid, p_period_start date, p_period_end date
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  WITH refs AS (
    SELECT DISTINCT d.id, d.document_hash, d.original_filename
      FROM public.match_records mr
      JOIN public.documents d ON d.id = mr.document_id
      JOIN public.transactions t ON t.id = mr.transaction_id
     WHERE t.business_id = p_business_id
       AND t.transaction_date BETWEEN p_period_start AND p_period_end
       AND mr.document_id IS NOT NULL
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'document_id', refs.id, 'file_hash', refs.document_hash,
    'original_filename', refs.original_filename,
    'evidence_storage_relative_path', 'evidence/' || refs.document_hash
  ) ORDER BY refs.document_hash), '[]'::jsonb)
  FROM refs;
$$;

CREATE OR REPLACE FUNCTION public._compose_vat_summary_json(
  p_business_id uuid, p_period_start date, p_period_end date
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  WITH agg AS (
    SELECT dle.vat_treatment::text AS treatment,
           SUM(COALESCE(dle.input_vat_reclaimable_amount, 0))::numeric AS total_in,
           SUM(COALESCE(dle.output_vat_due_amount, 0))::numeric        AS total_out,
           count(*)::int                                                AS cnt
      FROM public.draft_ledger_entries dle
      JOIN public.transactions t ON t.id = dle.parent_transaction_id
     WHERE t.business_id = p_business_id
       AND t.transaction_date BETWEEN p_period_start AND p_period_end
     GROUP BY dle.vat_treatment
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'treatment', agg.treatment,
    'total_input_vat_reclaimable', agg.total_in,
    'total_output_vat_due', agg.total_out,
    'count_of_entries', agg.cnt
  ) ORDER BY agg.treatment), '[]'::jsonb)
  FROM agg;
$$;

CREATE OR REPLACE FUNCTION public._compose_vies_export_csv(
  p_business_id uuid, p_period_start date, p_period_end date
) RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_rows text := '';
BEGIN
  SELECT string_agg(
    format('%s,%s,%s',
      COALESCE(dle.counterparty_country, ''),
      COALESCE(dle.counterparty_vat_number, ''),
      SUM(COALESCE(dle.vies_value_basis_eur, 0))::text),
    E'\n' ORDER BY dle.counterparty_country, dle.counterparty_vat_number)
    INTO v_rows
    FROM public.draft_ledger_entries dle
    JOIN public.transactions t ON t.id = dle.parent_transaction_id
   WHERE t.business_id = p_business_id
     AND t.transaction_date BETWEEN p_period_start AND p_period_end
     AND dle.vies_relevant = true
   GROUP BY dle.counterparty_country, dle.counterparty_vat_number;
  RETURN 'counterparty_country,counterparty_vat_number,value_basis_eur' ||
         CASE WHEN v_rows IS NULL THEN '' ELSE E'\n' || v_rows END;
END;
$$;

CREATE OR REPLACE FUNCTION public._compose_finalization_summary_json(
  p_run_id uuid, p_archive_package_id uuid
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_run public.workflow_runs;
  v_appr public.workflow_run_approvals;
BEGIN
  SELECT * INTO v_run  FROM public.workflow_runs WHERE id = p_run_id;
  SELECT * INTO v_appr FROM public.workflow_run_approvals
    WHERE run_id = p_run_id
      AND approval_method = 'STEP_UP'::public.workflow_approval_method_enum
      AND revoked_at IS NULL
    ORDER BY approved_at DESC LIMIT 1;
  RETURN jsonb_build_object(
    'run_id', v_run.id, 'period_start', v_run.period_start::date,
    'period_end', v_run.period_end::date, 'business_id', v_run.business_id,
    'organization_id', v_run.organization_id,
    'approval_id', v_appr.id, 'approver_user_id', v_appr.approved_by,
    'approval_method', v_appr.approval_method, 'approved_at', v_appr.approved_at,
    'finalization_started_at', v_run.started_at,
    'archive_package_id', p_archive_package_id, 'manifest_version', 1);
END;
$$;

CREATE OR REPLACE FUNCTION public._compose_period_report_pdf_stub(
  p_business_id uuid, p_period_start date, p_period_end date, p_run_id uuid
) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions, pg_temp
AS $$
  -- Stage-1 stub; Block 16 owns the real PDF generator. Deterministic from inputs.
  SELECT '%PDF-1.4' || E'\n' || 'stub-period-report:' ||
         public._hash_text(p_run_id::text || '|' || p_period_start::text || '|' ||
                            p_period_end::text || '|' || p_business_id::text);
$$;

CREATE OR REPLACE FUNCTION public._compose_manifest_v1_json(
  p_run_id uuid, p_archive_package_id uuid,
  p_internal_file_hashes jsonb, p_bundle_hash_anchor text
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_run public.workflow_runs;
BEGIN
  SELECT * INTO v_run FROM public.workflow_runs WHERE id = p_run_id;
  RETURN jsonb_build_object(
    'manifest_version', 1, 'run_id', v_run.id,
    'business_id', v_run.business_id, 'organization_id', v_run.organization_id,
    'period_start', v_run.period_start::date, 'period_end', v_run.period_end::date,
    'archive_package_id', p_archive_package_id,
    'bundle_hash_anchor', p_bundle_hash_anchor,
    'internal_file_hashes', p_internal_file_hashes);
END;
$$;

CREATE OR REPLACE FUNCTION public._compute_bundle_anchor(p_file_list jsonb)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = public, extensions, pg_temp
AS $$
DECLARE v_concat text := '';
BEGIN
  SELECT string_agg(item.path || '|' || item.hash, E'\n' ORDER BY item.path)
    INTO v_concat
    FROM jsonb_to_recordset(p_file_list) AS item(path text, hash text);
  RETURN public._hash_text(COALESCE(v_concat, ''));
END;
$$;

CREATE OR REPLACE FUNCTION public._construct_archive_bundle_stub(
  p_run_id uuid, p_business_id uuid, p_organization_id uuid,
  p_period_start date, p_period_end date, p_started_by uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, audit, extensions, pg_temp
AS $$
DECLARE
  v_pkg_id uuid := public.gen_uuid_v7();
  v_manifest_id uuid := public.gen_uuid_v7();
  v_txns text; v_matches text; v_ledger text; v_issues text; v_evidx text;
  v_vat text; v_vies text; v_finsum text; v_pdf text;
  v_evidence_list jsonb;
  v_manifest_pass1 text; v_manifest_pass2 text;
  v_internal_hashes jsonb := '{}'::jsonb;
  v_file_list jsonb;
  v_anchor_pass1 text; v_anchor_final text;
BEGIN
  v_txns    := public._compose_transactions_json(p_business_id, p_period_start, p_period_end)::text;
  v_matches := public._compose_matches_json(p_business_id, p_period_start, p_period_end)::text;
  v_ledger  := public._compose_ledger_entries_json(p_business_id, p_period_start, p_period_end)::text;
  v_issues  := public._compose_review_issues_json(p_run_id)::text;
  v_evidence_list := public._compose_evidence_index_json(p_business_id, p_period_start, p_period_end);
  v_evidx   := v_evidence_list::text;
  v_vat     := public._compose_vat_summary_json(p_business_id, p_period_start, p_period_end)::text;
  v_vies    := public._compose_vies_export_csv(p_business_id, p_period_start, p_period_end);
  v_finsum  := public._compose_finalization_summary_json(p_run_id, v_pkg_id)::text;
  v_pdf     := public._compose_period_report_pdf_stub(p_business_id, p_period_start, p_period_end, p_run_id);

  v_internal_hashes := jsonb_build_object(
    'transactions.json',         public._hash_text(v_txns),
    'matches.json',              public._hash_text(v_matches),
    'ledger_entries.json',       public._hash_text(v_ledger),
    'review_issues.json',        public._hash_text(v_issues),
    'evidence_index.json',       public._hash_text(v_evidx),
    'vat_summary.json',          public._hash_text(v_vat),
    'vies_export.csv',           public._hash_text(v_vies),
    'finalization_summary.json', public._hash_text(v_finsum),
    'period_report.pdf',         public._hash_text(v_pdf));

  SELECT v_internal_hashes ||
         COALESCE(jsonb_object_agg('evidence/' || (e->>'file_hash'),
                                    public._hash_text('evidence/' || (e->>'file_hash')
                                                       || ':' || (e->>'document_id'))),
                  '{}'::jsonb)
    INTO v_internal_hashes
    FROM jsonb_array_elements(v_evidence_list) AS e;

  v_manifest_pass1 := public._compose_manifest_v1_json(
    p_run_id, v_pkg_id, v_internal_hashes, 'PLACEHOLDER_BUNDLE_HASH')::text;

  v_file_list := jsonb_build_array(
    jsonb_build_object('path','manifest_v1.json',          'hash', public._hash_text(v_manifest_pass1)),
    jsonb_build_object('path','transactions.json',         'hash', v_internal_hashes->>'transactions.json'),
    jsonb_build_object('path','matches.json',              'hash', v_internal_hashes->>'matches.json'),
    jsonb_build_object('path','ledger_entries.json',       'hash', v_internal_hashes->>'ledger_entries.json'),
    jsonb_build_object('path','review_issues.json',        'hash', v_internal_hashes->>'review_issues.json'),
    jsonb_build_object('path','evidence_index.json',       'hash', v_internal_hashes->>'evidence_index.json'),
    jsonb_build_object('path','vat_summary.json',          'hash', v_internal_hashes->>'vat_summary.json'),
    jsonb_build_object('path','vies_export.csv',           'hash', v_internal_hashes->>'vies_export.csv'),
    jsonb_build_object('path','finalization_summary.json', 'hash', v_internal_hashes->>'finalization_summary.json'),
    jsonb_build_object('path','period_report.pdf',         'hash', v_internal_hashes->>'period_report.pdf'));
  SELECT v_file_list ||
         COALESCE(jsonb_agg(jsonb_build_object(
           'path', 'evidence/' || (e->>'file_hash'),
           'hash', v_internal_hashes->>('evidence/' || (e->>'file_hash')))), '[]'::jsonb)
    INTO v_file_list
    FROM jsonb_array_elements(v_evidence_list) AS e;

  v_anchor_pass1 := public._compute_bundle_anchor(v_file_list);

  v_manifest_pass2 := public._compose_manifest_v1_json(
    p_run_id, v_pkg_id, v_internal_hashes, v_anchor_pass1)::text;

  v_file_list := jsonb_build_array(
    jsonb_build_object('path','manifest_v1.json', 'hash', public._hash_text(v_manifest_pass2)))
    || (SELECT jsonb_agg(item) FROM jsonb_array_elements(v_file_list) item
        WHERE (item->>'path') <> 'manifest_v1.json');

  v_anchor_final := public._compute_bundle_anchor(v_file_list);

  INSERT INTO public.archive_packages (id, organization_id, business_id, workflow_run_id,
    period_start, period_end, package_storage_object_id, bundle_hash_anchor,
    created_by_user_id, step_up_auth_used, original_finalization)
  VALUES (v_pkg_id, p_organization_id, p_business_id, p_run_id,
          p_period_start, p_period_end,
          format('archive/%s/%s/bundle_v1.zip', p_business_id, p_run_id),
          v_anchor_final, p_started_by, true, true);

  INSERT INTO public.archive_manifests (id, organization_id, business_id, archive_package_id,
    manifest_version_number, manifest_storage_object_id, manifest_hash,
    produced_by_run_id, produced_by_approval_id)
  VALUES (v_manifest_id, p_organization_id, p_business_id, v_pkg_id,
          1, format('archive/%s/%s/manifest_v1.json', p_business_id, p_run_id),
          public._hash_text(v_manifest_pass2), p_run_id,
          public.latest_qualifying_step_up_approval(p_business_id, p_run_id));

  INSERT INTO public.archive_files (organization_id, business_id, archive_manifest_id,
    relative_path, file_hash, byte_size)
  SELECT p_organization_id, p_business_id, v_manifest_id, item.path, item.hash,
         CASE item.path
           WHEN 'manifest_v1.json'         THEN octet_length(v_manifest_pass2)
           WHEN 'transactions.json'        THEN octet_length(v_txns)
           WHEN 'matches.json'             THEN octet_length(v_matches)
           WHEN 'ledger_entries.json'      THEN octet_length(v_ledger)
           WHEN 'review_issues.json'       THEN octet_length(v_issues)
           WHEN 'evidence_index.json'      THEN octet_length(v_evidx)
           WHEN 'vat_summary.json'         THEN octet_length(v_vat)
           WHEN 'vies_export.csv'          THEN octet_length(v_vies)
           WHEN 'finalization_summary.json' THEN octet_length(v_finsum)
           WHEN 'period_report.pdf'        THEN octet_length(v_pdf)
           ELSE 1
         END
    FROM jsonb_to_recordset(v_file_list) AS item(path text, hash text);

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='FINALIZATION_BUNDLE_CONSTRUCTED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
    p_actor_system:='finalization_bundle_constructor',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_after_state:=jsonb_build_object('archive_package_id', v_pkg_id, 'manifest_version', 1,
      'bundle_hash_anchor', v_anchor_final, 'file_count', jsonb_array_length(v_file_list)));
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='FINALIZATION_PERIOD_REPORT_GENERATED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
    p_actor_system:='finalization_bundle_constructor',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_after_state:=jsonb_build_object('pdf_hash', v_internal_hashes->>'period_report.pdf'));
  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum, p_action:='FINALIZATION_VIES_EXPORT_GENERATED',
    p_subject_type:='WORKFLOW_RUN'::audit.subject_type_enum, p_subject_id:=p_run_id,
    p_actor_system:='finalization_bundle_constructor',
    p_organization_id:=p_organization_id, p_business_id:=p_business_id,
    p_after_state:=jsonb_build_object('vies_hash', v_internal_hashes->>'vies_export.csv',
                                       'byte_size', octet_length(v_vies)));

  RETURN v_pkg_id;
END;
$$;
