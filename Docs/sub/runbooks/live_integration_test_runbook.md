# live_integration_test_runbook

**Category:** Runbooks · **Owning block:** 07 — Bank Statement Pipeline · **Co-owners:** 08, 09, 10, 11, 13 · **Stage:** 4 sub-doc (Layer 1 cross-block runbook)

The procedure for running tests against live external integrations — Document AI, Anthropic Claude EU, RFC 3161 TSA, ECB API. Most test runs use recorded fixtures per `ai_response_recording_fixtures` for determinism and cost containment; live runs happen periodically to verify the recordings still reflect the live API's behavior.

Used across six blocks that touch external integrations. The runbook is shared because the pattern is identical across them.

---

## When to run live tests

| Cadence | Trigger | Scope |
| --- | --- | --- |
| **Weekly** | Scheduled CI job | A small representative subset (1-2 fixtures per integration); cost-bounded |
| **Pre-deploy** | Before any production release | Re-record any fixtures touched by the release |
| **Post-incident** | After a third-party API change is reported | Re-record affected fixtures + verify regression |
| **Manual** | Engineering investigation | As needed; cost-tracked |

Default CI runs against fixtures only (no live API calls). Live mode is opt-in via `--live` flag or scheduled job.

## Recording procedure

```bash
# Enable live mode
export TEST_LIVE_MODE=true
export TEST_RECORD_TO=ai_response_recording_fixtures/<integration>/<scenario>

# Run the specific fixture
pnpm test fixtures/intake/ocr_invoice_typical.fixture.ts --live --record
```

The recording wraps every request and response pair from the live API:

```json
{
  "recorded_at": "2026-01-15T09:00:00Z",
  "integration": "google_document_ai",
  "fixture_scope": "intake.ocr_invoice_typical",
  "request": {
    "endpoint": "https://eu-documentai.googleapis.com/v1/projects/.../processors/.../:process",
    "method": "POST",
    "headers_redacted": {...},
    "body_sha256": "..."             // body hash; body content stored separately
  },
  "response": {
    "status": 200,
    "headers_redacted": {...},
    "body_canonical_json": {...}     // full response body, canonicalized
  },
  "latency_ms": 4523
}
```

Per `redaction_policies`: PII in request bodies is redacted before recording (recordings live in git; PII would leak through code review). Document bytes that are themselves the test fixture's input file are not duplicated in the recording — the recording references the input fixture file's hash.

## Replay procedure

Default CI runs without `TEST_LIVE_MODE`:

```bash
pnpm test
```

The test runner intercepts integration calls. For each call:

1. Compute the request canonical hash
2. Look up the matching recorded fixture
3. Return the recorded response
4. Verify latency stays within `fixture_performance_budget` for that fixture

If no fixture matches: test fails with `INTEGRATION_REPLAY_NO_MATCH` and prompts the developer to re-record.

If the live response in `TEST_LIVE_MODE` differs from the recorded fixture: test fails with `LIVE_TEST_DRIFT_DETECTED` — the developer must either accept the new response (re-record) or investigate the unexpected change.

## Drift detection

Per `fixture_format_spec`: every replay run records the matched/unmatched outcomes. Aggregate drift reports surface:

- Integrations whose recorded fixtures haven't been refreshed in > 90 days
- Fixtures with frequent drift (suggesting upstream API instability)
- Fixtures with no recent invocations (potentially obsolete)

Operator runs the drift report periodically:

```bash
pnpm fixture:drift-report
```

Output is JSON; non-zero drift counts above the threshold (typically 5%) trigger operator action.

## Cost containment

| Integration | Per-fixture cost | Live cadence cost (weekly) |
| --- | --- | --- |
| Google Document AI | ~$0.02-0.05 per fixture | < $5/month |
| Anthropic Claude EU | ~$0.01-0.10 per fixture | < $20/month |
| RFC 3161 TSA | ~$0.001-0.005 per fixture | negligible |
| ECB API | Free | $0 |

Default budget for live mode: $50/month. Per-integration budget caps are configurable. Exceeding the budget halts live runs and emits `LIVE_TEST_BUDGET_EXCEEDED` (operator alert).

## Recording rotation

Per `ai_response_recording_fixtures` recommendations:

- Fixtures touched in the last 30 days: kept fresh via weekly live runs
- Fixtures older than 90 days: regenerated quarterly
- Fixtures older than 180 days without invocation: candidate for retirement

Retirement requires verifying no test still references the fixture. Per-block fixture inventories are tracked in `cross_block_fixture_stitching`.

## Failure recovery

| Failure | Behavior |
| --- | --- |
| Live API unreachable | Test fails with `LIVE_API_UNREACHABLE`; retry once after 30s; fall back to fixture replay with `--skip-live-on-failure` |
| Live API returns 401 (auth) | Operator escalation — credential rotation per `key_rotation_runbook` |
| Live API returns 5xx persistently | Defer the affected fixture's live run; record incident; resume on next cadence |
| Drift detected | Developer investigates; decide accept-and-rerecord vs investigate-upstream-change |

## Audit events

| Event | When |
| --- | --- |
| `LIVE_TEST_RUN_STARTED` | Live mode activated |
| `LIVE_TEST_RUN_COMPLETED` | Live run finished successfully |
| `LIVE_TEST_BUDGET_EXCEEDED` | Cost cap hit |
| `LIVE_TEST_DRIFT_DETECTED` | Recorded vs live response divergence |
| `INTEGRATION_REPLAY_NO_MATCH` | Replay couldn't find matching fixture |

These events live in the audit log under a `LIVE_TEST` domain — distinct from operational integration events.

## Cross-references

- `ai_response_recording_fixtures` — recording format
- `fixture_format_spec` — overall fixture file shape
- `fixture_performance_budget` — latency targets
- `cross_block_fixture_stitching` — fixture inventory
- `google_document_ai_integration` — primary live target
- `rfc_3161_timestamp_integration` — secondary live target
- `redaction_policies` — PII redaction before recording
- `key_rotation_runbook` — credential rotation
- Block 07 Phase 10 — end-to-end pipeline tests (canonical fixture host)
- Per-block Phase 10 / 11 / 12 — end-to-end test surfaces
