# Block 06 — Phase 06: Tier 2 (Local LLM) Integration

## References

- Block doc: `Docs/blocks/06_ai_layer.md` (Tier 2 — Local LLM / Local AI)
- Decisions log: `Docs/decisions_log.md` (operator's dedicated machine for Tier 2; specific model deferred to AI sub-doc)

## Phase Goal

Implement the Tier 2 model integration: a typed request/response client that talks to a local LLM running on the operator's dedicated machine over a private channel. Every call dispatched only through the Privacy Gateway. The specific model and runtime are deferred to a Stage 4 sub-doc (we know the operator has hardware; the model choice is calibrated to it once the hardware specs are confirmed).

## Dependencies

- Phase 02 (gateway pipeline)
- Phase 04 (prompts resolved from the registry)
- Block 05 Phase 07 (network-access credentials fetched via `getSecret`)
- Block 05 Phase 01 (TLS + cert pinning on the private channel)

## Deliverables

- **Connection to operator hardware:**
  - Private channel between the hosted backend and the operator's machine. Default architecture: Tailscale, WireGuard, or an authenticated mTLS tunnel — exact choice deferred to the network-architecture sub-doc.
  - The channel is treated as outbound traffic with cert pinning per Block 05 Phase 01.
  - Connection credentials live in Phase 07 secrets manager.
- **Model serving interface:**
  - The local machine exposes an HTTP-or-gRPC endpoint with a typed request/response API (e.g., an Ollama-compatible or vLLM-compatible interface — final choice in sub-doc).
  - Backend speaks to it as `tier2.invoke(prompt, parameters) → ModelResponse`.
- **Health check:**
  - `GET /health` (or equivalent) on the local model endpoint, polled on a short cadence.
  - Failure raises `TIER_2_HEALTH_CHECK_FAILED` and trips the integration's circuit breaker — subsequent Tier 2 calls return `MODEL_ERROR` with `transient: true` until the breaker resets.
- **Request/response wiring:**
  - System + user prompt from the registry (Phase 04).
  - Structured JSON outputs preferred; the prompt's `meta.yaml` declares the expected output format.
- **Error mapping:**
  - Connection failure → `MODEL_ERROR` with `transient: true`.
  - Health-check breaker open → `MODEL_ERROR` with `transient: true`.
  - Schema-violation in the response → returned to the gateway, which surfaces `SCHEMA_VIOLATION_OUTPUT`.
- **Bypass-detection runtime guard** — same pattern as Phase 05.
- **Compute counting** — capture wall-clock latency and (where exposable) GPU-seconds for the cost estimator in Phase 07. Tier 2 cost is dominated by compute, not per-token billing.
- **Audit events:** `TIER_2_INVOKED`, `TIER_2_RESPONSE_RECEIVED`, `TIER_2_FAILED`, `TIER_2_HEALTH_CHECK_FAILED`, `TIER_2_CIRCUIT_BREAKER_OPENED`, `TIER_2_BYPASS_ATTEMPT_BLOCKED`.

## Definition of Done

- A Tier 2 call dispatched through the gateway reaches the operator's machine and returns a validated typed response.
- The private channel is established and verified at startup; failures surface clearly.
- Health check polls and the circuit breaker work as expected (verified by simulating an outage).
- Latency is captured on every call.
- Direct calls to the local endpoint outside the gateway are rejected at runtime.

## Sub-doc Hooks (Stage 4)

- **Network architecture sub-doc** — final choice of private-channel technology, IP ranges, failover, monitoring.
- **Local model selection sub-doc** — model family, size, runtime (Ollama, vLLM, llama.cpp), once the operator's hardware specs are confirmed.
- **Health check & circuit breaker sub-doc** — poll cadence, breaker thresholds, recovery.
- **Compute-count to cost mapping sub-doc** — Tier 2 cost model (electricity + amortised hardware), how it surfaces in the cost ceiling alongside Tier 3 token costs.
- **Bypass-detection guard sub-doc** — same shape as Phase 05's.
