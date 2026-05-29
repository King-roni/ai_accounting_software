"use client";
import { useState } from "react";
import { UploadCloud } from "lucide-react";
import { Alert, Button, Drawer, Select, useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "@/components/shell/ShellContext";

const ENTITY_OPTIONS = [
  { value: "INVOICE", label: "Invoice", content: "application/pdf" },
  { value: "RECEIPT", label: "Receipt", content: "application/pdf" },
  { value: "CONTRACT", label: "Contract", content: "application/pdf" },
] as const;

/**
 * UploadDocumentDrawer — registers a supporting document (invoice/receipt/
 * contract) via the B07 `request_raw_upload` grant RPC. OCR + field extraction
 * run server-side (B09 pipeline); this surface performs the registration step.
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
    const supabase = createSupabaseBrowserClient();
    const { error: rpcError } = await supabase.rpc("request_raw_upload", {
      p_business_id: currentBusiness.id,
      p_entity_type: entity,
      p_original_filename: file.name,
      p_declared_size_bytes: file.size,
      p_declared_content_type: file.type || "application/pdf",
      p_grant_ttl_seconds: 300,
    });
    setBusy(false);
    if (rpcError) { setError(rpcError.message); return; }
    toast({ variant: "success", title: "Document registered", description: `${file.name} will be OCR-processed and extracted.` });
    close();
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
