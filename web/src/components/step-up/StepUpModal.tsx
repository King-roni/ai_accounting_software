"use client";

/**
 * Step-up authentication modal (B02·P06).
 *
 * Triggered when a sensitive action needs a fresh MFA proof. Lists the
 * user's verified TOTP factors via the browser Supabase client and submits
 * (factorId, code) to the verifyStepUp server action which performs the
 * actual MFA challenge+verify server-side and returns a single-use token
 * the caller must pass to the gated action.
 *
 * Not yet wired into any concrete sensitive action — that integration lands
 * with FINALIZATION (B15) and per-business toggles for other surfaces.
 *
 * Per step_up_ui_spec.md the canonical UX uses 6 separate code-digit
 * inputs with auto-advance + auto-submit on full entry; this MVP keeps a
 * single 6-digit input to minimize new component surface — the visual
 * polish ships when finalize lands and the spec's design tokens exist.
 */

import { useEffect, useState } from "react";

import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import {
  verifyStepUp,
  type VerifyStepUpResult,
} from "@/app/(auth)/step-up/actions";

interface FactorOption {
  id: string;
  friendlyName: string;
}

const SURFACE_HEADLINES: Record<string, { title: string; body: string }> = {
  FINALIZATION: {
    title: "Verify before finalizing",
    body: "Finalizing a period creates an immutable archive. Verify your identity to confirm.",
  },
  BUSINESS_SETTINGS_EDIT: {
    title: "Verify before changing settings",
    body: "Changes to business settings affect future workflows. Verify your identity.",
  },
  USER_INVITE: {
    title: "Verify before inviting",
    body: "Inviting a user grants them access to this business. Verify your identity.",
  },
  EXTERNAL_INTEGRATION: {
    title: "Verify before connecting integration",
    body: "Connecting an integration shares data with an external service. Verify your identity.",
  },
};

const DEFAULT_HEADLINE = {
  title: "Verify your identity",
  body: "Enter the 6-digit code from your authenticator app.",
};

export default function StepUpModal(props: {
  surface: string;
  businessId: string;
  onSuccess: (tokenId: string) => void;
  onCancel: () => void;
}) {
  const { surface, businessId, onSuccess, onCancel } = props;
  const supabase = createSupabaseBrowserClient();
  const [factors, setFactors] = useState<FactorOption[] | null>(null);
  const [factorId, setFactorId] = useState<string>("");
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data, error: listErr } = await supabase.auth.mfa.listFactors();
      if (cancelled) return;
      if (listErr) {
        setError("Could not load authenticators. Try again.");
        setFactors([]);
        return;
      }
      const verified = (data?.totp ?? [])
        .filter((f) => f.status === "verified")
        .map((f) => ({
          id: f.id,
          friendlyName: f.friendly_name ?? "Authenticator app",
        }));
      setFactors(verified);
      if (verified.length > 0) setFactorId(verified[0].id);
    })();
    return () => {
      cancelled = true;
    };
  }, [supabase]);

  async function submit() {
    if (!factorId) return;
    setError(null);
    setBusy(true);
    try {
      const result: VerifyStepUpResult = await verifyStepUp({
        factorId,
        code: code.trim(),
        businessId,
        surface,
      });
      if (result.ok) {
        onSuccess(result.tokenId);
        return;
      }
      switch (result.error) {
        case "INVALID_CODE":
          setError("Code didn't match. Try again.");
          break;
        case "NOT_AUTHENTICATED":
          setError("Your session ended. Please sign in again.");
          break;
        case "NO_BUSINESS_ROLE":
          setError("You no longer have access to this business.");
          break;
        case "FACTOR_NOT_FOUND":
          setError("Authenticator unavailable. Try a different factor.");
          break;
        default:
          setError("Something went wrong. Try again.");
      }
      setCode("");
    } finally {
      setBusy(false);
    }
  }

  const headline = SURFACE_HEADLINES[surface] ?? DEFAULT_HEADLINE;

  if (factors !== null && factors.length === 0) {
    return (
      <div role="dialog" aria-modal="true" className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
        <div className="w-full max-w-md rounded-xl bg-white p-6 shadow-xl dark:bg-action-primary">
          <h2 className="text-lg font-medium text-zinc-900 dark:text-zinc-50">
            MFA not enrolled
          </h2>
          <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
            This action requires an authenticator. Enroll one in Account
            Settings, then try again.
          </p>
          <div className="mt-4 flex justify-end">
            <button
              type="button"
              onClick={onCancel}
              className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700"
            >
              Close
            </button>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div role="dialog" aria-modal="true" aria-labelledby="step-up-title"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
      <div className="w-full max-w-md space-y-4 rounded-xl bg-white p-6 shadow-xl dark:bg-action-primary">
        <div>
          <h2 id="step-up-title" className="text-lg font-medium text-zinc-900 dark:text-zinc-50">
            {headline.title}
          </h2>
          <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">{headline.body}</p>
        </div>

        {factors && factors.length > 1 && (
          <label className="block">
            <span className="mb-1 block text-sm font-medium text-zinc-700 dark:text-zinc-300">
              Authenticator
            </span>
            <select
              value={factorId}
              onChange={(e) => setFactorId(e.target.value)}
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm shadow-sm dark:border-zinc-700 dark:bg-zinc-800"
            >
              {factors.map((f) => (
                <option key={f.id} value={f.id}>
                  {f.friendlyName}
                </option>
              ))}
            </select>
          </label>
        )}

        <label className="block">
          <span className="mb-1 block text-sm font-medium text-zinc-700 dark:text-zinc-300">
            6-digit code
          </span>
          <input
            autoFocus
            inputMode="numeric"
            autoComplete="one-time-code"
            pattern="\d{6}"
            maxLength={6}
            value={code}
            onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
            disabled={busy || factors === null}
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 font-mono text-base tracking-widest shadow-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-100"
          />
        </label>

        {error && <p className="text-sm text-red-700 dark:text-red-400">{error}</p>}

        <div className="flex justify-end gap-2">
          <button
            type="button"
            onClick={onCancel}
            disabled={busy}
            className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-action-hover"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={submit}
            disabled={busy || code.length !== 6 || !factorId}
            className="rounded-md bg-action-primary px-3 py-1.5 text-sm font-medium text-text-on-primary hover:bg-action-hover disabled:opacity-50"
          >
            {busy ? "Verifying…" : "Verify"}
          </button>
        </div>
      </div>
    </div>
  );
}
