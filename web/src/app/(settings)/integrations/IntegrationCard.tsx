"use client";

import { useState, useTransition } from "react";

import {
  connectIntegration,
  disconnectIntegration,
  refreshIntegration,
  saveDriveMapping,
} from "./actions";

interface IntegrationRow {
  id: string;
  status: "ACTIVE" | "DISCONNECTED" | "ERROR";
  connected_at: string;
  last_refreshed_at: string | null;
  access_token_expires_at: string | null;
  last_error: string | null;
}

interface DriveMappingRow {
  root_folder_id: string;
  root_folder_name: string | null;
}

const PROVIDER_LABEL: Record<"GMAIL" | "GOOGLE_DRIVE", string> = {
  GMAIL: "Gmail",
  GOOGLE_DRIVE: "Google Drive",
};

export default function IntegrationCard(props: {
  businessId: string;
  provider: "GMAIL" | "GOOGLE_DRIVE";
  integration?: IntegrationRow;
  driveMapping?: DriveMappingRow;
}) {
  const { businessId, provider, integration, driveMapping } = props;
  const [pending, startTransition] = useTransition();
  const [status, setStatus] = useState<string | null>(null);
  const [folderId, setFolderId] = useState(driveMapping?.root_folder_id ?? "");
  const [folderName, setFolderName] = useState(driveMapping?.root_folder_name ?? "");
  const [stepUpToken, setStepUpToken] = useState("");

  function connect() {
    setStatus(null);
    startTransition(async () => {
      const result = await connectIntegration({ businessId, provider });
      if (result.ok) {
        window.location.href = result.authorizationUrl;
      } else {
        setStatus(`Connect failed: ${result.error}`);
      }
    });
  }

  function refresh() {
    if (!integration) return;
    setStatus(null);
    startTransition(async () => {
      const result = await refreshIntegration(integration.id);
      setStatus(
        result.ok ? "Refreshed." : `Refresh failed: ${result.error}${result.detail ? ` (${result.detail})` : ""}`,
      );
    });
  }

  function disconnect() {
    if (!integration) return;
    if (!stepUpToken) {
      setStatus("Step-up token required (paste a token from /step-up).");
      return;
    }
    setStatus(null);
    startTransition(async () => {
      const result = await disconnectIntegration({
        integrationId: integration.id,
        stepUpToken,
      });
      setStatus(
        result.ok ? "Disconnected." : `Disconnect failed: ${result.error}`,
      );
      if (result.ok) setStepUpToken("");
    });
  }

  function saveMapping() {
    if (!folderId) return;
    setStatus(null);
    startTransition(async () => {
      const result = await saveDriveMapping({
        businessId,
        rootFolderId: folderId,
        rootFolderName: folderName,
      });
      setStatus(result.ok ? "Saved." : `Save failed: ${result.error}`);
    });
  }

  const isActive = integration?.status === "ACTIVE";

  return (
    <div className="rounded-md border border-zinc-200 p-3 text-sm dark:border-zinc-800">
      <header className="flex items-center justify-between">
        <h3 className="font-medium">{PROVIDER_LABEL[provider]}</h3>
        <span
          className={
            integration?.status === "ACTIVE"
              ? "rounded-full bg-green-100 px-2 py-0.5 text-xs text-green-800 dark:bg-green-900 dark:text-green-100"
              : integration?.status === "ERROR"
                ? "rounded-full bg-red-100 px-2 py-0.5 text-xs text-red-800 dark:bg-red-900 dark:text-red-100"
                : "rounded-full bg-zinc-100 px-2 py-0.5 text-xs text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300"
          }
        >
          {integration?.status ?? "NOT_CONNECTED"}
        </span>
      </header>

      {integration ? (
        <dl className="mt-2 space-y-1 text-xs text-zinc-600 dark:text-zinc-400">
          <div>Connected: {new Date(integration.connected_at).toLocaleString()}</div>
          {integration.last_refreshed_at && (
            <div>Refreshed: {new Date(integration.last_refreshed_at).toLocaleString()}</div>
          )}
          {integration.access_token_expires_at && (
            <div>Expires: {new Date(integration.access_token_expires_at).toLocaleString()}</div>
          )}
          {integration.last_error && (
            <div className="text-red-700 dark:text-red-400">Error: {integration.last_error}</div>
          )}
        </dl>
      ) : (
        <p className="mt-2 text-xs text-zinc-500">Not connected.</p>
      )}

      <div className="mt-3 flex flex-wrap gap-2">
        {!isActive ? (
          <button
            type="button"
            onClick={connect}
            disabled={pending}
            className="rounded-md bg-zinc-900 px-3 py-1.5 text-xs font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900"
          >
            {pending ? "Working…" : "Connect"}
          </button>
        ) : (
          <>
            <button
              type="button"
              onClick={refresh}
              disabled={pending}
              className="rounded-md border border-zinc-300 px-3 py-1.5 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              Refresh token
            </button>
            <input
              type="text"
              placeholder="step-up token"
              value={stepUpToken}
              onChange={(e) => setStepUpToken(e.target.value)}
              className="w-40 rounded-md border border-zinc-300 px-2 py-1 text-xs dark:border-zinc-700 dark:bg-zinc-800"
            />
            <button
              type="button"
              onClick={disconnect}
              disabled={pending || !stepUpToken}
              className="rounded-md border border-red-300 px-3 py-1.5 text-xs text-red-700 hover:bg-red-50 disabled:opacity-50 dark:border-red-700 dark:text-red-300 dark:hover:bg-red-950"
            >
              Disconnect
            </button>
          </>
        )}
      </div>

      {provider === "GOOGLE_DRIVE" && isActive && (
        <div className="mt-3 space-y-2 border-t border-zinc-200 pt-3 dark:border-zinc-800">
          <p className="text-xs font-medium text-zinc-700 dark:text-zinc-300">Root folder</p>
          <div className="flex flex-wrap gap-2">
            <input
              type="text"
              placeholder="Folder ID"
              value={folderId}
              onChange={(e) => setFolderId(e.target.value)}
              className="flex-1 rounded-md border border-zinc-300 px-2 py-1 text-xs dark:border-zinc-700 dark:bg-zinc-800"
            />
            <input
              type="text"
              placeholder="Folder name (optional)"
              value={folderName}
              onChange={(e) => setFolderName(e.target.value)}
              className="flex-1 rounded-md border border-zinc-300 px-2 py-1 text-xs dark:border-zinc-700 dark:bg-zinc-800"
            />
            <button
              type="button"
              onClick={saveMapping}
              disabled={pending || !folderId}
              className="rounded-md bg-zinc-900 px-3 py-1.5 text-xs font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900"
            >
              Save mapping
            </button>
          </div>
        </div>
      )}

      {status && (
        <p className="mt-2 text-xs text-zinc-600 dark:text-zinc-400">{status}</p>
      )}
    </div>
  );
}
