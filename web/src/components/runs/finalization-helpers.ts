/** Finalization precondition gates (B15). Each takes just p_run_id and returns
 *  { gate, decision: 'ADVANCE'|'HOLD', payload? }. The master gate
 *  gate_finalization_preconditions_satisfied returns { decision, failing_gate, failure_payload }. */
export interface GateDef { key: string; fn: string; label: string }

export const FINALIZATION_GATES: GateDef[] = [
  { key: "transactions_processed", fn: "gate_finalization_transactions_processed", label: "All transactions processed" },
  { key: "no_unknown_types", fn: "gate_finalization_no_unknown_types", label: "No unknown transaction types" },
  { key: "vat_classifications_complete", fn: "gate_finalization_vat_classifications_complete", label: "VAT classifications complete" },
  { key: "draft_ledger_entries_complete", fn: "gate_finalization_draft_ledger_entries_complete", label: "Draft ledger entries complete" },
  { key: "evidence_satisfied", fn: "gate_finalization_evidence_satisfied", label: "Evidence requirements satisfied" },
  { key: "zero_blocking_issues", fn: "gate_finalization_zero_blocking_issues", label: "No blocking review issues" },
  { key: "audit_log_quiescent", fn: "gate_finalization_audit_log_quiescent", label: "Audit log quiescent" },
  { key: "approval_recorded", fn: "gate_finalization_approval_recorded", label: "Approval recorded" },
  { key: "approval_present_and_step_up", fn: "gate_finalization_approval_present_and_step_up", label: "Step-up approval present" },
];

export interface GateResult { decision?: string; gate?: string; payload?: Record<string, unknown> | null; failure_payload?: Record<string, unknown> | null }

export function gatePassed(r: GateResult | null): boolean {
  return r?.decision === "ADVANCE";
}

/** Short human reason for a non-passing gate, from its payload. */
export function gateReason(r: GateResult | null): string | null {
  if (!r || r.decision === "ADVANCE") return null;
  const p = r.payload ?? r.failure_payload;
  if (!p || Object.keys(p).length === 0) return r.decision ?? "Hold";
  if (typeof p.reason === "string") return p.reason.replaceAll("_", " ").toLowerCase();
  return Object.entries(p).map(([k, v]) => `${k}: ${v}`).join(", ");
}

/** Row from public.archive_packages (RLS-scoped). */
export interface ArchivePackageRow {
  id: string;
  business_id: string;
  organization_id: string;
  workflow_run_id: string;
  period_start: string;
  period_end: string;
  bundle_hash_anchor: string | null;
  package_storage_object_id: string | null;
  step_up_auth_used: boolean;
  original_finalization: boolean;
  created_at: string;
}

export const ARCHIVE_COLUMNS =
  "id, business_id, organization_id, workflow_run_id, period_start, period_end, bundle_hash_anchor, package_storage_object_id, step_up_auth_used, original_finalization, created_at";
