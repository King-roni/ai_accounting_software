# Tool Registration Framework

**Category:** Reference · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2)

How tools self-register in the system and how the gateway discovers and validates them at runtime.
Every tool author binds to this document alongside `tool_naming_convention_policy.md`. The gateway
enforces the constraints described here; a tool that fails registration causes a fatal boot error.

---

## Section 1 — Registration contract

Every tool must declare the following fields in its registration call. All fields are required;
missing fields cause a boot-time fatal error.

| Field | Type | Constraint |
| --- | --- | --- |
| `name` | string | `namespace.action` format per `tool_naming_convention_policy.md`; namespace in the 14-namespace allowlist |
| `version` | string | Semver `major.minor` format — matches `^\d+\.\d+$` |
| `side_effect_class` | string[] | One or more values from the closed enum in `tool_naming_convention_policy.md` |
| `input_schema` | JSON Schema object | Must be a valid JSON Schema draft-07 object |
| `output_schema` | JSON Schema object | Must be a valid JSON Schema draft-07 object |
| `idempotency_strategy` | enum | One of: `KEYED`, `NON_IDEMPOTENT`, `PURE` |
| `ai_tier_required` | enum \| null | One of: `TIER_1`, `TIER_2`, `TIER_3`, `null` |
| `audit_events` | string[] | All audit event names this tool may emit; each must be in `audit_event_taxonomy.md` |
| `description_ref` | string | Absolute path to the tool's sub-doc in `Docs/sub/tools/` |

### idempotency_strategy values

| Value | Meaning |
| --- | --- |
| `KEYED` | Tool is idempotent under the `caller_idempotency_key` deduplication mechanism |
| `NON_IDEMPOTENT` | Tool produces side effects that cannot be deduplicated — AI calls, external API writes |
| `PURE` | Tool produces no side effects; output is deterministic for a given input |

`PURE` tools are also `READ_ONLY` by definition; the gateway does not write a `tool_invocations`
row for `PURE` calls, reducing write amplification on hot read paths.

---

## Section 2 — Registration mechanism

Tools register via `engine.register_tool` at service startup. The registration API is defined in
`tool_registration_api.md`. The call is synchronous and blocking — the service does not accept
workflow traffic until all tools have registered successfully.

The `gateway_bypass_detection_policy.md` enforces that no tool invocation reaches business logic
without passing through the gateway. The gateway is the only code path that resolves a tool name
to its implementation and validates the registration contract. Any invocation that bypasses the
gateway — including direct function calls in tests that lack gateway wrapping — emits
`SECURITY_GATEWAY_BYPASS_DETECTED` (HIGH) if detected at runtime, or fails a lint check if
detected statically.

Name collisions at boot are fatal. If two tool registrations supply the same `name`, the engine
refuses to start and logs both registrations for debugging. This is intentional — ambiguous tool
resolution at runtime would be a correctness failure, not just a configuration error.

---

## Section 3 — Version pinning

Workflow run configurations pin tool versions at the time the run is created. A run created with
tool `matching.score_pair` at version `1.2` uses version `1.2` for the full lifetime of that run,
regardless of subsequent deployments.

Version pinning is stored in the `workflow_run_configs` table as a `tool_versions` JSONB column
mapping tool names to their pinned version. The gateway resolves the pinned version on each tool
invocation within the run.

If the pinned version is no longer deployed (for example, it was removed after the deprecation
window), the gateway returns a `TOOL_VERSION_NOT_FOUND` error and transitions the run to `FAILED`.
Operator intervention is required to update the run config and resume with a compatible version.

---

## Section 4 — Deprecation

A tool is deprecated by setting `deprecated_at` on its registration record. Deprecation has two
phases:

### Phase 1 — Soft deprecation (deprecated_at set, grace period active)

- The gateway permits invocations from in-flight runs that were created before `deprecated_at`.
- The gateway rejects tool invocations for new runs.
- A `WORKFLOW_TOOL_REGISTRATION_DEPRECATED` audit event is emitted when `deprecated_at` is set.
- The grace period is one full workflow-run cycle: 30 days by default.

### Phase 2 — Hard removal (after grace period)

- The tool implementation and registration are removed from the codebase.
- In-flight runs that still reference the deprecated version are blocked — see the version pinning
  failure path in Section 3.
- The tool's sub-doc in `Docs/sub/tools/` is archived, not deleted.

---

## Section 5 — Tool metadata storage

Every tool invocation is recorded in the `tool_invocations` table per `tool_invocation_schema.md`.
The stored fields include:

- `tool_name` — the registered `namespace.action` name
- `tool_version` — the version resolved for this invocation
- `caller_idempotency_key` — the key computed by the engine per `resumability_and_idempotency.md`
- `invocation_status` — `RUNNING`, `SUCCEEDED`, `FAILED`
- `output_payload` — the tool's output, stored for cache hits
- `started_at`, `completed_at` — timing for observability

For `PURE` tools, no row is written. For `NON_IDEMPOTENT` tools, a row is written but
`caller_idempotency_key` is not used for deduplication — it is stored for audit traceability only.

---

## Section 6 — AI tier metadata

Tools that require AI calls declare `ai_tier_required` in their registration. The AI tier values
map to the gateway's authorization tiers defined in `tool_ai_tier_metadata.md`:

| Tier | Meaning |
| --- | --- |
| `TIER_1` | Local embedding model — no external data transmission |
| `TIER_2` | Locally-operated inference model — data stays within the deployment boundary |
| `TIER_3` | Anthropic Claude API — external data transmission, requires explicit business consent |

A tool declaring `TIER_3` causes the gateway to check the business's AI consent flag before
invocation. If consent is absent, the invocation is rejected with `AI_CONSENT_REQUIRED` before
any external call is made.

Tools with `ai_tier_required = null` make no AI calls. The gateway does not perform an AI
authorization check for these tools.

---

## Cross-references

- `tool_naming_convention_policy.md` — namespace allowlist, side_effect_class enum, lint rules
- `tool_atomicity_policy.md` — proposer + single-writer pattern for write tools
- `tool_schema_definition_policy.md` — JSON Schema constraints and type fragments
- `tool_invocation_schema.md` — database schema for invocation records
- `tool_ai_tier_metadata.md` — AI tier definitions and consent check flow
- `tool_registration_api.md` — engine.register_tool call shape
- `gateway_bypass_detection_policy.md` — enforcement that all invocations pass through gateway
- `resumability_and_idempotency.md` — caller_idempotency_key construction and cache hit behavior
