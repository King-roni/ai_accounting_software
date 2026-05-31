"use server";

/**
 * Upload server actions (P0.2) — the entry point of the bookkeeping journey.
 *
 * The raw-uploads / processing-zone / archive-bundles storage buckets are
 * private and RLS blocks `authenticated` INSERT, so the browser cannot write
 * to them directly. The flow is therefore:
 *
 *   1. prepareUpload()  — (server, user session) request_raw_upload to allocate
 *      a raw_upload_files PENDING row + storage path, then (service role)
 *      createSignedUploadUrl to mint a one-time upload token for that path.
 *   2. client            — uploadToSignedUrl(path, token, file) PUTs the bytes.
 *   3. completeStatementUpload() / completeDocumentUpload() — (service role)
 *      confirm_raw_upload, then for statements complete_statement_upload +
 *      emit_statement_upload_completed_event so the P0.1 orchestrator picks the
 *      event off the outbox and drives OUT_MONTHLY + IN_MONTHLY runs.
 *
 * confirm_raw_upload / complete_statement_upload / emit_* are service_role-only;
 * request_raw_upload runs as the user (current_user_id + business-access check).
 */
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export type UploadEntityType = "STATEMENT" | "INVOICE" | "RECEIPT" | "CONTRACT";

type Fail = { ok: false; error: string };
type GrantOk = {
  ok: true;
  rawUploadFileId: string;
  bucket: string;
  path: string;
  token: string;
};

/** Resolve the public.users.id (the actor id RPCs expect) from the session. */
async function resolveActorUserId(): Promise<string | null> {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;
  const admin = createSupabaseAdminClient();
  const { data } = await admin
    .from("users")
    .select("id")
    .eq("auth_user_id", user.id)
    .maybeSingle();
  return (data?.id as string | undefined) ?? null;
}

export async function prepareUpload(input: {
  businessId: string;
  entityType: UploadEntityType;
  filename: string;
  sizeBytes: number;
  contentType: string;
}): Promise<GrantOk | Fail> {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "NOT_AUTHENTICATED" };

  // request_raw_upload runs as the user: validates business access, size/type
  // caps, and allocates a raw_upload_files PENDING row + storage path.
  const { data, error } = await supabase.rpc("request_raw_upload", {
    p_business_id: input.businessId,
    p_entity_type: input.entityType,
    p_original_filename: input.filename,
    p_declared_size_bytes: input.sizeBytes,
    p_declared_content_type: input.contentType,
    p_grant_ttl_seconds: 600,
  });
  if (error) return { ok: false, error: error.message };
  const grant = (Array.isArray(data) ? data[0] : data) as
    | { raw_upload_file_id: string; storage_bucket: string; storage_path: string }
    | undefined;
  if (!grant?.raw_upload_file_id) return { ok: false, error: "GRANT_FAILED" };

  // The bucket is private + write-locked for authenticated; mint a one-time
  // signed upload token with the service role so the browser can PUT bytes.
  const admin = createSupabaseAdminClient();
  const { data: signed, error: signErr } = await admin.storage
    .from(grant.storage_bucket)
    .createSignedUploadUrl(grant.storage_path);
  if (signErr || !signed?.token) {
    return { ok: false, error: signErr?.message ?? "SIGN_FAILED" };
  }

  return {
    ok: true,
    rawUploadFileId: grant.raw_upload_file_id,
    bucket: grant.storage_bucket,
    path: grant.storage_path,
    token: signed.token,
  };
}

export async function completeStatementUpload(input: {
  businessId: string;
  rawUploadFileId: string;
  storagePath: string;
  fileHash: string;
  sizeBytes: number;
  contentType: string;
  fileFormat: "CSV" | "PDF";
  provider: string;
  periodYear: number;
  periodMonth: number;
  filename: string;
}): Promise<{ ok: true; uploadId: string } | Fail> {
  const actorUserId = await resolveActorUserId();
  if (!actorUserId) return { ok: false, error: "NOT_AUTHENTICATED" };
  const admin = createSupabaseAdminClient();

  const { data: bankAccount } = await admin
    .from("bank_accounts")
    .select("id")
    .eq("business_id", input.businessId)
    .limit(1)
    .maybeSingle();
  if (!bankAccount?.id) return { ok: false, error: "NO_BANK_ACCOUNT_CONFIGURED" };

  const { error: confirmErr } = await admin.rpc("confirm_raw_upload", {
    p_raw_upload_file_id: input.rawUploadFileId,
    p_file_hash: input.fileHash,
    p_actual_size_bytes: input.sizeBytes,
    p_actual_content_type: input.contentType,
    p_confirmed_by_system: "web_upload",
  });
  if (confirmErr) return { ok: false, error: confirmErr.message };

  const mm = String(input.periodMonth).padStart(2, "0");
  const lastDay = new Date(Date.UTC(input.periodYear, input.periodMonth, 0)).getUTCDate();
  const periodStart = `${input.periodYear}-${mm}-01`;
  const periodEnd = `${input.periodYear}-${mm}-${String(lastDay).padStart(2, "0")}`;

  const { data: completeRaw, error: completeErr } = await admin.rpc(
    "complete_statement_upload",
    {
      p_actor_user_id: actorUserId,
      p_business_id: input.businessId,
      p_bank_account_id: bankAccount.id,
      p_file_id: input.storagePath,
      p_file_hash: input.fileHash,
      p_file_format: input.fileFormat,
      p_provider: input.provider.trim().toUpperCase(),
      p_declared_period_start: periodStart,
      p_declared_period_end: periodEnd,
      p_original_filename: input.filename,
    },
  );
  if (completeErr) return { ok: false, error: completeErr.message };
  const complete = completeRaw as {
    ok?: boolean;
    upload_id?: string;
    reason?: string;
    message?: string;
  };
  if (!complete?.ok || !complete.upload_id) {
    return { ok: false, error: complete?.message ?? complete?.reason ?? "COMPLETE_FAILED" };
  }

  const { data: emitRaw, error: emitErr } = await admin.rpc(
    "emit_statement_upload_completed_event",
    { p_statement_upload_id: complete.upload_id, p_actor_user_id: actorUserId },
  );
  if (emitErr) return { ok: false, error: emitErr.message };
  const emit = emitRaw as { ok?: boolean; reason?: string };
  if (emit && emit.ok === false) {
    return { ok: false, error: emit.reason ?? "EMIT_FAILED" };
  }

  return { ok: true, uploadId: complete.upload_id };
}

export async function completeDocumentUpload(input: {
  rawUploadFileId: string;
  fileHash: string;
  sizeBytes: number;
  contentType: string;
}): Promise<{ ok: true } | Fail> {
  const actorUserId = await resolveActorUserId();
  if (!actorUserId) return { ok: false, error: "NOT_AUTHENTICATED" };
  const admin = createSupabaseAdminClient();

  // Confirm the raw upload (bytes landed). OCR + field extraction → the
  // matchable `documents` row run server-side in the B09 intake pipeline (P2).
  const { error } = await admin.rpc("confirm_raw_upload", {
    p_raw_upload_file_id: input.rawUploadFileId,
    p_file_hash: input.fileHash,
    p_actual_size_bytes: input.sizeBytes,
    p_actual_content_type: input.contentType,
    p_confirmed_by_system: "web_upload",
  });
  if (error) return { ok: false, error: error.message };
  return { ok: true };
}
