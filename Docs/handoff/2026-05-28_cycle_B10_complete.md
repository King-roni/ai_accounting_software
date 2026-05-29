# Cycle B10 (Matching Engine) — complete

**Date:** 2026-05-28
**Cycle UUID:** `2b0d88ce-3bf2-4e9c-b9fe-91d91fe08985`
**Final state:** 45/45 total · 45 done · **0 backlog** · 0 cancelled
**Sessions consumed:** 2 (2026-05-26..27 prior session for BOOK-164..211 partial + 2026-05-28 closeout)

Per-cycle wrap-up. Punch list of cross-block coordination items for downstream consumers (B05·P02 taxonomy, B11 ledger, B13 invoice generator, B14 review queue).

---

## 1. This session closed 12 tickets

| Ticket | Disposition | Output |
|---|---|---|
| BOOK-213 | verify + 5 Stage-6 drifts | `match_reason_prompt.md`: TIER drift / char-limit / fallback / output-schema / signal-vocab |
| BOOK-215 | **WRITE** | `match_reason_sample_output_corpus.md` (~270 lines) |
| BOOK-217 | **WRITE** | `match_reason_regeneration_audit_policy.md` (~280 lines, 4 triggers + history table) |
| BOOK-218 | **WRITE** | `income_matching_signal_weighting.md` (~190 lines, ref-field=0.35 dominant) |
| BOOK-220 | **WRITE** | `partial_payment_minimum_threshold_policy.md` (~180 lines, 5% floor + 6 edge cases) |
| BOOK-223 | verify + 3 Stage-6 drifts | `tool_invoice_lifecycle_integration.md`: enum-naming / missing-ONE_INVOICE_MULTIPLE_PAYMENTS / casing |
| BOOK-225 | **WRITE** | `refund_detection_rule_policy.md` (~210 lines, 2 trigger signals + 3 user paths) |
| BOOK-228 | **WRITE** | `matching_tools_io_schemas.md` (~190 lines, full JSONSchema for 5 tools) |
| BOOK-229 | **WRITE** | `matching_phase_definitions.md` (~180 lines, name-not-index cross-block contract) |
| BOOK-231 | **WRITE** | `matching_cross_product_performance.md` (~180 lines, 25ms/pair + 3 safety valves) |
| BOOK-233 | verify-only | `ai_response_recording_fixtures.md` — canonical |
| BOOK-234 | verify + coverage gap | `matching_per_fixture_content.md`: 5 of 25+ fixtures (Stage-6 expansion) |

**Prior session this cycle** closed 33 tickets via BOOK-164..211 + Stage-2 phase tickets BOOK-86..95. Total 45 cycle tickets DONE.

---

## 2. Cross-block coordination — punch list by consumer

### 2.1 B05·P02 taxonomy — many new events / payload-field verifications

| Event | Severity | Source |
|---|---|---|
| `MATCHING_PARTIAL_THRESHOLD_CHANGED` | MEDIUM | BOOK-220 §6 |
| `MATCHING_CANDIDATE_EXPLOSION` | HIGH | BOOK-231 §5.1 |
| `MATCHING_RUN_TOO_LARGE` | BLOCKING | BOOK-231 §5.2 |
| `MATCHING_RUN_CAP_OVERRIDDEN` | HIGH | BOOK-231 §5.2 |
| `INCOME_MATCHING_OUTCOME_POSSIBLE_REFUND_OR_TRANSFER` | MEDIUM | BOOK-225 §4 |
| `INCOME_MATCHING_FALSE_POSITIVE_DISMISSED` | LOW | BOOK-225 §5.1 |
| `INCOMING_RECLASSIFIED_AS_REFUND` | MEDIUM | BOOK-225 §5.2 |
| `INCOMING_RECLASSIFIED_AS_INTERNAL_TRANSFER` | MEDIUM | BOOK-225 §5.3 |
| `TOOL_INPUT_SCHEMA_VIOLATION` | MEDIUM | BOOK-228 §7 |
| `TOOL_OUTPUT_SCHEMA_VIOLATION` | HIGH | BOOK-228 §7 |

**Payload-field verifications:**
- `MATCH_PROPOSED`: add `weighting_profile ∈ {OUT_EXPENSE, IN_INCOME}` field (BOOK-218 §4)
- `MATCHING_REASON_REGENERATED`: 11-field payload (BOOK-217 §4)
- `NO_MATCH` outcome: add `below_partial_threshold_count` forensic field (BOOK-220 §5)
- `*_PHASE_COMPLETED`: per-status-counts payload field (BOOK-229)

### 2.2 B10·P07 migration — match-reason history infra (BOOK-217)

- `match_reason_history` table + `match_reason_trigger_enum` (4 values: USER_SIGNAL_EDIT, SCHEMA_MIGRATION_RESCORE, PROMPT_VERSION_BUMP, FALLBACK_REGENERATE_REQUESTED) + 1 index
- `matching.regenerate_reason(match_id uuid, trigger text)` SECURITY DEFINER RPC implementing 5-step atomic swap

### 2.3 B10·P08 migration — matching settings (BOOK-220)

- `business_settings.matching_partial_payment_threshold_pct numeric(4,3) NOT NULL DEFAULT 0.050` with CHECK [0.000, 0.500]

### 2.4 B11 ledger — reconciliation logic for refund / internal transfer (BOOK-225)

- Refund (§5.2): refund reverses original expense's ledger impact
- Internal transfer (§5.3): net-zero across two own-account ledger lines (debit one, credit other)
- Bidirectional FK links: `transactions.refund_received_against_id` + `transactions.transfer_pair_id` columns (verify exist)

### 2.5 B13 invoice generator

- **`recurring_client_bank_info` table** — verify exists or schedule creation (BOOK-218 §2.2 IBAN-history-boost)
- **`invoices.total_eur_minor > 0` CHECK constraint** — Stage-6 schema-hardening (BOOK-220 §3.5)
- **Lifecycle function name resolution** — Stage-6 reconcile snake_case (`in_workflow.mark_invoice_paid`) vs CamelCase (`invoice.markPaid`) per BOOK-223 drift queue
- **Outcome enum reconciliation** — add `ONE_INVOICE_MULTIPLE_PAYMENTS` row to tool_invoice_lifecycle_integration mapping (BOOK-223 drift)

### 2.6 B14 review queue — new issue types + UI features

| Item | Source |
|---|---|
| `MATCHING_RUN_TOO_LARGE` blocking-severity review issue with 3 user-action paths (split-run / Owner-override / cancel) | BOOK-231 §5.2 |
| Phase-level progress indicator with estimated completion time (`pairs_remaining × 25ms_p95`) | BOOK-231 §4 |
| `MATCHING_CANDIDATE_EXPLOSION` HIGH review issue | BOOK-231 §5.1 |
| `INCOMING_LIKELY_REFUND_OR_TRANSFER` MEDIUM review issue + 3-action card | BOOK-225 §3 |
| `INTERNAL_TRANSFER_PAIR_MISSING` LOW review issue | BOOK-225 §5.3 |
| `AUTO_RESOLVED_BY_RESCAN` resolution action triggered when FALLBACK_REGENERATE_REQUESTED succeeds | BOOK-217 §8 |
| Reason-history disclosure card (per-user expanded state) gated by `MATCHING_AUDIT_VIEW` surface | BOOK-217 §7 |

### 2.7 B02·P11 settings UI

- Matching-settings section needs `partial_payment_threshold_pct` control with [0%, 50%] slider + audit-event preview (BOOK-220 §6)

### 2.8 Block 12 + Block 13 decompositions

- Block 12 OUT_MONTHLY: register `MATCHING` phase at correct sequence position; entry-gate inheriting from EVIDENCE_DISCOVERY completion (BOOK-229)
- Block 13 IN_MONTHLY: register `INCOME_MATCHING` phase at correct sequence position; entry-gate inheriting from CLASSIFICATION completion (BOOK-229)
- **Both reference phases by NAME not by INDEX** per BOOK-229 §5 durable contract

### 2.9 B06·P10 AI layer test harness

- `ai.invoke` mocking primitives that can return canned responses + simulate 4 failure categories at gateway boundary (consumed by BOOK-215 fallback samples)

### 2.10 Permission matrix

- `MATCHING_SETTINGS_EDIT` surface registration (BOOK-220 §6 step-up requirement)
- `MATCHING_AUDIT_VIEW` surface registration (BOOK-217 §7 reason-history disclosure)

---

## 3. Stage-6 drift queue additions from this cycle

### B10 5-way scoring docs drift (existing — multiple new entries)

| Drift | Source |
|---|---|
| **Tier classification (CRITICAL)** — match_reason_prompt declares `TIER_1` bypass; phase doc says Tier 2 default + Tier 3 escalation on cross-currency/cross-period/ambiguous | BOOK-213 |
| **Match-level enum 3-way** — numeric 1-4 (phase) vs EXACT/STRONG_PROBABLE/WEAK_POSSIBLE (match_signal_weights) vs STRONG_MATCH/PROBABLE_MATCH/WEAK_MATCH (other docs) | BOOK-213 + multiple prior |
| **Output char-limit** — 200 (match_reason_prompt) vs 300 (phase doc) | BOOK-213 |
| **Output schema** — `{reason_text, confidence}` (match_reason_prompt) vs single string via generatePlainLanguage (phase) | BOOK-213 |
| **Fallback template** — simple template (match_reason_prompt) vs per-level structured strings + LOW review issue + Regenerate action (phase) | BOOK-213 |
| **Signal-name vocabulary** (already in queue from prior session) | BOOK-210 / BOOK-213 |

### tool_invoice_lifecycle_integration drift

| Drift | Source |
|---|---|
| **Outcome enum naming** — FULL_PAYMENT/OVERPAYMENT_PRIMARY/SURPLUS (tool) vs FULL_MATCH/OVERPAYMENT (phase); tool splits overpayment into 2 sub-values | BOOK-223 |
| **Missing ONE_INVOICE_MULTIPLE_PAYMENTS** — tool doc lacks the 7th outcome value | BOOK-223 |
| **Function-name casing** — snake_case `in_workflow.mark_invoice_paid` (tool) vs CamelCase `invoice.markPaid` (phase) | BOOK-223 |

### matching_per_fixture_content coverage gap

| Gap | Source |
|---|---|
| **5 fixtures of 25+ required** — 20 fixtures missing across 7 of 8 categories required by phase doc B10·P10 | BOOK-234 |

---

## 4. Stage-6 doc-write candidates surfaced this cycle

- `audit_event_kind_display_strings.md` (carried over from B02 wrap-up) — also consumed by BOOK-217 §7
- `runbook_high_volume_rescore.md` — consumed by BOOK-217 §8 for off-peak batch rescore
- `out_refund_propagation_runbook.md` — consumed by BOOK-225 §5.2

---

## 5. New anchor docs introduced this cycle

Cycle B10 doesn't produce as many fresh anchor docs as B02 (most of B10's anchors were established in the prior session — BOOK-188 split-payment-bounds, BOOK-198 dedup-ownership). The new docs are tactical implementations of the anchor patterns:

- **`match_reason_regeneration_audit_policy.md`** (BOOK-217) — anchor for reason-history preservation; consumed by all downstream regeneration paths
- **`matching_phase_definitions.md`** (BOOK-229) — phase-by-name cross-block contract; consumed by Block 12 + Block 13 decompositions

---

## 6. Next cycle in execution order

Per Stage-3 execution order in project-meta drawer: **B03 (Workflow Engine)** next, with 43 backlog tickets.

Cycle B03 UUID: `430809b2-3204-4401-8bf9-833c7e2de000`

Pickup checklist for next session:
1. Load project-meta drawer + 2026-05-28 handoff + this wrap-up + Cycle B02 wrap-up
2. `retrieve_cycle` on Cycle B03 UUID
3. List Cycle B03 backlog tickets (filter by state `06b2fd3b-5d0c-486a-9a37-fe086b725315`)
4. Pick lowest sequence_id; proceed per cadence

Notable upcoming risk: B03 contains the workflow runner per BOOK-221's GUC-dispatch contract — B03·P02 implementation must honor the `SET LOCAL app.principal_context_json` same-tx rule.

---

## 7. Cadence reminder

Unchanged from 2026-05-28 handoff:

- Easy verify-only: 5-10 per turn, batched, one-line DoD
- Verify-only with drift: 3-5 per turn, terser comments  
- Routine write-required: write directly, ~120-180 lines / 8-10 sections, NO propose-wait
- Novel write-required (anchor): keep propose-wait, ~180-280 lines / 10 sections max

Cross-references are LOAD-BEARING. Quality is KING. Speed is secondary.

---

## 8. KG triples filed for this wrap-up

- `cycle_b10` → `completed_at` → 2026-05-28 (45/45 done, 0 backlog)
- `cycle_b10` → `wrap_up_doc` → this doc path
- `cycle_b10` → `cross_block_items` → 25+ across §2.1-§2.10
- `stage3_next_action` → `resume_at` → Cycle B03 Workflow Engine (UUID 430809b2-3204-4401-8bf9-833c7e2de000); 43 backlog

End of cycle. Move to Cycle B03 when ready.
