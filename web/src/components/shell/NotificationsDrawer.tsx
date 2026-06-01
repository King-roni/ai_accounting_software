"use client";
import { useRouter } from "next/navigation";
import {
  AlertTriangle, BellOff, CheckCheck, Download, FileWarning, KeyRound,
  ListChecks, PauseCircle, type LucideIcon,
} from "lucide-react";
import { Drawer, EmptyState } from "@/components/ui";
import { useShell } from "./ShellContext";
import { useNotifications, type NotificationRow } from "./useNotifications";

/**
 * NotificationsDrawer (R7.3) — the real notifications feed. Rows come from the
 * worker-projected notification_inbox (review issues, run holds, exports,
 * expiring integrations). Clicking a notification marks it read and navigates
 * to the relevant screen.
 */
const KIND_META: Record<string, { icon: LucideIcon; title: string }> = {
  REVIEW_ISSUE_OPENED: { icon: AlertTriangle, title: "Review needed" },
  REVIEW_ASSIGNMENT: { icon: ListChecks, title: "Assigned to you" },
  REVIEW_NOTIFICATION_FAILURE: { icon: FileWarning, title: "Notification delivery failed" },
  RUN_REVIEW_HOLD: { icon: PauseCircle, title: "Run paused for review" },
  RUN_AWAITING_APPROVAL: { icon: ListChecks, title: "Run ready to finalise" },
  EXPORT_READY: { icon: Download, title: "Export ready" },
  INTEGRATION_TOKEN_EXPIRING: { icon: KeyRound, title: "Integration expiring" },
};

function metaFor(kind: string) {
  return KIND_META[kind] ?? { icon: BellOff, title: kind.replaceAll("_", " ").toLowerCase() };
}

function bodyFor(n: NotificationRow): string {
  const p = n.payload ?? {};
  switch (n.kind) {
    case "REVIEW_ISSUE_OPENED":
      return (p.title as string) ?? `A ${(p.severity as string)?.toLowerCase() ?? ""} issue needs review`.trim();
    case "RUN_REVIEW_HOLD":
    case "RUN_AWAITING_APPROVAL":
      return `${(p.workflow_type as string) ?? "Workflow"} run`;
    case "EXPORT_READY":
      return `${(p.export_kind as string) ?? "Report"} (${(p.format as string) ?? ""})`;
    case "INTEGRATION_TOKEN_EXPIRING":
      return `${(p.provider as string) ?? "Integration"} token expiring soon`;
    default:
      return "";
  }
}

function relativeTime(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  const m = Math.round(diff / 60000);
  if (m < 1) return "just now";
  if (m < 60) return `${m}m ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h}h ago`;
  const d = Math.round(h / 24);
  return `${d}d ago`;
}

export function NotificationsDrawer() {
  const { notifOpen, setNotifOpen } = useShell();
  const { notifications, unreadCount, markRead, markAllRead } = useNotifications();
  const router = useRouter();

  const open = (n: NotificationRow) => {
    void markRead(n.id);
    const route = n.payload?.route as string | undefined;
    setNotifOpen(false);
    if (route) router.push(route);
  };

  return (
    <Drawer
      open={notifOpen}
      onClose={() => setNotifOpen(false)}
      title="Notifications"
      width={380}
      footer={
        unreadCount > 0 ? (
          <button
            type="button"
            onClick={() => void markAllRead()}
            className="ml-auto inline-flex cursor-pointer items-center gap-1.5 rounded-sm px-2 py-1 text-sm text-text-secondary hover:bg-bg-raised hover:text-text-primary"
          >
            <CheckCheck size={15} aria-hidden="true" /> Mark all read
          </button>
        ) : undefined
      }
    >
      {notifications.length === 0 ? (
        <EmptyState
          icon={BellOff}
          heading="You're all caught up"
          body="Review items, run updates, exports, and alerts will show up here."
        />
      ) : (
        <ul className="-mx-1 flex flex-col">
          {notifications.map((n) => {
            const meta = metaFor(n.kind);
            const Icon = meta.icon;
            const unread = !n.read_at;
            return (
              <li key={n.id}>
                <button
                  type="button"
                  onClick={() => open(n)}
                  className="flex w-full items-start gap-3 rounded-md px-3 py-2.5 text-left hover:bg-bg-raised"
                >
                  <span className="mt-0.5 shrink-0 text-text-muted"><Icon size={17} aria-hidden="true" /></span>
                  <span className="min-w-0 flex-1">
                    <span className="flex items-center gap-2">
                      <span className={`truncate text-sm ${unread ? "font-semibold text-text-primary" : "text-text-secondary"}`}>
                        {meta.title}
                      </span>
                      {unread && <span className="h-1.5 w-1.5 shrink-0 rounded-full bg-action-primary" aria-label="Unread" />}
                    </span>
                    <span className="block truncate text-xs text-text-muted">{bodyFor(n)}</span>
                    <span className="mt-0.5 block text-[11px] text-text-muted tabular-nums">{relativeTime(n.created_at)}</span>
                  </span>
                </button>
              </li>
            );
          })}
        </ul>
      )}
    </Drawer>
  );
}
