-- B08·P01 — Schema for Classification & Tagging
--
-- Pure DDL phase. 5 new tables + 3 new enums + 1 col on transactions +
-- 1 col on workflow_runs + RLS policies.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'classification_rule_kind_enum') THEN
    CREATE TYPE public.classification_rule_kind_enum AS ENUM (
      'REGEX_DESCRIPTION', 'COUNTERPARTY_NAME', 'COUNTERPARTY_DOMAIN',
      'AMOUNT_THRESHOLD', 'MERCHANT_CATEGORY_CODE', 'OWN_ACCOUNT_TRANSFER'
    );
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'classification_method_enum') THEN
    CREATE TYPE public.classification_method_enum AS ENUM (
      'RULE', 'VENDOR_MEMORY', 'AI_FALLBACK', 'NO_AI_AVAILABLE', 'MANUAL'
    );
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'vendor_memory_status_enum') THEN
    CREATE TYPE public.vendor_memory_status_enum AS ENUM ('ACTIVE','REVOKED');
  END IF;
END$$;

-- ============================================================================
-- classification_rules
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.classification_rules (
  id                    uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id       uuid REFERENCES public.organizations(id),
  business_id           uuid REFERENCES public.business_entities(id),
  rule_kind             public.classification_rule_kind_enum NOT NULL,
  rule_predicate        jsonb NOT NULL,
  assigned_type         public.transaction_type_enum NOT NULL,
  assigned_tag          text,
  priority              int NOT NULL DEFAULT 100,
  enabled               boolean NOT NULL DEFAULT true,
  created_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_by_user_id    uuid REFERENCES public.users(id),
  CONSTRAINT classification_rules_predicate_obj CHECK (jsonb_typeof(rule_predicate) = 'object'),
  CONSTRAINT classification_rules_scope_pair_chk CHECK (
    (business_id IS NULL) = (organization_id IS NULL)
  ),
  CONSTRAINT classification_rules_priority_nonneg CHECK (priority >= 0)
);

CREATE INDEX IF NOT EXISTS classification_rules_business_kind_enabled_idx
  ON public.classification_rules (business_id, rule_kind, enabled);
CREATE INDEX IF NOT EXISTS classification_rules_global_kind_enabled_idx
  ON public.classification_rules (rule_kind, enabled)
  WHERE business_id IS NULL;

REVOKE ALL ON public.classification_rules FROM PUBLIC, authenticated, anon;
GRANT  SELECT ON public.classification_rules TO authenticated;
ALTER TABLE public.classification_rules ENABLE ROW LEVEL SECURITY;

CREATE POLICY classification_rules_select ON public.classification_rules
  FOR SELECT TO authenticated
  USING (
    business_id IS NULL
    OR (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()))
  );
CREATE POLICY classification_rules_no_insert ON public.classification_rules
  FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY classification_rules_no_update ON public.classification_rules
  FOR UPDATE TO authenticated USING (false);
CREATE POLICY classification_rules_no_delete ON public.classification_rules
  FOR DELETE TO authenticated USING (false);

-- ============================================================================
-- recurring_vendor_memory
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.recurring_vendor_memory (
  id                       uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id          uuid NOT NULL REFERENCES public.organizations(id),
  business_id              uuid NOT NULL REFERENCES public.business_entities(id),
  counterparty_signature   text NOT NULL,
  suggested_type           public.transaction_type_enum,
  suggested_tag            text,
  confirmations_count      int NOT NULL DEFAULT 0,
  first_seen_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_confirmation_at     timestamptz,
  status                   public.vendor_memory_status_enum NOT NULL DEFAULT 'ACTIVE',
  created_at               timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at               timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT recurring_vendor_memory_business_sig_uq UNIQUE (business_id, counterparty_signature),
  CONSTRAINT recurring_vendor_memory_confirmations_nonneg CHECK (confirmations_count >= 0),
  CONSTRAINT recurring_vendor_memory_signature_nonempty CHECK (length(counterparty_signature) > 0)
);

REVOKE ALL ON public.recurring_vendor_memory FROM PUBLIC, authenticated, anon;
GRANT  SELECT ON public.recurring_vendor_memory TO authenticated;
ALTER TABLE public.recurring_vendor_memory ENABLE ROW LEVEL SECURITY;

CREATE POLICY recurring_vendor_memory_select ON public.recurring_vendor_memory
  FOR SELECT TO authenticated
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
CREATE POLICY recurring_vendor_memory_no_insert ON public.recurring_vendor_memory
  FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY recurring_vendor_memory_no_update ON public.recurring_vendor_memory
  FOR UPDATE TO authenticated USING (false);
CREATE POLICY recurring_vendor_memory_no_delete ON public.recurring_vendor_memory
  FOR DELETE TO authenticated USING (false);

-- ============================================================================
-- tag_taxonomy_versions
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.tag_taxonomy_versions (
  id              uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  version_label   text NOT NULL UNIQUE,
  definition      jsonb NOT NULL,
  is_default      boolean NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
  retired_at      timestamptz,
  CONSTRAINT tag_taxonomy_versions_definition_array CHECK (jsonb_typeof(definition) = 'array'),
  CONSTRAINT tag_taxonomy_versions_label_nonempty CHECK (length(version_label) > 0)
);

-- Exactly one row with is_default=true
CREATE UNIQUE INDEX IF NOT EXISTS tag_taxonomy_versions_one_default
  ON public.tag_taxonomy_versions ((is_default))
  WHERE is_default = true;

REVOKE ALL ON public.tag_taxonomy_versions FROM PUBLIC, authenticated, anon;
GRANT  SELECT ON public.tag_taxonomy_versions TO authenticated;
ALTER TABLE public.tag_taxonomy_versions ENABLE ROW LEVEL SECURITY;

-- Taxonomy versions are platform-wide; all authenticated users can read.
CREATE POLICY tag_taxonomy_versions_select ON public.tag_taxonomy_versions
  FOR SELECT TO authenticated USING (true);
CREATE POLICY tag_taxonomy_versions_no_insert ON public.tag_taxonomy_versions
  FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY tag_taxonomy_versions_no_update ON public.tag_taxonomy_versions
  FOR UPDATE TO authenticated USING (false);
CREATE POLICY tag_taxonomy_versions_no_delete ON public.tag_taxonomy_versions
  FOR DELETE TO authenticated USING (false);

-- ============================================================================
-- business_tag_taxonomy_assignments
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.business_tag_taxonomy_assignments (
  id                        uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id           uuid NOT NULL REFERENCES public.organizations(id),
  business_id               uuid NOT NULL REFERENCES public.business_entities(id),
  tag_taxonomy_version_id   uuid NOT NULL REFERENCES public.tag_taxonomy_versions(id),
  assigned_at               timestamptz NOT NULL DEFAULT clock_timestamp(),
  assigned_by_user_id       uuid REFERENCES public.users(id),
  CONSTRAINT business_tag_taxonomy_assignments_business_uq UNIQUE (business_id)
);

REVOKE ALL ON public.business_tag_taxonomy_assignments FROM PUBLIC, authenticated, anon;
GRANT  SELECT ON public.business_tag_taxonomy_assignments TO authenticated;
ALTER TABLE public.business_tag_taxonomy_assignments ENABLE ROW LEVEL SECURITY;

CREATE POLICY business_tag_taxonomy_assignments_select ON public.business_tag_taxonomy_assignments
  FOR SELECT TO authenticated
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
CREATE POLICY business_tag_taxonomy_assignments_no_insert ON public.business_tag_taxonomy_assignments
  FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY business_tag_taxonomy_assignments_no_update ON public.business_tag_taxonomy_assignments
  FOR UPDATE TO authenticated USING (false);
CREATE POLICY business_tag_taxonomy_assignments_no_delete ON public.business_tag_taxonomy_assignments
  FOR DELETE TO authenticated USING (false);

-- ============================================================================
-- business_custom_tags
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.business_custom_tags (
  id                       uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id          uuid NOT NULL REFERENCES public.organizations(id),
  business_id              uuid NOT NULL REFERENCES public.business_entities(id),
  tag_name                 text NOT NULL,
  mapped_transaction_type  public.transaction_type_enum NOT NULL,
  created_at               timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_by_user_id       uuid REFERENCES public.users(id),
  CONSTRAINT business_custom_tags_business_name_uq UNIQUE (business_id, tag_name),
  CONSTRAINT business_custom_tags_name_nonempty CHECK (length(tag_name) > 0)
);

REVOKE ALL ON public.business_custom_tags FROM PUBLIC, authenticated, anon;
GRANT  SELECT ON public.business_custom_tags TO authenticated;
ALTER TABLE public.business_custom_tags ENABLE ROW LEVEL SECURITY;

CREATE POLICY business_custom_tags_select ON public.business_custom_tags
  FOR SELECT TO authenticated
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
CREATE POLICY business_custom_tags_no_insert ON public.business_custom_tags
  FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY business_custom_tags_no_update ON public.business_custom_tags
  FOR UPDATE TO authenticated USING (false);
CREATE POLICY business_custom_tags_no_delete ON public.business_custom_tags
  FOR DELETE TO authenticated USING (false);

-- ============================================================================
-- transactions + classification_method
-- ============================================================================
ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS classification_method public.classification_method_enum;

-- ============================================================================
-- workflow_runs + tag_taxonomy_version_id (finalization snapshot)
-- ============================================================================
ALTER TABLE public.workflow_runs
  ADD COLUMN IF NOT EXISTS tag_taxonomy_version_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'workflow_runs_tag_taxonomy_version_id_fkey'
  ) THEN
    ALTER TABLE public.workflow_runs
      ADD CONSTRAINT workflow_runs_tag_taxonomy_version_id_fkey
      FOREIGN KEY (tag_taxonomy_version_id)
      REFERENCES public.tag_taxonomy_versions(id);
  END IF;
END$$;
