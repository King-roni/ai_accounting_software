# Block 14 — Phase 04: Resolution Actions

## References

- Block doc: `Docs/blocks/14_review_queue.md` (Resolution Actions — the closed action vocabulary)
- Block doc: `Docs/blocks/01_core_principles.md` (Principle 1 — Workflow-First; resolutions advance state through the engine)
- Block doc: `Docs/blocks/03_workflow_engine.md` (Phase 06 — phase execution; resolution events feed gate re-evaluation)

## Phase Goal

Define the closed vocabulary of resolution actions, the per-`issue_type` allowed-actions table, the audit-event shape for every resolution, and the cross-block effect of each action (which downstream tools / state changes the resolution triggers). After this phase, every issue raised by upstream blocks has an unambiguous set of actions the user can take, each producing a deterministic effect.

## Dependencies

- Phase 01 (`review_issues` schema; `REVIEW_QUEUE_RESOLVE` permission surface)
- Phase 02 (`registerIssueType` provides `allowed_resolution_actions`)
- Phase 03 (card-content provides the recommended-action label)
- Block 02 Phase 04 (`REVIEW_QUEUE_RESOLVE` surface gate)
- Block 03 Phase 06 (resolutions feed gate re-evaluation)
- Block 05 Phase 02 (audit log)
- Various producing blocks (06, 07, 08, 10, 11, 13) — each owns the downstream effects of resolutions on its own state

## Deliverables

- **Closed resolution-action vocabulary** (canonical 13-action list; the architecture doc lists representative actions; this phase pins the exhaustive enum):
  - `Upload document`
  - `Confirm match`
  - `Reject match`
  - `Change tag`
  - `Change transaction type`
  - `Mark as internal transfer`
  - `Mark as bank fee`
  - `Mark as non-deductible`
  - `Mark as no invoice available (with reason)`
  - `Add explanation note` (writes to `review_issues.notes`; does NOT close the issue — keeps it open with the comment attached)
  - `Send to accountant review` (re-routes the issue; sets `assigned_to` to a designated `Accountant` role user; sub-doc tracks the picker)
  - `Ignore with reason` (closes the issue with a free-text reason; treated as a documented exception)
  - `Re-run scan after change` (manually triggers Phase 08's affected-issues re-scan; rare — the system normally re-scans automatically)
- **Stored as enum** (Postgres ENUM type `resolution_action_kind`); attempting to use an unregistered value is rejected at insertion.
- **Per-`issue_type` allowed-actions table** (declared by `registerIssueType` in Phase 02):
  - Each `issue_type` registration declares its `allowed_resolution_actions` as a subset of the 13-value vocabulary.
  - A user invoking an action not in the issue's allowed set is rejected with a structured error.
  - **Stage 1 representative mappings** (full table in sub-doc):

    | `issue_type` | Allowed actions |
    | --- | --- |
    | `matching.no_match_out_expense` | `Upload document`, `Mark as no invoice available (with reason)`, `Add explanation note`, `Send to accountant review`, `Re-run scan after change` |
    | `matching.matched_needs_confirmation` | `Confirm match`, `Reject match`, `Add explanation note`, `Send to accountant review` |
    | `matching.possible_match` | `Confirm match`, `Reject match`, `Change tag`, `Add explanation note` |
    | `matching.split_payment_proposal` | `Confirm match`, `Reject match`, `Add explanation note` |
    | `matching.document_used_multiple_times` | `Confirm match` (as split-payment), `Reject match`, `Add explanation note`, `Send to accountant review` |
    | `classification.unknown_type` | `Change transaction type`, `Mark as internal transfer`, `Mark as bank fee`, `Add explanation note`, `Send to accountant review` |
    | `classification.rule_conflict` | `Change tag`, `Change transaction type`, `Add explanation note`, `Send to accountant review` |
    | `dedup.possible_duplicate` | `Confirm match` (as new), `Reject match`, `Add explanation note` |
    | `endscan.unusual_amount` | `Add explanation note`, `Ignore with reason`, `Send to accountant review` |
    | `endscan.large_outlier` | `Add explanation note`, `Ignore with reason`, `Send to accountant review` |
    | `ledger.accountant_review_unknown_treatment` | `Change tag`, `Add explanation note`, `Send to accountant review`, `Ignore with reason` |
    | `ledger.tag_mismatch_detected` | `Change tag`, `Add explanation note` |
    | `ledger.missing_required_evidence` | `Upload document`, `Mark as no invoice available (with reason)`, `Add explanation note` |
    | `ledger.vies_vat_number_missing` | `Add explanation note`, `Send to accountant review` |
    | `invoice.numbering_gap_detected` | `Add explanation note`, `Send to accountant review` (resolution requires admin investigation; this issue typically indicates a system anomaly) |

- **Per-action contract:**
  - Each action takes `(issue_id, actor_user_id, action_payload?, optional_note?)` and produces:
    1. A `review_issues.status` transition (typically `OPEN → RESOLVED` or `OPEN → DISMISSED`; `Add explanation note` keeps the issue `OPEN`).
    2. A side-effect on the producing block's state (per the per-action mapping below).
    3. An audit event capturing actor, issue, action kind, payload, optional note.
- **Per-action downstream effects** (the cross-block contract — each producing block owns the effect on its own state):
  - **`Upload document`** — invokes `intake.manual_upload_handler` (Block 09 Phase 07) with the new file; on successful match, issue closes; on no-match, issue stays open with the new candidate.
  - **`Confirm match`** — Block 10 Phase 03's `MATCHING_USER_CONFIRMED` event; transitions `match_records.match_status` to `MATCHED_CONFIRMED`; for split-payment proposals, creates the `split_payment_groups` row.
  - **`Reject match`** — Block 10 Phase 06's rejection memory: writes to `match_rejection_memory`; `match_records.match_status = REJECTED_MATCH`. Forever-remembered per Stage 1.
  - **`Change tag`** — Block 08 Phase 05's tag-update path; updates `transactions.tag`; triggers Block 11's ledger recompute for the affected entry; vendor memory increments per Block 08 Phase 03.
  - **`Change transaction type`** — Block 08 Phase 09's reclassification path; if the new type changes which workflow filter (OUT vs IN) the row falls into, Block 12 Phase 03 / Block 13 Phase 08's filter re-runs.
  - **`Mark as internal transfer`** — convenience for `Change transaction type` to `INTERNAL_TRANSFER`; same effect.
  - **`Mark as bank fee`** — convenience for `Change transaction type` to `BANK_FEE`; same effect.
  - **`Mark as non-deductible`** — Block 11 Phase 03's chart-of-accounts customization path: sets the entry's account to the non-deductible sub-account for its category; ledger recomputes.
  - **`Mark as no invoice available (with reason)`** — **OUT-side only** for Stage 1. Invokes Block 12 Phase 06's `out_workflow.document_exception` path; sets `transactions.effective_match_status = EXCEPTION_DOCUMENTED`; mandatory `reason`. **IN-side does NOT have an analog** — IN-side `NO_MATCH` (income received without an invoice) is resolved by either creating a tax invoice via Block 13's Invoice Generator and then re-matching, OR reclassifying the transaction type via `Change transaction type` to `INTERNAL_TRANSFER` / `LOAN_OR_SHAREHOLDER_MOVEMENT` IN-direction / `REFUND_IN`. The 13-action vocabulary is unified, but the per-`issue_type` allowed-actions table excludes `Mark as no invoice available` from IN-side `Missing Documents` issues. Sub-doc tracks the IN-side resolution UX.
  - **`Add explanation note`** — writes to `review_issues.notes`; the issue stays `OPEN`. Audit-logged.
  - **`Send to accountant review`** — sets `assigned_to` to a user with `role = Accountant` in the same business (sub-doc owns the picker UI; Stage 1 default: the user picks from a list); the issue stays `OPEN`; assignee is notified per Phase 06.
  - **`Ignore with reason`** — closes the issue as `DISMISSED` with mandatory `reason`. The issue is treated as a documented exception by Block 12 Phase 07 / Block 13 Phase 09 gates. **Restricted by severity:** `BLOCKING` issues cannot be dismissed via this action (the underlying problem must be fixed; sub-doc tracks the per-severity allow-list for `Ignore with reason`).
  - **`Re-run scan after change`** — manually triggers Phase 08's affected-issues re-scan; emits `REVIEW_RESCAN_TRIGGERED_MANUALLY`.
- **Permission gating:**
  - All resolution actions require `REVIEW_QUEUE_RESOLVE` (Phase 01's surface). Reviewer / Read-only roles are denied.
  - Some actions have stricter sub-permissions (per the matrix; sub-doc owns the exact mapping):
    - `Mark as no invoice available` requires `WORKFLOW_TRIGGER` (Block 02 Phase 04 — same surface as starting a workflow run, since the action documents an exception that affects period closure). **Important interaction with Send-to-accountant-review:** when an issue is `Send to accountant review`-assigned to an Accountant who lacks `WORKFLOW_TRIGGER` (per the matrix's role-table, Accountant is denied workflow execution), the Accountant CANNOT resolve the issue via `Mark as no invoice available`. The intended flow is: the Accountant reviews, adds a note, and sends the issue back (via reassignment to Owner / Admin / Bookkeeper) for the documented-exception action. Sub-doc covers the accountant-handback UX.
    - `Ignore with reason` for `BLOCKING` severity is denied entirely (per the severity restriction above); for `HIGH` requires Owner / Admin only.
- **Resolution feeds gate re-evaluation** (Block 03 Phase 05's framework):
  - On every successful resolution, the engine triggers a gate-re-evaluation pass via Block 03 Phase 05's existing mechanism. The re-evaluation emits Block 03 Phase 05's standard events (`WORKFLOW_GATE_PASSED`, `WORKFLOW_GATE_HOLD`, or `WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE` per the gate's return). Affected gates re-run; the workflow may transition out of `REVIEW_HOLD` (set by Block 12 Phase 06's `MANUAL_UPLOAD_HOLD`) or out of `AWAITING_APPROVAL` (set by Block 12 Phase 07 / Block 13 Phase 09's `HUMAN_REVIEW_HOLD`) if the resolution cleared the last blocking issue.
- **Idempotency:**
  - Re-applying the same resolution action to the same issue (already-`RESOLVED` or already-`DISMISSED`) is a no-op; the audit event records the no-op attempt.
  - Re-applying a different action to a closed issue is rejected (a closed issue cannot be re-resolved; the user re-opens via Owner/Admin override — sub-doc tracks the rare path).
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `REVIEW_QUEUE`):
  - `REVIEW_RESOLUTION_APPLIED` (per resolution; payload = action kind, payload, note, before/after `status`, downstream tool invoked)
  - `REVIEW_RESOLUTION_REJECTED_PERMISSION` (when permission gate denies)
  - `REVIEW_RESOLUTION_REJECTED_DISALLOWED_ACTION` (when the action isn't in the issue's allowed set)
  - `REVIEW_RESOLUTION_REJECTED_BLOCKING_DISMISSAL` (when `Ignore with reason` attempted on `BLOCKING`)
  - `REVIEW_RESOLUTION_REJECTED_NOOP` (when re-applying to an already-closed issue)
  - `REVIEW_RESCAN_TRIGGERED_MANUALLY`

## Definition of Done

- The 13-action enum is registered as a Postgres ENUM; non-vocabulary actions are rejected.
- Each `issue_type` registered in Phase 02 carries a non-empty `allowed_resolution_actions` subset.
- A test invokes `Confirm match` on a `matching.matched_needs_confirmation` issue → Block 10 Phase 03's confirmation path fires → `match_records.match_status = MATCHED_CONFIRMED` → the issue closes → `gate.out.matching_complete` re-evaluates.
- A test invokes `Reject match` → Block 10 Phase 06's rejection memory writes → next run skips the pair.
- A test invokes `Change tag` → Block 11 ledger recomputes for the affected entry.
- A test invokes `Mark as no invoice available` with mandatory reason → Block 12 Phase 06's exception path → `transactions.effective_match_status = EXCEPTION_DOCUMENTED`.
- A test invokes `Ignore with reason` on a `MEDIUM` issue → succeeds; on a `BLOCKING` issue → rejected with the right error.
- A user without `REVIEW_QUEUE_RESOLVE` is denied with the right error.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Full per-`issue_type` allowed-actions table sub-doc** — exhaustive map across all upstream blocks.
- **Per-action payload schema sub-doc** — JSON shapes for `Upload document`, `Change tag`, `Change transaction type`, etc.
- **Severity-restricted dismissal sub-doc** — exact rules for `Ignore with reason` per severity / role combination.
- **Re-open closed issue sub-doc** — the Owner/Admin override path; audit shape.
- **Picker UI sub-doc for `Send to accountant review`** — accountant-role list, per-business filtering.
- **Idempotency / replay sub-doc** — handling network retries on resolution actions; double-click protection.
