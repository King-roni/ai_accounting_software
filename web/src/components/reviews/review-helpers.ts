import type { BadgeVariant } from "@/components/ui";
import type { Severity } from "@/theme/tokens";

export type IssueGroup = "MISSING_DOCUMENTS" | "NEEDS_CONFIRMATION" | "POSSIBLE_WRONG_MATCH" | "POSSIBLE_TAX_VAT_ISSUE" | "UNUSUAL_TRANSACTION";

export interface IssueRow {
  id: string;
  issue_type: string;
  issue_group: IssueGroup;
  severity: Severity;
  plain_language_title: string;
  plain_language_description: string | null;
  recommended_action: string | null;
  status: "OPEN" | "RESOLVED" | "SNOOZED" | "DISMISSED" | "AUTO_RESOLVED_BY_RESCAN";
  transaction_id: string | null;
  document_id: string | null;
  match_record_id: string | null;
  draft_ledger_entry_id: string | null;
  assigned_to: string | null;
  snoozed_until: string | null;
  created_at: string;
}

export const ISSUE_COLUMNS =
  "id, issue_type, issue_group, severity, plain_language_title, plain_language_description, recommended_action, status, transaction_id, document_id, match_record_id, draft_ledger_entry_id, assigned_to, snoozed_until, created_at";

/** The actionable buckets (B14). */
export const GROUPS: { id: IssueGroup; label: string }[] = [
  { id: "MISSING_DOCUMENTS", label: "Missing documents" },
  { id: "NEEDS_CONFIRMATION", label: "Needs confirmation" },
  { id: "POSSIBLE_WRONG_MATCH", label: "Possible wrong match" },
  { id: "POSSIBLE_TAX_VAT_ISSUE", label: "Possible tax / VAT issue" },
  { id: "UNUSUAL_TRANSACTION", label: "Unusual transaction" },
];
export const GROUP_LABEL: Record<IssueGroup, string> = Object.fromEntries(GROUPS.map((g) => [g.id, g.label])) as Record<IssueGroup, string>;

export const SEVERITY_BADGE: Record<Severity, { variant: BadgeVariant }> = {
  BLOCKING: { variant: "severity-blocking" },
  HIGH: { variant: "severity-high" },
  MEDIUM: { variant: "severity-medium" },
  LOW: { variant: "severity-low" },
};
export const SEVERITY_RANK: Record<Severity, number> = { BLOCKING: 0, HIGH: 1, MEDIUM: 2, LOW: 3 };

/** Friendly labels for the resolution_action_kind_enum values. */
export const ACTION_LABEL: Record<string, string> = {
  CONFIRM_CLASSIFICATION: "Confirm classification",
  CONFIRM_MATCH: "Confirm match",
  REJECT_MATCH: "Mark as wrong",
  MARK_AS_NO_INVOICE_AVAILABLE: "No invoice available",
  UPLOAD_DOCUMENT: "Upload document",
  ADD_EXPLANATION_NOTE: "Add note",
  IGNORE_WITH_REASON: "Ignore with reason",
  SEND_TO_ACCOUNTANT_REVIEW: "Send to accountant",
  CHANGE_TAG: "Change tag",
  CHANGE_TRANSACTION_TYPE: "Change type",
  MARK_AS_INTERNAL_TRANSFER: "Internal transfer",
  MARK_AS_BANK_FEE: "Bank fee",
  MARK_AS_NON_DEDUCTIBLE: "Non-deductible",
  RERUN_SCAN_AFTER_CHANGE: "Re-run scan",
  CONFIRM_LEDGER_ENTRY: "Confirm entry",
};

/** Actions whose apply_resolution_action call requires a free-text reason/note. */
export const ACTION_NEEDS_TEXT = new Set<string>([
  "MARK_AS_NO_INVOICE_AVAILABLE", "ADD_EXPLANATION_NOTE", "IGNORE_WITH_REASON",
]);

/** Actions the review drawer renders as in-place resolve buttons (others route
 *  to another surface, or are handled by Assign). */
export const INLINE_RESOLVE_ACTIONS = new Set<string>([
  "CONFIRM_CLASSIFICATION", "CONFIRM_MATCH", "REJECT_MATCH",
  "MARK_AS_NO_INVOICE_AVAILABLE", "ADD_EXPLANATION_NOTE", "IGNORE_WITH_REASON",
  "CONFIRM_LEDGER_ENTRY",
]);

/** Map a recommended resolution action to the surface that resolves it. */
export function resolutionRoute(action: string | null): { label: string; href: string } | null {
  switch (action) {
    case "UPLOAD_DOCUMENT": return { label: "Upload document", href: "/documents" };
    case "CONFIRM_MATCH":
    case "REJECT_MATCH": return { label: "Review match", href: "/matching" };
    case "CHANGE_TAG":
    case "CHANGE_TRANSACTION_TYPE":
    case "MARK_AS_INTERNAL_TRANSFER":
    case "MARK_AS_BANK_FEE":
    case "MARK_AS_NON_DEDUCTIBLE":
    case "ADD_EXPLANATION_NOTE": return { label: "Open transaction", href: "/transactions" };
    case "SEND_TO_ACCOUNTANT_REVIEW": return { label: "Open in ledger", href: "/ledger" };
    default: return null;
  }
}
