-- B03·P01 Workflow Run Schema (main)
-- =============================================================================
-- Graduates the workflow_runs stub (B04·P04 prelude) to the B03·P01 spec
-- WITHOUT dropping the table (preserves the 6 FKs from archive.archive_runs,
-- public.draft_ledger_entries × 2, public.review_issues, public.processing_artifacts,
-- public.processing_artifact_events). Two-part migration because of ALTER TYPE
-- deferred visibility — see _b03p01_workflow_run_status_enum_graduation.sql
-- for Part 1.
--
-- After this phase: workflow runs can be created with valid shape, phase
-- states can be added per run, tool invocations + audit links can be recorded.
-- No engine LOGIC operates on them yet (B03·P04 ships the state machine,
-- B03·P06 ships the phase execution engine).
-- =============================================================================

-- ---- new enums ---------------------------------------------------------------
CREATE TYPE public.workflow_type_enum AS ENUM (
  'OUT_MONTHLY','IN_MONTHLY','OUT_ADJUSTMENT','IN_ADJUSTMENT'
);
CREATE TYPE public.phase_state_status_enum AS ENUM (
  'PENDING','RUNNING','COMPLETED','FAILED','SKIPPED','HOLDING'
);
CREATE TYPE public.tool_invocation_status_enum AS ENUM (
  'PENDING','SUCCESS','RETRY_PENDING','FAILED'
);
CREATE TYPE public.gate_decision_enum AS ENUM (
  'ADVANCE','HOLD','ROUTE_TO_SIDE_PHASE'
);

-- ---- graduate workflow_runs --------------------------------------------------
-- Stub had: id, organization_id, business_id, run_type text, status (stub enum),
-- principal_snapshot, started_at, finalized_at, created_at, updated_at, legal_hold_active.
-- Spec adds: workflow_type enum (drops run_type), period_start/end, started_by,
-- completed_at, finalized_by, aborted_by/at/reason, parent_run_id, summary_json.

ALTER TABLE public.workflow_runs DROP COLUMN run_type;

ALTER TABLE public.workflow_runs
  ADD COLUMN workflow_type   public.workflow_type_enum NOT NULL,
  ADD COLUMN period_start    timestamptz NOT NULL,
  ADD COLUMN period_end      timestamptz NOT NULL,
  ADD COLUMN started_by      uuid REFERENCES public.users(id) ON DELETE RESTRICT,
  ADD COLUMN completed_at    timestamptz,
  ADD COLUMN finalized_by    uuid REFERENCES public.users(id) ON DELETE RESTRICT,
  ADD COLUMN aborted_by      uuid REFERENCES public.users(id) ON DELETE RESTRICT,
  ADD COLUMN aborted_at      timestamptz,
  ADD COLUMN abort_reason    text,
  ADD COLUMN parent_run_id   uuid REFERENCES public.workflow_runs(id) ON DELETE RESTRICT,
  ADD COLUMN summary_json    jsonb NOT NULL DEFAULT '{}'::jsonb;

-- principal_snapshot already exists from the stub (jsonb NOT NULL); matches
-- B02·P09 contract (spec calls it principal_context_snapshot — same semantic;
-- we keep the existing column name to match B02·P09's established naming).

ALTER TABLE public.workflow_runs
  ADD CONSTRAINT wfr_period_order_chk CHECK (period_end > period_start),
  ADD CONSTRAINT wfr_workflow_type_parent_chk CHECK (
    (workflow_type IN ('OUT_ADJUSTMENT','IN_ADJUSTMENT') AND parent_run_id IS NOT NULL)
    OR
    (workflow_type IN ('OUT_MONTHLY','IN_MONTHLY') AND parent_run_id IS NULL)
  ),
  ADD CONSTRAINT wfr_aborted_state_chk CHECK (
    status <> 'ABORTED' OR (aborted_at IS NOT NULL AND aborted_by IS NOT NULL AND abort_reason IS NOT NULL)
  ),
  ADD CONSTRAINT wfr_finalized_state_chk CHECK (
    status <> 'FINALIZED' OR (finalized_at IS NOT NULL AND finalized_by IS NOT NULL)
  ),
  ADD CONSTRAINT wfr_started_state_chk CHECK (
    status NOT IN ('RUNNING','PAUSED','REVIEW_HOLD','AWAITING_APPROVAL','FINALIZING')
    OR (started_at IS NOT NULL AND started_by IS NOT NULL)
  );

CREATE INDEX IF NOT EXISTS idx_workflow_runs_tenant_type_status
  ON public.workflow_runs (organization_id, business_id, workflow_type, status);
CREATE INDEX IF NOT EXISTS idx_workflow_runs_parent
  ON public.workflow_runs (parent_run_id) WHERE parent_run_id IS NOT NULL;

-- ---- parent_run_id must reference a FINALIZED run (trigger; CHECKs can't subquery) ----
CREATE OR REPLACE FUNCTION public.fn_check_parent_run_finalized()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_parent_status public.workflow_run_status_enum;
BEGIN
  IF NEW.parent_run_id IS NULL THEN RETURN NEW; END IF;
  SELECT status INTO v_parent_status FROM public.workflow_runs WHERE id = NEW.parent_run_id;
  IF v_parent_status IS NULL THEN
    RAISE EXCEPTION 'workflow_runs: parent_run_id % does not exist', NEW.parent_run_id USING ERRCODE='P0002';
  END IF;
  IF v_parent_status <> 'FINALIZED' THEN
    RAISE EXCEPTION 'workflow_runs: parent_run_id % must be FINALIZED (got %)', NEW.parent_run_id, v_parent_status USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_workflow_runs_parent_finalized
  BEFORE INSERT OR UPDATE OF parent_run_id ON public.workflow_runs
  FOR EACH ROW EXECUTE FUNCTION public.fn_check_parent_run_finalized();

-- ---- workflow_phase_states --------------------------------------------------
CREATE TABLE public.workflow_phase_states (
  id                uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  workflow_run_id   uuid NOT NULL REFERENCES public.workflow_runs(id) ON DELETE CASCADE,
  phase_name        text NOT NULL,
  phase_order       int  NOT NULL,
  status            public.phase_state_status_enum NOT NULL DEFAULT 'PENDING',
  started_at        timestamptz,
  completed_at      timestamptz,
  retry_count       int NOT NULL DEFAULT 0,
  error_summary     text,
  gate_decision     public.gate_decision_enum,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT wps_phase_name_nonempty CHECK (length(btrim(phase_name)) > 0),
  CONSTRAINT wps_phase_order_nonneg  CHECK (phase_order >= 0),
  CONSTRAINT wps_retry_count_nonneg  CHECK (retry_count >= 0),
  CONSTRAINT wps_unique_run_order    UNIQUE (workflow_run_id, phase_order)
);

CREATE INDEX idx_workflow_phase_states_run_order ON public.workflow_phase_states (workflow_run_id, phase_order);
CREATE INDEX idx_workflow_phase_states_status    ON public.workflow_phase_states (status);

CREATE TRIGGER workflow_phase_states_set_updated_at
  BEFORE UPDATE ON public.workflow_phase_states
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ---- tool_invocations -------------------------------------------------------
CREATE TABLE public.tool_invocations (
  id                  uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  workflow_run_id     uuid NOT NULL REFERENCES public.workflow_runs(id) ON DELETE CASCADE,
  phase_state_id      uuid NOT NULL REFERENCES public.workflow_phase_states(id) ON DELETE CASCADE,
  tool_name           text NOT NULL,
  attempt_number      int  NOT NULL DEFAULT 1,
  input_hash          text,
  output_hash         text,
  status              public.tool_invocation_status_enum NOT NULL DEFAULT 'PENDING',
  dedup_key           text,
  external_request_id text,
  started_at          timestamptz,
  completed_at        timestamptz,
  error_summary       text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ti_tool_name_nonempty CHECK (length(btrim(tool_name)) > 0),
  CONSTRAINT ti_attempt_positive   CHECK (attempt_number >= 1),
  CONSTRAINT ti_input_hash_format  CHECK (input_hash  IS NULL OR input_hash  ~ '^[0-9a-f]{64}$'),
  CONSTRAINT ti_output_hash_format CHECK (output_hash IS NULL OR output_hash ~ '^[0-9a-f]{64}$')
);

CREATE UNIQUE INDEX idx_tool_invocations_unique_dedup
  ON public.tool_invocations (workflow_run_id, dedup_key)
  WHERE dedup_key IS NOT NULL;
CREATE INDEX idx_tool_invocations_phase    ON public.tool_invocations (phase_state_id);
CREATE INDEX idx_tool_invocations_status   ON public.tool_invocations (status);
CREATE INDEX idx_tool_invocations_external ON public.tool_invocations (external_request_id) WHERE external_request_id IS NOT NULL;

CREATE TRIGGER tool_invocations_set_updated_at
  BEFORE UPDATE ON public.tool_invocations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ---- phase_audit_links (the bridge to audit.audit_events) ------------------
CREATE TABLE public.phase_audit_links (
  id                uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  workflow_run_id   uuid NOT NULL REFERENCES public.workflow_runs(id) ON DELETE CASCADE,
  phase_state_id    uuid REFERENCES public.workflow_phase_states(id) ON DELETE CASCADE,
  audit_event_id    uuid NOT NULL REFERENCES audit.audit_events(id) ON DELETE RESTRICT,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pal_unique_bridge UNIQUE (workflow_run_id, audit_event_id)
);

CREATE INDEX idx_phase_audit_links_run_phase ON public.phase_audit_links (workflow_run_id, phase_state_id);
CREATE INDEX idx_phase_audit_links_audit     ON public.phase_audit_links (audit_event_id);

-- ---- RLS Workflow-First template on all 3 new tables ------------------------
ALTER TABLE public.workflow_phase_states ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workflow_phase_states FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.tool_invocations      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tool_invocations      FORCE  ROW LEVEL SECURITY;
ALTER TABLE public.phase_audit_links     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.phase_audit_links     FORCE  ROW LEVEL SECURITY;

CREATE POLICY wps_select_tenant ON public.workflow_phase_states
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.workflow_runs wr
     WHERE wr.id = workflow_phase_states.workflow_run_id
       AND wr.organization_id = public.current_org()
       AND (wr.business_id = ANY(public.current_user_businesses()))
  ));
CREATE POLICY wps_no_insert ON public.workflow_phase_states AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY wps_no_update ON public.workflow_phase_states AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY wps_no_delete ON public.workflow_phase_states AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

CREATE POLICY ti_select_tenant ON public.tool_invocations
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.workflow_runs wr
     WHERE wr.id = tool_invocations.workflow_run_id
       AND wr.organization_id = public.current_org()
       AND (wr.business_id = ANY(public.current_user_businesses()))
  ));
CREATE POLICY ti_no_insert ON public.tool_invocations AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY ti_no_update ON public.tool_invocations AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY ti_no_delete ON public.tool_invocations AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

CREATE POLICY pal_select_tenant ON public.phase_audit_links
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.workflow_runs wr
     WHERE wr.id = phase_audit_links.workflow_run_id
       AND wr.organization_id = public.current_org()
       AND (wr.business_id = ANY(public.current_user_businesses()))
  ));
CREATE POLICY pal_no_insert ON public.phase_audit_links AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY pal_no_update ON public.phase_audit_links AS RESTRICTIVE FOR UPDATE TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY pal_no_delete ON public.phase_audit_links AS RESTRICTIVE FOR DELETE TO authenticated USING (false);

GRANT SELECT ON public.workflow_phase_states, public.tool_invocations, public.phase_audit_links TO authenticated, service_role;

COMMENT ON TABLE public.workflow_runs IS
'B03·P01 (graduated from B04·P04 stub). Workflow engine read+write target. RLS Workflow-First — writes via DEFINER RPCs only (B03·P04 state machine, B03·P06 phase engine). principal_snapshot matches B02·P09 contract (spec calls it principal_context_snapshot — same semantic).';

COMMENT ON TABLE public.workflow_phase_states IS
'B03·P01 per-run phase rows; phase_order UNIQUE within a run; status drives B03·P04 state machine. gate_decision set on phase exit by B03·P05 evaluator.';

COMMENT ON TABLE public.tool_invocations IS
'B03·P01 per-tool-call rows; partial-UNIQUE (workflow_run_id, dedup_key) WHERE dedup_key IS NOT NULL gives B03·P07 idempotency. input_hash + output_hash link to Processing zone artefacts (Block 04).';

COMMENT ON TABLE public.phase_audit_links IS
'B03·P01 bridge table — workflow runs reconstruct their audit trail by JOINing through here to audit.audit_events. No payload duplication.';
