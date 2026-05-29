# Matching Per-Fixture Content

**Category:** Fixtures · **Owning block:** 10 — Matching Engine · **Stage:** 4 sub-doc (Layer 2)

Canonical fixture corpus for Block 10 Matching Engine live integration tests and development seed data. Every scenario listed here maps 1:1 to a test case in `matching_live_integration_runbook.md`. The JSON representation of all fixtures is the authoritative source; the prose descriptions are explanatory only. When a fixture and a runbook assertion conflict, the fixture JSON wins.

---

## Purpose

These fixtures establish a shared, version-controlled baseline for:

- Live integration test assertions against the `matching.score_pair` and `matching.auto_confirm` tools
- Development seed data for local runs of the Matching Engine phase
- Calibration regression checks — any change to `match_scoring_calibration_policy.md` thresholds must be validated against these fixtures before merge

The fixtures are stored inline in this document as canonical JSON objects. The fixture export script (`scripts/export_matching_fixtures.ts`) reads this file, extracts the JSON blocks, and writes them to `fixtures/matching_fixtures.json`. The CI pipeline runs the export before running live integration tests to ensure test data is always derived from this document.

---

## Fixture format

Each fixture object carries these top-level fields:

| Field | Type | Description |
|---|---|---|
| `fixture_id` | string | Stable identifier; never reused after deletion |
| `scenario_name` | string | Human-readable scenario label |
| `invoice_fixture` | object | The invoice being matched against |
| `transaction_fixtures` | array | One or more transactions presented to the scorer |
| `expected_match_level` | string | The `match_level` enum value the scorer must return |
| `expected_match_count` | integer | Count of transactions the engine must include in the match result |
| `cross_period` | boolean (optional) | Present and `true` when the scenario exercises cross-period logic |

`invoice_fixture` shape:

```
{
  "amount_eur": number,          // positive, two decimal places
  "currency": "EUR",
  "issue_date": "YYYY-MM-DD",
  "due_date": "YYYY-MM-DD",
  "counterparty_name": string
}
```

`transaction_fixtures` element shape:

```
{
  "amount_eur": number,          // positive for inflow
  "value_date": "YYYY-MM-DD",
  "counterparty_name": string
}
```

---

## Fixtures

### Fixture 1 — Exact match

```json
{
  "fixture_id": "MF-001",
  "scenario_name": "exact_match_single_transaction",
  "invoice_fixture": {
    "amount_eur": 1200.00,
    "currency": "EUR",
    "issue_date": "2026-04-01",
    "due_date": "2026-04-30",
    "counterparty_name": "Acme Ltd"
  },
  "transaction_fixtures": [
    {
      "amount_eur": 1200.00,
      "value_date": "2026-04-28",
      "counterparty_name": "Acme Ltd"
    }
  ],
  "expected_match_level": "EXACT",
  "expected_match_count": 1
}
```

**Scenario description.** A single transaction with an amount identical to the invoice total (`1200.00 EUR`). The counterparty name is an exact string match. The value date (`2026-04-28`) falls two days before the due date (`2026-04-30`), within the standard settlement window. The scorer must return `EXACT` with one matched transaction.

Scoring signals active: amount equality, counterparty string equality, pre-due-date proximity within 30 days.

---

### Fixture 2 — Probable match (counterparty name variant)

```json
{
  "fixture_id": "MF-002",
  "scenario_name": "probable_match_name_variant",
  "invoice_fixture": {
    "amount_eur": 850.00,
    "currency": "EUR",
    "issue_date": "2026-03-15",
    "due_date": "2026-04-14",
    "counterparty_name": "Acme Ltd"
  },
  "transaction_fixtures": [
    {
      "amount_eur": 850.00,
      "value_date": "2026-04-24",
      "counterparty_name": "Acme Limited"
    }
  ],
  "expected_match_level": "STRONG_PROBABLE",
  "expected_match_count": 1
}
```

**Scenario description.** Amount is identical. The counterparty name on the transaction (`"Acme Limited"`) differs from the invoice name (`"Acme Ltd"`) by a common legal-suffix abbreviation. The value date (`2026-04-24`) is 10 days after the due date (`2026-04-14`). The combination of identical amount, fuzzy-matched name, and moderate lateness produces `STRONG_PROBABLE` rather than `EXACT`. The scorer must NOT return `EXACT` here; the name variant alone disqualifies the exact tier.

Scoring signals active: amount equality, fuzzy counterparty name similarity above the strong-probable threshold, late payment within 30-day post-due window.

---

### Fixture 3 — Split payment

```json
{
  "fixture_id": "MF-003",
  "scenario_name": "split_payment_two_transactions",
  "invoice_fixture": {
    "amount_eur": 3000.00,
    "currency": "EUR",
    "issue_date": "2026-03-01",
    "due_date": "2026-03-31",
    "counterparty_name": "Delta Supplies CY"
  },
  "transaction_fixtures": [
    {
      "amount_eur": 1500.00,
      "value_date": "2026-03-20",
      "counterparty_name": "Delta Supplies CY"
    },
    {
      "amount_eur": 1500.00,
      "value_date": "2026-03-28",
      "counterparty_name": "Delta Supplies CY"
    }
  ],
  "expected_match_level": "STRONG_PROBABLE",
  "expected_match_count": 2,
  "per_transaction_expected_match_level": "WEAK_POSSIBLE"
}
```

**Scenario description.** The invoice total is `3000.00 EUR`. Two transactions of `1500.00 EUR` each, from the same counterparty, both within the 30-day window before the due date, sum exactly to the invoice total. The split payment group scorer must recognise the pair and return `STRONG_PROBABLE` with `expected_match_count = 2`. Each individual transaction, scored in isolation against the invoice, produces `WEAK_POSSIBLE` because a single 1500 EUR transaction covers only 50% of the 3000 EUR invoice.

The `per_transaction_expected_match_level` field is asserted by the split-payment sub-assertion in the runbook; it is not part of the top-level matcher output.

Scoring signals active: sum-equals-invoice-amount, same counterparty for both transactions, both within 30-day window, split payment group detection flag.

---

### Fixture 4 — No match

```json
{
  "fixture_id": "MF-004",
  "scenario_name": "no_match_amount_and_counterparty_mismatch",
  "invoice_fixture": {
    "amount_eur": 2200.00,
    "currency": "EUR",
    "issue_date": "2026-04-01",
    "due_date": "2026-04-30",
    "counterparty_name": "Helix Corp"
  },
  "transaction_fixtures": [
    {
      "amount_eur": 1700.00,
      "value_date": "2026-04-15",
      "counterparty_name": "Sigma GmbH"
    }
  ],
  "expected_match_level": "NO_MATCH",
  "expected_match_count": 0
}
```

**Scenario description.** The transaction amount (`1700.00 EUR`) differs from the invoice total (`2200.00 EUR`) by 22.7%, which exceeds the 20% tolerance threshold. The counterparty names (`"Helix Corp"` vs `"Sigma GmbH"`) share no tokens and produce a fuzzy similarity score below the weak-possible floor. Both amount and name signals fail; the scorer must return `NO_MATCH` with zero matched transactions.

This fixture guards against false positives on amount tolerance and name similarity. Neither signal alone is sufficient; both failing together is the hard no-match case.

---

### Fixture 5 — Cross-period match

```json
{
  "fixture_id": "MF-005",
  "scenario_name": "cross_period_match_prior_month_invoice",
  "invoice_fixture": {
    "amount_eur": 560.00,
    "currency": "EUR",
    "issue_date": "2026-02-10",
    "due_date": "2026-03-10",
    "counterparty_name": "Lumina Services Ltd"
  },
  "transaction_fixtures": [
    {
      "amount_eur": 560.00,
      "value_date": "2026-04-05",
      "counterparty_name": "Lumina Services Ltd"
    }
  ],
  "expected_match_level": "STRONG_PROBABLE",
  "expected_match_count": 1,
  "cross_period": true
}
```

**Scenario description.** The invoice was issued in February (`issue_date: 2026-02-10`) with a due date of `2026-03-10`. The run period is April 2026. The transaction value date (`2026-04-05`) falls 26 days after the due date — outside the standard 30-day same-period window but within the 90-day cross-period look-back. The amount is identical; the counterparty name is an exact string match.

The scorer must set `cross_period: true` on the match result and return `STRONG_PROBABLE` with one matched transaction. The cross-period flag must be asserted separately by the runbook; it does not affect the `match_level` enum value.

This fixture is also used to verify that the Matching Engine phase correctly ingests prior-period invoices when the run's `cross_period_window_days` is set to 90.

---

## Storage

Fixtures are stored inline above as JSON code blocks. The export script `scripts/export_matching_fixtures.ts` extracts all JSON blocks from this file, validates each object against the fixture schema, and writes the array to `fixtures/matching_fixtures.json`. The JSON file is committed to the repository and read directly by the live integration test harness.

The export script must be run before committing changes to this file. CI validates that `fixtures/matching_fixtures.json` is in sync with this document by re-running the export and diffing the output.

To add a new fixture: add a numbered section above, provide the JSON block, write the scenario description, then run the export script. Fixture IDs must be unique across all matching fixture files and must not be reused after a fixture is removed.

---

## Cross-references

- `matching_live_integration_runbook.md` — test assertions that consume these fixtures
- `match_record_schema.md` — `match_level` enum values and `match_records` table DDL
- `match_scoring_calibration_policy.md` — thresholds that determine level boundaries (EXACT / STRONG_PROBABLE / WEAK_POSSIBLE / NO_MATCH)
- `income_matching_schema.md` — `income_match_records` table; cross-period flag field definition
