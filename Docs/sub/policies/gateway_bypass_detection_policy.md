# gateway_bypass_detection_policy

**Category:** Policies · **Owning block:** 06 — AI Layer · **Co-owner:** 07 — Bank Statement Pipeline · **Stage:** 4 sub-doc (Layer 1 cross-block policy)

The two-layer guard against code paths that bypass the AI Privacy Gateway. The gateway is the single approved point of contact between project code and Tier 2 / Tier 3 AI providers — bypassing it skips redaction, cost ceiling, audit emission, and per-business config.

Per Block 06 Phase 02's pipeline ordering: every AI call MUST flow through the gateway. This policy enforces that invariant at lint time AND at runtime.

---

## Layer 1 — lint rule

CI scans every source file for direct provider invocations. The disallowed list:

| Provider | Disallowed function / API |
| --- | --- |
| Anthropic | `Anthropic.messages.create`, `anthropic-sdk`'s direct send |
| Google Document AI | `documentai.processorClient.processDocument`, raw HTTP to `*-documentai.googleapis.com` |
| Open-source Tier 2 LLM clients | Direct HTTP to localhost LLM ports without `ai.gateway_invoke()` wrapper |
| Any future provider | Added to the list at integration time |

Allowed wrappers:

| Provider | Allowed wrapper |
| --- | --- |
| Tier 2 | `ai.gateway_invoke({ tier: 'LOCAL', ... })` per Block 06 Phase 06 |
| Tier 3 (Anthropic) | `ai.gateway_invoke({ tier: 'EXTERNAL', ... })` per Block 06 Phase 05 |
| Document AI | `intake.ocr_and_extract()` (which calls `ai.gateway_invoke` internally) |

The lint regex matches direct imports + direct function calls. False positives are documented in `prompts/` and `Docs/sub/integrations/` — both directories are excluded from the lint scope.

### CI invocation

```bash
pnpm lint:gateway-bypass
```

Output is a JSON list of offending file paths + line numbers. Non-zero exit on any match.

## Layer 2 — runtime check

Each per-tier integration includes a runtime guard:

```ts
// Inside the Tier 3 Anthropic client wrapper
function callAnthropic(args: AnthropicArgs) {
  if (!isInvokedFromGateway(getCallStack())) {
    emitAudit("AI_PRIVACY_GATEWAY_BYPASS_DETECTED", {
      attempted_provider: "anthropic",
      caller_stack: redactPii(getCallStack()),
      timestamp: now()
    });
    throw new GatewayBypassError("Anthropic calls must flow through ai.gateway_invoke");
  }
  // ... proceed with the call
}
```

`isInvokedFromGateway` checks the call stack for `ai.gateway_invoke()` as a parent frame within the last K frames. The threshold K is configured to capture the standard wrapping depth without false positives.

The runtime guard fires AFTER the lint passes — it catches dynamically-loaded code, ad-hoc scripts, REPL invocations, or any path the static lint misses.

## Document AI guard (Block 07 / 09 specifically)

Per the 2026-05-07 Block 07 scan fix and Block 09 scan: Document AI is a Tier 3 integration. The dispatch goes through:

```
caller (Block 07 or 09 phase)
  → intake.ocr_and_extract  (the gateway-wrapped tool per tool_naming_convention_policy)
    → ai.gateway_invoke({ tier: 'EXTERNAL', provider: 'document_ai', ... })
      → callDocumentAi  (the actual provider client)
```

Calling `callDocumentAi` directly skips redaction (per `redaction_policies`) — the document bytes are typically not redactable, but the metadata payload around them IS, and the output response goes through schema validation.

The Document AI guard is the most aggressive: it inspects the call stack AND the provider client's request authentication context. A request without a valid gateway-issued auth context fails immediately.

## Per-tier configuration

| Tier | Guard strictness |
| --- | --- |
| Tier 2 (LOCAL) | Soft — operator-controlled environment; bypass logs a WARN-level event but does NOT block |
| Tier 3 (EXTERNAL) | Hard — bypass is a BLOCKING error; the call refuses to proceed |

The asymmetry reflects the trust model: Tier 2 runs on hardware the operator owns; Tier 3 is a third-party processor under DPA, and a bypass exposes user data to the third party without the gateway's redaction + audit.

## Audit events

| Event | When |
| --- | --- |
| `AI_PRIVACY_GATEWAY_BYPASS_DETECTED` | Runtime guard triggered |
| `AI_PRIVACY_GATEWAY_BYPASS_LINT_FAILURE` | CI lint caught a direct import / call |

Both events are HIGH severity per `severity_enum`. The first triggers `cross_tenant_alerting_runbook` per the gateway-bypass alert class.

## False-positive handling

| Source | Resolution |
| --- | --- |
| Test fixtures replaying recorded responses | The replay layer is gateway-aware; lint excludes `__fixtures__/` paths; runtime check sees the test-mode flag |
| Prompt-engineering exploratory scripts | Excluded from production; lint allows `scripts/dev-only/` |
| Documentation code-block examples | Excluded; lint targets `.ts`/`.js` source only |

Adding to the exception list requires PR approval + decisions-log amendment for production-path exceptions.

## Maintenance

The disallowed list is maintained per `prompt_management_policies`-style versioning — additions / removals are PR'd, the version is bumped, CI re-runs.

When a new provider is integrated, the wrapper is added FIRST, then the lint disallowed list, then the runtime guard. The ordering ensures the disallowed list never has an entry without a corresponding allowed wrapper.

## Cross-references

- `redaction_policies` — what the gateway redacts
- `ai_routing_decision_policy` (merged into `redaction_policies` cross-references) — pipeline ordering
- `tool_ai_tier_metadata` — tier declaration on each tool
- `gateway_pipeline_ordering_policy` (consolidated) — gateway position
- `audit_log_policies` — `AI_PRIVACY_GATEWAY_BYPASS_*` events
- `cross_tenant_alerting_runbook` — escalation
- `live_integration_test_runbook` — test-mode replay
- Block 06 Phase 01 — tier classification
- Block 06 Phase 02 — gateway pipeline
- Block 06 Phase 05 — Tier 3 integration
- Block 06 Phase 06 — Tier 2 integration
- 2026-05-07 Block 07 scan fix — Document AI guard requirement

---

## Detection examples — bypass patterns

The following patterns constitute a bypass attempt and trigger the lint rule or runtime guard (or both):

**Pattern 1 — Direct SDK import:**
```ts
// BYPASS — disallowed
import Anthropic from "@anthropic-ai/sdk";
const client = new Anthropic();
const response = await client.messages.create({ ... });
```
The lint rule matches on `from "@anthropic-ai/sdk"` in any `.ts` / `.js` file outside excluded paths.

**Pattern 2 — Raw HTTP to provider endpoint:**
```ts
// BYPASS — disallowed
const response = await fetch("https://api.anthropic.com/v1/messages", {
  method: "POST",
  headers: { "x-api-key": process.env.ANTHROPIC_KEY, ... },
  body: JSON.stringify({ ... })
});
```
The lint regex matches on `api.anthropic.com` and `*-documentai.googleapis.com` in any source file.

**Pattern 3 — Calling internal provider wrapper without gateway:**
```ts
// BYPASS — disallowed
// callAnthropic is the internal wrapper; it checks isInvokedFromGateway
// Calling it directly (not via ai.gateway_invoke) triggers the runtime guard
callAnthropic({ model: "claude-3-opus", messages: [...] });
```
The runtime guard fires `AI_PRIVACY_GATEWAY_BYPASS_DETECTED` and throws `GatewayBypassError`.

**Pattern 4 — Direct write to `processing_zone.ai_payload_redacted` without gateway:**
```sql
-- BYPASS — the RLS write policy blocks this
INSERT INTO processing_zone.ai_payload_redacted (...) VALUES (...);
-- Error: RLS policy ai_payload_redacted_write denies: app.ai_gateway_active != 'true'
```
The `redaction_at_write_policy` single-writer enforcement rejects the write at the database layer.

**Compliant pattern — correct usage:**
```ts
// ALLOWED
const result = await ai.gateway_invoke({
  tier: 'EXTERNAL',
  tool_name: 'classification.classify_transaction',
  prompt_name: 'transaction_classifier_v3',
  payload: { ... }
});
```

---

## False-positive handling

The following patterns look like bypasses to the lint but are legitimate:

| Pattern | Why it looks like a bypass | Why it is legitimate | Resolution |
| --- | --- | --- | --- |
| Test fixtures that import the Anthropic SDK to record golden responses | Import of `@anthropic-ai/sdk` in test files | The recording runs against the real provider once to capture the golden response; subsequent test runs use the cached response, not the live provider | Lint excludes `**/__fixtures__/` and `**/__recordings__/` paths |
| Documentation code blocks showing the provider API shape | Inline code examples in `.md` files | Documentation only; not executed | Lint targets `.ts` / `.js` source only; `.md` excluded |
| Provider SDK used inside `ai.gateway_invoke()`'s own implementation | The gateway itself imports the SDK | This is the sole legitimate production path for SDK usage | The gateway implementation file is explicitly allowlisted in the lint config via `gateway_allowlist_paths` |
| Exploration scripts in `scripts/dev-only/` | Raw provider calls for prompt development | Not in the production path; never deployed | Lint excludes `scripts/dev-only/` |

Adding a new legitimate exception requires:
1. A PR with the path added to the lint exclusion list
2. A `Docs/decisions_log.md` amendment explaining why the exception is safe
3. The exception must NOT appear in any code path that runs in the production environment

A production-path exception (e.g., a new legitimate gateway-adjacent module) requires a `decisions_log.md` amendment even if it is correctly wrapped via `ai.gateway_invoke()` — the amendment documents why the path was reviewed and approved.

---

## Additional cross-references

- `redaction_policies` — the redaction allowlist that the gateway applies; bypass detection references this to determine what would have been redacted
- `redaction_at_write_policy` — single-writer rule for `processing_zone.ai_payload_redacted`; the write-policy RLS is the database-layer bypass guard
