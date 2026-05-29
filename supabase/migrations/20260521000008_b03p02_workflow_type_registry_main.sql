-- B03·P02 Workflow Type Registry & Per-Business Config (main)
-- =============================================================================
-- Workflow types are code-resident (declared in API/web). The DB mirrors them
-- as authoritative reference data so the resolver + validator can run server-
-- side. Block 12/13 will lock the canonical phase sequences; this migration
-- ships placeholder rows so the engine has SOMETHING to resolve against.
-- =============================================================================

CREATE TABLE public.workflow_type_definitions (
  workflow_type           public.workflow_type_enum PRIMARY KEY,
  default_trigger_modes   text[] NOT NULL DEFAULT '{MANUAL}'::text[],
  requires_parent_run     boolean NOT NULL,
  description             text NOT NULL,
  created_at              timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at              timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT wtd_trigger_modes_nonempty CHECK (cardinality(default_trigger_modes) > 0),
  CONSTRAINT wtd_trigger_modes_valid    CHECK (default_trigger_modes <@ ARRAY['MANUAL','EVENT'])
);

CREATE TRIGGER workflow_type_definitions_set_updated_at
  BEFORE UPDATE ON public.workflow_type_definitions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

INSERT INTO public.workflow_type_definitions (workflow_type, default_trigger_modes, requires_parent_run, description) VALUES
  ('OUT_MONTHLY',    '{MANUAL,EVENT}', false, 'Outgoing/expense monthly workflow (Block 12)'),
  ('IN_MONTHLY',     '{MANUAL,EVENT}', false, 'Incoming/income monthly workflow (Block 13)'),
  ('OUT_ADJUSTMENT', '{MANUAL}',       true,  'Outgoing adjustment workflow — requires parent OUT_MONTHLY (Block 12)'),
  ('IN_ADJUSTMENT',  '{MANUAL}',       true,  'Incoming adjustment workflow — requires parent IN_MONTHLY (Block 13)');

CREATE TABLE public.workflow_phase_definitions (
  id              uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  workflow_type   public.workflow_type_enum NOT NULL REFERENCES public.workflow_type_definitions(workflow_type) ON DELETE RESTRICT,
  phase_order     int NOT NULL,
  phase_name      text NOT NULL,
  optional        boolean NOT NULL DEFAULT false,
  description     text,
  created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT wpd_phase_name_nonempty CHECK (length(btrim(phase_name)) > 0),
  CONSTRAINT wpd_phase_order_nonneg  CHECK (phase_order >= 0),
  CONSTRAINT wpd_unique_order        UNIQUE (workflow_type, phase_order),
  CONSTRAINT wpd_unique_name         UNIQUE (workflow_type, phase_name)
);

CREATE INDEX idx_workflow_phase_definitions_type_order ON public.workflow_phase_definitions (workflow_type, phase_order);

-- Bootstrap placeholder phase sequences. Block 12/13 will lock canonical names
-- via subsequent migrations (INSERT IF NOT EXISTS pattern).
INSERT INTO public.workflow_phase_definitions (workflow_type, phase_order, phase_name, optional, description) VALUES
  ('OUT_MONTHLY',  1, 'INGEST_STATEMENT',         false, 'Ingest bank statement file'),
  ('OUT_MONTHLY',  2, 'PARSE_TRANSACTIONS',       false, 'Parse and normalise transactions'),
  ('OUT_MONTHLY',  3, 'EVIDENCE_DISCOVERY_LOCAL', false, 'Discover supporting documents in uploaded set'),
  ('OUT_MONTHLY',  4, 'EVIDENCE_DISCOVERY_DRIVE', true,  'Discover supporting documents via Google Drive (optional)'),
  ('OUT_MONTHLY',  5, 'EVIDENCE_DISCOVERY_GMAIL', true,  'Discover supporting documents via Gmail (optional)'),
  ('OUT_MONTHLY',  6, 'MATCH',                    false, 'Match transactions to documents'),
  ('OUT_MONTHLY',  7, 'CLASSIFY',                 false, 'AI classification + Cyprus VAT tagging'),
  ('OUT_MONTHLY',  8, 'LEDGER_DRAFT',             false, 'Draft ledger entries'),
  ('OUT_MONTHLY',  9, 'REVIEW_QUEUE_GATE',        false, 'Gate to review queue'),
  ('OUT_MONTHLY', 10, 'USER_REVIEW',              false, 'Owner/Accountant review'),
  ('OUT_MONTHLY', 11, 'ARCHIVE_PROMOTION',        false, 'Finalize + promote to archive'),
  ('IN_MONTHLY',   1, 'INVOICE_GENERATION',       false, 'Generate or import invoices'),
  ('IN_MONTHLY',   2, 'PARSE_INCOME',             false, 'Parse income records'),
  ('IN_MONTHLY',   3, 'EVIDENCE_DISCOVERY_LOCAL', false, 'Discover supporting documents'),
  ('IN_MONTHLY',   4, 'EVIDENCE_DISCOVERY_DRIVE', true,  'Discover via Google Drive (optional)'),
  ('IN_MONTHLY',   5, 'EVIDENCE_DISCOVERY_GMAIL', true,  'Discover via Gmail (optional)'),
  ('IN_MONTHLY',   6, 'CLASSIFY',                 false, 'Classification + Cyprus VAT'),
  ('IN_MONTHLY',   7, 'LEDGER_DRAFT',             false, 'Draft ledger entries'),
  ('IN_MONTHLY',   8, 'REVIEW_QUEUE_GATE',        false, 'Gate to review queue'),
  ('IN_MONTHLY',   9, 'USER_REVIEW',              false, 'Owner/Accountant review'),
  ('IN_MONTHLY',  10, 'ARCHIVE_PROMOTION',        false, 'Finalize + promote to archive'),
  ('OUT_ADJUSTMENT', 1, 'ADJUSTMENT_DRAFT',       false, 'Draft adjustment entries against parent finalized run'),
  ('OUT_ADJUSTMENT', 2, 'CLASSIFY_ADJUSTMENT',    false, 'Classification + VAT'),
  ('OUT_ADJUSTMENT', 3, 'USER_REVIEW',            false, 'Owner/Accountant review'),
  ('OUT_ADJUSTMENT', 4, 'ARCHIVE_PROMOTION',      false, 'Finalize + promote to archive (manifest v2+)'),
  ('IN_ADJUSTMENT',  1, 'ADJUSTMENT_DRAFT',       false, 'Draft adjustment entries against parent finalized run'),
  ('IN_ADJUSTMENT',  2, 'CLASSIFY_ADJUSTMENT',    false, 'Classification + VAT'),
  ('IN_ADJUSTMENT',  3, 'USER_REVIEW',            false, 'Owner/Accountant review'),
  ('IN_ADJUSTMENT',  4, 'ARCHIVE_PROMOTION',      false, 'Finalize + promote to archive (manifest v2+)');

CREATE TABLE public.business_workflow_config (
  id                uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  business_id       uuid NOT NULL REFERENCES public.business_entities(id) ON DELETE CASCADE,
  workflow_type     public.workflow_type_enum NOT NULL REFERENCES public.workflow_type_definitions(workflow_type) ON DELETE RESTRICT,
  enabled_phases    jsonb,
  enabled_tools     jsonb,
  updated_by        uuid REFERENCES public.users(id),
  created_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT bwc_unique_biz_type UNIQUE (business_id, workflow_type),
  CONSTRAINT bwc_enabled_phases_is_array CHECK (enabled_phases IS NULL OR jsonb_typeof(enabled_phases) = 'array'),
  CONSTRAINT bwc_enabled_tools_is_array  CHECK (enabled_tools  IS NULL OR jsonb_typeof(enabled_tools)  = 'array')
);

CREATE INDEX idx_business_workflow_config_biz ON public.business_workflow_config (business_id);

CREATE TRIGGER business_workflow_config_set_updated_at
  BEFORE UPDATE ON public.business_workflow_config
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.workflow_type_definitions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workflow_type_definitions  FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.workflow_phase_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workflow_phase_definitions FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.business_workflow_config   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_workflow_config   FORCE  ROW LEVEL SECURITY;

CREATE POLICY wtd_select_all ON public.workflow_type_definitions AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY wtd_no_insert ON public.workflow_type_definitions AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY wtd_no_update ON public.workflow_type_definitions AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY wtd_no_delete ON public.workflow_type_definitions AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

CREATE POLICY wpd_select_all ON public.workflow_phase_definitions AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY wpd_no_insert ON public.workflow_phase_definitions AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY wpd_no_update ON public.workflow_phase_definitions AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY wpd_no_delete ON public.workflow_phase_definitions AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

CREATE POLICY bwc_select_tenant ON public.business_workflow_config
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.business_entities be
                  WHERE be.id = business_workflow_config.business_id
                    AND be.organization_id = public.current_org()));
CREATE POLICY bwc_no_insert ON public.business_workflow_config AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY bwc_no_update ON public.business_workflow_config AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY bwc_no_delete ON public.business_workflow_config AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

GRANT SELECT ON public.workflow_type_definitions, public.workflow_phase_definitions, public.business_workflow_config TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_workflow_type(p_workflow_type public.workflow_type_enum)
RETURNS public.workflow_type_definitions
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
  SELECT * FROM public.workflow_type_definitions WHERE workflow_type = p_workflow_type;
$fn$;
GRANT EXECUTE ON FUNCTION public.get_workflow_type(public.workflow_type_enum) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.list_workflow_phases(p_workflow_type public.workflow_type_enum)
RETURNS SETOF public.workflow_phase_definitions
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
  SELECT * FROM public.workflow_phase_definitions WHERE workflow_type = p_workflow_type ORDER BY phase_order ASC;
$fn$;
GRANT EXECUTE ON FUNCTION public.list_workflow_phases(public.workflow_type_enum) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.validate_workflow_config(
  p_workflow_type    public.workflow_type_enum,
  p_enabled_phases   jsonb
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_errors           jsonb := '[]'::jsonb;
  v_enabled_names    text[];
  v_unknown          text[];
  v_missing_required text[];
BEGIN
  IF p_workflow_type IS NULL THEN RAISE EXCEPTION 'validate_workflow_config: workflow_type required' USING ERRCODE='22000'; END IF;
  IF p_enabled_phases IS NULL THEN RETURN jsonb_build_object('valid', true, 'errors', '[]'::jsonb); END IF;
  IF jsonb_typeof(p_enabled_phases) <> 'array' THEN
    RETURN jsonb_build_object('valid', false, 'errors', jsonb_build_array(jsonb_build_object('code','NOT_ARRAY','message','enabled_phases must be a JSON array')));
  END IF;

  SELECT array_agg(value) INTO v_enabled_names FROM jsonb_array_elements_text(p_enabled_phases) AS t(value);
  v_enabled_names := COALESCE(v_enabled_names, ARRAY[]::text[]);

  SELECT array_agg(name) INTO v_unknown FROM (
    SELECT n.name FROM unnest(v_enabled_names) AS n(name)
     WHERE NOT EXISTS (SELECT 1 FROM public.workflow_phase_definitions wpd
                        WHERE wpd.workflow_type = p_workflow_type AND wpd.phase_name = n.name)
  ) sub;
  IF v_unknown IS NOT NULL THEN
    v_errors := v_errors || jsonb_build_object(
      'code', 'UNKNOWN_PHASE',
      'message', format('phases not in registry for %s: %s', p_workflow_type, array_to_string(v_unknown, ', ')),
      'phases', to_jsonb(v_unknown)
    );
  END IF;

  SELECT array_agg(wpd.phase_name) INTO v_missing_required
    FROM public.workflow_phase_definitions wpd
   WHERE wpd.workflow_type = p_workflow_type
     AND wpd.optional = false
     AND NOT (wpd.phase_name = ANY(v_enabled_names));
  IF v_missing_required IS NOT NULL THEN
    v_errors := v_errors || jsonb_build_object(
      'code', 'MANDATORY_PHASE_DISABLED',
      'message', format('mandatory phases missing: %s', array_to_string(v_missing_required, ', ')),
      'phases', to_jsonb(v_missing_required)
    );
  END IF;

  RETURN jsonb_build_object('valid', jsonb_array_length(v_errors) = 0, 'errors', v_errors);
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.validate_workflow_config(public.workflow_type_enum, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.validate_workflow_config(public.workflow_type_enum, jsonb) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_effective_phase_sequence(
  p_business_id   uuid,
  p_workflow_type public.workflow_type_enum
) RETURNS TABLE (phase_order int, phase_name text, optional boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_enabled_phases jsonb;
BEGIN
  IF p_business_id IS NULL THEN RAISE EXCEPTION 'get_effective_phase_sequence: business_id required' USING ERRCODE='22000'; END IF;
  IF p_workflow_type IS NULL THEN RAISE EXCEPTION 'get_effective_phase_sequence: workflow_type required' USING ERRCODE='22000'; END IF;
  SELECT bwc.enabled_phases INTO v_enabled_phases FROM public.business_workflow_config bwc
   WHERE bwc.business_id = p_business_id AND bwc.workflow_type = p_workflow_type;
  IF v_enabled_phases IS NULL THEN
    RETURN QUERY SELECT wpd.phase_order, wpd.phase_name, wpd.optional
      FROM public.workflow_phase_definitions wpd
     WHERE wpd.workflow_type = p_workflow_type ORDER BY wpd.phase_order ASC;
  ELSE
    RETURN QUERY SELECT wpd.phase_order, wpd.phase_name, wpd.optional
      FROM public.workflow_phase_definitions wpd
     WHERE wpd.workflow_type = p_workflow_type
       AND wpd.phase_name = ANY(SELECT jsonb_array_elements_text(v_enabled_phases))
     ORDER BY wpd.phase_order ASC;
  END IF;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.get_effective_phase_sequence(uuid, public.workflow_type_enum) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_effective_phase_sequence(uuid, public.workflow_type_enum) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.upsert_business_workflow_config(
  p_business_id     uuid,
  p_workflow_type   public.workflow_type_enum,
  p_enabled_phases  jsonb,
  p_enabled_tools   jsonb,
  p_actor_user_id   uuid
) RETURNS public.business_workflow_config
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $fn$
DECLARE
  v_validation jsonb;
  v_before     public.business_workflow_config;
  v_row        public.business_workflow_config;
  v_org_id     uuid;
BEGIN
  IF p_business_id IS NULL THEN RAISE EXCEPTION 'upsert_business_workflow_config: business_id required' USING ERRCODE='22000'; END IF;
  IF p_workflow_type IS NULL THEN RAISE EXCEPTION 'upsert_business_workflow_config: workflow_type required' USING ERRCODE='22000'; END IF;
  IF p_actor_user_id IS NULL THEN RAISE EXCEPTION 'upsert_business_workflow_config: actor_user_id required' USING ERRCODE='22000'; END IF;
  SELECT organization_id INTO v_org_id FROM public.business_entities WHERE id = p_business_id;
  IF v_org_id IS NULL THEN RAISE EXCEPTION 'upsert_business_workflow_config: business % not found', p_business_id USING ERRCODE='P0002'; END IF;

  v_validation := public.validate_workflow_config(p_workflow_type, p_enabled_phases);
  IF NOT (v_validation->>'valid')::boolean THEN
    RAISE EXCEPTION 'upsert_business_workflow_config: validation failed: %', v_validation->'errors' USING ERRCODE='23514';
  END IF;

  SELECT * INTO v_before FROM public.business_workflow_config WHERE business_id = p_business_id AND workflow_type = p_workflow_type;

  INSERT INTO public.business_workflow_config (business_id, workflow_type, enabled_phases, enabled_tools, updated_by)
  VALUES (p_business_id, p_workflow_type, p_enabled_phases, p_enabled_tools, p_actor_user_id)
  ON CONFLICT (business_id, workflow_type) DO UPDATE SET
    enabled_phases = EXCLUDED.enabled_phases,
    enabled_tools  = EXCLUDED.enabled_tools,
    updated_by     = EXCLUDED.updated_by,
    updated_at     = clock_timestamp()
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum, p_action => 'WORKFLOW_CONFIG_UPDATED',
    p_subject_type => 'WORKFLOW_CONFIG'::audit.subject_type_enum, p_subject_id => v_row.id,
    p_actor_user_id => p_actor_user_id, p_organization_id => v_org_id, p_business_id => p_business_id,
    p_reason => format('workflow config updated for biz %s / %s', p_business_id, p_workflow_type),
    p_before_state => CASE WHEN v_before.id IS NULL THEN NULL ELSE jsonb_build_object(
      'enabled_phases', v_before.enabled_phases, 'enabled_tools', v_before.enabled_tools
    ) END,
    p_after_state => jsonb_build_object(
      'config_id', v_row.id, 'business_id', p_business_id, 'workflow_type', p_workflow_type,
      'enabled_phases', v_row.enabled_phases, 'enabled_tools', v_row.enabled_tools
    )
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.upsert_business_workflow_config(uuid, public.workflow_type_enum, jsonb, jsonb, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.upsert_business_workflow_config(uuid, public.workflow_type_enum, jsonb, jsonb, uuid) TO service_role;

COMMENT ON TABLE public.workflow_type_definitions IS
'B03·P02 workflow type registry. 4 rows. Code-resident definitions mirrored here as authoritative reference data.';

COMMENT ON TABLE public.workflow_phase_definitions IS
'B03·P02 per-type phase sequences. PLACEHOLDER phase names — Block 12/13 will lock canonical names + correct optional flags.';

COMMENT ON TABLE public.business_workflow_config IS
'B03·P02 per-business workflow config. enabled_phases NULL means all default-enabled; non-NULL is subtractive subset.';

COMMENT ON FUNCTION public.upsert_business_workflow_config(uuid, public.workflow_type_enum, jsonb, jsonb, uuid) IS
'B03·P02 config write chokepoint. Validates (rejects unknown phases and disabled mandatory phases). Emits WORKFLOW_CONFIG_UPDATED with before/after.';
