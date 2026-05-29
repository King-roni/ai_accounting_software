# match_scoring_weights_policy

**Category:** Policies · **Owning block:** 10 — Matching Engine · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the binding weighting model for the `matching.score_pair` tool. The final match score is a weighted sum of five component scores. This policy is the canonical reference for how those weights are defined, what each component measures, and how businesses may override defaults. Every change to the weighting model — even a temporary experiment — must be traced back to this policy and to the `MATCH_SCORING_CONFIG_UPDATED` audit event.

---

## Section 1 — Final score formula

```
final_score = (amount_match × 0.35)
            + (date_proximity × 0.25)
            + (description_similarity × 0.20)
            + (vendor_memory_hit × 0.15)
            + (document_reference_match × 0.05)
```

Weights sum to 1.00. Each component score is a float in `[0.0, 1.0]`. The final score is therefore also in `[0.0, 1.0]`.

When a business-level weight override is active (stored in `match_scoring_config` — forward reference), the same formula applies with the overridden weights substituted. The override must also sum to 1.00; the engine rejects configurations that do not satisfy this constraint.

---

## Section 2 — Component definitions

### `amount_match` (weight: 0.35)

**Measures:** how closely the transaction amount matches the document (invoice or receipt) amount.

- Score `1.0`: amounts are exactly equal in minor units and currency.
- Score `0.0`: amounts differ by more than 5% of the document amount, or currencies differ.
- Linear interpolation between `0.0` and `1.0` for differences within the 5% tolerance band.
- Currency mismatch: score is `0.0` regardless of numerical proximity. A transaction in USD is never matched to a EUR invoice with a non-zero `amount_match` score. FX-adjusted matching is a Stage 2 feature.
- `amount_match` carries the highest weight (0.35) because amount is the most discriminating field in practice. Two different invoices rarely have the same amount.

### `date_proximity` (weight: 0.25)

**Measures:** how close the transaction date is to the document's invoice or receipt date.

- Score `1.0`: same date.
- Linear decay: score decreases by `1 / 30` per day of separation, reaching `0.0` at exactly 30 days.
- Score `0.0`: separation ≥ 30 days.
- Formula: `max(0.0, 1.0 - (abs(date_delta_days) / 30.0))`.
- The 30-day window is the system default. It is not per-business configurable in MVP; the window is a property of the scoring model, not of a business's matching configuration.
- Both dates are evaluated as calendar dates in the `Europe/Nicosia` timezone for Cyprus-domiciled businesses. The timezone is resolved from the business's `timezone_id` stored in `businesses`; no hardcoded timezone appears in the scoring code.

### `description_similarity` (weight: 0.20)

**Measures:** textual similarity between the transaction's `normalized_description` and the document's extracted vendor name and description fields.

- Score is computed as the weighted average of:
  - Normalised Levenshtein similarity (edit distance / max length): weight 0.60 within this component.
  - Keyword overlap (Jaccard coefficient on tokenized word sets): weight 0.40 within this component.
- Both sub-scores are floats in `[0.0, 1.0]`.
- Normalization applied before comparison: lowercase, punctuation-stripped, whitespace-collapsed.
- `description_similarity` is the most noise-prone component; its weight (0.20) is lower than `amount_match` (0.35) and `date_proximity` (0.25) to limit its influence on false-positive matches.

### `vendor_memory_hit` (weight: 0.15)

**Measures:** whether the vendor memory for this business confirms that this counterparty has been paired with this document vendor before.

- Score `1.0`: the recurring vendor memory (Block 08 Phase 03) has a confirmed pairing record for `(counterparty_signature, document_vendor_name)` with `confirmation_count ≥ 1`.
- Score `0.0`: no confirmed pairing record exists.
- This component is binary — no intermediate values. Rationale: partial vendor-memory evidence has not shown predictive value in design review; a single confirmed pairing is sufficient signal.
- `vendor_memory_hit` is `0.0` for the first time a counterparty is seen (by definition). The vendor memory is populated by confirmed matches, so this component bootstraps to non-zero only after one human or auto-confirmed match.

### `document_reference_match` (weight: 0.05)

**Measures:** whether the transaction's `reference` field contains the document's reference number (invoice number, receipt number).

- Score `1.0`: exact match after normalising both to uppercase, stripping hyphens and spaces.
- Score `0.0`: no match.
- Binary component. The weight (0.05) is intentionally low: reference numbers are frequently absent from transaction descriptions, so a non-match does not significantly lower the overall score.

---

## Section 3 — Match level thresholds

The final score is classified into a match level:

| Match level | Threshold | Behaviour |
|---|---|---|
| `EXACT` | `final_score ≥ 0.95` | Auto-confirmed without human review (subject to auto-confirm gate in Block 10 Phase 03) |
| `STRONG_PROBABLE` | `final_score ≥ 0.80` | Surfaced as a strong candidate; auto-confirmed if business auto-confirm is enabled |
| `WEAK_POSSIBLE` | `final_score ≥ 0.60` | Surfaced as a probable candidate; requires human confirmation |
| `NO_MATCH` | `final_score ≥ 0.40` | Surfaced as a possible candidate; requires human confirmation; ranked below WEAK_POSSIBLE candidates |
| Below `NO_MATCH` | `final_score < 0.40` | Pair is not surfaced as a candidate; discarded |

Match levels are stored on the `match_records` table as `match_level` (closed enum). The `EXACT`, `STRONG_PROBABLE`, `WEAK_POSSIBLE`, `NO_MATCH` values are canonical. No additional match levels are defined in MVP.

---

## Section 4 — Business-level weight overrides

Businesses may override the system-default weights via their `match_scoring_config` table row (table definition is deferred — forward reference to Block 10 Phase 02 sub-doc).

Override constraints:
- Override weights must sum to exactly `1.00` (enforced at write time by `matching.update_scoring_config`; the tool rejects a configuration that does not satisfy this constraint).
- No individual component weight may be set to `0.00` in MVP. Rationale: zeroing a component changes the qualitative behaviour of the scorer and requires accountant review of existing confirmed matches.
- Overrides are scoped to a single business; they do not affect other businesses.
- The override is stored as a JSONB column on `match_scoring_config`, not as individual float columns, to allow schema flexibility in Stage 2.

Override activation: the engine reads `match_scoring_config` at the start of each scoring run. If a row exists for the business and `is_active = true`, the override weights are used; otherwise, system defaults apply.

---

## Section 5 — Access control and audit

Modifying the scoring configuration requires the **Owner or Admin** role on the business (enforced by `canPerform('MATCH_CONFIG_WRITE', business_id)` in Block 02 Phase 04).

Every write to `match_scoring_config` (insert or update) emits:

| Event | When | Severity |
|---|---|---|
| `MATCHING_SCORING_CONFIG_UPDATED` | Business-level weight override created or modified | MEDIUM |

`MEDIUM` severity reflects that scoring configuration changes affect how transactions are matched and can alter accounting outcomes. The audit record includes the before and after weight values.

---

## Section 6 — Mobile write rejection

The `matching.update_scoring_config` tool is a write surface and is not available to mobile clients. Mobile write requests to this surface are rejected per `mobile_write_rejection_endpoints.md`. Reading the current scoring configuration is permitted on mobile via read-only API surfaces.

---

## Section 7 — Workflow run states

Match scoring runs within the MATCHING workflow phase. The applicable run states from the canonical 10-value set during scoring are `RUNNING` (active scoring), `REVIEW_HOLD` (a split or low-confidence match requires human confirmation), and `FAILED` (scoring tool encountered an unrecoverable error). Auto-confirmed matches at `EXACT` or `STRONG_PROBABLE` level do not cause a `REVIEW_HOLD` transition. `WEAK_POSSIBLE` and `NO_MATCH` level matches surface to the review queue but do not halt the workflow run state itself — the run advances to `REVIEW_HOLD` only when an explicit gate requires human input before the run can continue.

---

## Section 8 — Scoring determinism

`matching.score_pair` is a deterministic tool (`READ_ONLY | WRITES_AUDIT` side-effect class). For the same pair of inputs and the same scoring config, it always produces the same output. This is enforced by:

- Using integer minor units for amount comparison (no float drift).
- Using fixed-precision Levenshtein on normalised strings (normalisation is deterministic).
- Vendor memory reads are point-in-time reads; the score snapshot is stored on the `match_records` row so that future vendor memory updates do not alter historical match scores.

Scoring is idempotent per Block 03 Phase 07: re-invoking `matching.score_pair` for the same pair within the same workflow run returns the cached result via the dedup key mechanism and does not emit a duplicate `MATCHING_PAIR_SCORED` event.

---

## Cross-references

- `audit_log_policies` — `MATCHING_*` domain; `<DOMAIN>_<PAST_VERB>` naming convention
- `audit_event_taxonomy` — `MATCHING_PAIR_SCORED`, `MATCHING_SCORING_CONFIG_UPDATED`
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy
- `tool_naming_convention_policy` — `matching.*` namespace; `matching.score_pair` as the primary tool
- Block 10 Phase 02 — match scoring engine; implementation of this weighting model; `match_scoring_config` table definition
- Block 10 Phase 03 — strong/probable auto-confirm rule; reads `match_level` produced by this scoring model
- Block 08 Phase 03 — vendor memory (Layer 2); source of `vendor_memory_hit` scores
- Block 02 Phase 04 — `canPerform` access control for `MATCH_CONFIG_WRITE`
