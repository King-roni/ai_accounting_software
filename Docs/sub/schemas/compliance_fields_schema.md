# compliance_fields_schema

**Category:** Schemas · **Owning block:** 11 — Ledger & Cyprus VAT Engine · **Co-owner:** 04 — Data Architecture · **Stage:** 4 sub-doc (Layer 2)

The canonical type and nullability contract for the 11 compliance fields on `draft_ledger_entries`. Block 11 Phase 01's sub-doc hook for "compliance-fields canonical schema" — exact column types, defaults, and evolution rules for the fields that drive Cyprus VAT preparation, VIES export, and the accountant-review queue.

Per Block 11's architecture doc, the 11 fields are pinned. The reverse-charge boolean is derived from `vat_treatment` per `vat_treatment_enum`'s VIES-relevance projection and lives outside this 11-field surface; that boolean is `vies_relevant` in the canonical list below.

---

## The 11 compliance fields

| # | Column | Type | Nullable | Default | Source |
| --- | --- | --- | --- | --- | --- |
| 1 | `counterparty_country_iso` | `char(2)` | yes | `NULL` | Block 11 Phase 04 resolver |
| 2 | `counterparty_vat_number` | `text` | yes | `NULL` | Block 11 Phase 04 resolver |
| 3 | `vat_treatment` | `vat_treatment_enum` | no | `'UNKNOWN'` | Block 11 Phase 05 classifier |
| 4 | `vat_amount_eur_cents` | `bigint` | no | `0` | Block 11 Phase 08 |
| 5 | `vies_relevant` | `boolean` | no | computed `false` | Block 11 Phase 06 projection |
| 6 | `vies_period` | `char(7)` | yes | `NULL` | Block 11 Phase 06 |
| 7 | `vies_value_basis_eur` | `bigint` | yes | `NULL` | Block 11 Phase 06 |
| 8 | `evidence_doc_id` | `uuid` | yes | `NULL` | Block 11 Phase 08 |
| 9 | `vat_treatment_explanation` | `text` | yes | `NULL` | Block 11 Phase 09 (plain-language pipeline) |
| 10 | `entry_currency_original` | `char(3)` | yes | `NULL` | Block 11 Phase 07 dispatcher |
| 11 | `entry_amount_original` | `numeric(15,4)` | yes | `NULL` | Block 11 Phase 07 dispatcher |

All 11 are columns on `draft_ledger_entries` and mirrored on `archive.locked_ledger_entries` with identical types — locking copies the value verbatim at finalization.

## Column definitions

```sql
ALTER TABLE draft_ledger_entries
  ADD COLUMN counterparty_country_iso  char(2),
  ADD COLUMN counterparty_vat_number   text,
  ADD COLUMN vat_treatment             vat_treatment_enum NOT NULL DEFAULT 'UNKNOWN',
  ADD COLUMN vat_amount_eur_cents      bigint             NOT NULL DEFAULT 0,
  ADD COLUMN vies_relevant             boolean            NOT NULL DEFAULT false,
  ADD COLUMN vies_period               char(7),
  ADD COLUMN vies_value_basis_eur      bigint,
  ADD COLUMN evidence_doc_id           uuid REFERENCES documents(document_id),
  ADD COLUMN vat_treatment_explanation text,
  ADD COLUMN entry_currency_original   char(3),
  ADD COLUMN entry_amount_original     numeric(15, 4);
```

### Field-by-field rationale

**`counterparty_country_iso`** — `char(2)`, ISO-3166 alpha-2, uppercase. The canonicalised form per Block 11 Phase 04's resolver. Nullable because the resolver may legitimately return `UNRESOLVED`; in that case `vat_treatment` defaults to `UNKNOWN` and the entry is review-flagged.

**`counterparty_vat_number`** — `text`, canonicalised per `vat_number_format_catalog` (country prefix uppercased, no internal whitespace or hyphens). Nullable because not every legitimate transaction has a counterparty VAT number — domestic consumer receipts, internal transfers, bank fees.

**`vat_treatment`** — `vat_treatment_enum` (8 closed values); see `vat_treatment_enum`. NOT NULL with default `'UNKNOWN'` — every draft entry has a treatment value, even if the classifier deferred.

**`vat_amount_eur_cents`** — `bigint` integer minor units, always EUR. `0` for `OUTSIDE_SCOPE`, `EXEMPT`-style, and zero-rated treatments. Per `data_layer_conventions_policy` Section 3, currency is integer minor units — never float.

**`vies_relevant`** — `boolean`, derived projection per `vat_treatment_enum`:

```sql
CASE
  WHEN vat_treatment = 'EU_REVERSE_CHARGE' THEN true
  WHEN vat_treatment = 'IMPORT_OR_ACQUISITION'
    AND import_acquisition_subtype = 'INTRA_EU_ACQUISITION' THEN true
  ELSE false
END
```

In MVP the projection is materialised by Block 11 Phase 06's writer at the moment `vat_treatment` is written — not a Postgres computed column, because the second branch references `import_acquisition_subtype` on the parent transaction. Block 06 Phase 06 owns the recompute trigger when `vat_treatment` changes.

**`vies_period`** — `char(7)`, `'YYYY-MM'`. Populated when `vies_relevant = true`. Per Block 11 Phase 06's period-assignment rule, the period is the calendar month the entry's `transaction_date` falls in, unless the per-business `vies_quarterly_eligibility_policy` toggles quarterly reporting (in which case the value is still `'YYYY-MM'` for the quarter's representative month per the policy's normalisation rule).

**`vies_value_basis_eur`** — `bigint` minor units; the value the entry contributes to the VIES total for its `vies_period`. Distinct from `vat_amount_eur_cents` — VIES reports the gross taxable basis, not the VAT amount itself. NULL when `vies_relevant = false`.

**`evidence_doc_id`** — `uuid` FK to `documents`. The supporting document evidencing the entry. Per Block 11 Phase 08, populated on a confirmed match; NULL when no evidence is required (e.g., `INTERNAL_TRANSFER`, `BANK_FEE`) or when the entry is held pending evidence (review issue raised).

**`vat_treatment_explanation`** — `text`, plain-language explanation generated by Block 11 Phase 09 via Block 06's plain-language pipeline. Length capped at 2000 chars by the pipeline's prompt template. NULL until generated; lazily populated when the entry is opened in the review queue or invoice PDF render requests it.

**`entry_currency_original`** — `char(3)`, ISO-4217. NULL when the entry's currency equals the business's bookkeeping currency (typically EUR). Per Block 11 Phase 07's cross-currency rule, when these differ the original currency + amount are preserved alongside the EUR amounts.

**`entry_amount_original`** — `numeric(15, 4)`. Original-currency amount, preserved to 4 decimal places for FX round-trip fidelity. NULL paired with `entry_currency_original`.

## Nullability matrix by `vat_treatment`

The contract for which compliance fields may be NULL given the treatment:

| `vat_treatment` | `counterparty_country_iso` | `counterparty_vat_number` | `vies_period` | `vies_value_basis_eur` | `evidence_doc_id` |
| --- | --- | --- | --- | --- | --- |
| `DOMESTIC_STANDARD` | required (`'CY'`) | optional | NULL | NULL | required |
| `DOMESTIC_REDUCED` | required (`'CY'`) | optional | NULL | NULL | required |
| `DOMESTIC_ZERO` | required (`'CY'`) | optional | NULL | NULL | required |
| `EU_REVERSE_CHARGE` | required (EU non-CY) | required | required | required | required |
| `IMPORT_OR_ACQUISITION` | required | required (intra-EU acquisition); optional (import) | required (intra-EU); NULL (import) | required (intra-EU); NULL (import) | required |
| `NON_EU_SERVICE` | required (non-EU) | optional | NULL | NULL | required |
| `OUTSIDE_SCOPE` | may be NULL | may be NULL | NULL | NULL | optional |
| `UNKNOWN` | may be NULL | may be NULL | NULL | NULL | optional |

Per `vat_treatment_enum`: `OUTSIDE_SCOPE` and `UNKNOWN` are the only two treatments where the counterparty fields may legitimately remain NULL. Every other treatment requires at least `counterparty_country_iso`. The classifier (Phase 05) raises `LEDGER_VAT_TREATMENT_UNKNOWN_RAISED` instead of advancing to a definite treatment when the resolver couldn't supply the required fields.

### CHECK constraints

```sql
ALTER TABLE draft_ledger_entries
  ADD CONSTRAINT compliance_country_when_required CHECK (
    vat_treatment IN ('OUTSIDE_SCOPE', 'UNKNOWN')
    OR counterparty_country_iso IS NOT NULL
  ),
  ADD CONSTRAINT compliance_vat_number_when_eu_rc CHECK (
    vat_treatment <> 'EU_REVERSE_CHARGE'
    OR counterparty_vat_number IS NOT NULL
  ),
  ADD CONSTRAINT compliance_vies_pair_consistency CHECK (
    (vies_period IS NULL) = (vies_value_basis_eur IS NULL)
  ),
  ADD CONSTRAINT compliance_vies_only_when_relevant CHECK (
    vies_relevant OR vies_period IS NULL
  ),
  ADD CONSTRAINT compliance_currency_original_pair CHECK (
    (entry_currency_original IS NULL) = (entry_amount_original IS NULL)
  );
```

The constraints encode the contract above. The classifier writes the treatment; the constraints prevent writing an inconsistent (treatment, fields) pair. A constraint violation indicates a Block 11 Phase 05 / Phase 06 / Phase 07 writer bug, not a user-input issue.

## Defaults and evolution rules

**Default values:** `vat_treatment` defaults to `'UNKNOWN'` so an INSERT with no treatment column produces a holding entry surfaced for review. `vat_amount_eur_cents` defaults to `0` so the column never lies — zero VAT is the truth for outside-scope and zero-rated treatments, and the classifier writes a non-zero value only for treatments that levy VAT.

**Evolution rules:**

1. Adding a value to `vat_treatment_enum` requires a `Docs/decisions_log.md` amendment AND a back-compat migration that re-evaluates the nullability matrix above. The closed 8-value enum is binding for MVP.
2. The `vies_relevant` projection rule is closed — modifying the projection requires an amendment because Block 16's VIES export depends on the exact rule.
3. Adding a 12th compliance field requires a Block 11 Phase 01 sub-doc amendment AND back-fill rules for existing draft entries — the migration cannot leave existing entries with a NULL value for a new NOT-NULL field.
4. Removing a compliance field is a Stage 2+ concern; MVP commits to all 11 staying.

## Recompute interaction

When a downstream user action changes `vat_treatment` (e.g., user reclassification in the review queue), the compliance fields recompute per Block 11 Phase 07's replace-on-recompute contract. The recompute is transactional: the old draft entry rows are deleted and the new set is INSERTed in one operational transaction; `LEDGER_ENTRIES_RECOMPUTED` fires per `audit_event_taxonomy`.

The recompute does NOT preserve `vat_treatment_explanation` — explanations are regenerated lazily on next read because they reference the new treatment. Per Block 11 Phase 09's plain-language pipeline, regeneration is gated on the entry being opened by a user; the gateway cost of explanation generation never fires on bulk recompute paths.

When recompute changes a treatment from one with `vies_relevant = true` to one with `vies_relevant = false`, the `vies_period` and `vies_value_basis_eur` columns are reset to NULL in the same statement that updates `vat_treatment`. The constraint `compliance_vies_only_when_relevant` enforces this — an UPDATE that flips `vies_relevant` without clearing the VIES pair is rejected.

## Per-entry-kind nullability addendum

The 11 fields are declared on every `draft_ledger_entries` row, but derived entries (`VAT_RECLAIM`, `VAT_OUTPUT`, `FX_DELTA`, `ROUNDING`) inherit most compliance fields from their PRIMARY parent. The contract:

| `entry_kind` | Fields populated by the dispatcher | Fields copied from PRIMARY |
| --- | --- | --- |
| `PRIMARY` | all 11 (per the matrix above) | n/a |
| `VAT_RECLAIM` | `vat_amount_eur_cents` (the reclaim amount) | `counterparty_country_iso`, `counterparty_vat_number`, `vat_treatment`, `vies_relevant` |
| `VAT_OUTPUT` | `vat_amount_eur_cents` (the output amount) | `counterparty_country_iso`, `counterparty_vat_number`, `vat_treatment`, `vies_relevant`, `vies_period`, `vies_value_basis_eur` |
| `FX_DELTA` | `entry_currency_original`, `entry_amount_original` | `vat_treatment = 'OUTSIDE_SCOPE'`, others nullable |
| `ROUNDING` | (no compliance fields) | `vat_treatment = 'OUTSIDE_SCOPE'`, others NULL |

The copy semantics are enforced at write time by the dispatcher, not by triggers — the database has no row-level inheritance mechanism. Block 11 Phase 07's `prepareLedgerEntries` function carries the contract.

## Adjustment-path interaction

Per `adjustment_entry_schema`, adjustment-path rows (`entry_kind = 'OUT_ADJUSTMENT' | 'IN_ADJUSTMENT'`) populate compliance fields directly from the adjustment's corrective values. The constraints above apply identically — an `OUT_ADJUSTMENT` row with `vat_treatment = 'EU_REVERSE_CHARGE'` must carry a non-null `counterparty_vat_number`. The pre-amendment locked-entry's compliance values are recoverable from `archive.locked_ledger_entries` via the FK chain.

## Cross-database mirror

The 11 fields are mirrored verbatim on `archive.locked_ledger_entries` (per `archive_schema`). The mirror uses the same Postgres `vat_treatment_enum` type via `USING vat_treatment::vat_treatment_enum`. Cross-database mirror invariants:

- `vat_treatment` types are identical (shared ENUM)
- `vies_period` format is identical (`'YYYY-MM'`)
- `evidence_doc_id` references survive the lock — the document row is also archived per `archive_bundle_layout_schema`

## Indexes

```sql
CREATE INDEX idx_dle_compliance_vat_treatment
  ON draft_ledger_entries(business_id, vat_treatment, entry_period);

CREATE INDEX idx_dle_compliance_vies
  ON draft_ledger_entries(business_id, vies_period)
  WHERE vies_relevant = true;

CREATE INDEX idx_dle_compliance_country
  ON draft_ledger_entries(business_id, counterparty_country_iso)
  WHERE counterparty_country_iso IS NOT NULL;
```

The first index supports the Cyprus VAT preparation grouping in Block 16. The second supports VIES export grouping. The third supports counterparty-by-country drill-down for the accountant pack.

## RLS and mobile rejection

Inherits `draft_ledger_entries` row-level isolation per `transactions_schema` template. Writes to these fields flow through Block 11's ledger-prep tools, which are not directly user-callable (`WRITES_RUN_STATE` from workflow tools, never from API). No mobile rejection surface lives on this schema — the writes are server-internal.

## Cross-references

- `vat_treatment_enum` — the closed 8-value enum, VIES-relevance projection rule
- `vies_record_format` — VIES CSV/XML field layout that consumes these fields
- `data_layer_conventions_policy` — UUID v7 for `evidence_doc_id`, integer minor units, canonical JSON
- `audit_log_policies` — `LEDGER_*` events that fire on compliance-field writes
- `audit_event_taxonomy` — `LEDGER_VAT_TREATMENT_DECIDED`, `LEDGER_VIES_PERIOD_ASSIGNED`, `LEDGER_ENTRIES_RECOMPUTED`
- `transactions_schema` — sibling table; `counterparty_country_iso` lives on both tables (transaction-side for classifier input, entry-side for VAT preparation)
- `archive_schema` — locked-ledger-entry mirror
- `chart_of_accounts_schema` — `debit_account_code` / `credit_account_code` consumers of these fields
- Block 11 Phase 01 — base `draft_ledger_entries` schema
- Block 11 Phase 04 — counterparty resolution (fields 1, 2)
- Block 11 Phase 05 — VAT treatment classifier (field 3)
- Block 11 Phase 06 — VIES relevance projection (fields 5, 6, 7)
- Block 11 Phase 08 — VAT amount + evidence binding (fields 4, 8)
- Block 11 Phase 09 — plain-language explanation (field 9)
