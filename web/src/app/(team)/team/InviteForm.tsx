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
        className="rounded-md border border-zinc-300 px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
      />
      <select
        value={businessId}
        onChange={(e) => setBusinessId(e.target.value)}
        className="rounded-md border border-zinc-300 px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
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
        className="rounded-md border border-zinc-300 px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
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
        className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900"
      >
        {pending ? "Sending…" : "Invite"}
      </button>
      {status && (
        <p className="sm:col-span-4 text-xs text-zinc-600 dark:text-zinc-400">{status}</p>
      )}
    </div>
  );
}
