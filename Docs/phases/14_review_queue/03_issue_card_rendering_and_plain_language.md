# Block 14 — Phase 03: Issue Card Rendering & Plain-Language Consumption

## References

- Block doc: `Docs/blocks/14_review_queue.md` (Issue Card Structure; Plain-Language Rendering)
- Block doc: `Docs/blocks/06_ai_layer.md` (Phase 10 — plain-language pipeline; Tier 2 default with Tier 3 escalation)
- Block doc: `Docs/blocks/01_core_principles.md` (Principle 5 — Simple Interface; technical taxonomy hidden by default)
- Decisions log: `Docs/decisions_log.md` (card content generated at issue-creation time)

## Phase Goal

Define the issue card structure, the plain-language consumption from Block 06 Phase 10, the **content-generation-at-issue-creation-time** rule (so the audit log captures exactly what the user saw), and the expand-for-technical-detail surface for advanced users. After this phase, every `review_issues` row carries stable rendered content from the moment it's created.

## Dependencies

- Phase 01 (`review_issues` schema)
- Phase 02 (`issue_group` and `severity` taxonomies; `registerIssueType` provides the `plain_language_template_ref`)
- Block 04 Phase 04 (`review_issues` already declares `plain_language_title`, `plain_language_description`, `recommended_action`, `card_payload_json` columns — Stage 1 default; sub-doc tracks the canonical column set)
- Block 06 Phase 04 (prompt registry — card-content prompts registered there)
- Block 06 Phase 09 (within-run cache for plain-language calls)
- Block 06 Phase 10 (`generatePlainLanguage('REVIEW_CARD', ...)` — the consumed pipeline)

## Deliverables

- **Card content schema** (columns on `review_issues`; declared in Block 04 Phase 04; restated here for clarity):
  - `plain_language_title` (text; ≤ 80 chars; one short line — the card's heading).
  - `plain_language_description` (text; 1–3 sentences; ≤ 300 chars per Block 06 Phase 10's output schema).
  - `recommended_action` (text; ≤ 120 chars — names the most likely resolution with optional context, e.g., "Upload invoice for €49 Google payment"). The 120-char cap accommodates contextualized recommendations that include amount / counterparty hints; sub-doc owns the per-action template.
  - `card_payload_json` (JSONB) — structured context: `{ transaction_id?, transaction_amount?, transaction_currency?, transaction_date?, counterparty?, current_tag?, attached_document_ids?, related_invoice_ids?, severity_label?, expand_pointer? }`. The card UI renders these into a deterministic layout.
  - **`expand_pointer` semantics (resolves the M2 frozen-vs-live tension):** the field carries pointers (FK + table name) into the producing-block tables, NOT a snapshot copy of the structured signals. The expand panel queries the live data at view time so changes to `match_signals`, `score_breakdown`, etc. are reflected. Only the user-facing TEXT fields (`plain_language_title` / `description` / `recommended_action`) are frozen at issue-creation time; the technical-detail expand panel is intentionally live so accountants reviewing weeks later see the current state. This contradicts an "everything frozen" reading of Phase 03; the canonical rule is "user-facing rendered text is frozen; technical-detail pointers resolve live."
  - `card_content_generated_at` (timestamp) — when the AI call finished.
  - `card_content_tier_used` (enum: `NONE`, `TIER_2_LOCAL_LLM`, `TIER_3_EXTERNAL_LLM`).
  - `card_content_fallback_applied` (boolean) — `true` when the AI call failed and the structured fallback was used.
- **Card-content generation timing rule (canonical):**
  - Card content is generated **at issue-creation time**, not at render time. The mechanism is a Block 14-internal helper `reviewQueue.generateAndPersistCardContent({ issue_id }) → void` that producing blocks invoke as part of their issue-insertion flow. Block 14 owns the helper; producing blocks call it the same way they currently call Block 06 Phase 10's `generatePlainLanguage(...)` — the integration point is a single line at the end of issue insertion.
  - **Producing-block contract (lightweight):** producing blocks (06/07/08/10/11/13) populate `review_issues.issue_type` and the structured-signals payload at insertion. They are NOT required to expose any new helper. Block 14's `generateAndPersistCardContent` reads `review_issues.id`, looks up the `issue_type` registration (Phase 02), pulls structured signals from the producing block's table via FK (`transaction_id`, `document_id`, `match_record_id`, `draft_ledger_entry_id`), and generates + persists the card content fields.
  - **Rationale for Block 14-internal placement:** producing blocks already populate the structured fields; Block 14 reads them. No cross-block contract amendment is needed — the helper is a Block 14 implementation detail.
  - Re-rendering is allowed only via an explicit "regenerate card content" action (Owner/Admin only via the `REVIEW_REGENERATE` permission surface — declared in Phase 01); the prior content is preserved in audit.
  - **Boundary with producing-block plain-language fields (resolves M8):** Block 10 Phase 07 and Block 11 Phase 05 maintain their own plain-language fields on `match_records` and `draft_ledger_entries` respectively (e.g., `match_reason_plain_language`). Those fields ARE re-generated when the underlying signals change (per their phase contracts). **Block 14's review-issue card text is independent** — the card text is frozen at issue-creation. The two can drift: an accountant viewing a 3-month-old `matching.matched_needs_confirmation` issue sees the original card text, while clicking expand reveals the live `match_reason_plain_language` (which may have been regenerated). This is intentional: the card snapshot captures what the user saw when the issue was raised; the live data shows the current state for context.
- **`reviewQueue.generateAndPersistCardContent` flow** (Block 14-internal):
  1. Look up the `issue_type` registration (Phase 02) to find `plain_language_template_ref` (the prompt name in Block 06 Phase 04's registry).
  2. Read the structured signals via FK from `review_issues` columns: `transaction_id`, `document_id`, `match_record_id`, `draft_ledger_entry_id`. Pull producing-block-specific fields from those tables (e.g., `match_records.match_signals` for matching issues; `draft_ledger_entries.vat_treatment_explanation` and `score_breakdown` for VAT issues).
  3. Invoke Block 06 Phase 10's `generatePlainLanguage('REVIEW_CARD', { template_ref, structured_input })`. **Tier 2 default** per Block 06 Phase 10; **Tier 3 escalation** triggered by:
     - Cross-currency, cross-period, or otherwise complex matching context (mirrors Block 10 Phase 07's escalation criteria).
     - Multiple related issues sharing the same `transaction_id` (likely a complex case worth a clearer explanation).
     - Severity `BLOCKING` (high-stakes; warrants the better tier).
  4. Persist `plain_language_title`, `plain_language_description`, `recommended_action`, `card_content_generated_at`, `card_content_tier_used` on the row.
  5. Within Block 06 Phase 09's within-run cache, identical structured inputs return cached strings (no duplicate AI calls when the same matching pattern produces multiple cards in one run).
- **Failure handling for the card-content AI call:**
  - On AI failure (timeout, rate limit, schema-validation failure after retries), a deterministic **structured fallback** is written to all three text fields:
    - `plain_language_title` = `"<Issue type> on transaction <TXN-ID>"` (deterministic template; sub-doc owns the per-`issue_group` exact wording).
    - `plain_language_description` = `"Structured signals: <decision_factors>. Plain-language summary unavailable; see expand for details."`
    - `recommended_action` = the first action in the `allowed_resolution_actions` list.
  - `card_content_fallback_applied = true`; `REVIEW_CARD_CONTENT_FALLBACK_APPLIED` audit event fires (with failure category).
  - A LOW-severity follow-up issue raises a "Card-content unavailable" placeholder action `Regenerate card content` so the user can re-attempt.
  - **Coalescing rule (avoids audit-volume storm under retry-storms):** at most one Card-content-unavailable follow-up exists per primary issue at any time, keyed by `(primary_issue_id, failure_category)`. Repeated failures during a rate-limit storm update the existing follow-up's `failure_category` and `card_content_generated_at` rather than creating new follow-ups. On retry success, the follow-up auto-resolves via Phase 08's affected-set re-scan (the `card_content_generated_at` field on the primary issue updates → the follow-up's validity check sees the success → auto-close).
  - **Contract alignment:** mirrors Block 10 Phase 07's plain-language fallback semantics and Block 11 Phase 05's VAT-explanation fallback semantics — same shape across blocks.
- **Card structure rendered to the user** (UI-layer; producer-block-agnostic):
  - **Plain-language title** (one short line)
  - **Plain-language description** (1–3 sentences)
  - **Context block:**
    - Transaction amount + currency + date + counterparty (when applicable)
    - Current `transaction.tag` (when applicable)
    - Attached document(s) thumbnail + click-through (when applicable)
    - Related invoice(s) link (when applicable)
  - **Severity badge** (visual: LOW gray; MEDIUM amber; HIGH red; BLOCKING red + bold border).
  - **Recommended action** (the most likely resolution; pre-selected button).
  - **Other one-click actions** (the remaining allowed resolutions for this issue type per Phase 04's vocabulary).
  - **Notes field** (Phase 06 — single free-text field; saves on blur or via explicit "Save note").
  - **Expand** — opens the technical detail panel:
    - `issue_type` string
    - `card_payload_json.expand_payload` (the structured signals — for matching, the full `match_signals` JSONB; for VAT, the `score_breakdown`; etc.)
    - Audit-trail link for this issue
- **Severity colour-coding** (canonical; sub-doc owns exact tokens):
  - `LOW` — neutral gray.
  - `MEDIUM` — amber.
  - `HIGH` — red.
  - `BLOCKING` — red with bold border + "Blocks finalization" label.
- **Per-bucket layout** (Phase 02's six groups):
  - Each bucket renders as a collapsible section with a count badge.
  - Within a bucket, cards sort by severity descending, then by `created_at` ascending.
  - The `Ready to Finalize` bucket renders the green-light card per Phase 02's projection.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `REVIEW_QUEUE`):
  - `REVIEW_CARD_CONTENT_GENERATED` (with `tier_used`)
  - `REVIEW_CARD_CONTENT_FALLBACK_APPLIED` (failure category)
  - `REVIEW_CARD_CONTENT_REGENERATED` (when an Owner/Admin manually triggers regeneration; old content preserved in audit)
  - `REVIEW_CARD_VIEWED` — **NOT emitted** in Stage 1 (would explode audit-log volume; per-view tracking is a Block 16 dashboard concern, not a Block 05 audit event).

## Definition of Done

- A producing block raises an issue → `generateAndPersistCardContent` fires synchronously → the row is queryable with all card-content columns populated.
- A user opens the queue → the card renders the persisted text exactly (no re-call to AI).
- An AI failure produces a deterministic fallback; `card_content_fallback_applied = true`; the LOW follow-up issue surfaces a regenerate action.
- Tier 3 escalation triggers correctly for complex cases (cross-currency, multi-issue transactions, BLOCKING severity).
- Identical structured inputs hit Block 06 Phase 09's within-run cache.
- The expand panel surfaces the technical taxonomy and the structured signals.
- Tests cover: each `issue_group`'s representative card; each severity badge; the fallback path; the Tier 3 escalation triggers; the expand panel; the cache-hit case.

## Sub-doc Hooks (Stage 4)

- **Card-content prompt design sub-doc** — system + user prompt per `issue_group`; tone guide; sample outputs.
- **Per-`issue_type` template-ref sub-doc** — exhaustive map.
- **Structured-fallback wording sub-doc** — exact templates per `issue_group`.
- **Severity colour-token sub-doc** — exact hex / token names; light + dark mode.
- **Card-layout sub-doc** — pixel-level desktop layout; per-bucket variations.
- **Regenerate-card-content UX sub-doc** — when to surface the action, audit shape.
- **Expand-panel sub-doc** — what counts as "technical detail" per producing block.
