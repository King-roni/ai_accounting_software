"use client";
import { useState } from "react";
import Link from "next/link";
import { Clock, UserPlus } from "lucide-react";
import { Badge, Button, Drawer } from "@/components/ui";
import { SeverityIcon } from "@/theme/icons";
import {
  GROUP_LABEL, SEVERITY_BADGE, resolutionRoute,
  ACTION_LABEL, ACTION_NEEDS_TEXT, INLINE_RESOLVE_ACTIONS, type IssueRow,
} from "./review-helpers";

export function ReviewDetailDrawer({
  row, open, onClose, onSnooze, onAssign, onResolve, allowedActions, busy,
}: {
  row: IssueRow | null;
  open: boolean;
  onClose: () => void;
  onSnooze: (r: IssueRow) => void;
  onAssign: (r: IssueRow) => void;
  onResolve: (r: IssueRow, action: string, opts?: { note?: string; reason?: string }) => void;
  allowedActions: string[];
  busy: boolean;
}) {
  const [text, setText] = useState("");
  // Reset the reason/note field when the drawer switches to a different issue,
  // during render (no effect, no remount — keeps the Drawer's open transition).
  const [seenId, setSeenId] = useState<string | null>(row?.id ?? null);
  if ((row?.id ?? null) !== seenId) { setSeenId(row?.id ?? null); setText(""); }

  const route = row ? resolutionRoute(row.recommended_action) : null;
  const inline = allowedActions.filter((a) => INLINE_RESOLVE_ACTIONS.has(a));
  const needsText = inline.some((a) => ACTION_NEEDS_TEXT.has(a));

  function act(action: string) {
    if (!row) return;
    if (ACTION_NEEDS_TEXT.has(action) && !text.trim()) return;
    onResolve(row, action, { note: text.trim() || undefined, reason: text.trim() || undefined });
  }

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
                className="ml-auto inline-flex h-8 items-center rounded-md border border-border-default bg-bg-base px-3 text-sm font-medium text-text-primary hover:border-border-strong hover:bg-bg-raised"
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

          {inline.length > 0 && (
            <div className="flex flex-col gap-2 border-t border-border-subtle pt-3">
              <p className="text-xs font-medium uppercase tracking-wide text-text-muted">Resolve</p>
              {needsText && (
                <textarea
                  value={text}
                  onChange={(e) => setText(e.target.value)}
                  rows={2}
                  placeholder="Reason / note (required for some actions)"
                  className="w-full resize-none rounded-md border border-border-default bg-bg-base px-3 py-2 text-sm text-text-primary placeholder:text-text-muted focus:border-border-strong focus:outline-none"
                />
              )}
              <div className="flex flex-wrap gap-2">
                {inline.map((action, i) => {
                  const disabled = busy || (ACTION_NEEDS_TEXT.has(action) && !text.trim());
                  return (
                    <Button
                      key={action}
                      variant={i === 0 ? "primary" : "secondary"}
                      size="sm"
                      loading={busy}
                      disabled={disabled}
                      onClick={() => act(action)}
                    >
                      {ACTION_LABEL[action] ?? action.replace(/_/g, " ").toLowerCase()}
                    </Button>
                  );
                })}
              </div>
            </div>
          )}
        </div>
      )}
    </Drawer>
  );
}
