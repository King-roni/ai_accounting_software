"use client";
import { Hammer, type LucideIcon } from "lucide-react";
import { EmptyState } from "@/components/ui";
import { useShell } from "./ShellContext";

/**
 * Placeholder for domain routes whose UI is built in R2. The shell, nav, and
 * business/period context are live; this fills the route until the screen lands.
 */
export function Placeholder({ title, icon, blurb }: { title: string; icon?: LucideIcon; blurb?: string }) {
  const { currentBusiness, isMultiBusiness } = useShell();
  const ctx = isMultiBusiness ? "All businesses" : currentBusiness?.display_name ?? "No business selected";
  return (
    <div className="flex flex-col gap-5">
      <header>
        <h1 className="text-2xl font-semibold text-text-primary">{title}</h1>
        <p className="text-sm text-text-secondary">{ctx}</p>
      </header>
      <EmptyState
        icon={icon ?? Hammer}
        heading={`${title} is coming soon`}
        body={blurb ?? "This screen is part of the R2 build. Its backend RPCs already exist in the database."}
      />
    </div>
  );
}
