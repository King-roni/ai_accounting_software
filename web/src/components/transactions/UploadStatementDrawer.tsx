"use client";
import { useState } from "react";
import { UploadCloud } from "lucide-react";
import { Alert, Button, Drawer, Input, useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { formatPeriod, useShell } from "@/components/shell/ShellContext";

/**
 * UploadStatementDrawer — registers a bank statement for the current business via
 * the B07 `request_raw_upload` grant RPC. Byte upload to the granted URL and the
 * parse → dedup → transactions pipeline run inside the period's IN/OUT bookkeeping
 * workflow (R2.6); this surface performs the registration step.
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
    const isPdf = file.name.toLowerCase().endsWith(".pdf");
    const supabase = createSupabaseBrowserClient();
    const { error: rpcError } = await supabase.rpc("request_raw_upload", {
      p_business_id: currentBusiness.id,
      p_entity_type: "STATEMENT",
      p_original_filename: file.name,
      p_declared_size_bytes: file.size,
      p_declared_content_type: file.type || (isPdf ? "application/pdf" : "text/csv"),
      p_grant_ttl_seconds: 300,
    });
    setBusy(false);
    if (rpcError) {
      setError(rpcError.message);
      return;
    }
    toast({
      variant: "success",
      title: "Statement registered",
      description: `${file.name} will be parsed in ${formatPeriod(period)}'s bookkeeping run.`,
    });
    close();
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
