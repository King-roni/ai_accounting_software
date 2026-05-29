# Retry Policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2)

Binding rules governing tool invocation retry behaviour. Every tool invocation failure passes through this policy. The `engine.invoke_tool` wrapper owns retry orchestration; phase code and block code may not implement their own retry loops outside this policy. Violations are blocking code-review failures.

---

## Section 1 — Error class taxonomy

Every tool invocation failure is assigned exactly one error class. The error class determines whether the invocation is retried.

### Retryable error classes

| Error class | Description |
| --- | --- |
| `TRANSIENT_NETWORK` | TCP connection failure, DNS resolution failure, or other network-layer error with no response received |
| `RATE_LIMITED` | HTTP 429 or equivalent rate-limit response from an external service |
| `TIMEOUT` | Invocation exceeded the per-tool timeout threshold; no response received within the deadline |
| `SERVICE_UNAVAILABLE` | HTTP 503 or equivalent temporary-unavailability response from an external service |

A retryable error class means the failure is plausibly transient — retrying without any change to the input or the system is expected to eventually succeed.

### Non-retryable error classes

| Error class | Description |
| --- | --- |
| `VALIDATION_ERROR` | Tool input failed schema validation; retrying with the same input will produce the same failure |
| `PERMISSION_DENIED` | The invocation was rejected by an access-control check; the permission state is unlikely to change between retries |
| `DATA_INTEGRITY_ERROR` | The input references data that is missing, inconsistent, or in a state that violates a domain invariant |
| `UNKNOWN` | The error cannot be classified; treated as non-retryable to prevent unpredictable retry behaviour on unexpected failure modes |

Non-retryable error classes transition the tool invocation immediately to `FAILED` with no retries.

---

## Section 2 — Standard retry parameters

For tools in the retryable error classes, the engine applies bounded exponential backoff:

| Parameter | Value |
| --- | --- |
| Maximum retry attempts | 3 |
| Backoff base | 2 seconds |
| Backoff formula | `base * 2^(attempt - 1)` — attempt 1: 2s, attempt 2: 4s, attempt 3: 8s |
| Maximum backoff cap | 30 seconds (backoff is capped; formula produces at most 30s per attempt) |
| Jitter | ±10% uniform jitter applied to each backoff interval to prevent thundering herd |

Attempt counting starts at 1. After attempt 3 (the third retry, meaning four total invocation attempts), if the error persists, the invocation is marked `FAILED` and the phase failure path is triggered.

---

## Section 3 — AI tool retry parameters

Tools with AI tier `EXTERNAL` (invoking Anthropic Claude via the Block 06 gateway) have a **separate, tighter retry budget**:

| Parameter | Value |
| --- | --- |
| Maximum retry attempts | 2 |
| Backoff base | 5 seconds |
| Backoff formula | `base * 2^(attempt - 1)` — attempt 1: 5s, attempt 2: 10s |
| Maximum backoff cap | 30 seconds |

The reduced retry count for EXTERNAL-tier tools reflects the cost-per-token and latency profile of Anthropic API calls. Retrying an AI invocation three times with the same input provides diminishing marginal benefit while incurring material cost. After 2 retries (three total invocation attempts), the invocation is marked `FAILED`.

The error class taxonomy from Section 1 applies identically to AI tools — `RATE_LIMITED` and `TIMEOUT` are retryable; `VALIDATION_ERROR` and `PERMISSION_DENIED` are not.

---

## Section 4 — Retry state tracking

Retry state is tracked at two levels:

### Phase-level counter

`workflow_phase_states.retry_count` — incremented before each retry attempt. Bounded by the maximum attempt count for the tool's tier. The counter is never reset within a phase's lifetime; it accumulates across the full retry sequence for a phase.

### Per-invocation retry state

`tool_invocation_schema` rows record per-invocation state: `attempt_number`, `error_class`, `last_error_message`, and `status`. Each invocation attempt is a distinct row. On retry, a new `tool_invocations` row is inserted with `attempt_number` incremented; the prior row's `status` is set to `FAILED`.

The dedup-key check from `resumability_policy` runs before each retry attempt. If the tool's `idempotency_key` matches an existing `SUCCESS` row (prior attempt succeeded but the result was not propagated before a crash), the retry is short-circuited and the cached result is returned.

---

## Section 5 — Phase failure on retry exhaustion

When the maximum retry count is reached and the error persists:

1. The tool invocation row is marked `FAILED` with `error_class`, `attempt_number`, and `last_error_message` populated.
2. `workflow_phase_states.status` transitions to `FAILED`.
3. The run-level state transitions to `FAILED` via `workflow_state_enum`.
4. Audit event `WORKFLOW_TOOL_INVOCATION_RETRY_EXHAUSTED` (HIGH) is emitted.

The phase failure triggers review-issue creation in Block 14 with severity `HIGH` for standard phases, or `BLOCKING` for phases in the FINALIZATION path where progression is critical.

Non-retryable error classes bypass steps 1–2 of the retry loop entirely and transition directly to step 2 (phase `FAILED`) on the first invocation failure.

---

## Section 6 — Tool registration contract

Each tool registration via `engine.registerTool` declares its retry behaviour:

```ts
engine.registerTool({
  name: "matching.score_pair",
  // ...
  retry_policy: {
    retryable: true,
    max_attempts: 3,        // override default; omit to use policy default
    backoff_base_ms: 2000,
    backoff_max_ms: 30000,
  },
});
```

A tool may declare `retryable: false` to opt out of all retries (equivalent to `IDEMPOTENT_AT_MOST_ONCE` semantics per Block 03 Phase 08). This is reserved for tools that trigger irrevocable external actions. Any failure on a non-retryable-declared tool follows the non-retryable error class path regardless of the error class returned.

Tools that do not declare a `retry_policy` inherit the standard parameters from Section 2 (or Section 3 for `EXTERNAL` AI tier).

---

## Section 7 — Audit event

| Event | Trigger | Severity |
| --- | --- | --- |
| `WORKFLOW_WORKFLOW_TOOL_INVOCATION_RETRY_EXHAUSTED` | Final retry attempt fails; invocation marked FAILED | HIGH |

Payload includes: `workflow_run_id`, `phase_name`, `tool_name`, `error_class`, `attempt_count`, `last_error_message`, `business_id`. HIGH severity because retry exhaustion always surfaces a review issue and requires operator action to proceed or abort the run.

---

## Cross-references

- `tool_invocation_schema` — per-invocation retry state; `attempt_number`, `error_class`, `status` columns
- `workflow_phase_states_schema` — `retry_count` column; phase-level retry counter
- `resumability_policy` — dedup-key check that short-circuits retries for already-completed invocations
- `tool_naming_convention_policy` — tool registration shape; `retry_policy` declaration context
- `audit_event_taxonomy` — `WORKFLOW_TOOL_INVOCATION_RETRY_EXHAUSTED` (HIGH) catalogue entry
- `audit_log_policies` — `WORKFLOW_TOOL` domain naming convention, severity enum `{LOW, MEDIUM, HIGH, BLOCKING}`
- `Docs/phases/03_workflow_engine/08_failure_policy_and_retry.md` — owning phase (error classification, retry constants, failure paths)
- `Docs/phases/03_workflow_engine/06_phase_execution_engine.md` — `engine.invoke_tool` wrapper that owns retry orchestration
