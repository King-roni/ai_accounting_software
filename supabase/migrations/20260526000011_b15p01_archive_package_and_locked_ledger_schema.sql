-- B15·P01 — Schema for Archive Package & Locked Ledger
-- =====================================================================
-- Four tables: archive_packages (per business/period family),
-- archive_manifests (per version), archive_files (per-file index),
-- archive.locked_ledger_entries (the immutable column-by-column copy).
-- Layer-1 immutability via RLS: UPDATE/DELETE denied to all roles;
-- INSERT allowed only when one of two session vars is set
-- (app.original_lock_active='1' for v1; app.adjustment_lock_active='1' for v>=2).
-- =====================================================================

CREATE TABLE public.archive_packages (
  id                            uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id               uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  business_id                   uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,
  workflow_run_id               uuid NOT NULL REFERENCES public.workflow_runs(id) ON DELETE RESTRICT,
  period_start                  date NOT NULL,
  period_end                    date NOT NULL,
  package_storage_object_id     text,
  bundle_hash_anchor            text NOT NULL,
  created_at                    timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_by_user_id            uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  step_up_auth_used             boolean NOT NULL DEFAULT false,
  original_finalization         boolean NOT NULL DEFAULT true,
  CONSTRAINT archive_packages_period_chk      CHECK (period_end >= period_start),
  CONSTRAINT archive_packages_bundle_hash_chk CHECK (bundle_hash_anchor ~ '^[0-9a-f]{64}$')
);
CREATE UNIQUE INDEX archive_packages_original_per_period
  ON public.archive_packages (business_id, period_start, period_end)
  WHERE original_finalization = true;
CREATE INDEX archive_packages_business_period_idx ON public.archive_packages (business_id, period_start);
CREATE INDEX archive_packages_workflow_run_idx    ON public.archive_packages (workflow_run_id);

ALTER TABLE public.archive_packages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.archive_packages FORCE  ROW LEVEL SECURITY;
CREATE POLICY archive_packages_select_org_biz ON public.archive_packages
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.business_user_roles bur
     WHERE bur.business_id = archive_packages.business_id
       AND bur.organization_id = archive_packages.organization_id
       AND bur.user_id = (SELECT u.id FROM public.users u WHERE u.auth_user_id = auth.uid())));
CREATE POLICY archive_packages_deny_insert ON public.archive_packages FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY archive_packages_deny_update ON public.archive_packages FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY archive_packages_deny_delete ON public.archive_packages FOR DELETE TO authenticated USING (false);


CREATE TABLE public.archive_manifests (
  id                            uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id               uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  business_id                   uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,
  archive_package_id            uuid NOT NULL REFERENCES public.archive_packages(id) ON DELETE RESTRICT,
  manifest_version_number       integer NOT NULL,
  manifest_storage_object_id    text,
  manifest_hash                 text NOT NULL,
  produced_by_run_id            uuid NOT NULL REFERENCES public.workflow_runs(id) ON DELETE RESTRICT,
  produced_by_approval_id       uuid REFERENCES public.workflow_run_approvals(id) ON DELETE RESTRICT,
  produced_at                   timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT archive_manifests_version_chk    CHECK (manifest_version_number >= 1),
  CONSTRAINT archive_manifests_hash_chk       CHECK (manifest_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT archive_manifests_unique_per_pkg UNIQUE (archive_package_id, manifest_version_number)
);
CREATE INDEX archive_manifests_pkg_version_desc_idx
  ON public.archive_manifests (archive_package_id, manifest_version_number DESC);

ALTER TABLE public.archive_manifests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.archive_manifests FORCE  ROW LEVEL SECURITY;
CREATE POLICY archive_manifests_select_org_biz ON public.archive_manifests
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.business_user_roles bur
     WHERE bur.business_id = archive_manifests.business_id
       AND bur.organization_id = archive_manifests.organization_id
       AND bur.user_id = (SELECT u.id FROM public.users u WHERE u.auth_user_id = auth.uid())));
CREATE POLICY archive_manifests_deny_insert ON public.archive_manifests FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY archive_manifests_deny_update ON public.archive_manifests FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY archive_manifests_deny_delete ON public.archive_manifests FOR DELETE TO authenticated USING (false);


CREATE TABLE public.archive_files (
  id                  uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id     uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  business_id         uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,
  archive_manifest_id uuid NOT NULL REFERENCES public.archive_manifests(id) ON DELETE RESTRICT,
  relative_path       text NOT NULL,
  file_hash           text NOT NULL,
  byte_size           bigint NOT NULL,
  CONSTRAINT archive_files_path_nonempty_chk CHECK (length(trim(relative_path)) > 0),
  CONSTRAINT archive_files_hash_chk          CHECK (file_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT archive_files_size_nonneg_chk   CHECK (byte_size >= 0)
);
CREATE INDEX archive_files_manifest_idx ON public.archive_files (archive_manifest_id);

ALTER TABLE public.archive_files ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.archive_files FORCE  ROW LEVEL SECURITY;
CREATE POLICY archive_files_select_org_biz ON public.archive_files
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.business_user_roles bur
     WHERE bur.business_id = archive_files.business_id
       AND bur.organization_id = archive_files.organization_id
       AND bur.user_id = (SELECT u.id FROM public.users u WHERE u.auth_user_id = auth.uid())));
CREATE POLICY archive_files_deny_insert ON public.archive_files FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY archive_files_deny_update ON public.archive_files FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY archive_files_deny_delete ON public.archive_files FOR DELETE TO authenticated USING (false);


CREATE TABLE archive.locked_ledger_entries (
  id                            uuid PRIMARY KEY,
  organization_id               uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  business_id                   uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE RESTRICT,
  parent_transaction_id         uuid,
  match_record_id               uuid,
  entry_kind                    public.ledger_entry_kind_enum NOT NULL,
  debit_account_code            text,
  credit_account_code           text,
  debit_amount                  numeric,
  credit_amount                 numeric,
  currency                      text NOT NULL,
  entry_period                  date,
  counterparty_country          text,
  counterparty_vat_number       text,
  vat_treatment                 public.vat_treatment_enum,
  input_vat_reclaimable_flag    boolean,
  input_vat_reclaimable_amount  numeric,
  output_vat_due_flag           boolean,
  output_vat_due_amount         numeric,
  reverse_charge_relevant       boolean,
  vies_relevant                 boolean,
  requires_contract             boolean,
  requires_invoice              boolean,
  requires_receipt              boolean,
  requires_accountant_review    boolean,
  accountant_review_reason      text,
  chart_mapping_version_id      uuid,
  vat_rate_table_version        text,
  status                        public.ledger_entry_status_enum,
  created_at                    timestamptz,
  last_recomputed_at            timestamptz,
  entry_currency_original       text,
  entry_amount_original         numeric,
  vies_period                   text,
  vies_value_basis_eur          numeric,
  vat_treatment_explanation     text,
  manual_override_by            uuid,
  manual_override_reason        text,
  manual_override_at            timestamptz,
  archive_package_id            uuid NOT NULL REFERENCES public.archive_packages(id) ON DELETE RESTRICT,
  archive_manifest_version      integer NOT NULL,
  locked_at                     timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT locked_ledger_version_chk CHECK (archive_manifest_version >= 1)
);
CREATE INDEX locked_ledger_entries_package_idx
  ON archive.locked_ledger_entries (archive_package_id, archive_manifest_version);
CREATE INDEX locked_ledger_entries_business_period_idx
  ON archive.locked_ledger_entries (business_id, entry_period);

ALTER TABLE archive.locked_ledger_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE archive.locked_ledger_entries FORCE  ROW LEVEL SECURITY;

CREATE POLICY locked_ledger_select_org_biz ON archive.locked_ledger_entries
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.business_user_roles bur
     WHERE bur.business_id = locked_ledger_entries.business_id
       AND bur.organization_id = locked_ledger_entries.organization_id
       AND bur.user_id = (SELECT u.id FROM public.users u WHERE u.auth_user_id = auth.uid())));
CREATE POLICY locked_ledger_insert_during_lock ON archive.locked_ledger_entries
  FOR INSERT TO authenticated
  WITH CHECK (
    (COALESCE(current_setting('app.original_lock_active', true), '0') = '1'
     AND archive_manifest_version = 1)
    OR
    (COALESCE(current_setting('app.adjustment_lock_active', true), '0') = '1'
     AND archive_manifest_version >= 2)
  );
CREATE POLICY locked_ledger_deny_update ON archive.locked_ledger_entries FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY locked_ledger_deny_delete ON archive.locked_ledger_entries FOR DELETE TO authenticated USING (false);


CREATE OR REPLACE VIEW public.v_archive_package_latest_manifest AS
  SELECT DISTINCT ON (am.archive_package_id)
         am.archive_package_id, am.id AS latest_manifest_id,
         am.manifest_version_number AS latest_version,
         am.manifest_hash, am.produced_at, am.produced_by_run_id
    FROM public.archive_manifests am
   ORDER BY am.archive_package_id, am.manifest_version_number DESC;

COMMENT ON VIEW public.v_archive_package_latest_manifest IS
  'B15·P01: per archive_package, the latest manifest version (highest manifest_version_number).';
