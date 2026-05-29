# ledger_live_integration_runbook

**Category:** Runbooks · **Owning block:** 11 — Ledger & Cyprus VAT · **Stage:** 4 sub-doc (Layer 2)

**Block reference:** Block 11 Phase 05 (VAT treatment assignment); Block 11 Phase 07 (ledger preparation dispatcher — `ledger.post_entries`); Block 11 Phase 08 (VAT amount computation and VIES integration); Block 11 Phase 10 (end-to-end ledger tests).

**Purpose:** Cadence, fixture set, test steps, VIES mock setup, acceptance criteria, and failure handling for the Ledger and Cyprus VAT live integration test suite. Validates that ledger entries are posted with correct VAT treatments per the Cyprus VAT rule catalog, VIES validation fires for intra-EU fixtures, and audit events are emitted with the correct account codes from the active mapping version.

---

## Cadence

| Trigger | Schedule | Scope |
|---|---|---|
| Pre-deploy | Before every production release | Full fixture set (4 fixtures) |
| Weekly scheduled | Monday 06:00 UTC | Full fixture set |
| Post-incident | After any Cyprus VAT rule catalog update or VIES endpoint change | Full fixture set + re-record VIES mock responses |
| Manual | Engineering investigation | As needed |

VIES lookups call the Cyprus Tax Department SOAP API, which is replaced by a mock during tests (see VIES mock setup below). ECB rate lookups use the live ECB API in live mode or recorded fixtures in replay mode.

---

## Fixture set

Four fixtures cover the critical Cyprus VAT treatment paths:

| Fixture ID | Scenario | VAT treatment | Notes |
|---|---|---|---|
| `ledger_standard_expense` | Standard domestic expense; Cypriot supplier with valid VAT number | `DOMESTIC_STANDARD` (19%) | Most common expense path |
| `ledger_intraeu_purchase` | Service purchased from an EU-registered supplier (e.g., German SaaS vendor); valid VIES VAT number | `EU_REVERSE_CHARGE` | VIES validation required; reverse charge accounting |
| `ledger_exempt_service` | Exempt service (e.g., bank interest, insurance premium) | `OUTSIDE_SCOPE` | No VAT return line item |
| `ledger_mixed_rate_invoice` | Single invoice with three line items: one at 19%, one at 9% (restaurant), one at 0% (export service) | `DOMESTIC_STANDARD`, `DOMESTIC_REDUCED`, `DOMESTIC_ZERO` (per line) | Tests multi-rate line item handling |

Each fixture's `.setup.json` seeds the relevant transactions, counterparty record, and (for `ledger_intraeu_purchase`) a VAT number for the counterparty. The `.expected.json` pins the expected `vat_treatment`, `account_code`, and `vat_amount_eur` per ledger entry.

---

## Test steps

The following 4 steps execute for each of the 4 fixtures. Run against a clean test database seeded from `.setup.json`. The VIES mock endpoint must be activated before Step 1 for `ledger_intraeu_purchase`.

### Step 1 — Post entries via `ledger.post_entries`

```bash
ledger.post_entries({
  workflow_run_id: "<fixture run UUID>",
  business_id: "<fixture business UUID>",
  transaction_ids: ["<fixture transaction UUID(s)>"],
  mapping_version: "<fixture chart-of-accounts mapping version>"
})
```

For `ledger_mixed_rate_invoice`: `transaction_ids` contains a single transaction UUID that references a multi-line-item invoice. The ledger preparation dispatcher splits the transaction into one `ledger_entries` row per line item.

Assert: the call returns without error. The returned array contains one `ledger_entry` object per expected entry (1 for single-rate fixtures; 3 for `ledger_mixed_rate_invoice`).

### Step 2 — VAT treatment assertion

For each returned `ledger_entry`, assert `vat_treatment` equals the fixture's `expected_vat_treatment` from `.expected.json`.

| Fixture | Expected VAT treatment(s) |
|---|---|
| `ledger_standard_expense` | `DOMESTIC_STANDARD` |
| `ledger_intraeu_purchase` | `EU_REVERSE_CHARGE` |
| `ledger_exempt_service` | `OUTSIDE_SCOPE` |
| `ledger_mixed_rate_invoice` | `DOMESTIC_STANDARD` (line 1), `DOMESTIC_REDUCED` (line 2), `DOMESTIC_ZERO` (line 3) |

For `ledger_mixed_rate_invoice`, assert all three treatments are present on the three returned ledger entries. Assert the `vat_rate` on each entry matches the Cyprus VAT rate for the treatment: 19% for `DOMESTIC_STANDARD`, 9% for `DOMESTIC_REDUCED`, 0% for `DOMESTIC_ZERO`. Reference: Cyprus VAT rates are 19% standard, 9% and 5% reduced, 0% zero-rated, and exempt per `cyprus_vat_rule_catalog`.

### Step 3 — VIES validation assertion (`ledger_intraeu_purchase` only)

For `ledger_intraeu_purchase` only:

Assert:
- The mock VIES endpoint was called exactly once during Step 1's execution
- The call used the counterparty's VAT number from the fixture (`expected_vat_number` in `.setup.json`)
- The mock returned `VALID` and the ledger entry reflects `EU_REVERSE_CHARGE` treatment (from Step 2)
- A `VIES_LOOKUP_COMPLETED` audit event was emitted with `is_valid = true` in the payload

The mock call count is verified by querying the mock server's call log (see VIES mock setup below). Assert exactly 1 call; more than 1 call indicates an unintended retry or duplicate invocation.

For all other fixtures: assert 0 VIES calls (no EU supplier in those fixtures).

### Step 4 — `LEDGER_ENTRY_POSTED` audit event with account code assertion

Query the audit log for `event_type = 'LEDGER_ENTRY_CREATED'` with `subject_id = <transaction_id>`. Assert:
- One event per ledger entry (1 for single-entry fixtures; 3 for `ledger_mixed_rate_invoice`)
- `debit_account_id` and `credit_account_id` in each event payload match the fixture's `expected_debit_account_code` and `expected_credit_account_code` from `.expected.json`
- The account codes correspond to the active mapping version used in Step 1

For `ledger_intraeu_purchase`: assert the reverse charge accounts are used (the fixture's `.expected.json` pins the specific Cyprus chart-of-accounts codes for EU reverse charge debit and credit entries). The exact account codes are tied to the `mapping_version` parameter from Step 1.

---

## VIES mock setup

The `ledger_intraeu_purchase` fixture requires a VIES SOAP endpoint mock. The mock is set up before the test run using the test infrastructure's endpoint override:

```bash
export VIES_ENDPOINT_OVERRIDE=http://localhost:9876/vies-mock
```

The mock server at `localhost:9876` is started by the test harness before the fixture runs. Mock configuration:

```json
{
  "endpoint": "/vies-mock",
  "responses": [
    {
      "vat_number": "<fixture EU VAT number from .setup.json>",
      "country_code": "DE",
      "response": {
        "valid": true,
        "name": "Test EU Supplier GmbH",
        "address": "Musterstraße 1, 10115 Berlin"
      }
    }
  ]
}
```

The mock returns `VALID` for the fixture's VAT number. Any VIES SOAP call to a VAT number not in the mock's response list returns a configurable error (default: `MS_UNAVAILABLE`) to test the failure path if needed.

After the test run, the mock server's call log is queried to assert the exact call count per Step 3.

**Important:** the `VIES_ENDPOINT_OVERRIDE` environment variable must be unset after the test suite completes. A post-test cleanup hook enforces this. The production VIES endpoint is never called during automated test runs.

---

## Acceptance criteria

| Condition | Result |
|---|---|
| All 4 fixtures post ledger entries without error (Step 1) | Required |
| VAT treatments match expected per Cyprus VAT rule catalog (Step 2) | Required |
| Mixed-rate fixture produces 3 entries with correct rates (Step 2) | Required |
| VIES mock called exactly once for intra-EU fixture; `VALID` result applied (Step 3) | Required |
| All ledger entry audit events carry correct account codes from active mapping version (Step 4) | Required |

Any single failure blocks the deploy.

---

## Failure handling

On any step failure:

1. Emit `LIVE_TEST_FAILED` with:
   - `fixture_name`: e.g., `ledger_intraeu_purchase`
   - `step_number`: 1–4
   - `failure_detail`: specific assertion failure (wrong VAT treatment, wrong account code, mock call count mismatch, missing audit event)
2. Block deploy.
3. Operator investigation paths: Cyprus VAT rule catalog regression (check `cyprus_vat_rule_catalog` for recent changes), account code mapping version mismatch (check `ledger_account_mapping_version_schema` — the mapping version in the fixture may be stale), VIES mock misconfiguration (check endpoint override and mock VAT number), multi-rate line item split regression (check Block 11 Phase 07 dispatcher logic).

---

## Cross-references

- `ledger_entry_schema` — `ledger_entries` table; `vat_treatment`, `debit_account_id`, `credit_account_id`, `amount_eur` columns
- `cyprus_vat_rule_catalog` — binding VAT treatment rules for Cyprus; source of `expected_vat_treatment` assertions
- `vies_record_schema` — `vies_records` table; populated by VIES SOAP calls; queried in Step 3
- `live_integration_test_runbook` — cross-block cadence, cost containment, recording procedure, and drift detection infrastructure
- `audit_event_taxonomy` — `LEDGER_ENTRY_CREATED`, `VIES_LOOKUP_COMPLETED`, `LIVE_TEST_FAILED`
- `ledger_account_mapping_version_schema` — account mapping version management; the `mapping_version` parameter in Step 1
- Block 11 Phase 05 — VAT treatment assignment logic
- Block 11 Phase 07 — `ledger.post_entries` dispatcher; multi-rate line item splitting
- Block 11 Phase 08 — VAT amount computation; VIES integration
- Block 11 Phase 10 — end-to-end ledger tests; primary fixture host
