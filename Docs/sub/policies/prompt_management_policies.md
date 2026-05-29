# Prompt Management Policies

**Category:** Policies · **Owning block:** 06 — AI Layer · **Stage:** 4 sub-doc (Layer 1 convention)

Two sub-policies bound together: how prompts are versioned and where they live on disk. Every Prompts sub-doc and every AI-tier-`LOCAL` / `EXTERNAL` tool binds to this. Prompts are versioned product surfaces — changing a prompt changes the product's behaviour. The conventions here let us roll prompts forward and backward without ambiguity.

Block 06 Phase 04 owns the runtime prompt registry; this policy owns the conventions the registry enforces.

---

## Section 1 — Naming

```
<block_short_name>.<purpose>
```

- `block_short_name` — same allowlist as `tool_naming_convention_policy`
- `purpose` — snake_case noun describing what the prompt does

Canonical names (binding, taken from the locked sub-doc list):

| Prompt name | Sub-doc | Block |
| --- | --- | --- |
| `ai.plain_language_pipeline` | `plain_language_pipeline_prompt` | 06 |
| `classification.tier_3_classifier` | `tier_3_classifier_prompt` | 08 |
| `intake.extraction` | `extraction_prompt` | 09 |
| `matching.match_reason` | `match_reason_prompt` | 10 |
| `ledger.vat_treatment_explanation` | `vat_treatment_explanation_prompt` | 11 |
| `review_queue.review_card_content` | `review_card_content_prompt` | 14 |

Adding a new prompt requires registering it in the runtime registry (Block 06 Phase 04) and adding a sub-doc per `Docs/sub/prompts/<purpose>_prompt.md`.

## Section 2 — Versioning

Semver with three parts: `major.minor.patch`.

| Bump | When | Effect on output | Cache invalidation |
| --- | --- | --- | --- |
| `major` | Tone, intent, or structural change that affects downstream meaning | Yes — output may differ for identical input | Required (cache key includes major) |
| `minor` | Clarifications, additional examples, new edge-case coverage | Possible drift on edge cases only | Required (cache key includes minor) |
| `patch` | Typo, whitespace, comment-only change | None | Not required |

Version is recorded on every prompt invocation in `ai_usage_records.prompt_version` (per Block 06 Phase 07 schema).

### Test-corpus requirement

Every major and minor bump requires:
1. The test corpus passes — every input maps to an acceptable output
2. The acceptable-output set may NOT widen on a major bump unless the change is documented as an intentional widening

Test corpus structure is `prompt_test_corpus_structure` (Stage 4 sub-doc, Block 06).

### Deprecation

Major bumps trigger deprecation of the prior major version. Old major lives in the runtime registry for one full workflow-run cycle minimum (typically 30 days). Audit event `AI_PROMPT_DEPRECATED` records the deprecation timestamp.

Workflows that started under the old major version finish under it (per Block 03 Phase 04 state machine — running phases honour the principal context, including AI registry snapshot). New workflows route to the new major.

## Section 3 — Directory layout

```
prompts/
  <block_short_name>/
    <purpose>/
      v<major>.<minor>.<patch>/
        system.md          # System prompt — required
        user.md            # User-prompt template — required
        redaction.md       # Redaction scope override (only if differs from default) — optional
        output_schema.json # JSON-schema for structured output validation — required
        test_corpus.md     # Test cases (input → expected output) — required
        notes.md           # Rationale for this version — optional but recommended
```

### Required files

- `system.md` — present
- `user.md` — present, contains placeholder syntax `{{variable_name}}` for runtime substitution
- `output_schema.json` — present, valid JSON Schema 2020-12, used by Block 06 Phase 02 schema-validator
- `test_corpus.md` — present, with at least 5 input/output pairs

The runtime registry refuses to load a prompt version that's missing any required file. Boot-time fatal.

### Optional files

- `redaction.md` — used only when this prompt requires a redaction scope different from the default. References `redaction_policies`. If absent, the global default redaction applies.
- `notes.md` — human-readable rationale for the version's existence, link to the PR / decision-doc / amendment

## Section 4 — Runtime registry mirror

At service boot, the registry walks `prompts/` and indexes every version. Each indexed prompt has:

```ts
{
  name: "classification.tier_3_classifier",
  version: "2.1.0",
  system_prompt_text: "...",   // from system.md
  user_prompt_template: "...", // from user.md
  output_schema: {...},        // from output_schema.json
  redaction_override?: {...},  // from redaction.md if present
}
```

Block 06 Phase 04 owns the implementation. Block 06 Phase 09's AI cache key includes `(name, version)` — major/minor bumps invalidate the cache by construction.

## Section 5 — Linting

CI checks:
1. **Filename format** — directory matches `prompts/[a-z][a-z0-9_]*/[a-z][a-z0-9_]*/v\d+\.\d+\.\d+/`
2. **Version monotonicity** — within a `<purpose>` directory, no version is missing in the major.minor sequence (gaps allowed in patch)
3. **Required files present** — every version directory has `system.md`, `user.md`, `output_schema.json`, `test_corpus.md`
4. **Output schema valid** — JSON-Schema 2020-12 syntactically valid; runs `ajv compile` in CI
5. **Test corpus parses** — at least 5 cases per version, each with `input` + `expected_output` blocks
6. **Sub-doc referenced** — every prompt name has a corresponding `Docs/sub/prompts/<...>_prompt.md`
7. **Audit events** — every prompt invocation in code emits `AI_PROMPT_INVOKED` with `name` + `version` (caught by static analysis)

Failures block the merge. Override requires an amendment.

## Section 6 — Versioning rules and breaking changes

A version bump is **breaking** (major) if any of the following apply:
- A field that appeared in the output schema is removed or renamed
- The output type of a field changes (e.g., `string` → `array`)
- The prompt's intent shifts such that the same input would be routed to a different downstream handler
- The redaction allowlist is loosened (new fields permitted through)

A version bump is **non-breaking** (minor) if the output schema is strictly backward-compatible: new optional fields may be added, examples extended, edge-case coverage added, but existing fields remain present and structurally identical.

Patch bumps require no test-corpus re-run (no semantic change) but still increment the version string so the cache key changes and CI records the new version in the deployment log.

## Section 7 — Deprecation procedure

When a major version is superseded:

1. The old major version's row in the runtime registry gains `deprecated_at = now()` and `deprecated_reason = "superseded by v{N+1}.0.0"`.
2. Audit event `AI_PROMPT_DEPRECATED` is emitted with `prompt_name`, `old_version`, `new_version`, and `deprecated_at`.
3. The old version remains active in the registry for **30 days** (one full workflow-run cycle). In-flight workflow runs that started under the old version finish under it; new runs route to the new version.
4. After 30 days, the old version's `enabled = false` in the registry. Attempting to invoke it returns `AI_PROMPT_VERSION_DISABLED`.
5. The old version's files remain on disk in version control — they are never deleted.

## Cross-references

- `redaction_policies` — referenced from `redaction.md` overrides
- `ai_gateway_schema` — `ai_usage_records.prompt_version` column; prompt invocation record
- `ai_cache_policies` — cache key includes `(name, version)`
- `audit_log_policies` — `AI_PROMPT_*` event naming
- Block 06 Phase 04 — runtime registry implementation
- Block 06 Phase 07 — `ai_usage_records.prompt_version` column
- Block 06 Phase 09 — AI cache key composition

## Open items deferred to later sub-docs

- The corpus structure itself (input format, expected-output format, regression tolerance) — `prompt_test_corpus_structure` (Stage 4 sub-doc, Block 06)
- The actual prompt content (system / user / examples / edge cases) — per-prompt sub-docs in `Docs/sub/prompts/`
- Cross-language prompt rollout (post-MVP EU languages) — `plain_language_localisation_policy` (Block 06)
