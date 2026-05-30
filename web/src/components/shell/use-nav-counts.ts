"use client";
import { useMemo } from "react";
import useSWR from "swr";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";
import { useShell } from "./ShellContext";

/**
 * Live counts for sidebar nav badges. Currently surfaces the open review-queue
 * backlog (the count users most want at a glance). Keyed by NavItem.countKey.
 */
export function useNavCounts(): Record<string, number> {
  const { currentBusiness } = useShell();
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);

  const { data } = useSWR(
    currentBusiness ? ["nav-counts", currentBusiness.id] : null,
    async () => {
      const { count } = await supabase
        .from("review_issues")
        .select("id", { count: "exact", head: true })
        .eq("business_id", currentBusiness!.id)
        .eq("status", "OPEN");
      return { reviews: count ?? 0 } as Record<string, number>;
    },
    { refreshInterval: 60_000, revalidateOnFocus: false },
  );

  return data ?? {};
}
