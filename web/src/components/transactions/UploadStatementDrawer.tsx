"use client";
import { useState } from "react";
import { UploadCloud } from "lucide-react";
import { Alert, Button, Drawer, Input, useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { formatPeriod, useShell } from "@/components/shell/ShellContext";
import { completeStatementUpload, prepareUpload } from "@/lib/uploads/actions";
import { sha256Hex } from "@/lib/uploads/hash";

/**
 * UploadStatementDrawer — uploads a bank statement for the current business and
 * kicks off its bookkeeping run. Flow (P0.2): request_raw_upload grant → byte
 * PUT to the signed URL → confirm + complete_statement_upload → emit
 * STATEMENT_UPLOAD_COMPLETED, which the orchestrator consumes to drive the
 * period's OUT_MONTHLY + IN_MONTHLY runs (parse → classify → match → ledger).
 */
export function UploadStatementDrawer({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { currentBusiness, period } = useShell();
  const { toast } = useToast();
  const [file, setFile] = useState<File | null>(null);
  const [provider, setProvider] = useState("Revolut");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const reset = () => { setFile(null); setError(null); setBusy(false); };
  const close = () => { reset(); onClose(); };

  const submit = async () => {
    if (!file || !currentBusiness) return;
    setBusy(true);
    setError(null);
    try {
      const isPdf = file.name.toLowerCase().endsWith(".pdf");
      const contentType = file.type || (isPdf ? "application/pdf" : "text/csv");
      const fileFormat = isPdf ? "PDF" : "CSV";

      const grant = await prepareUpload({
        businessId: currentBusiness.id,
        entityType: "STATEMENT",
        filename: file.name,
        sizeBytes: file.size,
        contentType,
      });
      if (!grant.ok) { setError(grant.error); setBusy(false); return; }

      const supabase = createSupabaseBrowserClient();
      const { error: uploadError } = await supabase.storage
        .from(grant.bucket)
        .uploadToSignedUrl(grant.path, grant.token, file, { contentType });
      if (uploadError) { setError(uploadError.message); setBusy(false); return; }

      const fileHash = await sha256Hex(file);
      const done = await completeStatementUpload({
        businessId: currentBusiness.id,
        rawUploadFileId: grant.rawUploadFileId,
        storagePath: grant.path,
        fileHash,
        sizeBytes: file.size,
        contentType,
        fileFormat,
        provider,
        periodYear: period.year,
        periodMonth: period.month,
        filename: file.name,
      });
      if (!done.ok) { setError(done.error); setBusy(false); return; }

      setBusy(false);
      toast({
        variant: "success",
        title: "Statement uploaded",
        description: `${file.name} is queued for ${formatPeriod(period)}'s bookkeeping run.`,
      });
      close();
    } catch (err) {
      setBusy(false);
      setError(err instanceof Error ? err.message : "Upload failed");
    }
  };

  return (
    <Drawer
      open={open}
      onClose={close}
      title="Upload bank statement"
      width={440}
      footer={
        <>
          <Button variant="tertiary" onClick={close}>Cancel</Button>
          <Button leadingIcon={UploadCloud} loading={busy} disabled={!file || !currentBusiness} onClick={submit}>Register</Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <Alert variant="status-info" title="How statements are processed">
          Uploaded statements are parsed, de-duplicated and turned into transactions inside the
          monthly bookkeeping run for the selected period — not instantly.
        </Alert>

        <div className="flex flex-col gap-1.5">
          <label htmlFor="stmt-file" className="text-sm font-medium text-text-primary">Statement file (CSV or PDF)</label>
          <input
            id="stmt-file"
            type="file"
            accept=".csv,.pdf,text/csv,application/pdf"
            onChange={(e) => setFile(e.target.files?.[0] ?? null)}
            className="block w-full cursor-pointer rounded-sm border border-border-default bg-bg-base text-sm text-text-secondary file:mr-3 file:cursor-pointer file:border-0 file:bg-bg-raised file:px-3 file:py-2 file:text-sm file:text-text-primary"
          />
        </div>

        <Input label="Bank / provider" value={provider} onChange={(e) => setProvider(e.target.value)} />

        <div className="text-sm text-text-secondary">
          Business: <span className="text-text-primary">{currentBusiness?.display_name ?? "—"}</span><br />
          Period: <span className="text-text-primary tabular-nums">{formatPeriod(period)}</span>
        </div>

        {error && <Alert variant="status-danger" title="Could not register statement">{error}</Alert>}
      </div>
    </Drawer>
  );
}
