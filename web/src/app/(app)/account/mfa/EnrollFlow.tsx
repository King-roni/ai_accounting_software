"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Alert, Button, Input } from "@/components/ui";
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
      <Button onClick={startEnroll} loading={step === "enrolling"}>
        Enroll authenticator app
      </Button>
    );
  }

  if (step === "show-codes" && recoveryCodes) {
    return (
      <div
        className="flex flex-col gap-4 rounded-md border bg-bg-raised p-4"
        style={{ borderColor: "var(--color-status-warning)" }}
      >
        <p className="text-sm font-medium text-text-primary">
          Save these recovery codes now — they won’t be shown again.
        </p>
        <ul className="grid grid-cols-2 gap-2 font-mono text-sm text-text-primary">
          {recoveryCodes.map((c) => (
            <li key={c} className="rounded bg-surface-default px-3 py-1.5">{c}</li>
          ))}
        </ul>
        <div>
          <Button onClick={finish}>I&apos;ve saved them</Button>
        </div>
      </div>
    );
  }

  // showing-qr or verifying
  return (
    <div className="flex flex-col gap-4">
      <div className="grid gap-4 sm:grid-cols-[auto_1fr]">
        {enroll?.qrCode && (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={enroll.qrCode}
            alt="TOTP QR code"
            className="h-40 w-40 rounded-md border border-border-subtle bg-white p-2"
          />
        )}
        <div className="flex flex-col gap-3 text-sm">
          <p className="text-text-secondary">
            Scan the QR code with your authenticator app, then enter the 6-digit code below.
          </p>
          <details className="text-xs text-text-muted">
            <summary className="cursor-pointer">Can’t scan? Use the manual key</summary>
            <p className="mt-1 break-all font-mono text-text-secondary">{enroll?.secret}</p>
          </details>
        </div>
      </div>
      <div className="flex items-end gap-3">
        <Input
          containerClassName="flex-1"
          label="6-digit code"
          inputMode="numeric"
          autoComplete="one-time-code"
          maxLength={6}
          value={code}
          onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
        />
        <Button onClick={verifyCode} loading={step === "verifying"} disabled={code.length !== 6}>
          Verify
        </Button>
      </div>
      {error && <Alert variant="status-danger" title="Verification failed">{error}</Alert>}
    </div>
  );
}
