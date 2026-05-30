"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { provisionRecoveryCodes } from "./actions";

type Step = "idle" | "enrolling" | "showing-qr" | "verifying" | "show-codes" | "done";

interface EnrollState {
  factorId: string;
  qrCode: string; // SVG/PNG data URI
  uri: string;
  secret: string;
}

export default function EnrollFlow() {
  const router = useRouter();
  const supabase = createSupabaseBrowserClient();
  const [step, setStep] = useState<Step>("idle");
  const [enroll, setEnroll] = useState<EnrollState | null>(null);
  const [code, setCode] = useState("");
  const [recoveryCodes, setRecoveryCodes] = useState<string[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function startEnroll() {
    setError(null);
    setStep("enrolling");
    const { data, error } = await supabase.auth.mfa.enroll({
      factorType: "totp",
      friendlyName: `Authenticator (${new Date().toISOString().slice(0, 10)})`,
    });
    if (error || !data) {
      setError(error?.message ?? "Failed to start enrollment");
      setStep("idle");
      return;
    }
    setEnroll({
      factorId: data.id,
      qrCode: data.totp.qr_code,
      uri: data.totp.uri,
      secret: data.totp.secret,
    });
    setStep("showing-qr");
  }

  async function verifyCode() {
    if (!enroll) return;
    setError(null);
    setStep("verifying");
    const { data: challenge, error: chalErr } = await supabase.auth.mfa.challenge({
      factorId: enroll.factorId,
    });
    if (chalErr || !challenge) {
      setError(chalErr?.message ?? "Challenge failed");
      setStep("showing-qr");
      return;
    }
    const { error: verErr } = await supabase.auth.mfa.verify({
      factorId: enroll.factorId,
      challengeId: challenge.id,
      code: code.trim(),
    });
    if (verErr) {
      setError(verErr.message);
      setStep("showing-qr");
      return;
    }
    const result = await provisionRecoveryCodes();
    if (result.error) {
      setError(result.error);
      setStep("showing-qr");
      return;
    }
    if (result.codes && result.codes.length > 0) {
      setRecoveryCodes(result.codes);
      setStep("show-codes");
    } else {
      // Already had codes (idempotent) — go straight to done.
      setStep("done");
      router.refresh();
      router.push("/account/mfa?enrolled=1");
    }
  }

  function finish() {
    setStep("done");
    router.refresh();
    router.push("/account/mfa?enrolled=1");
  }

  if (step === "idle" || step === "enrolling") {
    return (
      <button
        type="button"
        onClick={startEnroll}
        disabled={step === "enrolling"}
        className="rounded-md bg-action-primary px-4 py-2 text-sm font-medium text-text-on-primary hover:bg-action-hover disabled:opacity-50"
      >
        {step === "enrolling" ? "Starting…" : "Enroll authenticator app"}
      </button>
    );
  }

  if (step === "show-codes" && recoveryCodes) {
    return (
      <div className="space-y-4 rounded-md border border-amber-300 bg-amber-50 p-4 dark:border-amber-700 dark:bg-amber-950">
        <p className="text-sm font-medium text-amber-900 dark:text-amber-100">
          Save these recovery codes now — they will not be shown again.
        </p>
        <ul className="grid grid-cols-2 gap-2 font-mono text-sm text-amber-950 dark:text-amber-50">
          {recoveryCodes.map((c) => (
            <li key={c} className="rounded bg-amber-100 px-3 py-1.5 dark:bg-amber-900">
              {c}
            </li>
          ))}
        </ul>
        <button
          type="button"
          onClick={finish}
          className="rounded-md bg-amber-900 px-4 py-2 text-sm font-medium text-amber-50 hover:bg-amber-800 dark:bg-amber-100 dark:text-amber-900"
        >
          I&apos;ve saved them
        </button>
      </div>
    );
  }

  // showing-qr or verifying
  return (
    <div className="space-y-4">
      <div className="grid gap-4 sm:grid-cols-[auto_1fr]">
        {enroll?.qrCode && (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={enroll.qrCode}
            alt="TOTP QR code"
            className="h-40 w-40 rounded-md border border-zinc-200 bg-white p-2 dark:border-zinc-700"
          />
        )}
        <div className="space-y-3 text-sm">
          <p className="text-zinc-700 dark:text-zinc-300">
            Scan the QR code with your authenticator app, then enter the 6-digit code below.
          </p>
          <details className="text-xs text-zinc-500 dark:text-zinc-400">
            <summary className="cursor-pointer">Can&apos;t scan? Use the manual key</summary>
            <p className="mt-1 break-all font-mono">{enroll?.secret}</p>
          </details>
        </div>
      </div>
      <div className="flex items-end gap-3">
        <label className="block flex-1">
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
          onClick={verifyCode}
          disabled={code.length !== 6 || step === "verifying"}
          className="rounded-md bg-action-primary px-4 py-2 text-sm font-medium text-text-on-primary hover:bg-action-hover disabled:opacity-50"
        >
          {step === "verifying" ? "Verifying…" : "Verify"}
        </button>
      </div>
      {error && (
        <p className="text-sm text-red-700 dark:text-red-400">{error}</p>
      )}
    </div>
  );
}
