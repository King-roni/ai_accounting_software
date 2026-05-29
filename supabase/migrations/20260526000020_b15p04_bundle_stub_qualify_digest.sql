-- B15·P04 fix-up: _construct_archive_bundle_stub called digest() unqualified,
-- but pgcrypto lives in the extensions schema and isn't on the search_path
-- set in the function. Qualify with extensions.digest() and add extensions
-- to the function's SET search_path.

CREATE OR REPLACE FUNCTION public._construct_archive_bundle_stub(
  p_run_id uuid, p_business_id uuid, p_organization_id uuid,
  p_period_start date, p_period_end date, p_started_by uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_pkg_id uuid := public.gen_uuid_v7();
  v_manifest_id uuid := public.gen_uuid_v7();
  v_bundle_hash text;
  v_manifest_hash text;
BEGIN
  SELECT encode(extensions.digest(coalesce(string_agg(t.transaction_fingerprint, '' ORDER BY t.id), '')
                       || p_run_id::text, 'sha256'), 'hex')
    INTO v_bundle_hash
    FROM public.transactions t
   WHERE t.business_id = p_business_id
     AND t.transaction_date BETWEEN p_period_start AND p_period_end;
  v_bundle_hash := coalesce(v_bundle_hash, repeat('0', 64));
  INSERT INTO public.archive_packages (id, organization_id, business_id, workflow_run_id,
    period_start, period_end, package_storage_object_id, bundle_hash_anchor,
    created_by_user_id, step_up_auth_used, original_finalization)
  VALUES (v_pkg_id, p_organization_id, p_business_id, p_run_id,
          p_period_start, p_period_end,
          format('archive/%s/%s/v1.zip', p_business_id, p_run_id),
          v_bundle_hash, p_started_by, true, true);
  v_manifest_hash := encode(extensions.digest(v_pkg_id::text || '|v1|' || v_bundle_hash, 'sha256'), 'hex');
  INSERT INTO public.archive_manifests (id, organization_id, business_id, archive_package_id,
    manifest_version_number, manifest_storage_object_id, manifest_hash,
    produced_by_run_id, produced_by_approval_id)
  VALUES (v_manifest_id, p_organization_id, p_business_id, v_pkg_id,
          1, format('archive/%s/%s/manifest_v1.json', p_business_id, p_run_id),
          v_manifest_hash, p_run_id,
          public.latest_qualifying_step_up_approval(p_business_id, p_run_id));
  RETURN v_pkg_id;
END;
$$;
