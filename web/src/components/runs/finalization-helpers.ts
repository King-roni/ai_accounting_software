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

// --------------------------------------------------------------------------- //
// Adjustment re-finalization (B15 / R7.8)
// --------------------------------------------------------------------------- //

/** The 8 adjustment delta kinds (adjustment_delta_kind_enum). */
export type AdjustmentDeltaKind =
  | "RECLASSIFY_TRANSACTION"
  | "ADD_EVIDENCE"
  | "CORRECT_VAT_TREATMENT"
  | "ADJUST_AMOUNT"
  | "OTHER"
  | "RETROACTIVE_CREDIT_NOTE"
  | "CORRECT_PAYMENT_ALLOCATION"
  | "MARK_INVOICE_WRITTEN_OFF";

export const DELTA_KIND_LABEL: Record<AdjustmentDeltaKind, string> = {
  RECLASSIFY_TRANSACTION: "Reclassify transaction",
  ADD_EVIDENCE: "Add evidence",
  CORRECT_VAT_TREATMENT: "Correct VAT treatment",
  ADJUST_AMOUNT: "Adjust amount",
  OTHER: "Other",
  RETROACTIVE_CREDIT_NOTE: "Retroactive credit note",
  CORRECT_PAYMENT_ALLOCATION: "Correct payment allocation",
  MARK_INVOICE_WRITTEN_OFF: "Mark invoice written off",
};

// The DB trigger fn_check_adjustment_delta_kind_vs_parent_workflow rejects these
// kinds per parent side; mirror it so the picker never offers an invalid combo.
const OUT_FORBIDDEN_KINDS: AdjustmentDeltaKind[] = [
  "RETROACTIVE_CREDIT_NOTE",
  "CORRECT_PAYMENT_ALLOCATION",
  "MARK_INVOICE_WRITTEN_OFF",
];
const IN_FORBIDDEN_KINDS: AdjustmentDeltaKind[] = ["ADD_EVIDENCE", "ADJUST_AMOUNT"];

/** Delta kinds valid for a given side (OUT = expenses, IN = income). */
export function deltaKindsForSide(side: "OUT" | "IN"): AdjustmentDeltaKind[] {
  const forbidden = side === "OUT" ? OUT_FORBIDDEN_KINDS : IN_FORBIDDEN_KINDS;
  return (Object.keys(DELTA_KIND_LABEL) as AdjustmentDeltaKind[]).filter(
    (k) => !forbidden.includes(k),
  );
}

/** Row from public.archive_manifests (RLS-scoped, append-only, versioned). */
export interface ManifestVersionRow {
  id: string;
  archive_package_id: string;
  manifest_version_number: number;
  manifest_hash: string | null;
  produced_by_run_id: string | null;
  produced_at: string;
}
export const MANIFEST_COLUMNS =
  "id, archive_package_id, manifest_version_number, manifest_hash, produced_by_run_id, produced_at";

/** Row from public.adjustment_records (RLS-scoped). One per adjustment run. */
export interface AdjustmentRecordRow {
  run_id: string;
  parent_run_id: string;
  delta_kind: AdjustmentDeltaKind;
  reason: string;
  created_at: string;
}
export const ADJUSTMENT_RECORD_COLUMNS =
  "run_id, parent_run_id, delta_kind, reason, created_at";
