"use client";

import { useState, useTransition } from "react";

import { Button, Input, useToast } from "@/components/ui";
import { updateProfile } from "./actions";

export default function ProfileForm(props: {
  initialDisplayName: string | null;
  email: string;
}) {
  const { toast } = useToast();
  const [displayName, setDisplayName] = useState(props.initialDisplayName ?? "");
  const [pending, startTransition] = useTransition();

  function save() {
    startTransition(async () => {
      const result = await updateProfile({ displayName });
      if (result.ok) {
        toast({ variant: "success", title: "Profile saved" });
      } else {
        toast({
          variant: "error",
          title: "Couldn’t save profile",
          description: `${result.error}${result.detail ? ` (${result.detail})` : ""}`,
        });
      }
    });
  }

  return (
    <div className="flex flex-col gap-3">
      <Input
        label="Display name"
        value={displayName}
        placeholder={props.email}
        onChange={(e) => setDisplayName(e.target.value)}
      />
      <div>
        <Button onClick={save} loading={pending}>Save</Button>
      </div>
    </div>
  );
}
