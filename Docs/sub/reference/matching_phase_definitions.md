# matching_phase_definitions

**Category:** Reference · **Owning block:** 10 — Matching Engine · **Co-owners:** 12 — OUT Workflow + 13 — IN Workflow · **Stage:** 4 sub-doc (Layer 1 cross-block phase contract)

The **canonical phase-name definitions** for `MATCHING` (phase of `OUT_MONTHLY`) and `INCOME_MATCHING` (phase of `IN_MONTHLY`). Block 12 and Block 13 reference these definitions by **phase name** (not phase index); the integer phase index is owned by each workflow's decomposition and may change without breaking the contract.

This doc is the durable cross-block contract: matching's phase is what it says it is, regardless of where Block 12 or Block 13 chooses to slot it numerically.

---

## 1. The two phases

| Phase name | Workflow | Owning block | Index ownership | Co-consumer |
|---|---|---|---|---|
| `MATCHING` | `OUT_MONTHLY` | Block 10 | Block 12 (decomposition) | — |
| `INCOME_MATCHING` | `IN_MONTHLY` | Block 10 (variant) | Block 13 (decomposition) | Block 13 (invoice lifecycle) |

Both phases share the same scoring engine (Phase 02) and the same matching tools (per `matching_tools_io_schemas.md`). The variants differ in candidate sets (documents for OUT; invoices for IN) and weights (`OUT_EXPENSE` vs `IN_INCOME` per `income_matching_signal_weighting.md`).

---

## 2. `MATCHING` (OUT side)

### Purpose

For every unmatched OUT transaction × every candidate document within the cross-period window, score the pair, suppress rejection-memory hits, apply auto-confirm rules, write `match_records` rows. Run split-payment combinatorial detection on residual unmatched transactions. Run duplicate detection at phase exit. Generate plain-language reasons for all new match records.

### Tool sequence

1. `matching.score_pair` (per pair × per candidate document)
2. `matching.detect_split_payments` (side = `OUT`)
3. `matching.detect_duplicates` (Patterns A + B)
4. `matching.generate_reasons`

### Entry gate

```
EVIDENCE_DISCOVERY phase (Block 09's email/Drive finder) COMPLETE
AND OUT_EXPENSE transactions present for the run period
AND candidate documents present for the run period
```

If the entry gate fails, the phase does not start; the run holds at the prior phase. Workflow engine's gate-check rules per Block 03 Phase 05.

### Exit gate

```
ALL OUT_EXPENSE transactions for the run period have match_status ∈ {EXACT, STRONG_PROBABLE_AUTO_CONFIRMED, MATCHED_NEEDS_CONFIRMATION, NO_MATCH, REJECTED}
AND duplicate-detection pass complete (Patterns A + B both ran)
AND all newly-created match_records have non-NULL match_reason_plain_language (either AI or fallback)
```

If the exit gate fails, the phase holds; review-queue issues from the duplicate detection or split-payment proposals surface and block advance until user resolves.

### Audit events

- `MATCHING_PHASE_STARTED` (LOW)
- `MATCHING_PHASE_COMPLETED` (LOW) with per-status counts in payload
- `MATCHING_PHASE_HOLDING` (MEDIUM) when an exit-gate failure holds the phase

---

## 3. `INCOME_MATCHING` (IN side)

### Purpose

For every IN-side transaction × every candidate `Invoice` record, run `matching.income_match_outcome` which internally invokes the same scoring engine with IN-side weights. Apply the 7-value income-outcome enum. Call Block 13's invoice-lifecycle functions per the outcome → function mapping at `tool_invoice_lifecycle_integration.md`. Detect IN-side split-payment cases (`MULTIPLE_INVOICES_ONE_PAYMENT`). Detect duplicates (IN-side equivalents of Patterns A + B). Generate plain-language reasons.

### Tool sequence

1. `matching.income_match_outcome` (per transaction)
2. `matching.detect_split_payments` (side = `IN`)
3. `matching.detect_duplicates` (Patterns A + B, IN-side variants)
4. `matching.generate_reasons`

### Entry gate

```
CLASSIFICATION phase (Block 08's) COMPLETE for the IN-side transactions
AND IN-side transactions present for the run period
AND active Invoice records exist (status ∈ {SENT, PAYMENT_EXPECTED, PARTIALLY_PAID, OVERPAID} per phase doc B10·P08)
```

The "no active invoices" case does NOT block the entry gate — incoming transactions can still match against (none) and surface as `NO_MATCH` or `POSSIBLE_REFUND_OR_TRANSFER`. The gate requires only that the transactions side is populated.

### Exit gate

```
ALL IN-side transactions for the run period have match_status set
AND every affected invoice has its lifecycle status correctly updated (via Block 13's lifecycle functions)
AND duplicate-detection pass complete
AND all newly-created match_records have non-NULL match_reason_plain_language
```

The "lifecycle status correctly updated" sub-condition is delegated to Block 13's lifecycle functions — they return success/failure per `tool_invoice_lifecycle_integration.md` and the matching tool either records the success or holds the phase per the lifecycle-failure path.

### Audit events

- `INCOME_MATCHING_PHASE_STARTED` (LOW)
- `INCOME_MATCHING_PHASE_COMPLETED` (LOW) with per-outcome counts in payload
- `INCOME_MATCHING_PHASE_HOLDING` (MEDIUM)

---

## 4. The shared invariants

Both phases honour these contracts:

| Invariant | Source |
|---|---|
| Tool side-effects declared up front (`WRITES_RUN_STATE`) | `tool_side_effect_taxonomy.md` |
| Replay idempotency (same inputs → same outputs) | Tool implementation; verified by replay tests |
| Step-up not required (matching is a phase, not a settings change) | `permission_matrix.md` |
| Phase principal-context snapshot is the run's snapshot (not live) | `role_change_propagation_policy.md` (BOOK-221) §3 |
| AI fallback is graceful (placeholder reason; LOW-severity review issue; run continues) | `match_reason_regeneration_audit_policy.md` (BOOK-217) + Phase 07 failure handling |
| Cross-period look-back applies (1-2 month window for OUT; asymmetric +30/-60d for IN) | `match_signal_weights.md` (OUT) + `income_matching_signal_weighting.md` (IN) §2.3 |

---

## 5. Phase-name binding

Block 12 and Block 13 reference the phases by name in their `workflow_definitions.phase_sequence` JSONB:

```jsonc
// Block 12 OUT_MONTHLY decomposition (illustrative)
{
  "workflow_type": "OUT_MONTHLY",
  "phase_sequence": [
    {"name": "STATEMENT_INTAKE",     "index": 1, "owner": "block_07"},
    {"name": "CLASSIFICATION",       "index": 2, "owner": "block_08"},
    {"name": "EVIDENCE_DISCOVERY",   "index": 3, "owner": "block_09"},
    {"name": "MATCHING",             "index": 4, "owner": "block_10"},   // ← THIS DOC's phase
    {"name": "LEDGER_DRAFT",         "index": 5, "owner": "block_11"},
    {"name": "REVIEW",               "index": 6, "owner": "block_14"},
    {"name": "FINALIZATION",         "index": 7, "owner": "block_15"}
  ]
}
```

If Block 12's decomposition later inserts a phase before MATCHING (e.g., a new validation step), MATCHING's `index` becomes `5` — but its `name` remains `MATCHING`. The workflow engine identifies phases by name, not index, in all cross-phase coordination paths.

This is the durable contract: **phase name is the cross-block identity; phase index is a per-workflow numbering choice**.

---

## 6. Cross-block coordination flagged

- **Block 12 decomposition:** must register `MATCHING` as a phase of `OUT_MONTHLY` at the correct sequence position. Entry gate inheriting from EVIDENCE_DISCOVERY completion.
- **Block 13 decomposition:** must register `INCOME_MATCHING` as a phase of `IN_MONTHLY` at the correct sequence position. Entry gate inheriting from CLASSIFICATION completion.
- **B05·P02 taxonomy:** 6 phase events (MATCHING_PHASE_STARTED/COMPLETED/HOLDING + INCOME_MATCHING_PHASE_STARTED/COMPLETED/HOLDING) — most already in taxonomy; verify per-status-counts payload field exists on COMPLETED events.

---

## 7. Cross-references

- `matching_tools_io_schemas.md` — JSON schemas for the 4 tools in each phase's sequence (BOOK-228 sibling)
- `matching_cross_product_performance.md` — performance characteristics of the per-pair invocation (BOOK-231 sibling)
- `match_signal_weights.md` — OUT-side scoring weights
- `income_matching_signal_weighting.md` — IN-side scoring weights (BOOK-218)
- `match_record_schema.md` — `match_records` table written by every tool
- `tool_invoice_lifecycle_integration.md` — Block 13 lifecycle function contract consumed at `INCOME_MATCHING`
- `match_reason_prompt.md` — AI prompt invoked by `matching.generate_reasons`
- `match_reason_regeneration_audit_policy.md` — fallback path (BOOK-217)
- `role_change_propagation_policy.md` — per-run snapshot inherited at phase entry (BOOK-221 §3)
- `audit_event_taxonomy.md` — 6 phase events listed in §2 + §3
- `workflow_phase_states_schema.md` — phase-state state machine these definitions plug into
- Block 03 Phase 05 — gate-check framework
- Block 03 Phase 06 — phase execution framework
- Block 10 Phase 09 — workflow phase registration (owning phase; this doc is its canonical sub-doc)
- Block 12 — OUT_MONTHLY workflow consumer
- Block 13 — IN_MONTHLY workflow consumer
- Stage 1 decision — phase-name-not-index cross-block contract
