# Tool Registration API

**Category:** Tools · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2)

The `engine.registerTool` call shape, the boot-time registration lifecycle, and the runtime tool-lookup contract. Every block (06–16) that exposes tools to the workflow engine binds to this document. The engine's behavior on name collisions, deprecated versions, and unresolved tool references is defined here and is not configurable.

---

## 1. Registration call shape

Tools are registered at engine startup via `engine.registerTool`. The TypeScript interface for the registration object:

```typescript
interface ToolRegistration {
  /**
   * Tool name. Must match ^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$ and the block
   * short-name allowlist per tool_naming_convention_policy.
   */
  name: string;

  /**
   * Schema version. Must match ^\d+\.\d+$. Declares the current version of
   * the input/output contract. Old major versions are retained for one
   * workflow-run cycle before being removed from the registry.
   */
  schema_version: string;

  /**
   * One or more side-effect classes from the closed enum in tool_side_effect_taxonomy.
   * At least one class must be declared. An empty array is a fatal registration error.
   */
  side_effect_class: SideEffectClass[];

  /**
   * AI tier from the closed enum: "NONE" | "LOCAL" | "EXTERNAL".
   * Declares the maximum reachable AI tier in this tool's call path.
   * Per tool_naming_convention_policy.
   */
  ai_tier: "NONE" | "LOCAL" | "EXTERNAL";

  /**
   * Reference to the input schema. Must resolve to a registered Zod schema.
   * Format: "<schema_file_slug>#v<major_version>.input"
   */
  input_schema_ref: string;

  /**
   * Reference to the output schema. Must resolve to a registered Zod schema.
   * Format: "<schema_file_slug>#v<major_version>.output"
   */
  output_schema_ref: string;

  /**
   * Audit event names this tool may emit. Every name must be in audit_event_taxonomy
   * and match the audit_log_policies lint regex. An empty array is valid for tools
   * that never emit audit events (rare; should be documented in the tool sub-doc).
   */
  audit_events: string[];

  /**
   * Absolute path to the tool's sub-doc within Docs/sub/tools/.
   * Validated by the CI lint check: the path must resolve to an existing file.
   */
  description_ref: string;

  /**
   * Pure function that computes the dedup key string from the tool's input.
   * Used by Phase 07 (Resumability & Idempotency) to detect already-completed
   * invocations within a workflow run.
   */
  dedup_key_generator: (input: unknown) => string;

  /**
   * Failure semantics from the closed enum. Determines retry behavior.
   * "RETRYABLE" | "FATAL_ON_FIRST_FAIL" | "IDEMPOTENT_AT_MOST_ONCE"
   * Defined in tool_atomicity_policy.
   */
  failure_semantics: FailureSemantics;

  /**
   * Optional. Previous version registration, present only during the deprecation
   * window following a major schema version bump. When present, the engine registers
   * both the current version and the deprecated version in the registry, and emits
   * WORKFLOW_TOOL_REGISTRATION_DEPRECATED for the deprecated entry at startup.
   */
  deprecated_version?: DeprecatedVersionEntry;
}

interface DeprecatedVersionEntry {
  schema_version: string;
  input_schema_ref: string;
  output_schema_ref: string;
  deprecated_at: string;  // ISO 8601 date; retention window starts here
}
```

**Required fields:** all fields except `deprecated_version`. A registration missing any required field causes a fatal engine startup failure.

---

## 2. Boot-time registration lifecycle

Registration calls run during the engine initialization phase, before the engine accepts any workflow run requests. The lifecycle:

```
1. Engine calls engine.initRegistry()
2. Each block (06–16) invokes engine.registerTool(declaration) in its module init
3. For each registration, the engine:
   a. Validates the name format (regex check)
   b. Validates name against the block short-name allowlist
   c. Validates side_effect_class elements against the closed enum
   d. Validates ai_tier against {NONE, LOCAL, EXTERNAL}
   e. Validates schema_version format
   f. Compiles and validates the input_schema_ref and output_schema_ref Zod schemas,
      including the required-field checks from tool_schema_definition_policy
   g. Validates all audit_events names against audit_event_taxonomy
   h. Validates description_ref path resolves to an existing file
   i. Validates failure_semantics against the closed enum
4. If all checks pass, the tool is added to the registry under its name + version key
5. If deprecated_version is present, the deprecated entry is also added to the registry,
   and WORKFLOW_TOOL_REGISTRATION_DEPRECATED is emitted
6. After all registrations complete, the engine emits TOOL_REGISTRY_STARTUP_COMPLETED
   with a payload of { tool_count: N, deprecated_count: M }
7. If any registration fails, the engine emits TOOL_REGISTRY_STARTUP_FAILED and
   refuses to start — no workflow runs are accepted
```

---

## 3. Name collision handling

Name collisions are **fatal**. If two calls to `engine.registerTool` are made with the same `name` and same `schema_version`, the engine:

1. Logs a structured error: `{ error: "TOOL_NAME_COLLISION", name: "...", version: "..." }`
2. Emits `TOOL_REGISTRY_STARTUP_FAILED` with the collision detail in the payload.
3. Exits the process. The engine does not start.

This is intentional. Ambiguous tool resolution at runtime would produce silent behavior differences between deployments. A fail-fast boot is the safer default.

Registering the same name with a different `schema_version` is the correct mechanism for a major version bump. Both versions coexist in the registry during the deprecation window; name + version is the compound key.

---

## 4. Runtime tool lookup

The execution loop (Block 03 Phase 06) looks up tools by name before invoking them. The lookup sequence:

```typescript
function resolveToolForInvocation(
  toolName: string,
  requestedVersion?: string
): RegisteredTool {
  const key = requestedVersion
    ? `${toolName}@${requestedVersion}`
    : toolName;            // defaults to current (non-deprecated) version

  const entry = registry.get(key);
  if (!entry) {
    throw ToolNotFoundError(toolName, requestedVersion);
  }
  if (entry.isDeprecated && !requestedVersion) {
    // This path should not be reached in normal operation; the current version
    // should always be available. Indicates a registry state bug.
    throw ToolNotFoundError(toolName, "current");
  }
  return entry;
}
```

The default lookup (no explicit version) always returns the current (non-deprecated) version. Deprecated versions are accessible only when an explicit `requestedVersion` is passed — this happens during the workflow-run cycle retention window, where a run that started under the old version continues using it to completion.

---

## 5. Tool-not-found error path

When `resolveToolForInvocation` throws `ToolNotFoundError`:

1. The phase execution engine catches the error.
2. A `WORKFLOW_TOOL_INVOCATION_FAILED` audit event is emitted with `error_code: "TOOL_NOT_FOUND"` and the `tool_name` in the payload.
3. The workflow run transitions to `FAILED` state.
4. A review issue (Block 14) is raised with issue type `TOOL_NOT_FOUND`.
5. The error is also emitted as a `SECURITY_ALERT_RAISED` event (HIGH severity) because a missing tool registration at runtime indicates a deployment integrity failure.

A tool-not-found error is not retryable. The workflow run must be investigated and re-triggered after the deployment issue is resolved.

---

## 6. Versioned tool lookup during deprecation window

When a workflow run was started under a deprecated tool version, the engine uses the version recorded in the `tool_invocations` row (`schema_version` column) to look up the correct version for replay during crash recovery (Phase 07).

The deprecated version remains in the registry for one full workflow-run cycle (30 days by default; the value is configurable per `engine_config.tool_deprecation_retention_days`). After the retention window:

1. The deprecated version is removed from the registry on the next engine restart.
2. Any workflow run still referencing the deprecated version triggers `TOOL_NOT_FOUND` on the next invocation attempt — treated as above.
3. Operators are responsible for ensuring all active runs complete or are cancelled before the retention window closes.

---

## 7. `WORKFLOW_TOOL_REGISTRATION_DEPRECATED` event

Emitted once per deprecated tool entry at engine startup (not per invocation). Severity: LOW. Payload:

```json
{
  "tool_name": "matching.score_pair",
  "deprecated_version": "1.0",
  "current_version": "2.0",
  "deprecated_at": "2026-05-01",
  "retention_expires_at": "2026-05-31"
}
```

This event is in `audit_event_taxonomy` under the `WORKFLOW_TOOL` domain.

---

## 8. Canonical registration example

```typescript
engine.registerTool({
  name: "matching.score_pair",
  schema_version: "1.0",
  side_effect_class: ["READ_ONLY", "WRITES_AUDIT"],
  ai_tier: "NONE",
  input_schema_ref: "tool_matching_score_pair#v1.input",
  output_schema_ref: "tool_matching_score_pair#v1.output",
  audit_events: ["MATCHING_PAIR_SCORED"],
  description_ref: "Docs/sub/tools/tool_matching_score_pair.md",
  dedup_key_generator: (input) => canonicalJson({
    tool_name: "matching.score_pair",
    transaction_id: input.transaction_id,
    document_id: input.document_id,
  }),
  failure_semantics: "RETRYABLE",
});
```

`matching.score_pair` is `READ_ONLY` because it produces a score proposal; it does not write the score to any operational table. A separate `matching.persist_score` tool (with `WRITES_RUN_STATE | WRITES_AUDIT`) writes the score to `match_records`. The `WRITES_AUDIT` class is included because `MATCHING_PAIR_SCORED` is emitted.

---

## 9. Mobile write surface note

Tool invocations are engine-internal. Mobile clients cannot trigger tool invocations directly. All write surfaces that could lead to a tool invocation are rejected at the API gateway layer per `mobile_write_rejection_endpoints` before the engine is reached.

---

## Cross-references

- `tool_naming_convention_policy` — name format regex, block short-name allowlist, schema version rules, `WORKFLOW_TOOL_REGISTRATION_DEPRECATED` event definition
- `tool_schema_definition_policy` — required fields in input/output schemas; Zod schema language requirement; schema versioning rules
- `tool_side_effect_taxonomy` — closed enum for `side_effect_class`; `WRITES_ARCHIVE` reservation rule
- `tool_atomicity_policy` (Block 03) — `failure_semantics` closed enum; proposer + single-writer pattern
- `audit_event_taxonomy` — all events in `audit_events` arrays must be present here; `WORKFLOW_TOOL_REGISTRATION_DEPRECATED`, `TOOL_REGISTRY_STARTUP_COMPLETED`, `TOOL_REGISTRY_STARTUP_FAILED`
- `emit_audit_api` — `security.emit_audit` tool used by all `WRITES_AUDIT` tools
- `tool_invocation_schema` — `tool_invocations` table schema; `schema_version` column used for versioned tool lookup
- `mobile_write_rejection_endpoints` — pre-invocation mobile rejection enforcement
- `Docs/phases/03_workflow_engine/03_tool_registration_framework.md` — Phase 03 owner of this framework
- `Docs/phases/03_workflow_engine/06_phase_execution_engine.md` — Phase 06 execution loop that calls `resolveToolForInvocation`
- `Docs/phases/03_workflow_engine/07_resumability_and_idempotency.md` — Phase 07 crash-recovery that uses versioned tool lookup

## Mobile

All write operations in this tool are rejected on mobile clients. Mobile apps receive `HTTP 405 Method Not Allowed` with error code `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints.md` for the full endpoint rejection list.