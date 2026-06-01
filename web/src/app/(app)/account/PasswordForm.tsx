"use client";

import { useState, useTransition } from "react";

import { Button, Input, useToast } from "@/components/ui";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

export default function PasswordForm() {
  const supabase = createSupabaseBrowserClient();
  const { toast } = useToast();
  const [newPassword, setNewPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [pending, startTransition] = useTransition();

  function submit() {
    if (newPassword.length < 12) {
      toast({ variant: "error", title: "Password must be at least 12 characters." });
      return;
    }
    if (newPassword !== confirm) {
      toast({ variant: "error", title: "Passwords don’t match." });
      return;
    }
    startTransition(async () => {
      const { error } = await supabase.auth.updateUser({ password: newPassword });
      if (error) {
        toast({ variant: "error", title: "Couldn’t update password", description: error.message });
        return;
      }
      setNewPassword("");
      setConfirm("");
      toast({ variant: "success", title: "Password updated" });
    });
  }

  return (
    <div className="flex flex-col gap-3">
      <Input
        label="New password"
        type="password"
        autoComplete="new-password"
        value={newPassword}
        onChange={(e) => setNewPassword(e.target.value)}
      />
      <Input
        label="Confirm new password"
        type="password"
        autoComplete="new-password"
        value={confirm}
        onChange={(e) => setConfirm(e.target.value)}
      />
      <div>
        <Button
          onClick={submit}
          loading={pending}
          disabled={newPassword.length < 12 || newPassword !== confirm}
        >
          Update password
        </Button>
      </div>
    </div>
  );
}
