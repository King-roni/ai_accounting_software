# Block 06 — Phase 04: Prompt Management

## References

- Block doc: `Docs/blocks/06_ai_layer.md` (Prompt Management section)
- Decisions log: `Docs/decisions_log.md` (prompts versioned in the repo + automated regression tests on a maintained corpus)

## Phase Goal

Treat prompts as code-reviewed, versioned artifacts with declared schemas and a maintained test corpus. Every change runs against the corpus before deploy; regression failures block the release. After this phase, no prompt reaches production without passing the regression gate, and rollback is a config change rather than a code edit.

## Dependencies

- Phase 02 (gateway resolves prompts during the pipeline)

## Deliverables

- **Prompt registry layout:**
  - Prompts live in the repo at `/prompts/<block>/<task>/<prompt_name>/v<n>.txt`.
  - Each prompt directory carries:
    - `prompt.txt` — the prompt template.
    - `meta.yaml` — `prompt_id`, `version`, `purpose`, `input_schema`, `output_schema`, `ai_tier` (LOCAL_LLM or EXTERNAL_LLM).
    - `tests/<case_name>.json` — input/expected-output test cases.
- **Runtime prompt registry:**
  - `prompt_registry` table mirroring the on-disk metadata for fast lookup at gateway invocation time. Refreshed at deploy.
  - `getPrompt(prompt_id, version) → PromptDefinition`.
- **Test corpus:**
  - Each prompt has at least 5 test cases covering happy path + 3 known edge cases + 1 adversarial case (e.g., input that previously caused a known failure, kept as a regression anchor).
  - Cases are versioned alongside the prompt — a new prompt version may add new cases but cannot delete existing ones without a documented removal entry.
- **Regression test runner:**
  - Runs in CI on every prompt change.
  - Calls the prompt via the gateway with each test input.
  - Compares output:
    - Structured outputs: exact JSON match (after canonical-JSON normalization).
    - Free-text outputs: semantic similarity using a deterministic comparator (sub-doc) plus a hard "must contain" assertion list per case.
  - Failure on any case blocks the merge.
- **Production binding:**
  - Production code references prompts by `(prompt_id, version)`.
  - The deployed version per environment is a config value, not hardcoded.
  - Rollback to a prior version is a config change.
- **Promotion path:**
  - A new prompt version is deployed to the test environment first; full corpus must pass.
  - Promotion to production requires a one-week soak in test or an explicit Owner override (audited).
- **Audit events:** `AI_PROMPT_REGISTERED`, `AI_PROMPT_DEPLOYED`, `AI_PROMPT_ROLLED_BACK`, `AI_PROMPT_REGRESSION_FAILED` (CI), `AI_PROMPT_PROMOTION_OVERRIDE_USED` — using the `AI_PROMPT_*` prefix per the Block 06 audit taxonomy declared in Phase 02.

## Definition of Done

- The `prompts/` directory structure exists with at least one example prompt (e.g., the supplier-name normalization prompt for Block 08) plus its test corpus.
- The CI runner picks up prompt changes and runs the corpus; a deliberately broken prompt causes the merge to be blocked.
- `getPrompt` resolves prompts by `(prompt_id, version)` from the runtime registry.
- Promotion from test to production works as a config change.
- Rollback to a prior version takes effect within one deploy cycle.
- Removing a test case requires a documented entry; an undocumented removal fails review.

## Sub-doc Hooks (Stage 4)

- **Prompt versioning convention sub-doc** — naming, semantic-versioning rules, when to bump major vs minor.
- **Test corpus structure sub-doc** — case JSON shape, must-contain assertion format, semantic-comparator choice.
- **Regression runner sub-doc** — CI integration, parallelisation, time budget, flaky-test handling.
- **Promotion path sub-doc** — soak window, override criteria, post-promotion monitoring.
- **Prompt directory layout sub-doc** — exact filesystem conventions, mirror-to-runtime-registry pipeline.
