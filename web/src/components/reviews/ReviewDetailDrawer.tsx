"use client";
import Link from "next/link";
import { Clock, UserPlus } from "lucide-react";
import { Badge, Button, Drawer } from "@/components/ui";
import { SeverityIcon } from "@/theme/icons";
import { GROUP_LABEL, SEVERITY_BADGE, resolutionRoute, type IssueRow } from "./review-helpers";

export function ReviewDetailDrawer({
  row, open, onClose, onSnooze, onAssign, busy,
}: {
  row: IssueRow | null;
  open: boolean;
  onClose: () => void;
  onSnooze: (r: IssueRow) => void;
  onAssign: (r: IssueRow) => void;
  busy: boolean;
}) {
  const route = row ? resolutionRoute(row.recommended_action) : null;
  return (
    <Drawer
      open={open}
      onClose={onClose}
      title="Review issue"
      width={440}
      footer={
        row ? (
          <>
            <Button variant="tertiary" size="sm" leadingIcon={Clock} loading={busy} onClick={() => onSnooze(row)}>Snooze</Button>
            <Button variant="secondary" size="sm" leadingIcon={UserPlus} loading={busy} onClick={() => onAssign(row)}>Assign to me</Button>
            {route && (
              <Link
                href={route.href}
                onClick={onClose}
                className="ml-auto inline-flex h-8 items-center rounded-md bg-action-primary px-3 text-sm font-medium text-text-on-primary hover:bg-action-hover"
              >
                {route.label}
              </Link>
            )}
          </>
        ) : undefined
      }
    >
      {row && (
        <div className="flex flex-col gap-4">
          <div className="flex flex-wrap items-center gap-2">
            <Badge variant={SEVERITY_BADGE[row.severity].variant} size="sm">{row.severity}</Badge>
            <span className="rounded-full border border-border-subtle bg-bg-raised px-2 py-0.5 text-xs text-text-secondary">{GROUP_LABEL[row.issue_group]}</span>
            <span className="rounded-full border border-border-subtle bg-bg-raised px-2 py-0.5 text-xs text-text-secondary">{row.status}</span>
          </div>
          <div className="flex items-start gap-2">
            <SeverityIcon severity={row.severity} size={20} className="mt-0.5 shrink-0" />
            <h3 className="text-base font-semibold text-text-primary">{row.plain_language_title}</h3>
          </div>
          {row.plain_language_description && <p className="text-sm text-text-secondary">{row.plain_language_description}</p>}
          {row.recommended_action && (
            <div className="rounded-md bg-bg-raised p-3">
              <p className="text-xs font-medium uppercase tracking-wide text-text-muted">Recommended action</p>
              <p className="mt-0.5 text-sm text-text-primary">{row.recommended_action.replace(/_/g, " ").toLowerCase()}</p>
            </div>
          )}
        </div>
      )}
    </Drawer>
  );
}
