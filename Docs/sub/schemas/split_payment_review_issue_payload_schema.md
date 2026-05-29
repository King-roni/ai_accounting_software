# split_payment_review_issue_payload_schema

**Category:** Schemas · **Owning block:** 10 — Matching Engine · **Co-owner:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 1 cross-block schema)

Exact JSON shape of the `review_issues.payload jsonb` value for rows where `issue_type = 'matching.split_payment_proposed'`. The payload carries everything the review-queue UI needs to render the candidate-group review card without re-querying the underlying tables.

Resolves the dangling cross-reference from `split_payment_relationship_schema.md` (BOOK-168) §"Cross-references" which points to `split_payment_review_issue_payload_schema` as the canonical payload shape.

---

## 1. What it is

Read-only payload from the UI's perspective. Mutations to the proposed group go through `split_payment_groups` directly via SECURITY DEFINER RPC (`matching.confirm_split_payment_group` / `matching.reject_split_payment_group`); never via in-place edits to this payload.

Insertion happens at the same transaction that creates the `split_payment_groups` row (per BOOK-188 §10 search-outcome capture). The two writes — group row + payload-bearing review_issue row — are part of the same SECURITY DEFINER call so the payload is consistent with the group state at the moment of proposal.

---

## 2. Top-level shape

```jsonc
{
  "schema_version": "1.0",
  "split_payment_group_id": "uuid",
  "pattern": "ONE_PAYMENT_MANY_INVOICES" | "MANY_PAYMENTS_ONE_INVOICE",
  "parent":             { /* §3 */ },
  "members":            [ /* §4 — array of 2..5 entries */ ],
  "totals":             { /* §5 */ },
  "scoring":            { /* §6 */ },
  "search_provenance":  { /* §7 */ }
}
```

`schema_version` is required. It is the disambiguator for future shape evolution (§9). Clients refuse to render unknown major versions; the review-queue UI shows a re-render-not-supported banner.

The `split_payment_group_id` is the FK back to `split_payment_groups.id`. Together with `issue_type = 'matching.split_payment_proposed'`, it is the join key clients use if they need to drill from the payload back to the source group row.

---

## 3. `parent` block

The single side of the relationship — a transaction for Pattern A, an invoice for Pattern B.

```jsonc
{
  "kind": "transaction" | "invoice",
  "id":   "uuid",
  "display": {
    "amount_eur_minor":      145000,
    "amount_display":        "€1,450.00",
    "original_currency":     "EUR" | "USD" | "GBP" | ...,
    "original_amount_minor": 145000,
    "date":                  "2026-05-12",
    "counterparty_label":    "Hellenic Bank Public Co. Ltd",
    "reference_text":        "INV-2026-0042" | null,
    "raw_description":       "ACME-DEP-CYP-2026-05-12"
  }
}
```

| Field | Source / shape |
|---|---|
| `kind` | Pattern-implied (Pattern A → `transaction`; Pattern B → `invoice`). Redundant with `pattern` at the top level; included for client-side branching ease. |
| `id` | UUID v7 (PK of the parent row). |
| `display.amount_eur_minor` | `bigint` cents per `currency_comparison_reference_policy.md` (BOOK-178) always-EUR rule. |
| `display.amount_display` | Pre-formatted EUR string for the UI — locale-aware thousands separator + 2dp. UI uses this verbatim. |
| `display.original_currency` | ISO 4217 3-char code. Equal to `EUR` for EUR-native rows. |
| `display.original_amount_minor` | Original-currency minor-unit value. Equal to `amount_eur_minor` for EUR-native; differs for foreign-currency rows. Preserved for accountant explanation per BOOK-178 §3. |
| `display.date` | ISO-8601 date (no time component). For transactions: `value_date`. For invoices: `invoice_date`. |
| `display.counterparty_label` | Post-normalisation display name (from `counterparties.normalised_name` or analogous). Subject to `fuzzy_match_algorithm_policy.md` (BOOK-172) §3 normalisation pipeline. |
| `display.reference_text` | Invoice number / reference token if known; `null` otherwise. |
| `display.raw_description` | Free-text bank description (transactions only — for invoices this echoes the invoice number). Same as `transactions.description`; no new PII exposure. |

---

## 4. `members` block

Array of **2..5 entries** (per `split_payment_combinatorial_bounds.md` BOOK-188 group-size range), each describing one candidate on the "multiple" side.

```jsonc
{
  "id":   "uuid",                       // the candidate's transaction_id OR document_id
  "kind": "transaction" | "invoice",    // opposite of parent.kind
  "amount_eur_minor":      50000,
  "amount_display":        "€500.00",
  "date":                  "2026-05-10",
  "counterparty_label":    "...",
  "reference_text":        "INV-2026-0042" | null,
  "per_pair_match_record_id":  "uuid",  // FK to match_records — the proposed pair
  "per_pair_composite_score":  0.78,    // numeric 0..1 from per-pair scoring
  "per_pair_signal_breakdown": {
    "amount_score":    0.95,
    "date_score":      0.80,
    "vendor_score":    1.00,
    "reference_score": 0.20
  },
  "contribution_pct": 34.5              // member amount / parent total × 100
}
```

| Field | Notes |
|---|---|
| `id` | Either `transactions.id` (Pattern A members) or `documents.id` / `invoices.id` (Pattern B members). |
| `kind` | Opposite of `parent.kind`. Pattern A: parent=transaction, members=invoice. Pattern B: parent=invoice, members=transaction. |
| `amount_eur_minor` / `amount_display` | Same convention as parent (§3). |
| `per_pair_match_record_id` | FK to `match_records` — the underlying per-pair scoring row. Lets the UI drill into a single pair's full breakdown. |
| `per_pair_composite_score` | From `match_records.composite_score` at the time of proposal. Frozen on the payload — not refreshed if rescoring happens later (the payload is immutable per §12). |
| `per_pair_signal_breakdown` | Condensed 4-field view; full breakdown available via API drill-in. Exact field set depends on the live scoring model — subject to BOOK-170 / BOOK-190 5-way drift reconciliation; producers should populate whichever signal names the live `match_records.signal_breakdown` exposes. |
| `contribution_pct` | `(amount_eur_minor / parent.amount_eur_minor) × 100`. Always positive. Used by the UI to render proportional bar segments. |

Members are ordered by `per_pair_composite_score DESC` then `date ASC` for stable display.

---

## 5. `totals` block

```jsonc
{
  "parent_amount_eur_minor":   145000,
  "members_sum_eur_minor":     144950,
  "delta_eur_minor":           50,           // signed: positive = members short; negative = members over
  "delta_pct":                 0.0345,       // |delta| / parent × 100 (always positive)
  "in_tolerance":              true          // delta_pct ≤ 2.0 per BOOK-188 §4 amount-tolerance
}
```

`delta_eur_minor` is signed (positive when the members under-sum vs the parent; negative when they over-sum) so the UI can distinguish under-coverage from over-coverage in display copy. `delta_pct` is always positive (absolute-value of percentage) for human readability.

`in_tolerance = false` is possible when the search produced a near-miss in the greedy fallback path (per BOOK-188 §7). The review-queue UI displays the out-of-tolerance state with a red badge but still surfaces the proposal — the human reviewer makes the final call.

---

## 6. `scoring` block

Group-level scoring for the proposed combination.

```jsonc
{
  "group_composite_score":  0.81,
  "group_score_method":     "mean_of_pair_scores" | "geometric_mean" | "min_of_pair_scores",
  "match_level":            "EXACT" | "STRONG_PROBABLE" | "WEAK_POSSIBLE" | "NO_MATCH",
  "auto_confirm_eligible":  false
}
```

| Field | Notes |
|---|---|
| `group_composite_score` | Aggregated from member `per_pair_composite_score` values via `group_score_method`. The aggregation method is calibration-dependent and may differ across Stage-2+ override paths. |
| `group_score_method` | The chosen aggregation function (mean / geometric-mean / min). Defaults to `mean_of_pair_scores` in MVP; subject to recalibration per `match_scoring_calibration_policy.md`. |
| `match_level` | `match_level_enum` value derived by feeding `group_composite_score` into the threshold table — subject to the BOOK-170 / BOOK-174 / BOOK-180 / BOOK-190 5-way threshold-drift reconciliation. |
| `auto_confirm_eligible` | **Always `false` in MVP**. Per Stage-1 decision ("Split-payment detection: surfaces candidates as review issues for user confirmation"), group-level auto-confirm is not enabled. Field preserved for Stage-2+ forward-compat. |

---

## 7. `search_provenance` block

Forensic / debugging visibility into the search that produced this proposal.

```jsonc
{
  "search_run_id":            "uuid",
  "workflow_run_id":          "uuid",
  "candidate_set_size":       20,                  // pre-narrowing top-N per BOOK-188
  "evaluated_combinations":   4720,                // count actually evaluated before pruning / hit
  "search_method":            "dp_subset_sum" | "greedy_fallback",
  "search_duration_ms":       342,
  "tie_breaker_applied":      false,               // true if multiple solutions matched BOOK-188 §5
  "calibration_version":      3
}
```

`search_method = 'greedy_fallback'` indicates the search hit one of the cap guards in `split_payment_combinatorial_bounds.md` (BOOK-188) §7 (DP memory cap, 10s wall-clock, or 21,700 evaluation ceiling). Cards displaying a greedy-fallback proposal SHOULD surface a small "Approximate match" indicator so reviewers know the solution may not be optimal.

`workflow_run_id` cross-references the `workflow_runs` row whose run produced this proposal. Useful when the same run is mid-debug post-hoc.

---

## 8. PII discipline

The payload contains:

- **NO** bank account numbers, **NO** IBAN suffixes (the `match_records` row may include them via `vendor_score` breakdown but this payload does NOT propagate).
- **NO** email addresses.
- **NO** VAT numbers (similar — internal scoring may use them; payload does not).
- **NO** encrypted-field plaintext (counterparty notes, classification rules, etc.).
- **NO** user identifiers other than what flows naturally from `match_records` FK chains.

The `counterparty_label` is the post-normalisation display name (from `counterparties.normalised_name`); the `raw_description` is the bank-statement free-text already in `transactions.description` (no new exposure). Original-currency fields preserved for accountant explanation but never derive from sensitive sources.

Audit emission upstream of payload construction (per `split_payment_relationship_schema.md` SPLIT_PAYMENT_GROUP_PROPOSED) follows the same exclusion rules.

---

## 9. Versioning + evolution

`schema_version` follows semver-style:

| Version bump | Backward-compat | Client behaviour |
|---|---|---|
| Patch (1.0 → 1.0.1) | Documentation-only changes | No behaviour change. |
| Minor (1.0 → 1.1) | Adds optional fields with safe defaults | Older clients ignore unknown fields; render normally. |
| Major (1.x → 2.0) | May rename / remove fields | Older clients show "Re-render not supported — please update" banner and skip rendering. |

Adding a new top-level field or new sub-field within an existing block: minor bump.
Renaming or removing any field, changing a field's type, or changing the `pattern` enum: major bump.

Major-version changes require a `Docs/decisions_log.md` amendment and a coordinated UI release in the same deployment window.

---

## 10. UI rendering rules

The review-queue card consumes this payload per `review_queue_card_layout_ui_spec.md` (BOOK-184) body section.

| UI element | Source field |
|---|---|
| Card header label | `"Split payment proposed: " + pattern_label` where `pattern_label = '1 payment → N invoices'` for Pattern A or `'N payments → 1 invoice'` for Pattern B (N = `members.length`). |
| Body row 1 (parent) | `parent.display.counterparty_label` + `amount_display` + `date`. |
| Body rows 2..N+1 (members) | Per member: `counterparty_label` + `amount_display` + `date` + small bar segment proportional to `contribution_pct`. |
| Body row N+2 (totals) | `"Coverage: " + (100 - delta_pct) + "%"` with ✓ green badge if `in_tolerance` else ✗ red badge with `"Off by " + |delta_eur_minor|/100 + " EUR"`. |
| Body row N+3 (scoring) | `match_level` as a badge from `severity_color_tokens.md` + `group_composite_score` as percentage. |
| "Approximate" indicator | Small text label if `search_provenance.search_method = 'greedy_fallback'`. |

**Actions on the card** (per BOOK-184 §5 expand-panel resolution-action set):

- **Confirm Split** → calls `matching.confirm_split_payment_group(group_id)` RPC. Requires confirmation modal (per BOOK-184 §"Result modal"). On success: all member `match_records` transition to `CONFIRMED`; `split_payment_groups.status = CONFIRMED`; review_issue resolves; emits `SPLIT_PAYMENT_GROUP_CONFIRMED` per BOOK-168.
- **Reject Split** → calls `matching.reject_split_payment_group(group_id, reason_text)` RPC. Requires confirmation modal with mandatory reason text (max 500 chars). On success: member `match_records` transition to `REJECTED`; `split_payment_groups.status = REJECTED`; review_issue resolves; emits `SPLIT_PAYMENT_GROUP_REJECTED`.
- **Edit Members** → opens a panel that lets the user add / remove members from the proposed group. Goes through manual-search per BOOK-186 edit-and-confirm flow. On save: produces a NEW `split_payment_groups` row with the user-edited member set; this review_issue resolves (action recorded); a fresh review_issue is generated with a new payload for the new group.

---

## 11. Mobile rendering

Per `review_queue_card_layout_ui_spec.md` (BOOK-184) §"Mobile":

- Single-column stacked layout.
- Member rows beyond the first 2 collapse into a "Show all N members" expander.
- "Confirm Split" / "Reject Split" / "Edit Members" are disabled with the standard mobile soft-prompt banner ("To resolve issues, open this page on a desktop browser").
- Server-side write-rejection per `mobile_write_rejection_endpoints.md` enforces this independently.

Read paths (viewing the proposed group, drilling into a member's per-pair breakdown) remain accessible on mobile.

---

## 12. Payload persistence + immutability

Once the `review_issue` row is INSERTed with this payload, **the payload is immutable**.

Changes to the underlying `split_payment_groups` (e.g., user adds a member via edit-and-confirm per §10) result in:

1. A NEW `split_payment_groups` row (with `status = PROPOSED`, new id).
2. A NEW `review_issues` row with a fresh payload reflecting the new group's state.
3. The OLD review_issue transitions to `RESOLVED` with `resolution_action = 'EDIT_AND_RECREATE'`; the OLD `split_payment_groups` row transitions to `REJECTED`.

This preserves audit history and prevents the UI from rendering a stale member set against a mutated group. The `match_records` row references the per-pair `original_match_record_id` chain for traceability across the edit-and-confirm boundary per `rejection_memory_schema.md`.

---

## 13. Validation

JSON schema validation at INSERT time via a SECURITY DEFINER PG function:

```sql
matching.validate_split_payment_payload(p_payload jsonb) RETURNS boolean
```

Required fields: every field in §2 except `tie_breaker_applied` and `auto_confirm_eligible` (which default to `false`).

Type checks: UUIDs (regex `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`), bigint integers, ISO-8601 dates.

Range checks: `contribution_pct` 0..100; `group_composite_score` 0..1; `members.length` 2..5; `delta_pct` 0..100; `match_level` ∈ canonical enum values; `pattern` ∈ canonical enum values.

Validation failure raises `MATCHING_SPLIT_PAYMENT_PAYLOAD_INVALID` (BLOCKING review-issue). The proposing run is halted at the workflow level pending operator investigation — invalid payloads indicate a bug in the proposer, not a normal data scenario.

---

## 14. Worked example

A Pattern A proposal: one transaction (€1,450.00 EUR) matched against three invoices (€500 + €450 + €500 = €1,450) — exact match.

```jsonc
{
  "schema_version": "1.0",
  "split_payment_group_id": "01923-…",
  "pattern": "ONE_PAYMENT_MANY_INVOICES",
  "parent": {
    "kind": "transaction",
    "id":   "01923-tx-…",
    "display": {
      "amount_eur_minor": 145000,
      "amount_display":   "€1,450.00",
      "original_currency": "EUR",
      "original_amount_minor": 145000,
      "date":              "2026-05-12",
      "counterparty_label": "Hellenic Bank Public Co. Ltd",
      "reference_text":    null,
      "raw_description":   "ACME-DEP-CYP-2026-05-12"
    }
  },
  "members": [
    { "id": "01923-inv-A", "kind": "invoice", "amount_eur_minor": 50000, "amount_display": "€500.00", "date": "2026-05-10",
      "counterparty_label": "Acme Ltd", "reference_text": "INV-2026-0042",
      "per_pair_match_record_id": "01923-mr-1", "per_pair_composite_score": 0.92,
      "per_pair_signal_breakdown": { "amount_score": 1.0, "date_score": 0.85, "vendor_score": 1.0, "reference_score": 1.0 },
      "contribution_pct": 34.5 },
    { "id": "01923-inv-B", "kind": "invoice", "amount_eur_minor": 45000, "amount_display": "€450.00", "date": "2026-05-09",
      "counterparty_label": "Acme Ltd", "reference_text": "INV-2026-0041",
      "per_pair_match_record_id": "01923-mr-2", "per_pair_composite_score": 0.88,
      "per_pair_signal_breakdown": { "amount_score": 1.0, "date_score": 0.82, "vendor_score": 1.0, "reference_score": 1.0 },
      "contribution_pct": 31.0 },
    { "id": "01923-inv-C", "kind": "invoice", "amount_eur_minor": 50000, "amount_display": "€500.00", "date": "2026-05-11",
      "counterparty_label": "Acme Ltd", "reference_text": "INV-2026-0043",
      "per_pair_match_record_id": "01923-mr-3", "per_pair_composite_score": 0.90,
      "per_pair_signal_breakdown": { "amount_score": 1.0, "date_score": 0.90, "vendor_score": 1.0, "reference_score": 1.0 },
      "contribution_pct": 34.5 }
  ],
  "totals": {
    "parent_amount_eur_minor":   145000,
    "members_sum_eur_minor":     145000,
    "delta_eur_minor":           0,
    "delta_pct":                 0.0,
    "in_tolerance":              true
  },
  "scoring": {
    "group_composite_score":  0.90,
    "group_score_method":     "mean_of_pair_scores",
    "match_level":            "STRONG_PROBABLE",
    "auto_confirm_eligible":  false
  },
  "search_provenance": {
    "search_run_id":          "01923-search-…",
    "workflow_run_id":        "01923-run-…",
    "candidate_set_size":     20,
    "evaluated_combinations": 4720,
    "search_method":          "dp_subset_sum",
    "search_duration_ms":     342,
    "tie_breaker_applied":    false,
    "calibration_version":    3
  }
}
```

---

## 15. Cross-references

- `split_payment_relationship_schema.md` (BOOK-168) — host table for the `split_payment_group_id` this payload references
- `split_payment_combinatorial_bounds.md` (BOOK-188) — `search_provenance` field semantics + 2..5 member-count range
- `review_queue_card_layout_ui_spec.md` (BOOK-184) — UI card that renders the payload
- `match_records_schema.md` — per-pair match record rows referenced by `per_pair_match_record_id`
- `tool_matching_score_pair.md` (BOOK-172) — `per_pair_composite_score` + breakdown source (subject to scoring-docs drift per BOOK-190)
- `fuzzy_match_algorithm_policy.md` (BOOK-172) — `counterparty_label` normalisation pipeline
- `currency_comparison_reference_policy.md` (BOOK-178) — `amount_eur_minor` source + always-EUR format
- `match_scoring_calibration_policy.md` — `match_level` enum + `calibration_version`
- `match_scoring_weights_policy.md` — alternate match_level enum source (subject to BOOK-190 drift)
- `issue_type_to_group_mapping.md` — `matching.split_payment_proposed` issue-type routing
- `rejection_memory_schema.md` (BOOK-166) — `original_match_record_id` chain for edit-and-confirm
- `review_issues_schema.md` — host table for the payload column
- `severity_color_tokens.md` — match-level badge styling
- `mobile_write_rejection_endpoints.md` — mobile write-rejection enforcement (§11)
- `audit_event_taxonomy.md` — `SPLIT_PAYMENT_GROUP_PROPOSED`, `SPLIT_PAYMENT_GROUP_CONFIRMED`, `SPLIT_PAYMENT_GROUP_REJECTED`, `MATCHING_SPLIT_PAYMENT_PAYLOAD_INVALID`
- Block 10 Phase 04 — owning phase (combinatorial detection)
- Block 14 — review queue consumer
- Stage 1 decision — proactive split-payment detection requires human confirmation
