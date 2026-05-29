# Block 14 — Phase 08: Re-Scan on Resolution & Affected-Issues Scope

## References

- Block doc: `Docs/blocks/14_review_queue.md` (Re-Scan on Resolution)
- Block doc: `Docs/blocks/06_ai_layer.md` (Phase 11 — End-Scan engine; the source of "scan" semantics)
- Decisions log: `Docs/decisions_log.md` (re-scan on resolution: affected-issues only — never full re-scan)

## Phase Goal

Implement targeted re-scan on resolution: when a user resolves an issue, the End-Scan engine re-runs ONLY on the issues affected by the resolution — not a full re-scan of the entire period. "Affected" = any issue touching the same `transaction_id`, `document_id`, or `match_record_id` as the resolved item. After this phase, the queue stays current without reprocessing the whole period after every click, and gates re-evaluate cleanly on partial scope.

## Dependencies

- Phase 01 (`review_issues` schema)
- Phase 04 (resolution actions trigger this re-scan)
- Phase 05 (bulk actions trigger per-issue re-scans)
- Block 03 Phase 05 (gate re-evaluation framework)
- Block 03 Phase 06 (phase execution — the engine consumes the re-scan results)
- Block 06 Phase 11 (End-Scan engine — the source of scan logic; this phase tells End-Scan what scope to re-scan)

## Deliverables

- **Affected-issues scope rule (canonical):**
  - When a resolution closes (or modifies) `review_issues.id = X`, the affected-issues set is computed by:
    1. Take the `transaction_id` referenced by issue X (from `review_issues.transaction_id` or `card_payload_json.transaction_id`).
    2. Take the `document_id` referenced by issue X.
    3. Take the `match_record_id` referenced by issue X.
    4. Find every `OPEN` issue in the same `business_id` whose row references ANY of those three IDs.
    5. The affected set = `{X} ∪ {those issues}`.
  - **Cross-period scope:** the search is NOT restricted to the current period — affected issues from prior periods (still `OPEN`) are included. This handles the rare case where a cross-period adjustment resolves an old issue.
  - **Cross-block scope:** issues from any producing block (06/07/08/10/11/13) are included if they share the affected ID set. Re-scan is producer-agnostic.
- **Re-scan trigger API:**
  - `rescan.triggerForResolvedIssue({ resolved_issue_id, run_id }) → ReScanResult`
    - Called by Phase 04's resolution path automatically — every resolution action invokes this AFTER the resolution writes commit.
    - Returns `{ affected_issues: UUID[], rescanned: N, recreated: M, closed: K, severity_changes: [...], audit_events: [...] }`.
  - `rescan.triggerManually({ run_id, actor_user_id })` — invoked by Phase 04's `Re-run scan after change` resolution action; widens the scope to "all OPEN issues in the run" but still does NOT do a full upstream re-scan (it only re-evaluates already-raised issues; new issues come from Block 06 Phase 11's End-Scan engine running its own scoped pass).
- **Per-affected-issue re-evaluation logic** (Block 14-internal mechanism — no producing-block helper required):
  - For each affected issue, Block 14 reads the current state of the underlying entity by FK (`transactions`, `documents`, `match_records`, `draft_ledger_entries`) and applies a per-`issue_type` validity-check function declared in the registration registry (Phase 02). Each `registerIssueType` registration carries an optional `validity_check_fn_ref` — a Block 14-resident function that reads the underlying state and returns `{ still_valid, new_severity? }`. Producing blocks supply the function as part of their `issue_type` registration; if absent, the default check is "is the underlying entity's state still in the same range it was at issue creation?"
  - **Producing-block contribution:** at `issue_type` registration time, the producing block (or Block 14 on the producing block's behalf) supplies the validity-check function. This is not a runtime cross-block API; it's a registration-time function-pointer. Block 06/07/08/10/11/13 phase docs do not need new deliverables — Block 14's sub-doc enumerates the per-`issue_type` validity functions.
  - **Possible outcomes per affected issue:**
    - **Still valid, no change** → no-op; issue remains `OPEN`.
    - **Still valid, severity changed** → update `severity`; if elevated to `HIGH` / `BLOCKING` while snoozed, Phase 07's auto-clear fires.
    - **No longer valid** → close the issue with `status = AUTO_RESOLVED_BY_RESCAN` (a new status value distinct from `RESOLVED` / `DISMISSED` so audit can distinguish).
    - **New related issue surfaces** — the producing block's revalidation may discover a new issue (e.g., resolving a match by uploading a document might reveal the document is duplicate-suspicious; a new `dedup.possible_duplicate` issue is raised). Each new issue follows the standard creation path (Phase 03 generates card content; Phase 02 routes to bucket).
- **`status = AUTO_RESOLVED_BY_RESCAN`** (new status value):
  - Distinct from `RESOLVED` (which captures user-driven closure) and `DISMISSED` (which captures `Ignore with reason`).
  - Treated identically by gates (closed = not blocking).
  - Audit-logged with `auto_resolution_trigger_issue_id` (the issue whose resolution triggered this auto-close).
  - Sub-doc tracks the migration of Block 04 Phase 04's `status` enum to add this value.
- **Gate re-evaluation triggered after re-scan:**
  - Re-scan triggers a gate re-evaluation via Block 03 Phase 05's existing mechanism AFTER all affected issues are re-evaluated. The re-evaluation emits Block 03 Phase 05's standard events (`WORKFLOW_GATE_PASSED`, `WORKFLOW_GATE_HOLD`, `WORKFLOW_GATE_ROUTED_TO_SIDE_PHASE`); the run may transition out of `REVIEW_HOLD` / `AWAITING_APPROVAL` if the last blocker cleared.
  - **Idempotency:** a single resolution → one re-scan call → one gate re-evaluation event. Bulk resolutions (Phase 05) trigger per-issue re-scans, but the gate re-eval is debounced — Block 03 Phase 05's framework owns the debounce; sub-doc tracks the timing.
- **Validity-check registration (Block 14-internal):**
  - The per-`issue_type` validity-check function lives in Block 14's `issue_type_registry`. Each registration's `validity_check_fn_ref` points at a Block 14-resident function that reads the underlying state by FK and returns the validity result.
  - Producing blocks do NOT register helpers — they declare their `issue_type` and rely on Block 14's default "underlying-state-still-matches" check or supply a more specific check via their sub-doc-stage `registerIssueType` payload.
  - Default check (Stage 1): for each affected issue, query the underlying entity (e.g., `transactions.classification_status` for `classification.unknown_type`); if the state has changed in a way that invalidates the issue (e.g., `classification_status` no longer `UNKNOWN`), close as `AUTO_RESOLVED_BY_RESCAN`. Sub-doc owns the exhaustive per-`issue_type` validity rules.
- **Performance and recursion safety:**
  - The affected-set search is bounded — it follows the three IDs (transaction / document / match_record) one hop, not transitively. A resolution doesn't trigger a cascading re-scan of the entire run.
  - Re-validations that surface new issues do NOT trigger their own re-scan immediately (would be infinite); the new issues land normally and await the next user resolution.
  - Sub-doc owns performance benchmarks; Stage 1 budget: re-scan completes in under 5 seconds for a typical resolution affecting ≤ 20 related issues.
- **Failure handling:**
  - If a producing block's `revalidateIssue` fails (e.g., DB error), the affected issue is left `OPEN` unchanged; a `REVIEW_RESCAN_REVALIDATION_FAILED` audit event fires; a LOW review issue surfaces noting the partial re-scan. Other affected issues continue.
  - The resolving user's resolution succeeds regardless — re-scan failure does not roll back the resolution.
- **Manual `Re-run scan after change` resolution action** (Phase 04's vocabulary):
  - Invokes `rescan.triggerManually` with the current run scope.
  - Use case: rare; user knows multiple issues are stale and wants a sweep.
  - Audit-logged with `REVIEW_RESCAN_TRIGGERED_MANUALLY`.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `REVIEW_QUEUE`):
  - `REVIEW_RESCAN_TRIGGERED_AUTOMATICALLY` (per `rescan.triggerForResolvedIssue`)
  - `REVIEW_RESCAN_TRIGGERED_MANUALLY` (per `rescan.triggerManually`)
  - `REVIEW_RESCAN_AFFECTED_SET_COMPUTED` (with affected-issue IDs and counts)
  - `REVIEW_RESCAN_ISSUE_AUTO_RESOLVED` (per issue auto-closed)
  - `REVIEW_RESCAN_ISSUE_SEVERITY_CHANGED` (per issue with elevated/demoted severity)
  - `REVIEW_RESCAN_NEW_ISSUE_SURFACED` (per new issue raised)
  - `REVIEW_RESCAN_REVALIDATION_FAILED` (per producing-block failure)

## Definition of Done

- A user resolves a `matching.matched_needs_confirmation` issue → re-scan finds two related issues sharing the same `transaction_id` (a `Possible Tax/VAT Issue` and an `Unusual Transaction`) → both are re-validated; one auto-closes (no longer applicable post-confirm) → `gate.out.matching_complete` re-evaluates and advances if no other blockers.
- A bulk resolution of 50 issues triggers 50 per-issue re-scans; the gate re-evaluates once (debounced).
- A re-scan that surfaces a new `dedup.possible_duplicate` issue creates the new card with the right severity; the new issue does NOT trigger another re-scan immediately.
- A producing block's `revalidateIssue` failure does NOT roll back the user's resolution; the failure is audit-logged and a LOW issue surfaces.
- Manual `Re-run scan after change` triggers a wider re-scan; audit-logged.
- The `AUTO_RESOLVED_BY_RESCAN` status is distinct from user-resolved in audit and reports.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Affected-set computation SQL sub-doc** — exact query joining `review_issues` to `transactions` / `documents` / `match_records`.
- **Per-block `revalidateIssue` contract sub-doc** — function signature, expected behavior, idempotency.
- **`status` enum migration sub-doc** — adding `AUTO_RESOLVED_BY_RESCAN` to Block 04 Phase 04.
- **Gate-re-evaluation debounce sub-doc** — Block 03 Phase 05's debounce timing for bulk-resolution sequences.
- **Performance budget sub-doc** — re-scan latency under typical and adversarial conditions.
- **Recursion-safety sub-doc** — exact rule for "new issues from re-scan don't re-scan themselves"; edge cases.
