"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";

import { inviteMember } from "./actions";

const ROLE_OPTIONS = [
  "OWNER",
  "ADMIN",
  "BOOKKEEPER",
  "ACCOUNTANT",
  "REVIEWER",
  "READ_ONLY",
] as const;

interface Business {
  id: string;
  display_name: string;
}

export default function InviteForm(props: {
  organizationId: string;
  businesses: Business[];
}) {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [businessId, setBusinessId] = useState(props.businesses[0]?.id ?? "");
  const [role, setRole] = useState<(typeof ROLE_OPTIONS)[number]>("BOOKKEEPER");
  const [status, setStatus] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function submit() {
    setStatus(null);
    startTransition(async () => {
      const result = await inviteMember({
        organizationId: props.organizationId,
        email,
        assignments: [{ business_id: businessId, role }],
      });
      if (result.ok) {
        setEmail("");
        setStatus("Invitation sent.");
        router.refresh();
      } else {
        setStatus(`Failed: ${result.error}${result.detail ? ` (${result.detail})` : ""}`);
      }
    });
  }

  return (
    <div className="mt-3 grid gap-3 sm:grid-cols-[2fr_2fr_1fr_auto]">
      <input
        type="email"
        placeholder="member@example.com"
        value={email}
        onChange={(e) => setEmail(e.target.value)}
        className="h-9 rounded-lg border border-border-default bg-bg-base px-3 text-sm text-text-primary outline-none focus:border-border-focus focus:ring-2 focus:ring-[var(--color-border-focus)]/35"
      />
      <select
        value={businessId}
        onChange={(e) => setBusinessId(e.target.value)}
        className="h-9 rounded-lg border border-border-default bg-bg-base px-3 text-sm text-text-primary outline-none focus:border-border-focus focus:ring-2 focus:ring-[var(--color-border-focus)]/35"
      >
        {props.businesses.map((b) => (
          <option key={b.id} value={b.id}>
            {b.display_name}
          </option>
        ))}
      </select>
      <select
        value={role}
        onChange={(e) => setRole(e.target.value as (typeof ROLE_OPTIONS)[number])}
        className="h-9 rounded-lg border border-border-default bg-bg-base px-3 text-sm text-text-primary outline-none focus:border-border-focus focus:ring-2 focus:ring-[var(--color-border-focus)]/35"
      >
        {ROLE_OPTIONS.map((r) => (
          <option key={r} value={r}>
            {r}
          </option>
        ))}
      </select>
      <button
        type="button"
        onClick={submit}
        disabled={pending || !email || !businessId}
        className="rounded-md bg-action-primary px-3 py-2 text-sm font-medium text-text-on-primary hover:bg-action-hover disabled:opacity-50"
      >
        {pending ? "Sending…" : "Invite"}
      </button>
      {status && (
        <p className="sm:col-span-4 text-xs text-text-secondary">{status}</p>
      )}
    </div>
  );
}
