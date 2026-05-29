# Block 11 — Phase 05: VAT Treatment Classifier (Rules-First; Eight Treatments)

## References

- Block doc: `Docs/blocks/11_ledger_and_cyprus_vat_engine.md` (The Eight VAT Treatments; Compliance Fields per Ledger Entry)
- Block doc: `Docs/blocks/01_core_principles.md` (Principle 3 — AI Assists, Rules Decide; AI never picks a VAT treatment)
- Block doc: `Docs/blocks/06_ai_layer.md` (Phase 10 — plain-language pipeline; consumed for VAT *explanation*, never for selection)

## Phase Goal

Pick exactly one of the eight VAT treatment values per draft ledger entry, deterministically, from the inputs Phases 01/04/07 have already populated. The classifier is rules-only — AI is invocable for *explanation* via Block 06 Phase 10, but never for choosing the treatment. Cases that rules cannot decide land on `UNKNOWN` with `requires_accountant_review = true` and a structured reason, surfaced in Phase 08.

## Dependencies

- Phase 01 (`draft_ledger_entries.vat_treatment`, `requires_accountant_review`, `accountant_review_reason`)
- Phase 04 (`counterparty_country`, `counterparty_vat_number` resolved upstream)
- Phase 07 (calls into this phase per ledger entry — the classifier is invoked once per `draft_ledger_entries` row of `entry_kind = PRIMARY`)
- Block 02 Phase 01 (per-business profile — own country, own VAT registration status, own VAT number)
- Block 08 Phase 05 (tag taxonomy — service-vs-goods and digital-services flags drive specific branches)
- Block 09 Phase 04 (extracted document fields — service-nature flags surfaced via tags)

## Deliverables

- **The eight VAT treatment values** (closed enum; matches the architecture-doc list verbatim):
  - `DOMESTIC_CYPRUS_VAT`
  - `EU_REVERSE_CHARGE`
  - `NON_EU_SERVICE`
  - `EXEMPT`
  - `NO_VAT`
  - `OUTSIDE_SCOPE`
  - `IMPORT_OR_ACQUISITION`
  - `UNKNOWN`
- **`classifyVatTreatment(draft_entry, business_profile, transaction, match_record?) → ClassificationResult`:**
  - Returns `{ treatment: one_of_eight, decided_by_rule_id, supporting_signals: { ... }, requires_accountant_review: boolean, accountant_review_reason: string | null }`.
  - **Rules-only**, deterministic, total over the input space — every input combination resolves to exactly one treatment (with `UNKNOWN` as the residual).
  - **Idempotent**: same inputs (including any persisted `manual_override_*` fields) always produce the same `ClassificationResult`. The classifier reads `manual_override_*` from the entry as just another deterministic input — no clock-dependent or stateful inputs.
- **Rule organisation** (Stage 1 ships representative rules; sub-doc enumerates the full Cyprus-aligned set):
  - **Pre-checks (apply to all treatments; ordered):**
    - **Manual override short-circuit** — if the in-progress entry carries `manual_override_by IS NOT NULL` AND `manual_override_at` post-dates the most recent automatic classifier run, the classifier returns the override `vat_treatment` directly with `decided_by_rule_id = 'MANUAL_OVERRIDE'` and emits `LEDGER_VAT_TREATMENT_HONORED_MANUAL_OVERRIDE` instead of `LEDGER_VAT_TREATMENT_DECIDED`. No further rules evaluate. The override persists across re-runs until cleared per Phase 08's clear-override path.
    - If business is **not VAT-registered**, treatment defaults to `NO_VAT` for all OUT-side entries and `OUTSIDE_SCOPE` for IN-side, regardless of counterparty (sub-doc tunes the IN-side default).
    - If `counterparty_country` is `UNRESOLVED` (Phase 04 returned null), treatment is `UNKNOWN` with reason `"Counterparty country could not be determined."`.
  - **OUT-side (expense / payment outgoing) rules** — applied in priority order; first hit wins:
    - **OUT-1 — Domestic Cyprus VAT:** `business.country = CY` AND `counterparty_country = CY` AND counterparty is VAT-registered (VAT number present and format-valid per Phase 04) → `DOMESTIC_CYPRUS_VAT`.
    - **OUT-2 — EU Reverse Charge (B2B services from EU supplier):** `business.country = CY` AND `counterparty_country` is in EU member-state set AND `counterparty_country != CY` AND counterparty has a valid VAT number AND tag implies services (or default-services for transaction type `OUT_EXPENSE` with no goods-tag) → `EU_REVERSE_CHARGE`.
    - **OUT-3 — Import / Acquisition (EU goods):** same as OUT-2 but tag implies goods → `IMPORT_OR_ACQUISITION`.
    - **OUT-4 — Non-EU service:** `counterparty_country` is non-EU AND service tag → `NON_EU_SERVICE`.
    - **OUT-5 — Non-EU import:** `counterparty_country` is non-EU AND goods tag → `IMPORT_OR_ACQUISITION`.
    - **OUT-6 — Exempt categories:** the entry's mapped expense category appears in the exempt list (financial services, certain healthcare/education categories — sub-doc enumerates) → `EXEMPT`.
    - **OUT-7 — Outside scope:** transaction type implies non-VAT-relevant movement (`INTERNAL_TRANSFER`, `LOAN_OR_SHAREHOLDER_MOVEMENT`, `TAX_PAYMENT`, `BANK_FEE` for fees that fall outside scope) → `OUTSIDE_SCOPE`.
    - **OUT-8 — No VAT (residual):** counterparty is domestic Cyprus but **not** VAT-registered (no valid VAT number) → `NO_VAT`.
    - **OUT-residual:** none of the above fired with definite signals → `UNKNOWN` with reason `"VAT treatment rules could not select a definite branch."`.
  - **IN-side (income / receipt) rules** — applied in priority order:
    - **IN-1 — Domestic Cyprus VAT:** business VAT-registered, client country `CY`, business issues a VAT-charging invoice (Block 13 owns the invoice creation; this phase reads the invoice's stated treatment when present) → `DOMESTIC_CYPRUS_VAT`.
    - **IN-2 — EU B2B reverse charge (service to EU customer):** client country in EU, client has a **format-valid** VAT number (per Phase 04's canonicalisation), service tag → `EU_REVERSE_CHARGE` (and `vies_relevant = true` — see Phase 06).
    - **IN-2-residual** — same shape but the client VAT number is missing or format-invalid → `UNKNOWN` with `requires_accountant_review = true` and `accountant_review_reason = "EU IN-side reverse-charge plausible but counterparty VAT number is missing or invalid; cannot fire IN-2 definitively."` This routes the case to the review queue rather than producing a half-set EU_REVERSE_CHARGE entry that Phase 06 would have to flag as `vies_relevant = false`. Keeps Phase 06's `reverse_charge_relevant` and `vies_relevant` aligned for IN-side cases.
    - **IN-3 — Non-EU service export:** client country non-EU, service tag → `NON_EU_SERVICE`. Treated as **zero-rated export of services** for Cyprus VAT — reportable on the VAT return as zero-rated supplies, NOT on VIES (Phase 06's `vies_relevant` is `false` for `NON_EU_SERVICE`). Distinct from `OUTSIDE_SCOPE`, which is reserved for non-VAT-relevant movements (transfers, loan disbursements, etc.) and is not reportable on the VAT return at all. Sub-doc enumerates the Cyprus zero-rated-vs-outside-scope criteria.
    - **IN-4 — Exempt:** category exempt → `EXEMPT`.
    - **IN-5 — Outside scope:** non-revenue inflows (refunds, intra-group transfers, loan disbursements) → `OUTSIDE_SCOPE`.
    - **IN-residual:** → `UNKNOWN`.
- **Tag-mismatch detection (review-flag trigger):**
  - When the rule fires definitively but the transaction's tag set contradicts the inferred branch (e.g., the rule picked `NON_EU_SERVICE` but the tag says "physical-goods-import"), the treatment stays as the rule chose, but `requires_accountant_review = true` with reason text identifying the mismatch.
- **AI-explanation handoff (Phase 09 wires this; specified here for contract clarity):**
  - `classifyVatTreatment` itself never calls AI. The AI-explanation pipeline is invoked separately by Phase 07's `ledger.generate_vat_explanations` (registered in Phase 09) per finished entry, calling `generatePlainLanguage('VAT_TREATMENT_EXPLANATION', { treatment, decided_by_rule_id, supporting_signals })` from Block 06 Phase 10.
  - The explanation is stored on the draft entry (sub-doc names the column; canonical: `vat_treatment_explanation`).
  - **Failure handling for the explanation call** mirrors Block 10 Phase 07's pattern — on AI failure, a deterministic structured-fallback string is written, full structured signals retained, `LEDGER_VAT_EXPLANATION_FALLBACK_APPLIED` audit event emitted, LOW review issue raised; the run continues. This phase declares the contract; Phase 09 wires the failure path.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `LEDGER`):
  - `LEDGER_VAT_TREATMENT_DECIDED` (with `treatment`, `decided_by_rule_id`, `requires_accountant_review` flag)
  - `LEDGER_VAT_TREATMENT_HONORED_MANUAL_OVERRIDE` (manual-override short-circuit fired)
  - `LEDGER_VAT_TREATMENT_UNKNOWN_RAISED` (residual / unresolved)
  - `LEDGER_VAT_TREATMENT_TAG_MISMATCH_DETECTED`
  - `LEDGER_VAT_EXPLANATION_GENERATED` (with tier used; emitted by Phase 09's tool — declared here for contract closure)
  - `LEDGER_VAT_EXPLANATION_FALLBACK_APPLIED`

## Definition of Done

- The classifier is total: every test fixture lands on exactly one of the eight values.
- A domestic-Cyprus B2B expense with a valid CY VAT number resolves to `DOMESTIC_CYPRUS_VAT`.
- An EU-supplier service expense with valid VAT number resolves to `EU_REVERSE_CHARGE`.
- An EU-supplier goods purchase resolves to `IMPORT_OR_ACQUISITION`.
- A non-VAT-registered business gets `NO_VAT` for OUT entries.
- An unresolved counterparty country produces `UNKNOWN` with the right reason text.
- Tag mismatch raises `requires_accountant_review` while keeping the rule's treatment.
- Re-running the classifier with identical inputs produces an identical `ClassificationResult`.
- AI never appears in the classification path; only in the explanation path.
- Tests cover: each of the eight treatments + tag mismatch + unresolved counterparty + non-VAT-registered business.

## Sub-doc Hooks (Stage 4)

- **Cyprus VAT rule catalog sub-doc** — the full ordered rule set, exact priority numbers, exempt-category list, current Cyprus VAT references.
- **EU member-state set sub-doc** — the closed list as of Stage 1 freeze + maintenance procedure.
- **VAT rate table sub-doc** — Cyprus standard / reduced / zero rates; mid-period rate change handling (deferred Stage 1 item). **Shared with Phase 08** — single Stage 4 sub-doc serves both phases.
- **Service-vs-goods tag derivation sub-doc** — how tags collapse to service/goods branches; ambiguous cases.
- **VAT-explanation prompt design sub-doc** — system + user prompt for `VAT_TREATMENT_EXPLANATION`, sample outputs per treatment.
- **Rule-priority calibration sub-doc** — how new rules are inserted; conflict resolution; A/B testing methodology.
