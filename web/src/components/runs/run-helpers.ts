import type { BadgeVariant } from "@/components/ui";

/** Row from public.workflow_runs (RLS-scoped). */
export interface RunRow {
  id: string;
  organization_id: string;
  business_id: string;
  workflow_type: "OUT_MONTHLY" | "IN_MONTHLY" | "OUT_ADJUSTMENT" | "IN_ADJUSTMENT";
  status: string;
  period_start: string;
  period_end: string;
  started_at: string | null;
  completed_at: string | null;
  finalized_at: string | null;
  aborted_at: string | null;
  abort_reason: string | null;
  paired_run_id: string | null;
  parent_run_id: string | null;
  manual_trigger_note: string | null;
  trigger_kind: string;
  created_at: string;
}

export const RUN_COLUMNS =
  "id, organization_id, business_id, workflow_type, status, period_start, period_end, started_at, completed_at, finalized_at, aborted_at, abort_reason, paired_run_id, parent_run_id, manual_trigger_note, trigger_kind, created_at";

export const WORKFLOW_TYPE_LABEL: Record<string, string> = {
  OUT_MONTHLY: "Outgoing — expenses",
  IN_MONTHLY: "Incoming — income",
  OUT_ADJUSTMENT: "Outgoing adjustment",
  IN_ADJUSTMENT: "Incoming adjustment",
};
export const WORKFLOW_SIDE: Record<string, "OUT" | "IN"> = {
  OUT_MONTHLY: "OUT", OUT_ADJUSTMENT: "OUT", IN_MONTHLY: "IN", IN_ADJUSTMENT: "IN",
};

export const RUN_STATUS_BADGE: Record<string, { variant: BadgeVariant; label: string }> = {
  CREATED: { variant: "status-neutral", label: "Created" },
  RUNNING: { variant: "status-info", label: "Running" },
  PAUSED: { variant: "severity-medium", label: "Paused" },
  REVIEW_HOLD: { variant: "severity-medium", label: "Review hold" },
  AWAITING_APPROVAL: { variant: "severity-medium", label: "Awaiting approval" },
  FINALIZING: { variant: "status-info", label: "Finalizing" },
  FINALIZED: { variant: "status-success", label: "Finalized" },
  FAILED: { variant: "severity-blocking", label: "Failed" },
  CANCELLED: { variant: "status-neutral", label: "Cancelled" },
  COMPENSATING: { variant: "severity-medium", label: "Compensating" },
  ABORTED: { variant: "status-neutral", label: "Aborted" },
};
export function runStatusBadge(s: string): { variant: BadgeVariant; label: string } {
  return RUN_STATUS_BADGE[s] ?? { variant: "status-neutral", label: s };
}

export interface PhaseDefRow { phase_order: number; phase_name: string; optional: boolean; description: string | null }
export interface PhaseStateRow { phase_name: string; phase_order: number; status: string; gate_decision: string | null; error_summary: string | null; started_at: string | null; completed_at: string | null }
export interface ApprovalRow { id: string; approved_by: string; approved_at: string; approval_method: string; approval_note: string | null; revoked_at: string | null }

export const PHASE_STATUS_META: Record<string, { variant: BadgeVariant; label: string }> = {
  PENDING: { variant: "status-neutral", label: "Pending" },
  RUNNING: { variant: "status-info", label: "Running" },
  COMPLETED: { variant: "status-success", label: "Completed" },
  FAILED: { variant: "severity-blocking", label: "Failed" },
  SKIPPED: { variant: "status-neutral", label: "Skipped" },
  HOLDING: { variant: "severity-medium", label: "Holding" },
};

export const GATE_LABEL: Record<string, string> = {
  ADVANCE: "Advance", HOLD: "Hold", ROUTE_TO_SIDE_PHASE: "Side phase",
};

/** "May 2026" from an ISO timestamp. */
export function periodLabel(periodStart: string): string {
  const d = new Date(periodStart);
  return new Intl.DateTimeFormat("en-GB", { month: "long", year: "numeric", timeZone: "UTC" }).format(d);
}

const STATUS_DONE = new Set(["FINALIZED", "CANCELLED", "ABORTED", "FAILED"]);
export function runIsActive(s: string): boolean {
  return !STATUS_DONE.has(s);
}
