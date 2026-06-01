"use client";

import { useTransition } from "react";
import { useRouter } from "next/navigation";

import { useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

export default function SignOutOthersButton() {
  const supabase = createSupabaseBrowserClient();
  const router = useRouter();
  const { toast } = useToast();
  const [pending, startTransition] = useTransition();

  function submit() {
    if (!confirm("Sign out every other device from your account? You'll stay signed in here.")) {
      return;
    }
    startTransition(async () => {
      const { error } = await supabase.auth.signOut({ scope: "others" });
      if (error) {
        toast({ variant: "error", title: "Sign-out failed", description: error.message });
        return;
      }
      toast({ variant: "success", title: "Signed out other devices" });
      router.refresh();
    });
  }

  return (
    <button
      type="button"
      onClick={submit}
      disabled={pending}
      className="inline-flex h-9 w-fit cursor-pointer items-center rounded-md border border-border-default px-3 text-sm font-medium transition-colors hover:bg-bg-raised disabled:opacity-50"
      style={{ color: "var(--color-status-danger)" }}
    >
      {pending ? "Signing out other devices…" : "Sign out everywhere else"}
    </button>
  );
}
