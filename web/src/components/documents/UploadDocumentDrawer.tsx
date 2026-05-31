"use client";
import { useState } from "react";
import { UploadCloud } from "lucide-react";
import { Alert, Button, Drawer, Select, useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";
import {
  completeDocumentUpload,
  prepareUpload,
  type UploadEntityType,
} from "@/lib/uploads/actions";
import { sha256Hex } from "@/lib/uploads/hash";

const ENTITY_OPTIONS = [
  { value: "INVOICE", label: "Invoice", content: "application/pdf" },
  { value: "RECEIPT", label: "Receipt", content: "application/pdf" },
  { value: "CONTRACT", label: "Contract", content: "application/pdf" },
] as const;

/**
 * UploadDocumentDrawer — uploads a supporting document (invoice/receipt/
 * contract). Flow (P0.2): request_raw_upload grant → byte PUT to the signed URL
 * → confirm_raw_upload. OCR + field extraction → the matchable `documents` row
 * run server-side in the B09 intake pipeline (P2).
 */
export function UploadDocumentDrawer({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { currentBusiness } = useShell();
  const { toast } = useToast();
  const [file, setFile] = useState<File | null>(null);
  const [entity, setEntity] = useState<string>("INVOICE");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const close = () => { setFile(null); setError(null); setBusy(false); onClose(); };

  const submit = async () => {
    if (!file || !currentBusiness) return;
    setBusy(true);
    setError(null);
    try {
      const contentType = file.type || "application/pdf";
      const grant = await prepareUpload({
        businessId: currentBusiness.id,
        entityType: entity as UploadEntityType,
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
      const done = await completeDocumentUpload({
        rawUploadFileId: grant.rawUploadFileId,
        fileHash,
        sizeBytes: file.size,
        contentType,
      });
      if (!done.ok) { setError(done.error); setBusy(false); return; }

      setBusy(false);
      toast({ variant: "success", title: "Document uploaded", description: `${file.name} will be OCR-processed and offered for matching.` });
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
      title="Upload document"
      width={440}
      footer={
        <>
          <Button variant="tertiary" onClick={close}>Cancel</Button>
          <Button leadingIcon={UploadCloud} loading={busy} disabled={!file || !currentBusiness} onClick={submit}>Register</Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <Alert variant="status-info" title="OCR runs server-side">
          Registered documents are OCR-processed and their fields extracted by the intake pipeline,
          then offered for matching against transactions.
        </Alert>
        <Select label="Document type" value={entity} onChange={(e) => setEntity(e.target.value)}>
          {ENTITY_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
        </Select>
        <div className="flex flex-col gap-1.5">
          <label htmlFor="doc-file" className="text-sm font-medium text-text-primary">File (PDF or image)</label>
          <input
            id="doc-file"
            type="file"
            accept=".pdf,.jpg,.jpeg,.png,application/pdf,image/*"
            onChange={(e) => setFile(e.target.files?.[0] ?? null)}
            className="block w-full cursor-pointer rounded-sm border border-border-default bg-bg-base text-sm text-text-secondary file:mr-3 file:cursor-pointer file:border-0 file:bg-bg-raised file:px-3 file:py-2 file:text-sm file:text-text-primary"
          />
        </div>
        <div className="text-sm text-text-secondary">Business: <span className="text-text-primary">{currentBusiness?.display_name ?? "—"}</span></div>
        {error && <Alert variant="status-danger" title="Could not register document">{error}</Alert>}
      </div>
    </Drawer>
  );
}
