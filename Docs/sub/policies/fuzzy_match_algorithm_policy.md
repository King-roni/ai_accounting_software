# fuzzy_match_algorithm_policy

**Category:** Policies · **Owning block:** 10 — Matching Engine · **Co-owner:** 08 — Transaction Classification · **Stage:** 4 sub-doc (Layer 2)

This policy commits to the **fuzzy-string-similarity algorithm choice** used by `matching.score_pair` and its callers, the per-signal threshold values, the normalisation pipeline applied before any similarity computation, and the internationalisation rules for Cyprus / EU-mixed-script business names.

Scope is deliberately limited to the **algorithm axis**. Signal weighting and signal-set decomposition are governed by `match_scoring_weights_policy.md` (and the parallel reference doc `match_signal_weights.md`) — those docs disagree on the signal set; this policy is valid regardless of which wins the Stage-6 reconciliation flagged on BOOK-170, because it commits only to *how* a given fuzzy comparison is computed, not *which* signals exist.

---

## 1. Algorithm selection by signal type

Two fuzzy-string algorithms are used, chosen per signal based on input characteristics:

| Signal | Algorithm | Rationale | Defined in |
|---|---|---|---|
| Counterparty name (post-normalisation) | **Jaro-Winkler** similarity | Names are short, prefix-typo-tolerant, and same-entity variants share leading characters. Winkler's prefix-weighting is the right shape. | `match_signal_weights.md` |
| Invoice number / reference token | **Jaro-Winkler** similarity | Reference numbers are short alphanumerics; prefix similarity is meaningful. | `tool_matching_score_pair.md` §4.3 |
| Free-form description text | **Normalised Levenshtein** (edit-distance / max-length), blended with **Jaccard** on token sets | Descriptions are longer, multi-word, and order-sensitive only weakly; the Levenshtein + Jaccard blend balances character-level and token-overlap signals. | `match_scoring_weights_policy.md` §2 (`description_similarity`) |
| Reference exact-token | **Token exact match** (post-normalisation) | When an invoice number appears literally in the description, no fuzziness is wanted — match-or-not. | `tool_matching_score_pair.md` §4.3 |
| VAT number | **Exact match** after `vies_record_schema.md` normalisation (country prefix + spaces stripped) | VAT numbers are structured identifiers; fuzziness here would be a false-positive vector. | `match_signal_weights.md`; B11·P04 |
| IBAN | **Exact match on last-8-characters suffix** | IBAN formatting variants (spaces, casing) collapse on the account-number suffix. | `tool_matching_score_pair.md` §4.4 |

**Rule of thumb:** if the field is a short identifier or short name where character-level prefix typos are the failure mode, use Jaro-Winkler. If the field is multi-word free text where token re-ordering is plausible, use the Levenshtein + Jaccard blend. Exact-match wins when the field is structured (VAT, IBAN, literal invoice number).

---

## 2. Canonical threshold table

Single-source-of-truth for per-signal × algorithm × match-tier cutoffs. Origin doc cited for each row; tiers map to `match_level_enum` per `match_level_enum` reference.

### 2.1 Counterparty-name (Jaro-Winkler)

| Similarity | Signal value | Interpretation | Origin |
|---|---|---|---|
| `= 1.00` | `1.0` | Exact normalised match | `match_signal_weights.md` |
| `≥ 0.85` | `0.85` | Single typo or abbreviation | `match_signal_weights.md` |
| `≥ 0.70` | `0.60` | Same legal entity, different display form | `match_signal_weights.md` |
| `< 0.70` | `0.0` | No name match | `match_signal_weights.md` |

### 2.2 Reference / invoice-number (Jaro-Winkler, fuzzy path)

| Similarity | reference_score | Origin |
|---|---|---|
| Exact-token match (string equality) | `1.0` | `tool_matching_score_pair.md` §4.3 |
| `≥ 0.90` | `0.8` | `tool_matching_score_pair.md` §4.3 |
| `≥ 0.75` | `0.5` | `tool_matching_score_pair.md` §4.3 |
| `< 0.75` | `0.0` | `tool_matching_score_pair.md` §4.3 |

### 2.3 Description (Levenshtein + Jaccard blend)

`description_similarity = 0.60 × levenshtein_norm + 0.40 × jaccard_tokens`

| Component | Formula | Origin |
|---|---|---|
| `levenshtein_norm` | `1 - (edit_distance / max(len_a, len_b))` | `match_scoring_weights_policy.md` §2 |
| `jaccard_tokens` | `|A ∩ B| / |A ∪ B|` on tokenised word sets | `match_scoring_weights_policy.md` §2 |

The blend output (0.0–1.0) is the `description_similarity` signal value. The scoring engine consumes it without further thresholding — threshold-to-tier mapping happens at the composite-score level via `match_level_enum`.

### 2.4 Threshold pinning

These thresholds are Stage-1 defaults. Per-business override is deferred to Stage 2+ per `per_business_threshold_override_policy`. **Any change to these threshold values requires a `Docs/decisions_log.md` amendment.**

---

## 3. Normalisation pipeline

Applied **deterministically** to both inputs before any similarity computation. Same pipeline for every fuzzy signal — there are no signal-specific normalisation variants.

```
Input string
  → 1. Unicode NFC normalisation
  → 2. Lowercase fold (locale-independent; uses ICU `LowerCase` with `und` locale)
  → 3. Greek-specific fold:
        - Remove combining tonos (U+0301) and dialytika
        - Unify final-sigma ς (U+03C2) → σ (U+03C3)
  → 4. Punctuation strip: remove [.,;:'"!?()\[\]/\\&#@*+] (literal set)
  → 5. Whitespace collapse: any run of whitespace → single space; trim
  → 6. Legal-entity-suffix strip (token-level; see §3.1)
  → 7. Tokenisation: split on single space (for token-set / Jaccard paths)
Output: normalised string (for char-level) or normalised token list (for token-set)
```

Step ordering matters. NFC must precede lowercase (combining-marks behave differently after fold). Greek fold must precede general punctuation strip (the combining tonos U+0301 is technically not punctuation but must be removed by step 3, not step 4). Legal-entity suffix strip must precede tokenisation so the suffix is a single normalised token at strip time.

### 3.1 Legal-entity suffix list

Stripped as the trailing token when present (case-insensitive after step 2):

| Jurisdiction | Suffixes stripped |
|---|---|
| Cyprus | `ltd`, `limited`, `plc`, `holdings`, `lp`, `llc` |
| Greece (common in Cypriot trade) | `ae`, `αε`, `epe`, `επε`, `oe`, `οε`, `ee`, `εε`, `ike`, `ικε` |
| EU general | `gmbh`, `sa`, `srl`, `bv`, `nv`, `sarl`, `ab`, `as`, `oy` |
| UK general | `llp`, `cic` |

**Single-trailing-token rule:** strip exactly one token from the tail if it matches the list. Don't recurse — `"Foo Ltd PLC"` strips to `"Foo Ltd"`, not `"Foo"`. Rationale: cascading strip is more likely to amplify a typo than to canonicalise a real entity name.

Multi-word suffixes (`"co. ltd."` post-normalise to `"co ltd"`) are matched as a single trailing tuple by the strip step — `"Acme Co Ltd"` → `"Acme"`, not `"Acme Co"`. The list above is the exhaustive MVP set; additions require a decisions-log amendment.

---

## 4. Internationalisation considerations

Cyprus business names commonly mix Greek and Latin scripts within a single legal name (e.g., `"ΕΛΛΗΝΙΚΗ ΤΡΑΠΕΖΑ (Hellenic Bank Public Company Limited)"`). The fuzzy-match algorithm must not silently treat these as unrelated strings.

| Concern | Rule |
|---|---|
| Greek + Latin mixed-script in same name | Compare raw (post-step-5) strings; do NOT auto-transliterate Greek → Latin. Auto-transliteration would map `"ΤΡΑΠΕΖΑ"` to `"TRAPEZA"` which has no fuzzy-match relationship to `"BANK"` — the mapping would create false negatives. |
| Cyrillic input | Same: compared at raw post-NFC level. No script-aware fold. |
| Final-sigma variants ς vs σ | Unified at step 3 (always to σ). Required: Greek convention writes final-sigma only at word-end. |
| Combining-marks decomposition | NFC at step 1; do NOT use NFD (would split `"Νικολάου"` into base + combining tonos with separate code points; downstream similarity would over-count differences). |
| VAT-number country prefix | Stripped in `vies_record_schema.md` normalisation path, NOT here. The fuzzy pipeline only sees the post-VIES-normalisation form. |
| Locale-aware case folding | Always `und` (locale-independent) ICU `LowerCase`. Turkish-locale fold of `"İ"` to `"i"` is intentionally NOT used — would create false positives across non-Turkish entities. |
| Right-to-left (Arabic, Hebrew) | Out of scope in MVP (Cyprus business landscape has negligible RTL). Defer to Stage 2+ if RTL businesses onboard. |

The principle: when in doubt, **preserve script and compare raw**. Auto-transliteration is harder than no transliteration; the wrong choice creates silent false-positive matches that are forensically expensive to unwind.

---

## 5. Algorithm parameter pinning

| Parameter | Value | Source |
|---|---|---|
| Jaro-Winkler prefix-weight `p` | `0.1` | Winkler 1990 default; widely-used standard |
| Jaro-Winkler max-prefix-length `L` | `4` characters | Standard cap; longer prefixes overweight prefix vs. body |
| Levenshtein insert / delete / substitute costs | `1.0` / `1.0` / `1.0` | Symmetric unit costs (no transposition heuristic) |
| Input upper-bound per string | `200` characters | DoS guard; strings beyond bound are right-truncated at step 5 output, then compared. Truncation does NOT reject input — the comparison is still computed against the truncated form. |
| Per-pair fuzzy-call latency budget | `< 1` ms | Sub-budget of the `< 5` ms / pair scoring budget in `tool_matching_score_pair.md` §10 |

Implementation: prefer the Postgres `pg_similarity` extension's `jarowinkler` and `levenshtein` functions when available. The `levenshtein_less_equal(s1, s2, max_distance)` early-exit variant is used by performance-sensitive call sites to short-circuit obviously-distant pairs.

---

## 6. Edge cases

| Input shape | Output |
|---|---|
| Both strings empty (post-normalisation) | `1.0` (degenerate match — both null-equivalent) |
| One empty, one non-empty | `0.0` |
| NULL inputs | `0.0` (never NULL-similarity; callers receive a deterministic zero) |
| Identical post-normalisation, different raw | `1.0` (the normalisation pipeline is the equivalence relation) |
| Single-token vs multi-token | Use Jaccard wrapper for token-set paths; character-level algorithms operate on the post-step-5 single-string form. |
| Repeated tokens (e.g., `"Acme Acme Ltd"`) | Token-set Jaccard uses sets (not multisets); duplicates collapse before union/intersection |
| Whitespace-only after strip | Treated as empty (apply the both-empty / one-empty rules above) |

---

## 7. Determinism and performance

Per `tool_matching_score_pair.md` §8, fuzzy-similarity computations are part of the deterministic-tool guarantee:

- Same inputs + same algorithm pinning + same locale (always `und`) → same output, bit-exact.
- No PRNG, no clock reads, no environment variable lookups inside the similarity path.
- Vendor-memory and other point-in-time reads happen at the scoring orchestrator level, not inside the fuzzy-match call.
- The breakdown payload on `MATCHING_PAIR_SCORED` audit events (per `tool_matching_score_pair.md` §7) includes the algorithm marker per signal (e.g., `vendor_score_algo: "jaro_winkler"`, `description_score_algo: "levenshtein_jaccard_blend"`) for forensic reproducibility. Threshold values are NOT included in the payload (would inflate every audit row); they're recoverable from this policy doc keyed by `scoring_config_id`.

Performance budget per algorithm call: see §5. Aggregate scoring budget per pair: `< 5` ms (`tool_matching_score_pair.md` §10).

---

## 8. Audit semantics

Fuzzy-match algorithm calls do **NOT** emit per-call audit events. They are pure inner functions of the scoring tool. The parent `matching.score_pair` emits one `MATCHING_PAIR_SCORED` event per pair containing the breakdown and the algorithm markers (see §7).

Threshold-change events go through `MATCHING_SCORING_CONFIG_UPDATED` (per `match_scoring_weights_policy.md` §5) when per-business overrides are introduced (Stage 2+). Default-threshold changes go through `Docs/decisions_log.md`.

---

## 9. Stage-6 reconciliation note (BOOK-170 cross-link)

The KG triple `match_signal_weights_drift → stage6_action_required → verify live B10 engine model` (filed 2026-05-26) records a material disagreement between `match_scoring_weights_policy.md` (5-signal model) and `match_signal_weights.md` (6-signal model). **This policy is decoupled from that drift** — it commits to the *algorithm* axis only:

- Whichever signal model wins reconciliation, the algorithm choice per signal type stays as documented in §1.
- Whichever signal weights win, the thresholds in §2 stay tied to the *signal*, not to its weight.
- The normalisation pipeline (§3) and i18n rules (§4) are signal-agnostic and apply uniformly.

If Stage-6 reconciliation merges signal `description_similarity` with `counterparty_name + reference` (or some other re-decomposition), the algorithm-selection table in §1 needs an additive row, not a rewrite.

---

## 10. Cross-references

- `match_scoring_weights_policy.md` — final-score formula; per-business weight overrides; `MATCHING_SCORING_CONFIG_UPDATED`
- `match_signal_weights.md` — 6-signal reference; counterparty-name threshold origin
- `tool_matching_score_pair.md` — implementation tool; breakdown schema; algorithm markers per signal
- `match_signal_evidence_schema.md` — persisted evidence payload for replay
- `vendor_signature_normalization` (Block 08) — recurring-vendor canonical form
- `vies_record_schema.md` — VAT-number normalisation (country prefix + spaces)
- `data_layer_conventions_policy.md` — Unicode NFC commitment for stored strings; locale-independent case-fold rule
- `match_level_enum` — composite-score → tier mapping
- `per_business_threshold_override_policy` — Stage 2+ override path
- Block 10 Phase 02 — match scoring engine (architecture)
- Block 10 Phase 03 — auto-confirm rule (consumes tier produced via these algorithms)
- Stage 1 decision — fuzzy-match algorithm choice for Cyprus business names
