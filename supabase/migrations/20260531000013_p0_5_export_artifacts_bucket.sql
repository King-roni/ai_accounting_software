-- P0.5 — export-artifacts storage bucket + signed-download.
--
-- Storage had only raw-uploads / processing-zone / archive-bundles; generated
-- export artifacts (CSV/XLSX/PDF/ZIP) had nowhere to live, and the Reports
-- screen never minted a download URL (it called record_export_download and
-- expected a signed_url back, which a DB RPC cannot produce). Creates the
-- private export-artifacts bucket with the same per-(org,business)-path read
-- policy as raw-uploads.
--
-- Writes are default-deny for authenticated (storage.objects has no permissive
-- INSERT policy — confirmed in P0.2): the export-generation worker (R7.1) writes
-- via the service role to {org}/{business}/... and records the path through
-- mark_export_completed(p_storage_object_id). Downloads are signed server-side
-- (web getExportDownloadUrl, service role) + recorded via record_export_download.
--
-- Retention: export artifacts are cleaned by the export-generation worker / a
-- scheduled sweep once R7.1 lands (storage-object deletion is a storage-API
-- operation, not SQL); exports.signed_url_expires_at already bounds link life.

INSERT INTO storage.buckets (id, name, public)
VALUES ('export-artifacts', 'export-artifacts', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS export_artifacts_object_select ON storage.objects;
CREATE POLICY export_artifacts_object_select ON storage.objects
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (
    bucket_id = 'export-artifacts'
    AND (storage.foldername(name))[1] = (current_org())::text
    AND ((storage.foldername(name))[2])::uuid = ANY (current_user_businesses())
  );
