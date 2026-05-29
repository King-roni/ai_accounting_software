"use client";

import { useTransition } from "react";
import { useRouter } from "next/navigation";

import { createSupabaseBrowserClient } from "@/lib/supabase/client";

export default function SignOutOthersButton() {
  const supabase = createSupabaseBrowserClient();
  const router = useRouter();
  const [pending, startTransition] = useTransition();

  function submit() {
    if (
      !confirm(
        "Sign out every other device from your account? You'll stay signed in here.",
      )
    ) {
      return;
    }
    startTransition(async () => {
      const { error } = await supabase.auth.signOut({ scope: "others" });
      if (error) {
        alert(`Sign-out failed: ${error.message}`);
        return;
      }
      router.refresh();
    });
  }

  return (
    <button
      type="button"
      onClick={submit}
      disabled={pending}
      className="rounded-md border border-red-300 bg-white px-3 py-2 text-sm text-red-700 hover:bg-red-50 disabled:opacity-50 dark:border-red-700 dark:bg-zinc-900 dark:text-red-300 dark:hover:bg-red-950"
    >
      {pending ? "Signing out other devices…" : "Sign out everywhere else"}
    </button>
  );
}
