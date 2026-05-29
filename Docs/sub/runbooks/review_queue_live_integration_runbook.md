# Review Queue Live Integration Runbook

**Category:** Runbooks · **Owning block:** 14 — Review Queue · **Block reference:** Block 14 § all phases · **Stage:** 4 sub-doc (Layer 2 runbook)

**Purpose:** Defines the live integration test cadence, fixture specification, test steps, and acceptance criteria for the Review Queue. This runbook verifies issue group routing, snooze behaviour, rescan-on-resolution, carry-forward state, and bulk-action preview token lifecycle. Tests run against the live engine; no mocks.

---

## Cadence

Run this test suite at two trigger points:

1. **Before each production deploy.** The deploy pipeline blocks on failure.
2. **Weekly, every Monday at 07:00 UTC.** Runs unattended. Failure emits `LIVE_TEST_DRIFT_DETECTED` and pages on-call.

---

## Fixture set: `REVIEW_QUEUE_INTEGRATION_FIXTURE_V1`

Eight canonical issues, one per issue group from `full_issue_type_to_group_routing_table.md`, plus two additional issues for snooze and escalation testing. All fixture issues belong to a dedicated test `workflow_run_id` on the fixture `business_id`.

### Primary fixture issues (8 — one per group)

| Fixture ID | Issue type | Expected group | Default severity |
| --- | --- | --- | --- |
| `rq_fix_01` | `STATEMENT_PARSE_ERROR` | `DATA_QUALITY` | HIGH |
| `rq_fix_02` | `CLASSIFICATION_CONFIDENCE_LOW` | `CLASSIFICATION_REVIEW` | MEDIUM |
| `rq_fix_03` | `DOCUMENT_OCR_CONFIDENCE_LOW` | `DOCUMENT_REVIEW` | MEDIUM |
| `rq_fix_04` | `MATCH_PROBABLE_UNCONFIRMED` | `MATCHING_REVIEW` | MEDIUM |
| `rq_fix_05` | `VAT_TREATMENT_UNCERTAIN` | `TAX_REVIEW` | HIGH |
| `rq_fix_06` | `TRANSACTION_EXCEPTION_DOCUMENTED` | `EXCEPTION_REVIEW` | LOW |
| `rq_fix_07` | `OUT_MANUAL_HOLD_ACTIVE` | `WORKFLOW_HOLD` | HIGH |
| `rq_fix_08` | `INVOICE_AMENDMENT_REQUIRED` | `INVOICE_REVIEW` | HIGH |

### Snooze test issues (2 additional)

| Fixture ID | Issue type | Group | Snooze state |
| --- | --- | --- | --- |
| `rq_fix_snoozed_a` | `CLASSIFICATION_CONFIDENCE_LOW` | `CLASSIFICATION_REVIEW` | `snoozed_until = now() + INTERVAL '7 days'` |
| `rq_fix_snoozed_b` | `CLASSIFICATION_CONFIDENCE_LOW` | `CLASSIFICATION_REVIEW` | `carry_forward_count = 2` (not snoozed; used for escalation testing) |

`rq_fix_snoozed_a` must be hidden from the default queue view during the test. `rq_fix_snoozed_b` has been carried forward twice and must trigger the escalation path when the next carry-forward threshold is evaluated.

### Carried-forward issue (1 — overlaps with primary set)

`rq_fix_04` (`MATCH_PROBABLE_UNCONFIRMED`) is seeded with `carried_forward_from_run_id` pointing to a prior fixture run ID. This tests the carry-forward linkage assertion in Step 5.

---

## Test steps

**Step 1 — Seed fixture issues**

Insert all 10 fixture issues via `review_queue.seed_fixture_issues` (test-infrastructure path, not a production tool). Assert:
- All 10 rows exist in `review_issues` with `status = OPEN`.
- `REVIEW_ISSUE_CREATED` is emitted for each.
- The fixture run's `workflow_run_id` is set on all rows.

**Step 2 — Assert each issue routes to the correct `issue_group`**

For each of the 8 primary fixture issues, query `review_issues.issue_group`. Assert each matches the expected group from the table above. The routing is determined at insert time by `review_queue.registerIssueType`; this step confirms the routing table in `full_issue_type_to_group_routing_table.md` is correctly reflected in the live registry.

No additional action is needed — routing is not a runtime computation. A mismatch here indicates a registry misconfiguration, not a logic error in the test.

**Step 3 — Snooze 2 issues and assert they are hidden from the default queue view**

Call `review_queue.snooze_issue` for `rq_fix_snoozed_a` with `snoozed_until = now() + INTERVAL '7 days'`. Assert:
- `REVIEW_QUEUE_ISSUE_SNOOZED` is emitted with `snooze_count = 1` (or the actual count for this fixture issue).
- `rq_fix_snoozed_a.status` reflects the snoozed state.
- Query the default queue view (the view that excludes snoozed issues). Assert `rq_fix_snoozed_a` does not appear.
- Assert all 8 primary fixture issues remain visible in the default queue view.

Also confirm `rq_fix_snoozed_b` is visible in the default queue view (it is not snoozed; carry-forward count does not affect default visibility).

**Step 4 — Resolve 1 issue and assert rescan triggers and completes**

Resolve `rq_fix_04` (`MATCH_PROBABLE_UNCONFIRMED`) via `review_queue.resolve_issue` with `resolution_kind = AUTO_RESOLVED`. Assert:
- `REVIEW_ISSUE_RESOLVED` is emitted.
- `review_queue.schedule_rescan` is called automatically by the resolution handler.
- `REVIEW_QUEUE_RESCAN_TRIGGERED` is emitted with `trigger_issue_id = rq_fix_04.id`.
- `REVIEW_QUEUE_RESCAN_COMPLETED` is emitted after the rescan pass.
- `rescan_depth` on the `REVIEW_QUEUE_RESCAN_TRIGGERED` event is `1`. For this fixture, no further rescan recursion should occur (the dependent issues in the fixture are not configured to cascade).
- Assert `REVIEW_QUEUE_RESCAN_DEPTH_EXCEEDED` is **not** emitted.

**Step 5 — Assert carried-forward issue has `carried_forward_from_run_id` set**

Query `rq_fix_04` (resolved in Step 4) and assert:
- `carried_forward_from_run_id` is set to the prior fixture run ID seeded in the fixture.
- The prior fixture run ID is a valid UUID v7 placeholder (not null, not the current run ID).

Also verify that `rq_fix_snoozed_b.carry_forward_count = 2` as seeded. Do not trigger the escalation path in this step — just assert the value. (Escalation testing is out of scope for this runbook's acceptance criteria; `rq_fix_snoozed_b` is a passive fixture for development seed data.)

**Step 6 — Assert bulk-action preview token is issued and consumed correctly**

Call `review_queue.preview_bulk_action` for issue type `OUT_MANUAL_HOLD_ACTIVE` (covering `rq_fix_07`). Assert:
- A `bulk_preview_tokens` row is created.
- `REVIEW_QUEUE_BULK_PREVIEW_TOKEN_ISSUED` is emitted. The payload's `token_id` is the PK of the `bulk_preview_tokens` row (UUID v7), not the secret token value.
- The token's `expires_at` is within 15 minutes of now: `expires_at <= now() + INTERVAL '15 minutes'`.

Consume the token via `review_queue.execute_bulk_action` with the token. Assert:
- `REVIEW_BULK_ACTION_APPLIED` is emitted.
- The `bulk_preview_tokens` row is marked consumed (`consumed_at` is set).
- Attempting to consume the same token again returns a `TOKEN_ALREADY_CONSUMED` error and emits no second `REVIEW_BULK_ACTION_APPLIED` event.

---

## Acceptance criteria

The test suite passes when all of the following are true:

1. All 8 issue groups are correctly routed — no routing mismatch across all 8 primary fixture issues.
2. `rq_fix_snoozed_a` is hidden from the default queue view after snooze is applied.
3. Rescan after resolving `rq_fix_04` completes with `rescan_depth = 1`. `REVIEW_QUEUE_RESCAN_DEPTH_EXCEEDED` is not emitted.
4. `rq_fix_04.carried_forward_from_run_id` is set to the expected prior run ID.
5. Bulk-action preview token `expires_at` is within 15 minutes of issue time, verified at assertion time.
6. The preview token is not reusable after consumption.
7. No `LIVE_TEST_DRIFT_DETECTED` event is emitted.

---

## Fixture teardown

After each run (pass or fail):

- Mark all fixture issues as `RESOLVED` or delete them via the test-infrastructure teardown path.
- Emit `LIVE_TEST_RUN_COMPLETED` (or failure equivalent).
- The fixture business `business_id` is dedicated to testing and does not share state with production data.
- Snoozed issues are not automatically un-snoozed by teardown; the dedicated fixture business reset handles the state reset.

---

## Failure response

| Failure type | Response |
| --- | --- |
| Routing mismatch on any group | Log the issue type, expected group, actual group. Halt test. Check `full_issue_type_to_group_routing_table.md` and the live `issue_type_registry`. |
| Snoozed issue appears in default view | Log the queue query result and the `snoozed_until` value. Fail the step. |
| Rescan depth exceeds 1 | Log `REVIEW_QUEUE_RESCAN_DEPTH_EXCEEDED` payload. Fail the test. |
| Token reuse succeeds | Indicates idempotency guard is broken. Fail immediately and file a security-priority bug. |

---

## Cross-references

- `full_issue_type_to_group_routing_table.md` — canonical issue type → group mapping, default severities
- `review_queue_rescan_on_resolution_policy.md` — rescan trigger rules, depth limit, recursion guard
- `snooze_carry_forward_policy.md` — snooze expiry rules, carry-forward mechanics, escalation thresholds
- `live_integration_test_runbook.md` — shared live integration test infrastructure
- `audit_event_taxonomy` — `REVIEW_ISSUE_CREATED`, `REVIEW_QUEUE_ISSUE_SNOOZED`, `REVIEW_ISSUE_RESOLVED`, `REVIEW_QUEUE_RESCAN_TRIGGERED`, `REVIEW_QUEUE_RESCAN_COMPLETED`, `REVIEW_QUEUE_BULK_PREVIEW_TOKEN_ISSUED`, `REVIEW_BULK_ACTION_APPLIED`
- `review_queue_per_fixture_content.md` — per-issue fixture corpus used by this runbook
- `issue_escalation_policy.md` — escalation thresholds for carry-forward issues
