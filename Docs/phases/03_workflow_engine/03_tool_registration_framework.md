# Block 03 — Phase 03: Tool Registration Framework

## References

- Block doc: `Docs/blocks/03_workflow_engine.md` (Tool Registration section)
- Block doc: `Docs/blocks/06_ai_layer.md` (AI tier classification)
- Decisions log: `Docs/decisions_log.md` (gates as registered functions per phase; AI tiers 1/2/3)

## Phase Goal

Build the contract through which every domain block (06–13) exposes its tools to the engine. A tool is a callable that the engine invokes inside a phase; the registration declares everything the engine needs to know to call it safely, validate its inputs and outputs, and enforce the phase-level side-effect contract.

## Dependencies

- Phase 01 (schema; tool invocations are persisted)
- Phase 02 (workflow types reference tools by name in their phase definitions)

## Deliverables

- **Tool registration API** — `engine.registerTool(declaration)` callable at startup by Blocks 06–13.
- **Tool declaration schema:**
  - `name` — namespaced, e.g. `bank_pipeline.parse_csv`, `matching.score_pair`, `ai.classify_transaction`.
  - `version` — semantic version of the tool's contract.
  - `input_schema` — typed schema (JSON Schema or equivalent) for input payload.
  - `output_schema` — typed schema for output payload.
  - `side_effect` — `READ_ONLY`, `WRITES_RUN_STATE`, or `CALLS_EXTERNAL_API`.
  - `ai_tier` — `NONE`, `LOCAL_LLM`, or `EXTERNAL_LLM` (Tier 1, 2, 3 from Block 06).
  - `failure_semantics` — `RETRYABLE`, `FATAL_ON_FIRST_FAIL`, or `IDEMPOTENT_AT_MOST_ONCE`.
  - `dedup_key_generator` — pure function `(input) → string` used by the resumability layer (Phase 07).
- **Phase-level expectation contract** — each phase declaration in the workflow type registry lists the tools it expects to invoke and the side-effect class it permits. The engine refuses to invoke a tool whose declared side-effect exceeds what the phase permits.
- **Schema validation** — at registration time, the engine compiles the input/output schemas and rejects malformed declarations. At invocation time, it validates the input against the schema before calling the tool, and validates the output against the schema before returning the result.
- **Tool invocation API** — `engine.invokeTool(phase_state, tool_name, input)` is the only way a phase invokes a tool. Direct calls into Blocks 06–13 from phase code are forbidden.
- **Registration audit:** `TOOL_REGISTRY_REGISTERED`, `TOOL_REGISTRY_REJECTED` events (startup-time, captured for ops visibility). The `TOOL_REGISTRY_*` prefix distinguishes startup-time registration events from runtime `WORKFLOW_TOOL_*` events emitted by Phases 06–08.

## Definition of Done

- Every tool a workflow phase needs is registered at engine startup.
- A phase declaration that references an unregistered tool fails at startup with a structured error.
- A tool whose side-effect exceeds its phase's permitted class is refused at invocation.
- Input that doesn't match the input schema fails before the tool is called.
- Output that doesn't match the output schema is treated as a tool failure.
- A test suite covers: valid registration, malformed registration, mismatched side-effect, schema violation on input, schema violation on output.

## Sub-doc Hooks (Stage 4)

- **Tool naming convention sub-doc** — namespace rules, casing, version bumps.
- **Schema definition sub-doc** — choice of schema language (JSON Schema), shared type fragments, versioning strategy.
- **Side-effect taxonomy sub-doc** — exact definitions of the three classes; tests for each.
- **Tool registration API sub-doc** — function signature, error shapes, lifecycle (register-only-at-startup vs hot reload — MVP is startup-only).
- **AI-tier metadata sub-doc** — how a tool's declared `ai_tier` propagates to Block 06's tier-routing decision and to Stage 1's per-run soft cost-ceiling enforcement. Cross-block link to Block 06's Privacy Gateway.
