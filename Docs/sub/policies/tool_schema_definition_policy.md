# Tool Schema Definition Policy

**Category:** Policies · **Owning block:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2)

Binding rules for how tool input and output schemas are authored, located, validated, and versioned. Every tool developer in Blocks 06–16 who writes or modifies a schema file binds to this document. The CI lint suite enforces these rules at PR time.

---

## 1. Schema language

Tool schemas are expressed as a **paired TypeScript interface and Zod runtime validator**. Both must exist; neither is optional.

```
TypeScript interface — compile-time shape contract (no runtime cost, full IDE support)
Zod schema          — runtime validator, identical shape, called by the engine at invocation time
```

The two must be structurally equivalent. Divergence is a lint failure. The Zod schema is the authoritative runtime check; the TypeScript interface is the developer-facing contract.

Using a different schema language (JSON Schema, Yup, Valibot, Joi, or hand-rolled validation) is forbidden. The engine's `registerTool` call accepts only Zod schemas for the `input_schema` and `output_schema` fields at registration time. See `tool_registration_api` for the registration call shape.

---

## 2. Required fields in every input schema

Every tool input schema must include:

| Field | Type | Notes |
| --- | --- | --- |
| `workflow_run_id` | `z.string().uuid()` | UUID v7. Required for dedup-key construction and audit correlation. No tool invocation is valid without it. |
| `business_id` | `z.string().uuid()` | UUID v7. Tenant scope for every operation. |
| `actor_id` | `z.string().uuid()` | UUID v7 referencing `users.id`. The principal invoking the tool. |

These three fields are the minimum baseline. Tools may add further fields. Removing any of the three requires a major schema version bump and a deprecation window per `tool_naming_convention_policy`.

---

## 3. Required fields in every output schema

Every tool output schema must include:

| Field | Type | Notes |
| --- | --- | --- |
| `audit_trail` | `z.array(AuditTrailEntry)` | Array of audit event references emitted by this tool invocation. May be empty (`[]`) for read-only tools that emit no events. The `AuditTrailEntry` type is the shared fragment defined in `Docs/sub/tools/shared_schema_fragments.md`. |
| `tool_invocation_id` | `z.string().uuid()` | UUID v7. The `tool_invocations.id` of the persisted record for this invocation. Populated by the engine before the tool function returns. |

---

## 4. Nullable fields

Fields whose value may be absent use an explicit `null` union, not `undefined` or TypeScript's optional operator (`?`).

```typescript
// Correct
workflow_run_id: z.string().uuid().nullable()

// Forbidden — undefined is structurally different from null and breaks canonical JSON serialization
workflow_run_id: z.string().uuid().optional()
```

The prohibition on `undefined` exists because canonical JSON serialization (per `data_layer_conventions_policy`) requires that `null`-valued fields appear in the serialized object with the key present and value `null`. Fields serialized as `undefined` are dropped by `JSON.stringify`, breaking the determinism guarantee.

---

## 5. Enums in schemas

Schemas must not define inline string literals for fields that correspond to a closed enum. Instead, reference the canonical closed-enum sub-doc and import the Zod enum from the shared schema fragment it exports.

```typescript
// Correct — imports the canonical severity enum
severity: SeverityEnum  // from Docs/sub/reference/severity_enum.md shared fragment

// Forbidden — inline string literals for a closed enum
severity: z.enum(["LOW", "MEDIUM", "HIGH", "BLOCKING"])
```

The only exception is a field that is genuinely local to a single tool and has no cross-system semantics. Such fields must be documented with a comment explaining why they are not in a shared enum.

---

## 6. Schema file location and naming

All tool schema files live in `Docs/sub/tools/`. The naming pattern is:

```
tool_<block_short_name>_<action>.md
```

Where `<block_short_name>` and `<action>` are taken from the tool name as defined in `tool_naming_convention_policy`. The `.md` extension is used because schema files are sub-docs (they document the schema; the actual TypeScript/Zod source lives in the implementation code, cross-referenced from the sub-doc).

Examples:
- `tool_matching_score_pair.md` — schema sub-doc for `matching.score_pair`
- `tool_intake_ocr_and_extract.md` — schema sub-doc for `intake.ocr_and_extract`
- `tool_emit_audit.md` — schema sub-doc for `security.emit_audit`

A tool whose schema sub-doc does not exist fails the `description_ref` lint check in `tool_naming_convention_policy` and cannot be registered.

---

## 7. Schema versioning

Schema versioning follows the `major.minor` rules from `tool_naming_convention_policy`:

- **Major bump** — input or output shape changes: field added, field removed, type changed, nullable constraint changed, side-effect class changed, AI tier widened.
- **Minor bump** — implementation change with no shape impact.

On a major bump:
1. The old version is retained in the registry for one full workflow-run cycle (typically 30 days).
2. The `WORKFLOW_TOOL_REGISTRATION_DEPRECATED` audit event is emitted at engine startup when the deprecated version is loaded.
3. The schema sub-doc is updated with a `## Previous versions` section documenting the prior version's shape and the migration path.

Schema version `1.0` is the initial version for every new tool. Version `0.x` is reserved for internal pre-registration prototyping and must not appear in production registrations.

---

## 8. Engine validation at boot

The engine calls `engine.registerTool` at startup for every declared tool. The registration call validates:

1. The input schema is a valid Zod object schema.
2. The output schema is a valid Zod object schema.
3. Both schemas contain the required fields listed in Sections 2 and 3.
4. The schema version string matches `^\d+\.\d+$`.

A registration that fails any of these checks causes a fatal engine startup failure. See `tool_registration_api` for the full registration lifecycle.

---

## 9. Mobile write surface note

Tool input validation runs exclusively server-side. Mobile clients are rejected before tool invocation per `mobile_write_rejection_endpoints`. Schema validation is not a substitute for the mobile rejection check; both operate independently.

---

## Cross-references

- `tool_naming_convention_policy` — tool name format, block short-name allowlist, schema version bump rules, `WORKFLOW_TOOL_REGISTRATION_DEPRECATED` event
- `tool_registration_api` — `engine.registerTool` call shape, registration lifecycle, fatal boot failure on schema validation error
- `data_layer_conventions_policy` — canonical JSON serialization rules that drive the `null` vs `undefined` requirement; UUID v7 for `workflow_run_id` and `business_id`
- `tool_side_effect_taxonomy` — side-effect class enum referenced in tool registration alongside schema
- `audit_event_taxonomy` — `WORKFLOW_TOOL_REGISTRATION_DEPRECATED` (LOW) event entry
- `mobile_write_rejection_endpoints` — pre-invocation mobile rejection enforcement
- `Docs/sub/tools/shared_schema_fragments.md` — `AuditTrailEntry` type and other shared Zod fragments
- `Docs/phases/03_workflow_engine/03_tool_registration_framework.md` — Phase 03 that owns the engine.registerTool framework
- `Docs/phases/03_workflow_engine/07_resumability_and_idempotency.md` — Phase 07 where `workflow_run_id` in input schemas feeds the dedup-key generator
