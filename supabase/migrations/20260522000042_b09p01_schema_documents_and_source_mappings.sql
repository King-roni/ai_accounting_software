-- B09·P01 — Schema for Documents & Source Mappings
-- Adds 3 enums + 4 tables for the document intake/extraction block.
-- Writes are routed via future SECURITY DEFINER RPCs; this phase only lays down schema + RLS.

-- 1. Enums --------------------------------------------------------------------

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname='document_extraction_layer_enum' AND typnamespace='public'::regnamespace) THEN
    CREATE TYPE public.document_extraction_layer_enum AS ENUM ('DETERMINISTIC','TIER2_AI','TIER3_AI');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname='sender_allowlist_entry_kind_enum' AND typnamespace='public'::regnamespace) THEN
    CREATE TYPE public.sender_allowlist_entry_kind_enum AS ENUM ('EMAIL_DOMAIN','EMAIL_ADDRESS');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname='document_source_kind_enum' AND typnamespace='public'::regnamespace) THEN
    CREATE TYPE public.document_source_kind_enum AS ENUM ('EMAIL','DRIVE','MANUAL','INVOICE_GENERATOR');
  END IF;
END$$;


-- 2. gmail_search_query_templates --------------------------------------------

CREATE TABLE IF NOT EXISTS public.gmail_search_query_templates (
  id                   uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id      uuid,
  business_id          uuid,
  template_name        text NOT NULL,
  pattern_jsonb        jsonb NOT NULL,
  enabled              boolean NOT NULL DEFAULT true,
  priority             integer NOT NULL DEFAULT 100,
  created_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_by_user_id   uuid,
  CONSTRAINT gsqt_name_format          CHECK (template_name ~ '^[a-z][a-z0-9_]+$'),
  CONSTRAINT gsqt_pattern_object       CHECK (jsonb_typeof(pattern_jsonb) = 'object'),
  CONSTRAINT gsqt_priority_nonneg      CHECK (priority >= 0),
  CONSTRAINT gsqt_global_scope_paired  CHECK (
    (business_id IS NULL AND organization_id IS NULL)
    OR (business_id IS NOT NULL AND organization_id IS NOT NULL)
  ),
  CONSTRAINT gsqt_org_fk      FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  CONSTRAINT gsqt_business_fk FOREIGN KEY (business_id) REFERENCES public.business_entities(id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS gsqt_unique_per_biz
  ON public.gmail_search_query_templates (business_id, template_name) WHERE business_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS gsqt_unique_global
  ON public.gmail_search_query_templates (template_name) WHERE business_id IS NULL;
CREATE INDEX IF NOT EXISTS gsqt_lookup
  ON public.gmail_search_query_templates (business_id, enabled, priority DESC);


-- 3. business_sender_allowlist -----------------------------------------------

CREATE TABLE IF NOT EXISTS public.business_sender_allowlist (
  id                uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id   uuid NOT NULL,
  business_id       uuid NOT NULL,
  entry_kind        public.sender_allowlist_entry_kind_enum NOT NULL,
  value             text NOT NULL,
  notes             text,
  added_by_user_id  uuid,
  added_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT bsa_value_nonempty   CHECK (length(value) > 0),
  CONSTRAINT bsa_value_lowercase  CHECK (value = lower(value)),
  CONSTRAINT bsa_org_fk      FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  CONSTRAINT bsa_business_fk FOREIGN KEY (business_id) REFERENCES public.business_entities(id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS bsa_unique
  ON public.business_sender_allowlist (business_id, entry_kind, value);
CREATE INDEX IF NOT EXISTS bsa_by_value
  ON public.business_sender_allowlist (business_id, value);


-- 4. document_extraction_results ---------------------------------------------

CREATE TABLE IF NOT EXISTS public.document_extraction_results (
  id                    uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id       uuid NOT NULL,
  business_id           uuid NOT NULL,
  document_id           uuid NOT NULL,
  extraction_layer      public.document_extraction_layer_enum NOT NULL,
  extracted_fields      jsonb NOT NULL DEFAULT '{}'::jsonb,
  confidence_per_field  jsonb NOT NULL DEFAULT '{}'::jsonb,
  started_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at          timestamptz,
  prompt_version        text,
  succeeded             boolean NOT NULL,
  error_summary         text,
  CONSTRAINT der_extracted_object       CHECK (jsonb_typeof(extracted_fields) = 'object'),
  CONSTRAINT der_confidence_object      CHECK (jsonb_typeof(confidence_per_field) = 'object'),
  CONSTRAINT der_prompt_version_pairing CHECK (
    (extraction_layer = 'DETERMINISTIC' AND prompt_version IS NULL)
    OR (extraction_layer IN ('TIER2_AI','TIER3_AI') AND prompt_version IS NOT NULL)
  ),
  CONSTRAINT der_error_summary_pairing  CHECK (
    (succeeded = true AND error_summary IS NULL)
    OR (succeeded = false AND error_summary IS NOT NULL AND length(trim(error_summary)) > 0)
  ),
  CONSTRAINT der_org_fk       FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  CONSTRAINT der_business_fk  FOREIGN KEY (business_id) REFERENCES public.business_entities(id) ON DELETE RESTRICT,
  CONSTRAINT der_document_fk  FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS der_by_doc_layer
  ON public.document_extraction_results (document_id, extraction_layer);


-- 5. document_source_links ---------------------------------------------------

CREATE TABLE IF NOT EXISTS public.document_source_links (
  id                  uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id     uuid NOT NULL,
  business_id         uuid NOT NULL,
  document_id         uuid NOT NULL,
  source_kind         public.document_source_kind_enum NOT NULL,
  source_external_id  text NOT NULL,
  discovered_at       timestamptz NOT NULL DEFAULT clock_timestamp(),
  discovery_reason    text,
  CONSTRAINT dsl_extid_nonempty CHECK (length(source_external_id) > 0),
  CONSTRAINT dsl_org_fk      FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  CONSTRAINT dsl_business_fk FOREIGN KEY (business_id) REFERENCES public.business_entities(id) ON DELETE RESTRICT,
  CONSTRAINT dsl_document_fk FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS dsl_unique_source
  ON public.document_source_links (business_id, source_kind, source_external_id);
CREATE INDEX IF NOT EXISTS dsl_by_doc
  ON public.document_source_links (business_id, document_id);
CREATE INDEX IF NOT EXISTS dsl_by_extid
  ON public.document_source_links (source_kind, source_external_id);


-- 6. RLS ---------------------------------------------------------------------

ALTER TABLE public.gmail_search_query_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_sender_allowlist    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.document_extraction_results  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.document_source_links        ENABLE ROW LEVEL SECURITY;

-- gmail_search_query_templates: SELECT allowed for in-org row OR global default
DROP POLICY IF EXISTS gsqt_select ON public.gmail_search_query_templates;
CREATE POLICY gsqt_select ON public.gmail_search_query_templates
  FOR SELECT
  USING (
    business_id IS NULL
    OR (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()))
  );
DROP POLICY IF EXISTS gsqt_no_insert ON public.gmail_search_query_templates;
CREATE POLICY gsqt_no_insert ON public.gmail_search_query_templates FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS gsqt_no_update ON public.gmail_search_query_templates;
CREATE POLICY gsqt_no_update ON public.gmail_search_query_templates FOR UPDATE USING (false);
DROP POLICY IF EXISTS gsqt_no_delete ON public.gmail_search_query_templates;
CREATE POLICY gsqt_no_delete ON public.gmail_search_query_templates FOR DELETE USING (false);

DROP POLICY IF EXISTS bsa_select ON public.business_sender_allowlist;
CREATE POLICY bsa_select ON public.business_sender_allowlist
  FOR SELECT
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
DROP POLICY IF EXISTS bsa_no_insert ON public.business_sender_allowlist;
CREATE POLICY bsa_no_insert ON public.business_sender_allowlist FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS bsa_no_update ON public.business_sender_allowlist;
CREATE POLICY bsa_no_update ON public.business_sender_allowlist FOR UPDATE USING (false);
DROP POLICY IF EXISTS bsa_no_delete ON public.business_sender_allowlist;
CREATE POLICY bsa_no_delete ON public.business_sender_allowlist FOR DELETE USING (false);

DROP POLICY IF EXISTS der_select ON public.document_extraction_results;
CREATE POLICY der_select ON public.document_extraction_results
  FOR SELECT
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
DROP POLICY IF EXISTS der_no_insert ON public.document_extraction_results;
CREATE POLICY der_no_insert ON public.document_extraction_results FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS der_no_update ON public.document_extraction_results;
CREATE POLICY der_no_update ON public.document_extraction_results FOR UPDATE USING (false);
DROP POLICY IF EXISTS der_no_delete ON public.document_extraction_results;
CREATE POLICY der_no_delete ON public.document_extraction_results FOR DELETE USING (false);

DROP POLICY IF EXISTS dsl_select ON public.document_source_links;
CREATE POLICY dsl_select ON public.document_source_links
  FOR SELECT
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
DROP POLICY IF EXISTS dsl_no_insert ON public.document_source_links;
CREATE POLICY dsl_no_insert ON public.document_source_links FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS dsl_no_update ON public.document_source_links;
CREATE POLICY dsl_no_update ON public.document_source_links FOR UPDATE USING (false);
DROP POLICY IF EXISTS dsl_no_delete ON public.document_source_links;
CREATE POLICY dsl_no_delete ON public.document_source_links FOR DELETE USING (false);
