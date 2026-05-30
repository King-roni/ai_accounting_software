"use client";

import { useState, useTransition } from "react";

import { createSupabaseBrowserClient } from "@/lib/supabase/client";

export default function EmailForm(props: { currentEmail: string }) {
  const supabase = createSupabaseBrowserClient();
  const [newEmail, setNewEmail] = useState("");
  const [pending, startTransition] = useTransition();
  const [status, setStatus] = useState<string | null>(null);

  function submit() {
    const trimmed = newEmail.trim();
    if (!trimmed || trimmed === props.currentEmail) {
      setStatus("Enter a different email address.");
      return;
    }
    setStatus(null);
    startTransition(async () => {
      const { error } = await supabase.auth.updateUser({ email: trimmed });
      if (error) {
        setStatus(`Failed: ${error.message}`);
        return;
      }
      setNewEmail("");
      setStatus(
        `Verification sent to ${trimmed}. Your address will change after you click the link.`,
      );
    });
  }

  return (
    <div className="space-y-3">
      <p className="text-sm text-zinc-500 dark:text-zinc-400">
        Current: <span className="font-mono text-zinc-700 dark:text-zinc-300">{props.currentEmail}</span>
      </p>
      <label className="block">
        <span className="mb-1 block text-sm font-medium text-zinc-700 dark:text-zinc-300">
          New email
        </span>
        <input
          type="email"
          autoComplete="email"
          value={newEmail}
          onChange={(e) => setNewEmail(e.target.value)}
          className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        />
      </label>
      <div className="flex items-center gap-3">
        <button
          type="button"
          onClick={submit}
          disabled={pending || !newEmail}
          className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900"
        >
          {pending ? "Sending…" : "Request change"}
        </button>
        {status && <p className="text-xs text-zinc-600 dark:text-zinc-400">{status}</p>}
      </div>
    </div>
  );
}
