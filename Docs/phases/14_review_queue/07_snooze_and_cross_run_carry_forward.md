# Block 14 — Phase 07: Snooze + Cross-Run Carry-Forward

## References

- Block doc: `Docs/blocks/14_review_queue.md` (Issue Snooze)
- Block doc: `Docs/blocks/12_out_workflow.md` (Phase 07 — snoozed-issue carry-forward boundary)
- Block doc: `Docs/blocks/13_in_workflow_and_invoice_generator.md` (Phase 09 — same carry-forward semantics for IN side)
- Decisions log: `Docs/decisions_log.md` (snooze yes, with explicit reason; restricted to non-blocking issues; auto-reappear at start of next run)

## Phase Goal

Implement the snooze mechanism: non-blocking issues can be deferred to the next workflow run with a mandatory reason. Snoozed issues do NOT block the current run's finalization; they automatically reappear at the start of the next workflow run for the same business so they aren't forgotten. Restricted to `LOW` / `MEDIUM` severity per Stage 1. After this phase, the carry-forward contract Block 12 Phase 07 + Block 13 Phase 09 commit to is implemented.

## Dependencies

- Phase 01 (`review_issues` schema — `snoozed_at`, `snooze_reason`, `snoozed_by`, `snoozed_until`)
- Phase 02 (severity enum — `LOW` / `MEDIUM` snoozable; `HIGH` / `BLOCKING` not)
- Phase 04 (resolution actions — snooze is a separate action surface, not in the 13-action vocabulary; see "Action surface" below)
- Block 02 Phase 04 (permission matrix — snooze requires `REVIEW_QUEUE_RESOLVE`)
- Block 03 Phase 09 (trigger engine — at-next-run-start unsnooze hook)
- Block 12 Phase 07 (consumer — OUT side's `HUMAN_REVIEW_HOLD` honors carry-forward)
- Block 13 Phase 09 (consumer — IN side's `HUMAN_REVIEW_HOLD` honors carry-forward)

## Deliverables

- **Snooze action surface** (separate from Phase 04's 13-action vocabulary because it doesn't close the issue):
  - `snooze.apply({ issue_id, actor_user_id, snooze_reason }) → snooze_record`
    - Permission gate: `REVIEW_QUEUE_RESOLVE` (Phase 01).
    - **Severity restriction:** if `review_issues.severity ∈ {HIGH, BLOCKING}`, the call is rejected with `REVIEW_SNOOZE_REJECTED_SEVERITY`. Only `LOW` and `MEDIUM` issues snooze.
    - **Reason mandatory:** `snooze_reason` is non-empty; empty rejected with `REVIEW_SNOOZE_REJECTED_REASON_REQUIRED`.
    - Sets `status = SNOOZED` (per Block 04 Phase 04's canonical status enum), `snoozed_at = now()`, `snooze_reason`, `snoozed_by = actor_user_id`, `snoozed_until = NULL` (Stage 1 — `snoozed_until` is computed lazily at next-run-start; sub-doc tracks the eager-vs-lazy choice).
    - **`SNOOZED` is a distinct status** (not a closure; the issue is still actionable on unsnooze) — distinct from `RESOLVED` / `DISMISSED` / `AUTO_RESOLVED_BY_RESCAN`. The active-queue filter excludes `SNOOZED`; the snoozed-view sub-tab includes them.
    - Audit-logged.
  - `snooze.unsnooze({ issue_id, actor_user_id }) → unsnooze_record` — manual unsnooze before the auto-reappear; sets `status = OPEN`, clears `snoozed_at` / `snooze_reason` / `snoozed_by`; the issue reappears in the active queue immediately.
- **Active-queue filter (default view):**
  - The default review-queue view filters out rows where `status = SNOOZED` (the canonical filter — driven by Block 04 Phase 04's status enum).
  - The user can switch to a "Snoozed" view that shows the snoozed rows separately (sub-doc owns the UI; Stage 1 default — a sub-tab in the queue).
- **Cross-run carry-forward (the canonical contract Block 12 Phase 07 / Block 13 Phase 09 reference):**
  - At the start of every `OUT_MONTHLY` / `IN_MONTHLY` / `OUT_ADJUSTMENT` / `IN_ADJUSTMENT` run for a business, **before any phase executes**, an unsnooze pass runs:
    1. Query `review_issues WHERE business_id = $b AND status = 'SNOOZED'`.
    2. For each row, set `status = OPEN`; clear `snoozed_at` / `snooze_reason` / `snoozed_by` / `snoozed_until` (the unsnooze).
    3. Emit `REVIEW_UNSNOOZED` per row with payload `{ issue_id, was_snoozed_at, snooze_reason, unsnoozed_at, unsnoozed_by_run_id }`.
  - **Unsnooze pass anchor (durable cross-block contract):** the unsnooze pass runs as a registered tool `review_queue.unsnooze_at_run_start` invoked by the engine as the FIRST tool of the FIRST phase (`INGESTION` for `OUT_MONTHLY` / `IN_MONTHLY`; `ADJUSTMENT_INTAKE` for `OUT_ADJUSTMENT` / `IN_ADJUSTMENT`) of every run. The tool registers via Block 03 Phase 03's standard tool-registration mechanism with side-effect `WRITES_RUN_STATE` and AI tier `NONE`. The first-phase-first-tool placement guarantees execution before any phase-specific gate or work runs, without needing a special "pre-phase hook" in Block 03 Phase 06.
  - The unsnooze tool is idempotent — re-invocation for a run with no snoozed issues is a no-op.
  - **Once unsnoozed, the issue is back in the active queue** — it counts toward `gate.out.ai_end_scan_complete` / `gate.in.ai_end_scan_complete` if its severity is `HIGH` or `BLOCKING` (which can't happen for snoozed issues per the severity restriction; but if a re-evaluation post-unsnooze raised the severity, the issue would now block).
- **Severity-change-during-snooze handling:**
  - If a re-scan (Phase 08) elevates an issue's severity from `MEDIUM` to `HIGH` while snoozed, the snooze is **automatically cleared** (the issue can no longer be snoozed at that severity); `REVIEW_SNOOZE_AUTO_CLEARED_SEVERITY_ELEVATED` audit event fires; the issue reappears in the active queue immediately.
  - If a re-scan demotes severity, the snooze persists.
- **Period-finalization interaction:**
  - When a run reaches `FINALIZATION` (Block 15), snoozed `MEDIUM` issues are captured in the finalized archive's `review_issues` snapshot exactly as they stood (per Block 12 Phase 07's L5 fix): the snooze status, reason, and `snoozed_by` are part of the snapshot.
  - Snoozed issues remain in the operational DB (not deleted at finalization); the next run's unsnooze pass picks them up.
  - **Sub-doc tracks** what happens if a business is dormant for many months — accumulated snoozed issues from periods 6 months ago auto-reappear in the next run; sub-doc owns the "fresh-snooze-needed" UX.
- **Bulk-snooze:**
  - Phase 05's bulk-action mechanism does NOT include snooze in its 13-action vocabulary; bulk-snooze is a separate `bulk.snooze({ business_id, issue_ids, snooze_reason })` API with the same preview / confirmation pattern.
  - Per-issue severity check applies: any selected `HIGH` / `BLOCKING` issues are skipped with `REVIEW_SNOOZE_REJECTED_SEVERITY`.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `REVIEW_QUEUE`):
  - `REVIEW_SNOOZED` (per `snooze.apply`)
  - `REVIEW_UNSNOOZED` (per row unsnoozed at next-run-start OR per manual unsnooze)
  - `REVIEW_SNOOZE_AUTO_CLEARED_SEVERITY_ELEVATED` (when severity escalation auto-clears the snooze)
  - `REVIEW_SNOOZE_REJECTED_SEVERITY` / `REVIEW_SNOOZE_REJECTED_REASON_REQUIRED`
  - `REVIEW_BULK_SNOOZE_APPLIED` (bulk version)

## Definition of Done

- A user snoozes a `MEDIUM` issue with a mandatory reason → `REVIEW_SNOOZED` fires; the issue is hidden from the active queue.
- A user attempts to snooze a `HIGH` issue → rejected with `REVIEW_SNOOZE_REJECTED_SEVERITY`.
- A user attempts to snooze with empty reason → rejected with `REVIEW_SNOOZE_REJECTED_REASON_REQUIRED`.
- The user manually unsnoozes → the issue reappears in the active queue.
- The next workflow run starts → the unsnooze pass clears all snoozed issues for the business; each emits `REVIEW_UNSNOOZED` with the `unsnoozed_by_run_id`.
- A re-scan (Phase 08) elevates a snoozed `MEDIUM` to `HIGH` → snooze auto-clears → audit event fires.
- A run finalizes with snoozed `MEDIUM` issues → they're captured in the archive snapshot; the next run's unsnooze pass picks them up from the operational DB.
- A bulk-snooze succeeds for `LOW` / `MEDIUM` selected; skips `HIGH` / `BLOCKING`.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Lazy vs eager unsnooze sub-doc** — Stage 1 default is lazy (next-run-start); eager (timer-based) is Stage 2+.
- **Unsnooze pre-execution-hook integration sub-doc** — exact Block 03 Phase 06 hook point.
- **Snoozed-view UI sub-doc** — sub-tab layout, count badge, search.
- **Long-dormant-business sub-doc** — UX for "5 month-old snoozed issues just reappeared"; fresh-snooze workflow.
- **Severity-elevation auto-clear sub-doc** — exact rules across re-scan triggers (Phase 08).
- **Bulk-snooze API sub-doc** — symmetric with Phase 05's bulk-action mechanism; per-issue severity-check failure semantics.
