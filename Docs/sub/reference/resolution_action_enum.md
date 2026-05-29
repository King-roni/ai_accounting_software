# Resolution Action Enum

**Category:** Reference data · **Owning block:** 04 — Data Architecture · **Co-owners:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 1 taxonomy)

The closed 13-value resolution-action vocabulary every review-queue resolution UI element binds to. Each action carries a defined effect (what changes), a role × severity eligibility matrix, and a canonical audit event. Adding an action requires a `Docs/decisions_log.md` amendment.

Block 14 Phase 04 is the architectural source. This sub-doc commits to the exact vocabulary + the matrix; per-action JSON payload shapes live in `review_resolution_action_payload_schema` (Schemas, Block 14).

---

## The 13 actions

Grouped by intent:

### Group 1 — Confirm / accept (4 actions)

| Action | Effect | Issue groups | Audit event |
| --- | --- | --- | --- |
| `mark_resolved` | Sets `status = RESOLVED`; the issue is closed without further state change | All | `REVIEW_ISSUE_RESOLVED` |
| `confirm_match` | Sets a proposed match to `CONFIRMED`; advances the underlying gate | Needs Confirmation, Possible Wrong Match | `MATCHING_USER_CONFIRMED` (per Block 10 Phase 07) |
| `mark_as_no_invoice_available` | OUT-only — declares a missing-doc exception; sets `effective_match_status = EXCEPTION_DOCUMENTED` on the transaction | Missing Documents (OUT only) | `OUT_WORKFLOW_DOCUMENT_EXCEPTION_RECORDED` |
| `accept_classification` | Sets `classification_status = CONFIRMED` for a NEEDS_CONFIRMATION classification | Needs Confirmation | `CLASSIFICATION_USER_CONFIRMED` |

### Group 2 — Reject / reclassify (3 actions)

| Action | Effect | Issue groups | Audit event |
| --- | --- | --- | --- |
| `reject_match` | Sets a proposed match to `REJECTED`; writes rejection memory per `rejection_memory_schema` (cannot re-suggest pair) | Possible Wrong Match, Needs Confirmation | `MATCHING_USER_REJECTED` |
| `reclassify_transaction` | Changes `transactions.transaction_type` to a different value from `transaction_type_enum`; replays Block 11's ledger preparation | Needs Confirmation, Possible Wrong Match | `CLASSIFICATION_USER_RECLASSIFIED` |
| `propose_alternative_match` | User picks a different candidate from a list; combines reject-old + confirm-new in one transaction | Possible Wrong Match | `MATCHING_USER_ALTERNATIVE_PROPOSED` |

### Group 3 — Defer / route (3 actions)

| Action | Effect | Issue groups | Audit event |
| --- | --- | --- | --- |
| `snooze` | Sets `status = SNOOZED` + `snoozed_at` + `snoozed_by`; carry-forward to next run per `rescan_policies` | Any (MEDIUM/LOW severity only) | `REVIEW_ISSUE_SNOOZED` |
| `reassign` | Sets `assigned_to_user_id`; notifies assignee per `transactional_email_service_integration` | Any | `REVIEW_ISSUE_REASSIGNED` |
| `send_to_my_inbox` | Posts a self-link via `send_to_my_inbox_self_link_schema`; keeps issue in queue but flags actor's personal inbox | Any | `REVIEW_ISSUE_SELF_LINKED` |

### Group 4 — Annotate / regenerate (2 actions)

| Action | Effect | Issue groups | Audit event |
| --- | --- | --- | --- |
| `add_note` | Appends to `resolution_note` (single free-text field per Stage 1 decision); no status change | Any | `REVIEW_NOTE_ADDED` |
| `request_regenerate_card` | Re-runs `generateAndPersistCardContent` for the issue (Block 14 internal); useful when source data changed | Any | `REVIEW_CARD_REGENERATED` |

### Group 5 — Dismiss (1 action)

| Action | Effect | Issue groups | Audit event |
| --- | --- | --- | --- |
| `dismiss_with_reason` | Sets `status = DISMISSED` + requires `resolution_note` (mandatory for this action); severity-restricted per `severity_enum` dismissal matrix | Any (except BLOCKING) | `REVIEW_ISSUE_DISMISSED` |

## Role × action eligibility matrix

| Action | Owner | Admin | Bookkeeper | Accountant | Reviewer | Read-only |
| --- | --- | --- | --- | --- | --- | --- |
| mark_resolved | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| confirm_match | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| mark_as_no_invoice_available | ✓ | ✓ | ✓ | ✗ (1) | ✗ | ✗ |
| accept_classification | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| reject_match | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| reclassify_transaction | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| propose_alternative_match | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| snooze (MEDIUM) | ✓ | ✓ | ✓ | ✗ | ✗ | ✗ |
| snooze (LOW) | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| reassign | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ |
| send_to_my_inbox | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ |
| add_note | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ |
| request_regenerate_card | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ |
| dismiss_with_reason | per severity (see below) | per severity | per severity | per severity (LOW only) | ✗ | ✗ |

(1) Per the 2026-05-08 Block 14 fix: an Accountant assigned via Send-to-accountant cannot resolve via `mark_as_no_invoice_available`; the intended flow is reassignment back to a Bookkeeper.

The full dismissal matrix is in `severity_enum` — `dismiss_with_reason` follows that table.

## Permission surface mapping

| Action | Permission surface |
| --- | --- |
| mark_resolved, confirm_match, mark_as_no_invoice_available, accept_classification, reject_match, reclassify_transaction, propose_alternative_match, snooze, send_to_my_inbox, add_note, dismiss_with_reason | `REVIEW_QUEUE_RESOLVE` |
| reassign | `REVIEW_ASSIGN` |
| request_regenerate_card | `REVIEW_REGENERATE` |
| (view-only — no action) | `REVIEW_QUEUE_VIEW` |

Surfaces are defined in `permission_matrix`. The 2026-05-08 amendment decomposed `ISSUE_RESOLVE` into these four; this matrix consumes that decomposition.

## Bulk action interaction

Per `bulk_action_policies`, the following actions support bulk apply (mass-select N issues, apply one action):

- `mark_resolved`
- `snooze`
- `dismiss_with_reason`
- `reassign`
- `accept_classification`

Bulk actions emit one audit event per affected issue (per Stage 1 decision: "One audit event per affected issue"), wrapped in a `REVIEW_BULK_ACTION_APPLIED` summary event with `affected_count`.

Bulk `confirm_match` / `reject_match` is NOT supported — these actions need per-issue context (which proposed candidate to confirm) that bulk cannot provide cleanly.

## Storage

Per-action payload shapes live in `review_resolution_action_payload_schema` (Schemas, Block 14). The shape varies:

```sql
-- review_resolution_actions (table reference; not part of this taxonomy)
action_type        text NOT NULL,  -- one of the 13 strings above
action_payload     jsonb NOT NULL, -- per-action schema
applied_by_user_id uuid NOT NULL,
applied_at         timestamptz NOT NULL,
review_issue_id    uuid NOT NULL,
audit_event_id     uuid NOT NULL   -- FK to audit_log
```

Lint rule: `action_type` value validated against this closed list at write time.

## Mobile write rejection

Per `mobile_write_rejection_endpoints.md`, all resolution-action write operations are blocked on mobile clients. The following actions are explicitly listed as mobile-rejected write surfaces:

| Action | Mobile behavior |
| --- | --- |
| `mark_resolved`, `confirm_match`, `accept_classification`, `reject_match`, `reclassify_transaction`, `propose_alternative_match` | Blocked — resolution writes are desktop-only |
| `snooze`, `dismiss_with_reason`, `reassign` | Blocked — state-changing defer/route actions are desktop-only |
| `add_note` | Blocked — note writes are desktop-only |
| `request_regenerate_card` | Blocked — AI regeneration is desktop-only |
| `send_to_my_inbox` | Blocked — self-link write is desktop-only |

Mobile clients may view the review queue (`REVIEW_QUEUE_VIEW` surface) and read issue cards, but cannot execute any of the 13 resolution actions. Any mobile write attempt returns `MOBILE_WRITE_REJECTED` before the permission check runs.

## Cross-references

- `severity_enum` — severity × dismissal eligibility
- `issue_group_enum` — which actions apply to which groups
- `permission_matrix` — `REVIEW_*` surfaces consumed
- `review_resolution_action_payload_schema` — per-action JSON shape
- `resolution_action_payload_schema` — canonical per-action payload shapes (Block 14)
- `bulk_action_policies` — bulk eligibility
- `audit_log_policies` — `REVIEW_*` event naming
- `transactional_email_service_integration` — reassign notification dispatch
- `mobile_write_rejection_endpoints` — all 13 actions blocked on mobile
- Block 14 Phase 04 — resolution actions (architecture)
- Block 14 Phase 05 — bulk actions
- Block 14 Phase 06 — notes & assignment
