# classification_live_integration_runbook

**Category:** Runbooks · **Owning block:** 08 — Transaction Classification & Tagging · **Stage:** 4 sub-doc (Layer 2)

**Block reference:** Block 08 Phase 02 (Layer 1 deterministic classifier); Block 08 Phase 04 (Layer 2 model); Block 08 Phase 05 (Layer 3 — Anthropic Claude Tier 3 gateway); Block 08 Phase 10 (end-to-end classification tests).

**Purpose:** Cadence, fixture corpus, test steps, acceptance criteria, and tier-escalation validation for the Transaction Classification live integration test suite. Validates the full classification pipeline — Layer 1 rules, Layer 2 model, Layer 3 escalation, and vendor memory — against one canonical fixture per `transaction_type_enum` value.

---

## Cadence

| Trigger | Schedule | Scope |
|---|---|---|
| Pre-deploy | Before every production release | Full fixture corpus (14 type fixtures + 2 escalation fixtures) |
| Weekly scheduled | Monday 03:00 UTC (after bank statement live test completes) | Full corpus |
| Post-incident | After any AI model update or Layer 1 rule change | Full corpus + affected fixture re-recording |
| Manual | Engineering investigation | As needed |

Layer 3 invocations call the Anthropic Claude EU API and accrue cost. Weekly budget impact: 2 escalation fixtures × Tier 3 cost per `live_integration_test_runbook` cost table. Escalation fixtures run in live mode only; the 14 type fixtures use fixture replay for the Layer 2 and Layer 3 paths.

---

## Fixture corpus

### Per-type fixtures (14 fixtures)

One fixture per `transaction_type_enum` value. Each fixture object contains:

| Field | Type | Description |
|---|---|---|
| `fixture_id` | UUID v7 | Stable identifier pinned in the fixture file |
| `transaction_type` | `transaction_type_enum` | The type this fixture exercises |
| `amount_eur` | `numeric(15,2)` | Transaction amount in EUR, signed |
| `counterparty_name` | text | Raw counterparty name as it would appear in a bank statement |
| `description_raw` | text | Raw transaction narrative |
| `value_date` | date (`YYYY-MM-DD`) | Transaction date |
| `expected_category` | text | Expected `transaction_type` output from the classifier |
| `expected_confidence_min` | `numeric(3,2)` | Minimum acceptable calibrated confidence (0.00–1.00) |

For `UNKNOWN` type: `expected_category = 'UNCATEGORISED'` and `expected_confidence_min = 0`. Confidence is not asserted for `UNKNOWN` because the classifier intentionally withholds a confidence score for unclassifiable transactions.

Full fixture content is defined in `classification_per_type_fixture_content`.

### Tier escalation fixtures (2 fixtures)

Two additional fixtures with intentionally ambiguous descriptions that neither the Layer 1 rule engine nor the Layer 2 local model can resolve with confidence ≥ 0.70. These are designed to trigger the Layer 3 Anthropic Claude escalation path.

| Fixture ID | Description | Expected behaviour |
|---|---|---|
| `escalation_fixture_a` | Generic payment description with no recognisable counterparty or narrative pattern | Layer 1 no-match → Layer 2 confidence < 0.70 → Layer 3 escalation → `AI_TIER_ESCALATED` emitted |
| `escalation_fixture_b` | Mixed-language description (Greek and English combined) that falls below Layer 2 threshold | Same escalation path; tests multilingual handling |

These fixtures use live Layer 3 calls only during pre-deploy and weekly runs. In standard CI replay, Layer 3 responses are served from `ai_response_recording_fixtures`.

---

## Test steps

The following 5 steps execute for each fixture. For the 14 type fixtures, steps run in fixture-replay mode (no live AI calls, except for `escalation_fixture_a` and `escalation_fixture_b`).

### Step 1 — Submit to `classification.classify_transaction`

```bash
classification.classify_transaction({
  transaction_id: "<fixture transaction UUID>",
  amount_eur: <fixture amount>,
  counterparty_name: "<fixture counterparty_name>",
  description_raw: "<fixture description_raw>",
  value_date: "<fixture value_date>",
  business_id: "<fixture business UUID>"
})
```

Assert: the call returns without error. The returned object includes `transaction_type`, `confidence`, and `tier_used`.

### Step 2 — Category assertion

Assert: `returned.transaction_type` equals `fixture.expected_category`.

For `UNKNOWN` fixtures: assert `returned.transaction_type = 'UNKNOWN'` and `returned.category = 'UNCATEGORISED'`.

A category mismatch is a hard failure regardless of confidence level.

### Step 3 — Confidence threshold assertion

Assert: `returned.confidence >= fixture.expected_confidence_min`.

Skip this assertion for `UNKNOWN` fixtures (`expected_confidence_min = 0`).

The `confidence` value in the response is the calibrated output from `classification_confidence_output_schema`. It incorporates vendor memory boost where applicable.

### Step 4 — Vendor memory hit assertion

For fixtures where the `counterparty_name` corresponds to a vendor with prior confirmed history in the test business's vendor memory:

Assert: `returned.vendor_memory_hit = true` and `returned.tier_used = 'TIER_1'` (vendor memory promotes to Tier 1 without Layer 2/3 invocation).

The test business's vendor memory is seeded with confirmed history for a subset of fixture counterparty names. The fixture spec in `classification_per_type_fixture_content` marks which fixtures have `has_vendor_memory_seed = true`.

Fixtures without a vendor memory seed: assert `returned.vendor_memory_hit = false`.

### Step 5 — `CLASSIFICATION_RUN_COMPLETED` audit event assertion

Query the audit log for `event_type = 'CLASSIFICATION_RUN_COMPLETED'` with `subject_id = <transaction_id>`. Assert:
- Exactly 1 event found
- `transaction_type` in event payload matches `returned.transaction_type`
- `tier_used` in event payload matches `returned.tier_used`

---

## Tier escalation assertions

For `escalation_fixture_a` and `escalation_fixture_b`, apply the following additional assertions after the standard Step 5:

**Escalation Step A — `AI_TIER_ESCALATED` emitted:**

Query the audit log for `event_type = 'AI_TIER_ESCALATED'` scoped to the fixture's workflow run. Assert:
- At least 1 event found
- `from_tier = 'LOCAL'` and `to_tier = 'EXTERNAL'` in the event payload
- `from_confidence < 0.70` in the event payload (confirms the threshold that triggered escalation)

**Escalation Step B — Category returned:**

Assert `returned.transaction_type` is not `UNKNOWN` (Layer 3 must resolve to a definite type for both escalation fixtures). The specific expected type for each escalation fixture is pinned in the fixture's `.expected.json`.

---

## Acceptance criteria

| Condition | Result |
|---|---|
| All 14 type fixtures pass category match (Step 2) | Required |
| All 14 type fixtures meet confidence threshold (Step 3, excluding UNKNOWN) | Required |
| Vendor memory hit asserted correctly on seeded fixtures (Step 4) | Required |
| Both escalation fixtures emit `AI_TIER_ESCALATED` (Escalation Step A) | Required |
| Both escalation fixtures return a non-UNKNOWN category (Escalation Step B) | Required |
| All fixture audit events present (Step 5) | Required |

Any single failure blocks the deploy.

---

## Failure handling

On any step failure:

1. Emit `LIVE_TEST_FAILED` with:
   - `fixture_name`: e.g., `classification_OUT_EXPENSE` or `classification_escalation_a`
   - `step_number`: 1–5 or `ESCALATION_A` / `ESCALATION_B`
   - `failure_detail`: the specific assertion that failed (category mismatch, confidence value, missing audit event, etc.)
2. Block deploy.
3. Operator investigation paths: Layer 1 rule regression (rule set changed without fixture update), Layer 2 model drift (re-record AI fixtures), vendor memory seed not applied (check test DB seed job), Layer 3 API change (re-record escalation fixtures in live mode).

---

## Cross-references

- `transaction_type_enum` — the 12-value closed enum; each value has exactly one fixture
- `classification_confidence_output_schema` — calibrated confidence output shape; defines the `confidence` field asserted in Step 3
- `classification_per_type_fixture_content` — canonical fixture corpus with all 14 fixture objects and vendor memory seed flags
- `live_integration_test_runbook` — cross-block cadence, recording procedure, cost containment, and drift detection infrastructure
- `audit_event_taxonomy` — `CLASSIFICATION_RUN_COMPLETED`, `AI_TIER_ESCALATED`, `LIVE_TEST_FAILED`
- Block 08 Phase 02 — Layer 1 deterministic classifier
- Block 08 Phase 04 — Layer 2 local model
- Block 08 Phase 05 — Layer 3 Anthropic Claude escalation path
- Block 08 Phase 10 — end-to-end classification tests; primary fixture host
