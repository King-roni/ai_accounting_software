# ai_response_recording_fixtures

**Category:** Fixtures · **Owning block:** 07 — Bank Statement Pipeline · **Co-owners:** 08, 09, 10, 11, 13 · **Stage:** 4 sub-doc (Layer 1 cross-block fixture spec)

The recording/replay mechanism for AI provider calls in test fixtures. Per `live_integration_test_runbook`: most CI runs replay recorded responses for determinism + cost. Live runs (scheduled / manual) re-record.

This spec pins the recording file shape, the replay matcher, the drift detection mechanism, and the rotation cadence.

---

## File location

Recordings live alongside their fixtures:

```
fixtures/
  classification/
    typical_50_transactions.fixture.ts
    typical_50_transactions.ai_recordings.json   <- canonical AI response file
```

One recordings file per fixture; carries all AI calls the fixture triggers.

## Recording file shape

```json
[
  {
    "recording_index": 0,
    "recorded_at": "2026-01-15T09:00:00Z",
    "integration": "anthropic_claude_eu",
    "tier": "EXTERNAL",
    "prompt_name": "classification.tier_3_classifier",
    "prompt_version": "2.1.0",
    "request": {
      "endpoint": "https://api.anthropic.com/v1/messages",
      "method": "POST",
      "headers_redacted": {
        "x-api-key": "<redacted>",
        "anthropic-version": "2023-06-01"
      },
      "body_canonical_json_hash": "abc123...",
      "body_canonical_json": {
        "model": "claude-3-5-sonnet-20241022",
        "max_tokens": 1024,
        "messages": [...]
      }
    },
    "response": {
      "status": 200,
      "headers_redacted": {
        "content-type": "application/json",
        "request-id": "req_..."
      },
      "body_canonical_json": {
        "id": "msg_...",
        "type": "message",
        "role": "assistant",
        "content": [{...}],
        "model": "claude-3-5-sonnet-20241022",
        "usage": { "input_tokens": 234, "output_tokens": 87 }
      }
    },
    "latency_ms": 1842
  },
  {
    "recording_index": 1,
    "integration": "google_document_ai",
    ...
  }
]
```

Per `redaction_policies`: sensitive headers (API keys, auth tokens) are stored as `<redacted>` placeholder. The recording is checked into git.

Per `data_layer_conventions_policy`: bodies are canonical JSON. The `body_canonical_json_hash` is the SHA-256 hex of the canonical JSON.

## Replay matcher

When the fixture runs in replay mode, the test harness intercepts each AI call:

```
1. Compute request_canonical_json_hash from the actual outgoing request
2. Find the matching recording entry by (integration, prompt_name, prompt_version, body_canonical_json_hash)
3. Return the recorded response body
4. Verify the actual latency is within fixture_performance_budget for that call
```

Matching rules:

- **Exact match** — `body_canonical_json_hash` equals recorded value → return recorded response
- **Fuzzy match (Stage 2+ feature)** — small request differences (e.g., random IDs in the prompt) may be ignored if explicitly marked; not in MVP
- **No match** — test fails with `INTEGRATION_REPLAY_NO_MATCH`; developer must re-record

## Drift detection

When the fixture is rerun in **live mode** (`--record-live`), the harness compares the new response against the recorded one:

| Comparison | Behavior |
| --- | --- |
| Response body bytes equal | No drift; recording unchanged |
| Response body bytes differ but semantically equivalent (per per-fixture acceptance rules) | Update recording with the new bytes; warn |
| Response body bytes differ significantly | Test fails; developer reviews; accepts (re-records) or investigates upstream change |

Semantic-equivalence rules are per-fixture; the default is "bytes equal". Some fixtures opt-in to looser rules (e.g., a fixture testing prompt structure may accept any well-formed model output that satisfies the prompt's output_schema).

## Cost containment

Per `live_integration_test_runbook` budget cap:

- Default monthly cap: $50 across all live runs
- Per-fixture cost is tracked in the recording's `latency_ms` proxy (heavier calls cost more)
- Exceeding the cap halts live runs; CI runs (replay-mode) are unaffected

## Recording rotation

Per `live_integration_test_runbook`:

- Fixtures with recordings older than 90 days: regenerated quarterly
- Fixtures with no live-run invocations in 180 days: candidate for retirement
- Drift reports flag stale recordings for review

## Per-integration variants

| Integration | Recording specifics |
| --- | --- |
| Anthropic Claude EU | Full message history; usage tokens; model ID |
| Google Document AI | Full extracted content; per-field confidence scores |
| RFC 3161 TSA | Timestamp token + cert chain |
| ECB API | Per-date rates |

Each integration's recording shape conforms to the standard schema above with integration-specific fields under `response.body_canonical_json`.

## Privacy

Per `redaction_policies`: the recording captures what the AI saw — which is already redacted at the gateway layer per `redaction_at_write_policy`. The recording itself contains no additional PII.

Per Stage 1 EU residency: recordings are stored in the EU-resident git repo. No external storage. No replication outside EU.

## Test-mode flag

The test harness sets `app.test_mode_active = 'true'` when replay mode is in effect. Per `gateway_bypass_detection_policy`: the runtime guard is aware of test mode and allows the replay layer to bypass the gateway (the replay layer IS the gateway in test).

In production: `app.test_mode_active` is never set; the gateway bypass guard is active normally.

## Audit events

Within replay mode, fixture-level events fire normally but the AI-specific events are tagged with `test_mode = true`:

```ts
emitAudit("AI_GATEWAY_INVOKED", {
  ...payload,
  test_mode: true                                  // present only in replay
});
```

This lets test-output audit consumers distinguish recorded from live behavior.

## Cross-references

- `fixture_format_spec` — base fixture file shape
- `redaction_policies` — pre-recording PII handling
- `gateway_bypass_detection_policy` — test-mode interaction
- `live_integration_test_runbook` — recording/replay procedure
- `fixture_performance_budget` — latency budget tracking
- `data_layer_conventions_policy` — canonical JSON for bodies
- `google_document_ai_integration` — primary recorded integration
- `anthropic_claude_integration` (deferred Stage 4) — second primary
- `audit_log_policies` — `AI_*` event family
- Block 07 Phase 10 — canonical first fixture host
- Block 06 Phase 02 — gateway pipeline
