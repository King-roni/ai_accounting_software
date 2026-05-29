# Block 06 — Phase 10: Plain-Language Pipeline

## References

- Block doc: `Docs/blocks/06_ai_layer.md` (Plain-language translation surface)
- Block doc: `Docs/blocks/01_core_principles.md` (Principle 5 — Simple Interface, Advanced Backend)
- Block doc: `Docs/blocks/14_review_queue.md` (consumer of `plain_language_title` / `plain_language_description`)
- Block doc: `Docs/blocks/10_matching_engine.md` (consumer of `match_reason_plain_language`)

## Phase Goal

Build the AI-driven generation of plain-language titles, descriptions, and reason text that the user actually reads. The pipeline is Tier-2-by-default with explicit Tier-3 escalation for cases that need stronger language ability. Output is schema-validated. After this phase, every review issue and every match record can be rendered with user-facing content that came from a controlled, audited path.

## Dependencies

- Phase 02 (gateway pipeline)
- Phase 04 (prompts for plain-language generation)
- Phase 09 (cache — plain-language calls are cacheable within a run)

## Deliverables

- **API:** `generatePlainLanguage(kind, structured_input, options) → { title, description }`
  - `kind` ∈ `{ REVIEW_ISSUE, MATCH_REASON, OTHER }`.
  - `structured_input` is the typed payload the caller wants rendered (e.g., the issue's `issue_type` + transaction context + relevant entity ids).
  - `options.preferred_tier` defaults to `LOCAL_LLM`; can be `EXTERNAL_LLM` for explicit Tier 3.
- **Default routing:**
  - Tier 2 by default for both kinds.
  - **Explicit Tier 3** when:
    - The calling phase passes `options.preferred_tier = EXTERNAL_LLM` (e.g., for issues with multiple linked records or unusually complex VAT cases).
    - The prompt's `meta.yaml` declares Tier 3 (some issue types are inherently complex enough that Tier 2 produces poor output — this is configured at prompt registration time per Phase 04).
- **Schema constraints on output:**
  - `title` — single line, max 80 characters.
  - `description` — 1–3 sentences, max 300 characters.
  - `language` — `en` for MVP, with a `language` field on the API for future localisation.
  - Output schema is registered with the prompt (Phase 04) so the gateway's output validation catches violations.
- **Prompt set:**
  - `06.plain_language.review_issue` — generates `(title, description)` for a structured issue payload.
  - `06.plain_language.match_reason` — generates the `match_reason_plain_language` string for a match record.
  - `06.plain_language.other` — fallback for ad-hoc plain-language needs from any block.
  - All registered with test corpora per Phase 04.
- **Style guide enforced via the prompt:**
  - Plain language only — no `OUT_EXPENSE_NO_INVOICE` codes, no VAT-treatment ENUM names, no internal IDs.
  - User-facing tone: factual, neutral, action-oriented (the issue card recommends a next step).
  - Currency formatted with the user's locale (per the Stage 1 deferred-locale decision; defaults to EUR + EU date format).
- **Caching** — calls go through Phase 09's within-run cache. Repeated rendering of the same structured input returns the cached title/description. **`language` is part of the canonical input that hashes into the cache key**, so two callers rendering the same structured input in different languages do not collide on the cache.
- **Failure handling:**
  - On Tier 2 failure with `transient: true` → caller decides whether to retry at Tier 2 or escalate to Tier 3.
  - On output schema violation → caller treats as a tool failure per Block 03 Phase 08; the underlying issue may still be created with a fallback title (e.g., `issue_type` rendered raw) but flagged as `plain_language_pending`.
- **Audit events:** `PLAIN_LANGUAGE_GENERATED`, `PLAIN_LANGUAGE_GENERATION_FAILED`, `PLAIN_LANGUAGE_FALLBACK_USED`.

## Definition of Done

- A review issue rendering call returns a valid `(title, description)` for a typical input (test corpus passes).
- A match-reason rendering call returns a valid plain-language string.
- A title that exceeds 80 characters or a description that exceeds 300 characters is treated as `SCHEMA_VIOLATION_OUTPUT` and the caller falls back gracefully.
- An explicit `preferred_tier = EXTERNAL_LLM` request routes to Tier 3 even when Tier 2 is available.
- Repeated rendering of the same input returns from the cache (Phase 09).
- The style-guide test corpus (assertions about prohibited tokens like raw ENUMs) passes.

## Sub-doc Hooks (Stage 4)

- **Plain-language style guide sub-doc** — full tone rules, prohibited tokens, currency/date formatting, voice.
- **Tier 3 escalation criteria sub-doc** — exact conditions that warrant Tier 3 for plain-language generation.
- **Output schema sub-doc** — title/description constraints, validation, fallback behaviour.
- **Localisation hook sub-doc** — how the `language` field will support EU-language rollout post-MVP.
- **Style-guide regression cases sub-doc** — corpus entries that protect against drift back to internal jargon.
