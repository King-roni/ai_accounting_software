"use client";

import { useTransition } from "react";

import { revokeInvitation } from "./actions";

export default function RevokeInvitationButton(props: { invitationId: string }) {
  const [pending, startTransition] = useTransition();
  return (
    <button
      type="button"
      onClick={() =>
        startTransition(async () => {
          const result = await revokeInvitation(props.invitationId);
          if (!result.ok) alert(`Revoke failed: ${result.error}`);
        })
      }
      disabled={pending}
      className="rounded-md border border-zinc-300 px-3 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
    >
      {pending ? "Revoking…" : "Revoke"}
    </button>
  );
}
