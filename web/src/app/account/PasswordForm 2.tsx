"use client";

import { useState, useTransition } from "react";

import { createSupabaseBrowserClient } from "@/lib/supabase/client";

export default function PasswordForm() {
  const supabase = createSupabaseBrowserClient();
  const [newPassword, setNewPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [pending, startTransition] = useTransition();
  const [status, setStatus] = useState<string | null>(null);

  function submit() {
    if (newPassword.length < 12) {
      setStatus("Password must be at least 12 characters.");
      return;
    }
    if (newPassword !== confirm) {
      setStatus("Passwords don't match.");
      return;
    }
    setStatus(null);
    startTransition(async () => {
      const { error } = await supabase.auth.updateUser({ password: newPassword });
      if (error) {
        setStatus(`Failed: ${error.message}`);
        return;
      }
      setNewPassword("");
      setConfirm("");
      setStatus("Password updated.");
      // The audit emission for PASSWORD_CHANGED happens server-side once the
      // emitter shim is wired to B05; for now the Supabase Auth log records it.
    });
  }

  return (
    <div className="space-y-3">
      <label className="block">
        <span className="mb-1 block text-sm font-medium text-zinc-700 dark:text-zinc-300">
          New password
        </span>
        <input
          type="password"
          autoComplete="new-password"
          value={newPassword}
          onChange={(e) => setNewPassword(e.target.value)}
          className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        />
      </label>
      <label className="block">
        <span className="mb-1 block text-sm font-medium text-zinc-700 dark:text-zinc-300">
          Confirm new password
        </span>
        <input
          type="password"
          autoComplete="new-password"
          value={confirm}
          onChange={(e) => setConfirm(e.target.value)}
          className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        />
      </label>
      <div className="flex items-center gap-3">
        <button
          type="button"
          onClick={submit}
          disabled={pending || newPassword.length < 12 || newPassword !== confirm}
          className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900"
        >
          {pending ? "Updating…" : "Update password"}
        </button>
        {status && <p className="text-xs text-zinc-600 dark:text-zinc-400">{status}</p>}
      </div>
    </div>
  );
}
