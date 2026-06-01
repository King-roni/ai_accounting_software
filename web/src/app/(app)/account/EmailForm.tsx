"use client";

import { useState, useTransition } from "react";

import { Button, Input, useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

export default function EmailForm(props: { currentEmail: string }) {
  const supabase = createSupabaseBrowserClient();
  const { toast } = useToast();
  const [newEmail, setNewEmail] = useState("");
  const [pending, startTransition] = useTransition();

  function submit() {
    const trimmed = newEmail.trim();
    if (!trimmed || trimmed === props.currentEmail) {
      toast({ variant: "error", title: "Enter a different email address." });
      return;
    }
    startTransition(async () => {
      const { error } = await supabase.auth.updateUser({ email: trimmed });
      if (error) {
        toast({ variant: "error", title: "Couldn’t update email", description: error.message });
        return;
      }
      setNewEmail("");
      toast({
        variant: "success",
        title: "Verification sent",
        description: `Check ${trimmed} — your address changes once you confirm the link.`,
      });
    });
  }

  return (
    <div className="flex flex-col gap-3">
      <p className="text-sm text-text-secondary">
        Current: <span className="font-mono text-text-primary">{props.currentEmail}</span>
      </p>
      <Input
        label="New email"
        type="email"
        autoComplete="email"
        value={newEmail}
        onChange={(e) => setNewEmail(e.target.value)}
      />
      <div>
        <Button onClick={submit} loading={pending} disabled={!newEmail}>Request change</Button>
      </div>
    </div>
  );
}
