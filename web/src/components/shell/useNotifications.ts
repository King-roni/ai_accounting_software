"use client";
import { useMemo } from "react";
import useSWR from "swr";
import { createSupabaseBrowserClient } from "@/lib/supabase/client";

/**
 * useNotifications (R7.3) — reads the recipient's notification_inbox (RLS scopes
 * it to the current user), exposes the unread count for the TopNav bell badge,
 * and marking-read via the SECURITY DEFINER RPCs (direct writes are denied).
 * Shared by the bell + the drawer via a single SWR key, and polls so the badge
 * stays live as the worker projects new notifications.
 */
export interface NotificationRow {
  id: string;
  kind: string;
  payload: Record<string, unknown>;
  created_at: string;
  read_at: string | null;
}

export function useNotifications() {
  const supabase = useMemo(() => createSupabaseBrowserClient(), []);

  const { data, mutate, isLoading } = useSWR<NotificationRow[]>(
    "notifications",
    async () => {
      const { data, error } = await supabase
        .from("notification_inbox")
        .select("id, kind, payload, created_at, read_at")
        .order("created_at", { ascending: false })
        .limit(30);
      if (error) throw new Error(error.message);
      return (data ?? []) as NotificationRow[];
    },
    { refreshInterval: 30000, revalidateOnFocus: true },
  );

  const notifications = data ?? [];
  const unreadCount = notifications.reduce((n, x) => (x.read_at ? n : n + 1), 0);

  async function markRead(id: string) {
    await supabase.rpc("mark_notification_read", { p_notification_id: id });
    await mutate();
  }

  async function markAllRead() {
    await supabase.rpc("mark_all_notifications_read");
    await mutate();
  }

  return { notifications, unreadCount, markRead, markAllRead, isLoading, mutate };
}
