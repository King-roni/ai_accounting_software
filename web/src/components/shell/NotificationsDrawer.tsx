"use client";
import { BellOff } from "lucide-react";
import { Drawer, EmptyState } from "@/components/ui";
import { useShell } from "./ShellContext";

/**
 * NotificationsDrawer — right-side drawer. Notification kinds (review-issue
 * assignments, run completions, finalization/archive events, system alerts) and
 * their data source are wired in a later phase; for now it shows the empty state.
 */
export function NotificationsDrawer() {
  const { notifOpen, setNotifOpen } = useShell();
  return (
    <Drawer open={notifOpen} onClose={() => setNotifOpen(false)} title="Notifications" width={360}>
      <EmptyState
        icon={BellOff}
        heading="You're all caught up"
        body="Assignments, run completions, and alerts will show up here."
      />
    </Drawer>
  );
}
