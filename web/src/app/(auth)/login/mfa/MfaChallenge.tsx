"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

interface FactorOption {
  id: string;
  friendlyName: string;
}

type Mode = "totp" | "recovery";

export default function MfaChallenge({
  factors,
  initialError,
}: {
  factors: FactorOption[];
  initialError: string | null;
}) {
  const router = useRouter();
  const supabase = createSupabaseBrowserClient();
  const [factorId, setFactorId] = useState(factors[0]?.id ?? "");
  const [mode, setMode] = useState<Mode>("totp");
  const [code, setCode] = useState("");
  const [recovery, setRecovery] = useState("");
  const [error, setError] = useState<string | null>(initialError);
  const [busy, setBusy] = useState(false);

  async function submitTotp() {
    setError(null);
    setBusy(true);
    try {
      const { data: challenge, error: chalErr } = await supabase.auth.mfa.challenge({
        factorId,
      });
      if (chalErr || !challenge) {
        setError(chalErr?.message ?? "Could not create challenge");
        return;
      }
      const { error: verErr } = await supabase.auth.mfa.verify({
        factorId,
        challengeId: challenge.id,
        code: code.trim(),
      });
      if (verErr) {
        setError(verErr.message);
        return;
      }
      router.refresh();
      router.push("/");
    } finally {
      setBusy(false);
    }
  }

  async function submitRecovery() {
    setError(null);
    setBusy(true);
    try {
      const { data, error: rpcErr } = await supabase.rpc("redeem_mfa_recovery_code", {
        submitted_code: recovery,
      });
      if (rpcErr) {
        setError(rpcErr.message);
        return;
      }
      const result = Array.isArray(data) ? data[0] : data;
      if (!result?.redeemed) {
        setError("Recovery code is invalid or already used.");
        return;
      }
      // Factor removed — refresh the session so the AAL drops, then
      // bounce the user to MFA re-enrollment.
      await supabase.auth.refreshSession();
      router.refresh();
      router.push("/account/mfa?error=Recovery+used.+Please+re-enroll+your+authenticator.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-4">
      <div className="flex gap-2 text-xs">
        <button
          type="button"
          className={`rounded-full px-3 py-1 ${mode === "totp" ? "bg-zinc-900 text-white dark:bg-zinc-50 dark:text-zinc-900" : "border border-zinc-300 text-zinc-700 dark:border-zinc-700 dark:text-zinc-300"}`}
          onClick={() => setMode("totp")}
        >
          Authenticator code
        </button>
        <button
          type="button"
          className={`rounded-full px-3 py-1 ${mode === "recovery" ? "bg-zinc-900 text-white dark:bg-zinc-50 dark:text-zinc-900" : "border border-zinc-300 text-zinc-700 dark:border-zinc-700 dark:text-zinc-300"}`}
          onClick={() => setMode("recovery")}
        >
          Recovery code
        </button>
      </div>

      {mode === "totp" ? (
        <>
          {factors.length > 1 && (
            <label className="block">
              <span className="mb-1 block text-sm font-medium text-zinc-700 dark:text-zinc-300">
                Factor
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
              inputMode="numeric"
              autoComplete="one-time-code"
              pattern="\d{6}"
              maxLength={6}
              value={code}
              onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 font-mono text-base tracking-widest shadow-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-100"
            />
          </label>
          <button
            type="button"
            onClick={submitTotp}
            disabled={code.length !== 6 || busy}
            className="w-full rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
          >
            {busy ? "Verifying…" : "Verify"}
          </button>
        </>
      ) : (
        <>
          <label className="block">
            <span className="mb-1 block text-sm font-medium text-zinc-700 dark:text-zinc-300">
              Recovery code
            </span>
            <input
              autoComplete="off"
              spellCheck={false}
              value={recovery}
              onChange={(e) => setRecovery(e.target.value.toUpperCase())}
              placeholder="XXXXX-XXXXX"
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 font-mono text-base tracking-widest shadow-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-100"
            />
          </label>
          <p className="text-xs text-zinc-500 dark:text-zinc-400">
            A recovery code removes your current MFA setup. You will be asked to re-enroll an
            authenticator before you can sign in again.
          </p>
          <button
            type="button"
            onClick={submitRecovery}
            disabled={recovery.length < 11 || busy}
            className="w-full rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
          >
            {busy ? "Verifying…" : "Use recovery code"}
          </button>
        </>
      )}

      {error && (
        <p className="text-sm text-red-700 dark:text-red-400">{error}</p>
      )}
    </div>
  );
}
