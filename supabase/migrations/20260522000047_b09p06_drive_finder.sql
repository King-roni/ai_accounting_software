-- B09·P06 — Drive Finder — DB scaffold.
-- Lifecycle for transaction-scoped Google Drive folder searches. Python
-- orchestrator owns the Drive API, subfolder selection (2-week convention
-- + cross-period buffer), file-name scoring, and rate-limit handling; this
-- migration delivers the lifecycle tables, audit-coupled RPCs, and the
-- non-convention review-issue plumbing.
--
-- Audit family DRIVE_FINDER:
--   DRIVE_FINDER_FOLDERS_SELECTED          (TRANSACTION subject)
--   DRIVE_FINDER_FILES_LISTED              (TRANSACTION subject)
--   DRIVE_FINDER_RESULT_FOUND              (DOCUMENT subject — new)
--   DRIVE_FINDER_NON_CONVENTION_DETECTED   (BUSINESS subject)
--   DRIVE_FINDER_RESULT_DUPLICATE_SOURCE   (DOCUMENT subject — existing)

-- 1. Enums -------------------------------------------------------------------

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname='drive_finder_run_status_enum' AND typnamespace='public'::regnamespace) THEN
    CREATE TYPE public.drive_finder_run_status_enum AS ENUM ('STARTED','COMPLETED','FAILED');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname='drive_finder_result_outcome_enum' AND typnamespace='public'::regnamespace) THEN
    CREATE TYPE public.drive_finder_result_outcome_enum AS ENUM ('FOUND','DUPLICATE_SOURCE');
  END IF;
END$$;


-- 2. drive_finder_runs -------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.drive_finder_runs (
  id                          uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id             uuid NOT NULL,
  business_id                 uuid NOT NULL,
  transaction_id              uuid NOT NULL,
  root_folder_id              text NOT NULL,
  status                      public.drive_finder_run_status_enum NOT NULL,
  subfolders_selected_count   integer NOT NULL DEFAULT 0,
  files_listed_count          integer NOT NULL DEFAULT 0,
  found_count                 integer NOT NULL DEFAULT 0,
  duplicate_count             integer NOT NULL DEFAULT 0,
  error_summary               text,
  started_at                  timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at                timestamptz,
  failed_at                   timestamptz,
  CONSTRAINT dfr_root_nonempty CHECK (length(trim(root_folder_id)) > 0),
  CONSTRAINT dfr_counts_nonneg CHECK (
    subfolders_selected_count >= 0 AND files_listed_count >= 0
    AND found_count >= 0 AND duplicate_count >= 0
  ),
  CONSTRAINT dfr_completed_pairing CHECK (
    (status <> 'COMPLETED') OR completed_at IS NOT NULL
  ),
  CONSTRAINT dfr_failed_pairing CHECK (
    (status <> 'FAILED')
    OR (failed_at IS NOT NULL AND error_summary IS NOT NULL AND length(trim(error_summary)) > 0)
  ),
  CONSTRAINT dfr_org_fk      FOREIGN KEY (organization_id) REFERENCES public.organizations(id)    ON DELETE RESTRICT,
  CONSTRAINT dfr_business_fk FOREIGN KEY (business_id)     REFERENCES public.business_entities(id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS dfr_by_txn
  ON public.drive_finder_runs (business_id, transaction_id, started_at DESC);

ALTER TABLE public.drive_finder_runs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS dfr_select ON public.drive_finder_runs;
CREATE POLICY dfr_select ON public.drive_finder_runs FOR SELECT
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
DROP POLICY IF EXISTS dfr_no_insert ON public.drive_finder_runs;
CREATE POLICY dfr_no_insert ON public.drive_finder_runs FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS dfr_no_update ON public.drive_finder_runs;
CREATE POLICY dfr_no_update ON public.drive_finder_runs FOR UPDATE USING (false);
DROP POLICY IF EXISTS dfr_no_delete ON public.drive_finder_runs;
CREATE POLICY dfr_no_delete ON public.drive_finder_runs FOR DELETE USING (false);


-- 3. drive_finder_results ----------------------------------------------------

CREATE TABLE IF NOT EXISTS public.drive_finder_results (
  id                    uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id       uuid NOT NULL,
  business_id           uuid NOT NULL,
  run_id                uuid NOT NULL,
  drive_file_id         text NOT NULL,
  file_name             text,
  subfolder_name        text,
  outcome               public.drive_finder_result_outcome_enum NOT NULL,
  document_id           uuid,
  discovery_confidence  numeric,
  processed_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT dfres_file_id_nonempty CHECK (length(trim(drive_file_id)) > 0),
  CONSTRAINT dfres_confidence_range CHECK (
    discovery_confidence IS NULL OR discovery_confidence BETWEEN 0 AND 1
  ),
  CONSTRAINT dfres_found_requires CHECK (
    (outcome <> 'FOUND')
    OR (document_id IS NOT NULL AND discovery_confidence IS NOT NULL)
  ),
  CONSTRAINT dfres_duplicate_requires_doc CHECK (
    (outcome <> 'DUPLICATE_SOURCE') OR (document_id IS NOT NULL)
  ),
  CONSTRAINT dfres_run_fk      FOREIGN KEY (run_id)          REFERENCES public.drive_finder_runs(id) ON DELETE RESTRICT,
  CONSTRAINT dfres_org_fk      FOREIGN KEY (organization_id) REFERENCES public.organizations(id)     ON DELETE RESTRICT,
  CONSTRAINT dfres_business_fk FOREIGN KEY (business_id)     REFERENCES public.business_entities(id) ON DELETE RESTRICT,
  CONSTRAINT dfres_document_fk FOREIGN KEY (document_id)     REFERENCES public.documents(id)         ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS dfres_unique_per_run
  ON public.drive_finder_results (run_id, drive_file_id);
CREATE INDEX IF NOT EXISTS dfres_by_outcome
  ON public.drive_finder_results (run_id, outcome);

ALTER TABLE public.drive_finder_results ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS dfres_select ON public.drive_finder_results;
CREATE POLICY dfres_select ON public.drive_finder_results FOR SELECT
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
DROP POLICY IF EXISTS dfres_no_insert ON public.drive_finder_results;
CREATE POLICY dfres_no_insert ON public.drive_finder_results FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS dfres_no_update ON public.drive_finder_results;
CREATE POLICY dfres_no_update ON public.drive_finder_results FOR UPDATE USING (false);
DROP POLICY IF EXISTS dfres_no_delete ON public.drive_finder_results;
CREATE POLICY dfres_no_delete ON public.drive_finder_results FOR DELETE USING (false);


-- 4. begin_drive_finder_run --------------------------------------------------

CREATE OR REPLACE FUNCTION public.begin_drive_finder_run(
  p_organization_id uuid,
  p_business_id     uuid,
  p_transaction_id  uuid,
  p_root_folder_id  text,
  p_context         jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_run_id uuid;
BEGIN
  IF p_root_folder_id IS NULL OR length(trim(p_root_folder_id)) = 0 THEN
    RAISE EXCEPTION 'ROOT_FOLDER_ID_REQUIRED' USING errcode='check_violation';
  END IF;

  INSERT INTO public.drive_finder_runs (
    organization_id, business_id, transaction_id, root_folder_id, status
  ) VALUES (
    p_organization_id, p_business_id, p_transaction_id, p_root_folder_id, 'STARTED'
  ) RETURNING id INTO v_run_id;

  RETURN jsonb_build_object(
    'decision','STARTED','run_id',v_run_id,
    'transaction_id',p_transaction_id,'root_folder_id',p_root_folder_id
  );
END;
$$;


-- 5. record_drive_finder_folders_selected ------------------------------------

CREATE OR REPLACE FUNCTION public.record_drive_finder_folders_selected(
  p_run_id            uuid,
  p_subfolder_count   integer,
  p_buffer_days       integer,
  p_subfolder_names   text[] DEFAULT NULL,
  p_context           jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid; v_business_id uuid; v_transaction_id uuid;
BEGIN
  IF p_subfolder_count IS NULL OR p_subfolder_count < 0 THEN
    RAISE EXCEPTION 'SUBFOLDER_COUNT_NONNEGATIVE' USING errcode='check_violation';
  END IF;
  SELECT organization_id, business_id, transaction_id
    INTO v_organization_id, v_business_id, v_transaction_id
  FROM public.drive_finder_runs WHERE id = p_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','RUN_NOT_FOUND','run_id',p_run_id);
  END IF;

  UPDATE public.drive_finder_runs
    SET subfolders_selected_count = p_subfolder_count
  WHERE id = p_run_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='DRIVE_FINDER_FOLDERS_SELECTED',
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=v_transaction_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='drive_finder',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'run_id',p_run_id,
      'subfolder_count',p_subfolder_count,
      'buffer_days',p_buffer_days,
      'subfolder_names',to_jsonb(p_subfolder_names)
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','RECORDED','run_id',p_run_id,
    'subfolder_count',p_subfolder_count
  );
END;
$$;


-- 6. record_drive_finder_files_listed ----------------------------------------

CREATE OR REPLACE FUNCTION public.record_drive_finder_files_listed(
  p_run_id        uuid,
  p_subfolder_name text,
  p_file_count    integer,
  p_context       jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid; v_business_id uuid; v_transaction_id uuid;
BEGIN
  IF p_file_count IS NULL OR p_file_count < 0 THEN
    RAISE EXCEPTION 'FILE_COUNT_NONNEGATIVE' USING errcode='check_violation';
  END IF;
  SELECT organization_id, business_id, transaction_id
    INTO v_organization_id, v_business_id, v_transaction_id
  FROM public.drive_finder_runs WHERE id = p_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','RUN_NOT_FOUND','run_id',p_run_id);
  END IF;

  UPDATE public.drive_finder_runs
    SET files_listed_count = files_listed_count + p_file_count
  WHERE id = p_run_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='DRIVE_FINDER_FILES_LISTED',
    p_subject_type:='TRANSACTION'::audit.subject_type_enum,
    p_subject_id:=v_transaction_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='drive_finder',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'run_id',p_run_id,
      'subfolder_name',p_subfolder_name,
      'file_count',p_file_count
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','RECORDED','run_id',p_run_id,
    'subfolder_name',p_subfolder_name,'file_count',p_file_count
  );
END;
$$;


-- 7. record_drive_finder_result_found ----------------------------------------

CREATE OR REPLACE FUNCTION public.record_drive_finder_result_found(
  p_run_id               uuid,
  p_drive_file_id        text,
  p_file_name            text,
  p_subfolder_name       text,
  p_discovery_confidence numeric,
  p_document_type        public.document_type_enum DEFAULT 'INVOICE',
  p_context              jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid; v_business_id uuid; v_transaction_id uuid;
  v_existing_doc uuid; v_source_extid text; v_new_doc_id uuid;
BEGIN
  IF p_drive_file_id IS NULL OR length(trim(p_drive_file_id)) = 0 THEN
    RAISE EXCEPTION 'DRIVE_FILE_ID_REQUIRED' USING errcode='check_violation';
  END IF;
  IF p_discovery_confidence IS NULL
     OR p_discovery_confidence < 0 OR p_discovery_confidence > 1 THEN
    RAISE EXCEPTION 'DISCOVERY_CONFIDENCE_OUT_OF_RANGE' USING errcode='check_violation';
  END IF;

  SELECT organization_id, business_id, transaction_id
    INTO v_organization_id, v_business_id, v_transaction_id
  FROM public.drive_finder_runs WHERE id = p_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','RUN_NOT_FOUND','run_id',p_run_id);
  END IF;

  v_source_extid := 'drive:' || p_drive_file_id;

  SELECT document_id INTO v_existing_doc
  FROM public.document_source_links
  WHERE business_id = v_business_id AND source_kind = 'DRIVE'
    AND source_external_id = v_source_extid
  LIMIT 1;

  IF FOUND THEN
    INSERT INTO public.drive_finder_results (
      organization_id, business_id, run_id, drive_file_id, file_name,
      subfolder_name, outcome, document_id
    ) VALUES (
      v_organization_id, v_business_id, p_run_id, p_drive_file_id, p_file_name,
      p_subfolder_name, 'DUPLICATE_SOURCE', v_existing_doc
    );

    PERFORM audit.emit_audit(
      p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
      p_action:='DRIVE_FINDER_RESULT_DUPLICATE_SOURCE',
      p_subject_type:='DOCUMENT'::audit.subject_type_enum,
      p_subject_id:=v_existing_doc,
      p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
      p_actor_system:='drive_finder',
      p_organization_id:=v_organization_id, p_business_id:=v_business_id,
      p_before_state:=NULL,
      p_after_state:=jsonb_build_object(
        'run_id',p_run_id,'drive_file_id',p_drive_file_id,
        'existing_document_id',v_existing_doc
      ),
      p_reason:=NULL, p_request_context:=p_context
    );

    UPDATE public.drive_finder_runs
      SET duplicate_count = duplicate_count + 1
    WHERE id = p_run_id;

    RETURN jsonb_build_object(
      'decision','DUPLICATE_SOURCE','run_id',p_run_id,
      'document_id',v_existing_doc,'drive_file_id',p_drive_file_id
    );
  END IF;

  INSERT INTO public.documents (
    organization_id, business_id, source, document_type,
    original_filename, discovery_reason, discovery_confidence
  ) VALUES (
    v_organization_id, v_business_id, 'DRIVE', p_document_type,
    p_file_name, 'drive_finder:' || COALESCE(p_subfolder_name,'root'),
    p_discovery_confidence
  ) RETURNING id INTO v_new_doc_id;

  INSERT INTO public.document_source_links (
    organization_id, business_id, document_id, source_kind,
    source_external_id, discovery_reason
  ) VALUES (
    v_organization_id, v_business_id, v_new_doc_id, 'DRIVE',
    v_source_extid, 'drive_finder:' || COALESCE(p_subfolder_name,'root')
  );

  INSERT INTO public.drive_finder_results (
    organization_id, business_id, run_id, drive_file_id, file_name,
    subfolder_name, outcome, document_id, discovery_confidence
  ) VALUES (
    v_organization_id, v_business_id, p_run_id, p_drive_file_id, p_file_name,
    p_subfolder_name, 'FOUND', v_new_doc_id, p_discovery_confidence
  );

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='DRIVE_FINDER_RESULT_FOUND',
    p_subject_type:='DOCUMENT'::audit.subject_type_enum,
    p_subject_id:=v_new_doc_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='drive_finder',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'run_id',p_run_id,'drive_file_id',p_drive_file_id,
      'file_name',p_file_name,'subfolder_name',p_subfolder_name,
      'discovery_confidence',p_discovery_confidence,'document_id',v_new_doc_id
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  UPDATE public.drive_finder_runs
    SET found_count = found_count + 1
  WHERE id = p_run_id;

  RETURN jsonb_build_object(
    'decision','FOUND','run_id',p_run_id,'document_id',v_new_doc_id,
    'drive_file_id',p_drive_file_id,'discovery_confidence',p_discovery_confidence
  );
END;
$$;


-- 8. record_drive_finder_non_convention_detected -----------------------------

CREATE OR REPLACE FUNCTION public.record_drive_finder_non_convention_detected(
  p_run_id                   uuid,
  p_workflow_run_id          uuid,
  p_detected_subfolder_names text[],
  p_context                  jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_organization_id uuid; v_business_id uuid; v_transaction_id uuid;
  v_review_issue_id uuid;
BEGIN
  SELECT organization_id, business_id, transaction_id
    INTO v_organization_id, v_business_id, v_transaction_id
  FROM public.drive_finder_runs WHERE id = p_run_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','RUN_NOT_FOUND','run_id',p_run_id);
  END IF;

  INSERT INTO public.review_issues (
    organization_id, business_id, workflow_run_id, transaction_id,
    issue_type, issue_group, severity,
    plain_language_title, plain_language_description, recommended_action,
    card_payload_json
  ) VALUES (
    v_organization_id, v_business_id, p_workflow_run_id, v_transaction_id,
    'drive.folder_naming_non_convention',
    'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
    'MEDIUM'::public.review_issue_severity_enum,
    'Drive subfolders do not follow the 2-week date-range convention',
    'We expected your Drive subfolders to be named like 2026-04-01_to_2026-04-14 so we can date-scope the search. Falling back to a flat search across the root folder for now.',
    'Rename subfolders to YYYY-MM-DD_to_YYYY-MM-DD ranges, or change the naming convention in Drive integration settings',
    jsonb_build_object(
      'run_id', p_run_id,
      'detected_subfolder_names', to_jsonb(p_detected_subfolder_names)
    )
  ) RETURNING id INTO v_review_issue_id;

  PERFORM audit.emit_audit(
    p_actor_kind:='SYSTEM'::audit.actor_kind_enum,
    p_action:='DRIVE_FINDER_NON_CONVENTION_DETECTED',
    p_subject_type:='BUSINESS'::audit.subject_type_enum,
    p_subject_id:=v_business_id,
    p_actor_user_id:=NULL, p_actor_role:=NULL, p_actor_session_id:=NULL,
    p_actor_system:='drive_finder',
    p_organization_id:=v_organization_id, p_business_id:=v_business_id,
    p_before_state:=NULL,
    p_after_state:=jsonb_build_object(
      'run_id',p_run_id,
      'review_issue_id',v_review_issue_id,
      'detected_subfolder_names',to_jsonb(p_detected_subfolder_names)
    ),
    p_reason:=NULL, p_request_context:=p_context
  );

  RETURN jsonb_build_object(
    'decision','REVIEW_ISSUE_RAISED','run_id',p_run_id,
    'review_issue_id',v_review_issue_id
  );
END;
$$;


-- 9. complete_drive_finder_run -----------------------------------------------

CREATE OR REPLACE FUNCTION public.complete_drive_finder_run(p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE
  v_status public.drive_finder_run_status_enum;
  v_found int := 0; v_dup int := 0;
BEGIN
  SELECT status INTO v_status FROM public.drive_finder_runs WHERE id = p_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','RUN_NOT_FOUND','run_id',p_run_id);
  END IF;
  IF v_status <> 'STARTED' THEN
    RETURN jsonb_build_object(
      'decision','REJECTED','reason','RUN_NOT_STARTED',
      'run_id',p_run_id,'current_status',v_status
    );
  END IF;

  SELECT
    count(*) FILTER (WHERE outcome='FOUND'),
    count(*) FILTER (WHERE outcome='DUPLICATE_SOURCE')
  INTO v_found, v_dup
  FROM public.drive_finder_results WHERE run_id = p_run_id;

  UPDATE public.drive_finder_runs
    SET status='COMPLETED', found_count=v_found, duplicate_count=v_dup,
        completed_at=clock_timestamp()
  WHERE id = p_run_id;

  RETURN jsonb_build_object(
    'decision','COMPLETED','run_id',p_run_id,
    'found_count',v_found,'duplicate_count',v_dup
  );
END;
$$;


-- 10. fail_drive_finder_run --------------------------------------------------

CREATE OR REPLACE FUNCTION public.fail_drive_finder_run(p_run_id uuid, p_error_summary text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, audit, pg_temp
AS $$
DECLARE v_status public.drive_finder_run_status_enum;
BEGIN
  IF p_error_summary IS NULL OR length(trim(p_error_summary)) = 0 THEN
    RAISE EXCEPTION 'ERROR_SUMMARY_REQUIRED' USING errcode='check_violation';
  END IF;
  SELECT status INTO v_status FROM public.drive_finder_runs WHERE id = p_run_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('decision','REJECTED','reason','RUN_NOT_FOUND','run_id',p_run_id);
  END IF;
  IF v_status <> 'STARTED' THEN
    RETURN jsonb_build_object(
      'decision','REJECTED','reason','RUN_NOT_STARTED',
      'run_id',p_run_id,'current_status',v_status
    );
  END IF;

  UPDATE public.drive_finder_runs
    SET status='FAILED', error_summary=p_error_summary, failed_at=clock_timestamp()
  WHERE id = p_run_id;

  RETURN jsonb_build_object(
    'decision','FAILED','run_id',p_run_id,'error_summary',p_error_summary
  );
END;
$$;


-- 11. Privilege grants -------------------------------------------------------

REVOKE EXECUTE ON FUNCTION public.begin_drive_finder_run(uuid, uuid, uuid, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_drive_finder_folders_selected(uuid, integer, integer, text[], jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_drive_finder_files_listed(uuid, text, integer, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_drive_finder_result_found(uuid, text, text, text, numeric, public.document_type_enum, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_drive_finder_non_convention_detected(uuid, uuid, text[], jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.complete_drive_finder_run(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fail_drive_finder_run(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.begin_drive_finder_run(uuid, uuid, uuid, text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_drive_finder_folders_selected(uuid, integer, integer, text[], jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_drive_finder_files_listed(uuid, text, integer, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_drive_finder_result_found(uuid, text, text, text, numeric, public.document_type_enum, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_drive_finder_non_convention_detected(uuid, uuid, text[], jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.complete_drive_finder_run(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fail_drive_finder_run(uuid, text) TO authenticated, service_role;
