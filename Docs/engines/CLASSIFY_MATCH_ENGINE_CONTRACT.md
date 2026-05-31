# CLASSIFY + MATCH Engine Contract (P0.1 layer 2)

> **Status:** build spec. Created 2026-05-31 during P0.1.
> **Why this exists:** the CLASSIFICATION and MATCHING *decision* engines are
> app-tier code that was **never built** — the DB shipped the primitives
> (reference tables, the `record_*` recorders, the writers, the gates) but the
> logic that *decides* a classification / *scores* a match lives in the
> application and did not exist (api was health+me; no `classification`/`matching`
> module). The tool-registry entries `classification.apply_layer1/2/3`,
> `merge_and_score`, `assign_status`, `matching.score_pair`, etc. are **tool
> declarations, not executor RPCs** — their descriptions say the work is computed
> *"in memory"* by the caller.
>
> This document captures **everything the two engines touch** so the
> implementation stays fully synced with the live DB and the Block 08 / Block 10
> specs. Source of truth: the live DB (project `noxvmnxrqlzsdfngfiww`) +
> `Docs/blocks/08_*.md`, `Docs/blocks/10_*.md`. Verify against the DB before
> editing — completed cycles lock against ad-hoc edits; engine changes are
> additive.

## Where the engines run

Both run as **orchestrator phase handlers** (`api/.../orchestrator/phases.py`),
invoked by `engine.drive_run` between `enter_phase` and the EXIT gate. They use
the service-role `SupabaseGateway` (`.rpc` / `.select` / `.update`). The
in-memory pipeline pattern: READ_ONLY "proposer" steps compute candidate
decisions in Python; a WRITES_RUN_STATE recorder persists them; then phase
audit + gate. Actor = `ctx.actor_user_id` (resolved by the engine; backfilled
to `started_by`).

⚠️ **Gate-result key mismatch:** `evaluate_classify_entry_gate` /
`evaluate_classify_exit_gate` return `{"passes": bool, "reason"?}`, whereas
`evaluate_ledger_exit_gate` returns `{"satisfied": bool}`. The orchestrator's
`gates._db_satisfied_gate` wrapper must accept **both** `passes` and `satisfied`
(and treat `reason`/`status_counts` as detail). Fix the wrapper when wiring
these gates.

---

# CLASSIFICATION engine (Block 08)

**Phase (live):** `CLASSIFICATION` — OUT_MONTHLY order 2, IN_MONTHLY order 2.
`is_shared_with_pair = true` (an OUT/IN pair from the same `trigger_event_id`
dedup via `check_shared_phase_can_dedup`). *DB seed name was `CLASSIFY`; a later
migration renamed the live phase to `CLASSIFICATION` — trust the live join.*

**Goal:** assign every in-scope transaction a `(transaction_type, system_tag,
classification_confidence, classification_status, classification_method)` +
secondary tags; auto-confirm above a per-type threshold else route to review.

### Inputs / scope
- In-scope transactions = rows for the run's business with
  `classification_status IN (PENDING, NULL)` (the ENTRY gate enforces none are
  already resolved). Scoped via `statement_upload_id IN (uploads of business)`.
- Reference data (all live, seeded):
  - `classification_rules` (6 global seeded; per-business allowed) via
    `get_classification_rules_for_business(business_id) → SETOF classification_rules`.
    Ordered by `priority` (lower = first). Seeded rules:
    | priority | rule_kind | type | tag | predicate |
    |---|---|---|---|---|
    | 5 | OWN_ACCOUNT_TRANSFER | INTERNAL_TRANSFER | Internal transfer | both accounts same business |
    | 8 | COUNTERPARTY_NAME | TAX_PAYMENT | Tax payment | registry=tax_authorities (CY) |
    | 10 | REGEX_DESCRIPTION | BANK_FEE | Bank fee | `^(Fee\|Revolut Fee\|Card replacement)` (i) |
    | 10 | REGEX_DESCRIPTION | FX_EXCHANGE | Currency exchange | `EXCHANGE\|Exchanged to` + `fx_paired_legs not null` |
    | 20 | COUNTERPARTY_DOMAIN | OUT_EXPENSE | (type default) | registry=known_suppliers, amount<0 |
    | 20 | COUNTERPARTY_DOMAIN | IN_INCOME | (type default) | registry=known_clients, amount>0 |
  - `classification_auto_confirm_thresholds` (12 rows, `business_id` null =
    global). Per type: INTERNAL_TRANSFER 0.80, BANK_FEE 0.75, FX_EXCHANGE 0.80,
    OUT_EXPENSE 0.85, IN_INCOME 0.85, REFUND_IN/OUT 0.85, CHARGEBACK 0.85,
    PAYROLL_OR_TEAM_PAYMENT 0.90, TAX_PAYMENT 0.90, LOAN_OR_SHAREHOLDER_MOVEMENT
    0.95, **UNKNOWN 1.0 + `never_auto_confirm=true`**.
  - `tag_taxonomy_versions` → active `cyprus-default-2026-05` (17 tags, each with
    `transaction_type` + `is_type_default`). Resolve the primary tag from the
    rule's `assigned_tag` else the type-default tag.
  - `recurring_vendor_memory` (layer 2), `business_custom_tags` (custom tags, one
    type each).

### Per-transaction algorithm (in-memory, app-side)
1. **Phase start:** `record_classify_phase_started(run_id, user_id)`;
   `snapshot_taxonomy(run_id, user_id)` (pins `classification_taxonomy_snapshot`,
   idempotent).
2. **Layer 1 — rules** (`classification_method=RULE`): evaluate rules by priority
   against the txn (`raw_description`/`normalized_description`, `counterparty_name`,
   `counterparty_country`, `amount`/`direction`, `fx_paired_legs`, `reference`).
   - Match → propose `(type, tag, high confidence)`; `record_classification_rule_matched(txn_id, rule_id, confidence, actor)`.
   - ≥2 matches on **different types** → `record_classification_rule_conflict(txn_id, run_id, conflicting_rule_ids[], actor)` (flag).
   - No match → `record_classification_rule_no_match(txn_id, actor)`.
3. **Layer 2 — vendor memory** (`VENDOR_MEMORY`): for L1-silent txns, look up
   `recurring_vendor_memory` by counterparty for the business. Tiered:
   1 confirmation → medium (~0.6, still review); 3+ → high (~0.85, auto-confirmable).
4. **Layer 3 — AI fallback** (`AI_FALLBACK`): **STUBBED until P2 (R8)** — via
   Block 06 gateway. Until then unresolved → `UNKNOWN`, low confidence, method
   `NO_AI_AVAILABLE`. (Record SKIPPED marker for `classification.apply_layer3`.)
5. **Merge:** `merge_layer_confidence(l1_conf,l1_type, l2_conf,l2_type, l3_conf,l3_type)
   → {merged_confidence, chosen_type, agreement_boost_applied, disagreement_penalty_applied}`.
   Resolve primary tag from snapshot/type-default.
6. **Assign status:** threshold = `classification_auto_confirm_thresholds[chosen_type]`.
   - `merged_confidence > threshold` **and not** `never_auto_confirm`
     → `record_classification_auto_confirmed(txn_id, merged_confidence, chosen_type, method, chosen_tag, actor)` → status **CONFIRMED**. Bump vendor-memory confirmations.
   - else → `record_classification_needs_confirmation(txn_id, run_id, merged_confidence, chosen_type, method, chosen_tag, actor)` → status **NEEDS_CONFIRMATION** + raises a review issue.
7. **Phase complete:** `record_classify_phase_completed(run_id, user_id, per_status_counts jsonb)`.

### Writes (only via recorders)
`transactions`: `transaction_type`, `system_tag`, `secondary_tags`,
`classification_status`, `classification_confidence`, `classification_method`.
Plus `review_issues` (NEEDS_CONFIRMATION), `recurring_vendor_memory` bumps.

### Gates
- ENTRY `classification.entry_v1` → `evaluate_classify_entry_gate(run_id)` →
  `{passes, reason?}` (fails if any txn already non-PENDING).
- EXIT `classification.exit_v1` → `evaluate_classify_exit_gate(run_id)` →
  `{passes, reason?, status_counts}` (every txn CONFIRMED|NEEDS_CONFIRMATION,
  non-null type, every NEEDS_CONFIRMATION has a review_issue).
- IN exit also: `gate_in_workflow_classification_exit_v1(run_id, ctx)`.

### Enums
- `transaction_type_enum`: OUT_EXPENSE, IN_INCOME, INTERNAL_TRANSFER, FX_EXCHANGE,
  BANK_FEE, REFUND_IN, REFUND_OUT, CHARGEBACK, LOAN_OR_SHAREHOLDER_MOVEMENT,
  PAYROLL_OR_TEAM_PAYMENT, TAX_PAYMENT, UNKNOWN.
- `transaction_classification_status_enum`: PENDING, NEEDS_CONFIRMATION,
  **CONFIRMED**, FAILED (no "AUTO_CONFIRMED").
- `classification_method_enum`: RULE, VENDOR_MEMORY, AI_FALLBACK,
  NO_AI_AVAILABLE, MANUAL.
- `classification_rule_kind_enum`: REGEX_DESCRIPTION, COUNTERPARTY_NAME,
  COUNTERPARTY_DOMAIN, AMOUNT_THRESHOLD, MERCHANT_CATEGORY_CODE,
  OWN_ACCOUNT_TRANSFER.

---

# MATCHING engine (Block 10)

**Phase (live):** `MATCHING` — OUT_MONTHLY order 6 only (IN side uses
`INCOME_MATCHING`). Deterministic-first; AI only rephrases, never overrides.

**Goal:** connect each in-scope OUT transaction to a justifying document, set its
`match_status`, store a structured signal breakdown + plain-language reason; detect
duplicates and split payments; honour rejection memory.

### Inputs / scope
- In-scope transactions: OUT_EXPENSE (+ refund/chargeback) rows for the business
  with no resolved `match_status`. `transactions.match_status` (enum — **confirm
  labels at build time**; spec statuses: MATCHED_CONFIRMED,
  MATCHED_AUTO_HIGH_CONFIDENCE, MATCHED_NEEDS_CONFIRMATION, POSSIBLE_MATCH,
  NO_MATCH, REJECTED_MATCH).
- Candidate documents: `documents` for the business, unmatched, within date
  windows. (No OUT `get_match_candidates` RPC found — query `documents` directly;
  `get_match_candidates` exists for the IN side only.)
- `match_rejection_memory` — filter out forever-rejected `(txn, doc)` pairs
  (pair-scoped).

### Signal weights (`match_signal_weights`, global, v1.0.0, sum ≈ 1.0)
| signal | weight |
|---|---|
| amount_exact_match | 0.20 |
| supplier_exact_match | 0.20 |
| date_proximity | 0.15 |
| currency_match | 0.10 |
| invoice_number_match | 0.10 |
| supplier_fuzzy_match | 0.10 |
| recurring_vendor_signal | 0.05 |
| email_sender_domain_match | 0.05 |
| business_name_on_invoice | 0.02 |
| drive_folder_relevance | 0.02 |
| vat_number_relevance | 0.01 |

Load live via `select match_signal_weights where enabled` (don't hardcode).

### Scoring algorithm (app-side)
For each (txn, candidate) pair: compute each signal in [0,1] (exact = 1/0; date
proximity graded by window; fuzzy = normalized string distance) × weight → sum =
`match_score` in [0,1]. Build `signal_breakdown` jsonb (per-signal value+weight).
Determine `match_level` + status:
- **EXACT** (±3 days, amount+currency+supplier exact, invoice/ref if present) →
  status `MATCHED_AUTO_HIGH_CONFIDENCE`.
- **STRONG_PROBABLE** (±10 days, amount exact + supplier fuzzy + recurring) →
  `MATCHED_AUTO_HIGH_CONFIDENCE` **only if strong recurring pattern**, else
  `MATCHED_NEEDS_CONFIRMATION`.
- **WEAK_POSSIBLE** (±30 days, partial signals) → `POSSIBLE_MATCH` (always review).
- No candidate above min threshold → `NO_MATCH` + "Missing Documents" review issue.

`match_level_enum` = EXACT, STRONG_PROBABLE, WEAK_POSSIBLE (NO_MATCH is **not** a
level). `match_method_enum` = DETERMINISTIC_RULE, AI_FALLBACK.

### Writer + recorders
- `apply_match_score(org, biz, txn_id, doc_id, signal_breakdown jsonb, match_score,
  match_level, match_method='DETERMINISTIC_RULE', match_reason_plain_language,
  matched_by_system, context)` — the single writer of `match_records` +
  `transactions.match_status` for a positive match.
- **NO_MATCH path: OPEN** — `apply_match_score` only takes EXACT/STRONG/WEAK.
  Find/confirm the NO_MATCH recorder (record_no_match / missing-documents issue)
  at build time; the exit gate requires every in-scope txn to have a match_status.
- Duplicates: `detect_duplicate_pattern_a(business_id, document_id)` (one doc →
  many txns), `detect_duplicate_pattern_b(business_id, transaction_id)` (one txn →
  many docs). Each duplicate raises a review issue; never auto-resolves.
- Split payments: proactive combinatorial search over recent unmatched invoices
  summing to the txn amount → `split_payment_groups` (+ constituents). **MVP may
  defer combinatorial; record the decision.**
- Reason: structured breakdown is authoritative; plain-language via Block 06
  (Tier 2/3) — **stub** with a deterministic template until P2; `regenerate_match_reason`
  exists for later.
- Phase audit: `record_matching_phase_started/completed/holding(run_id, event_family,
  phase_name, ...)`.

### Gate
- EXIT `matching.exit_all_out_expense_match_status_set_v1` →
  `evaluate_matching_exit_gate(run_id)` (every in-scope OUT_EXPENSE has match_status).

### Key tables/columns
- `match_records`: transaction_id, document_id, match_level, match_method,
  match_score, match_signals (jsonb), match_reason_plain_language, match_status,
  split_payment_flag, split_payment_group_id, requires_user_confirmation, …
- `documents` candidate fields: supplier_name, supplier_vat_number, invoice_number,
  invoice_date, amount_total, currency, payment_reference, client_name.
- `transactions` match fields: match_status, matched_invoice_id, counterparty_name,
  amount, currency, transaction_date, reference.

---

## Build order (layer 2)
1. ✅ CLASSIFICATION (done, on main `df56695`) — shared OUT/IN.
2. ✅ MATCHING (done, on main `334971d`) — OUT scorer; NO_MATCH via
   `record_match_no_match`; status enum `transaction_match_status_enum`.
3. ✅ LEDGER_PREPARATION (done, on main `052f761`) — **real RPC names differ
   from the tool declarations** (verified 2026-05-31 against pg_proc):
   - writer: **`prepare_ledger_entries`**(org, biz, transaction_id, run,
     match_record_id, input_vat_reclaimable, output_vat_due, vat_amount,
     entry_period, actor, ctx) — *not* `prepare_entries`.
   - proposer: `resolve_counterparty`(... transaction_id ...) → counterparty
     country/vat (may writeback vendor memory).
   - per-draft-entry enrichers (take `draft_ledger_entry_id`, so they run AFTER
     the writer creates the row): `classify_vat_treatment`,
     **`compute_reverse_charge_and_vies`** (not `_vies`),
     `compute_vat_and_evidence_flags`(+ document_extracted_vat_amount, matched_evidence_kind).
   - **No** `flag_for_review` / `generate_vat_explanations` RPC exists — review
     flagging is folded into `compute_vat_and_evidence_flags`; VAT explanations
     are AI (Block 06) → STUB until P2.
   - helpers: `suggest_vat_treatment`, `suggest_reverse_charge_applicable`,
     `validate_vat_number_format`, `canonicalize_vat_number`,
     `cyprus_vat_rate_for_category`.
   - gates: EXIT `evaluate_ledger_exit_gate`(run) {satisfied} — every in-scope
     txn has ≥1 draft_ledger_entries row OR a LEDGER_HELD_PENDING_CLASSIFICATION
     audit. IN: `gate_in_workflow_ledger_preparation_exit_v1`(run, ctx).
   - phase recorders: `record_ledger_phase_started/completed/holding`(run, phase_name, ...).
   - ⚠️ **Sequence ambiguity to resolve before building:** `prepare_ledger_entries`
     takes `input_vat_reclaimable`/`output_vat_due`/`vat_amount` as INPUT, but
     `compute_vat_and_evidence_flags` produces those AFTER the draft row exists.
     Read the `prepare_ledger_entries` + `classify_vat_treatment` *implementations*
     to pin the true order (likely: resolve_counterparty → prepare_ledger_entries
     with preliminary VAT inputs → per-entry classify/compute enrich). This is the
     most correctness-sensitive engine (VAT/ledger) — build with care.
4. ✅ INCOME_MATCHING (done, on main `052f761`) — **no `get_match_candidates`
   RPC exists** (candidate discovery is app-side over invoices); writer is
   `apply_income_match`(txn, invoice, outcome, run, has_reference_match, actor, ctx).
   Exit gate `evaluate_income_matching_exit_gate` requires `income_match_outcome`
   set on every IN-direction txn in period.

## ✅ Layer 2 status (2026-05-31)
All four deterministic engines built, unit-tested, ruff/mypy-clean, on `main`:
CLASSIFICATION + MATCHING + LEDGER_PREPARATION + INCOME_MATCHING. Remaining to a
clean full end-to-end drive: the demo business **chart of accounts is not
configured** (`chart_of_accounts_mappings` empty, no active mapping version for
the period) → `prepare_ledger_entries` raises and the run correctly holds at
LEDGER. Configuring a minimal Cyprus chart + mapping version is a Block-11 setup
task (separate from the orchestrator). Optional scale piece still open: the
multi-worker run-claim lease.

Each handler: unit tests (mock gateway) + live drive against the demo
(business `0e000000-0000-4000-8000-0000000000b1`, 6 txns), reset after.

## Open items to resolve at build time
- `transactions.match_status` enum labels (exact values).
- NO_MATCH / missing-documents recorder for the matching exit gate.
- Supplier-name normalization function (spec defers to phase docs; DB may ship one).
- Whether combinatorial split detection is in MVP scope or deferred.
- Gate wrapper must accept `{passes}` and `{satisfied}`.
