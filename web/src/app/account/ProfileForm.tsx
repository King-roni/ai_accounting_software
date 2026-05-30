"use client";

import { useState, useTransition } from "react";

import { updateProfile } from "./actions";

export default function ProfileForm(props: {
  initialDisplayName: string | null;
  email: string;
}) {
  const [displayName, setDisplayName] = useState(props.initialDisplayName ?? "");
  const [pending, startTransition] = useTransition();
  const [status, setStatus] = useState<string | null>(null);

  return (
    <div className="space-y-3">
      <label className="block">
        <span className="mb-1 block text-sm font-medium text-zinc-700 dark:text-zinc-300">
          Display name
        </span>
        <input
          type="text"
          value={displayName}
          onChange={(e) => setDisplayName(e.target.value)}
          placeholder={props.email}
          className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        />
      </label>
      <div className="flex items-center gap-3">
        <button
          type="button"
          disabled={pending}
          onClick={() => {
            setStatus(null);
            startTransition(async () => {
              const result = await updateProfile({ displayName });
              setStatus(
                result.ok ? "Saved." : `Failed: ${result.error}${result.detail ? ` (${result.detail})` : ""}`,
              );
            });
          }}
          className="rounded-md bg-action-primary px-3 py-2 text-sm font-medium text-text-on-primary hover:bg-action-hover disabled:opacity-50"
        >
          {pending ? "Saving…" : "Save"}
        </button>
        {status && <p className="text-xs text-zinc-600 dark:text-zinc-400">{status}</p>}
      </div>
    </div>
  );
}
