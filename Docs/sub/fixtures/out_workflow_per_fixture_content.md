# out_workflow_per_fixture_content

**Category:** Fixtures · **Owning block:** 12 — OUT Workflow · **Co-owner:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 1 cross-block fixture spec)

The Block 12-specific content shape for OUT_MONTHLY and OUT_ADJUSTMENT fixtures. Per `fixture_format_spec`: each block's fixtures customize the standard shape with block-specific content. This spec pins what's in an OUT_MONTHLY fixture's `setup`, `input`, and `expected` blocks.

The IN-side fixtures follow the same shape with `IN_*` substitutions. Block 13 contributes the IN-side variant under the same conventions.

---

## OUT_MONTHLY fixture content shape

### `setup` block

```ts
setup: {
  business: {
    id: "...",                                   // deterministic UUID v7
    name: "Acme Cyprus Ltd",
    legal_name: "Acme Cyprus Limited",
    vat_number: "CY12345678X",
    country_iso: "CY",
    accounting_method: "ACCRUAL",                // Stage 1 default
    enabled_workflows: ["OUT_MONTHLY", "IN_MONTHLY"],
  },

  bank_accounts: [
    {
      id: "...",
      currency: "EUR",
      bank_name: "Bank of Cyprus",
      account_number_masked: "****1234",
      iban_encrypted: "<encrypted_placeholder>",
    },
  ],

  chart_of_accounts: {
    version_label: "Cyprus default v1",
    accounts: [...],                              // 80-account standard chart per cyprus_default_chart_catalog
  },

  recurring_vendor_memory: [
    {
      vendor_id: "...",
      vendor_signature: "andreas karasidis constructions",
      confirmations_count: 3,                     // HIGH tier
      first_seen_at: "2025-10-01",
    },
  ],

  classification_rules: [
    {
      rule_id: "...",
      pattern_field: "normalized_description",
      pattern_value: "BANK FEE",
      target_type: "BANK_FEE",
    },
  ],

  workflow_runs: [],                              // no prior runs (typical OUT_MONTHLY starts fresh)
  documents: [],
  invoices: [],
}
```

### `input` block

```ts
input: {
  statement_upload: {
    file: "./statement_revolut_january.csv",     // sibling data file
    statement_kind: "STATEMENT_CSV",
    declared_period_start: "2026-01-01",
    declared_period_end: "2026-01-31",
    bank_account_id: "...",                       // FK from setup
    actor_user_id: "...",
  },

  // For OUT_ADJUSTMENT fixtures, also:
  adjustment_intake?: {
    parent_run_id: "...",
    adjustment_records: [
      {
        target_record_kind: "transactions",
        target_record_id: "...",
        delta_kind: "CORRECT_VAT_TREATMENT",
        delta_payload: {...},
        reason_text: "...",
      },
    ],
  },

  // User interventions during the workflow
  user_interventions: [
    {
      stage: "REVIEW_HOLD",
      action: "resolve_issue",
      issue_id: "...",
      resolution_action_type: "confirm_match",
    },
    {
      stage: "AWAITING_APPROVAL",
      action: "approve",
      approver_user_id: "...",
      step_up_token: "<simulated_per_step_up_auth_fixture_simulation>",
    },
  ],
}
```

### `expected` block

```ts
expected: {
  transactions: {
    count: 50,
    by_type: {
      OUT_EXPENSE: 35,
      IN_INCOME: 12,
      INTERNAL_TRANSFER: 2,
      BANK_FEE: 1,
    },
    by_classification_method: {
      RULE: 5,                                    // Layer 1
      VENDOR_MEMORY: 30,                          // Layer 2
      AI_FALLBACK: 10,                            // Layer 3 — these triggered Tier 3 calls
      MANUAL: 5,                                  // user reclassified during review
    },
    by_match_status: {
      MATCHED_AUTO_HIGH_CONFIDENCE: 25,
      MATCHED_CONFIRMED: 8,
      UNMATCHED: 0,
      EXCEPTION_DOCUMENTED: 2,
    },
  },

  review_issues: [
    {
      issue_type: "matching.weak_possible_match",
      severity: "MEDIUM",
      issue_group: "Possible Wrong Match",
      count: 5,
    },
    {
      issue_type: "ledger.unresolved_counterparty",
      severity: "MEDIUM",
      count: 3,
    },
  ],

  workflow_run: {
    workflow_type: "OUT_MONTHLY",
    final_status: "FINALIZED",
    completed_at_within: "180 seconds from created_at",
  },

  ledger_entries: {
    count: 55,                                    // 50 transactions, some FX-derived
    by_vat_treatment: {
      DOMESTIC_STANDARD: 35,
      DOMESTIC_REDUCED: 8,
      EU_REVERSE_CHARGE: 5,
      OUTSIDE_SCOPE: 7,
    },
  },

  archive_bundle: {
    created: true,
    bundle_hash_matches_expected_format: true,
    object_lock_set: true,
    rfc_3161_anchor_recorded: true,
  },

  audit_events: [
    // Ordered list of events that should fire
    "STATEMENT_UPLOADED",
    "STATEMENT_UPLOAD_COMPLETED",
    "CLASSIFICATION_RUN_STARTED",
    "WORKFLOW_TOOL_INVOKED",
    // ... per the OUT_MONTHLY phase sequence
    "FINALIZATION_LOCK_COMMITTED",
    "ARCHIVE_PROMOTION_COMPLETED",
  ],

  ai_calls: {
    document_ai_count: 0,                         // CSV upload doesn't need OCR
    classifier_layer_3_count: 10,
    plain_language_pipeline_count: 5,             // for review-card content
    total_estimated_cost_eur_cents: 12,
  },
}
```

## Subset variants

Per Block 12 Phase 10 fixture catalogue:

| Variant | Difference from base |
| --- | --- |
| `out_monthly_partial_upload_30_transactions` | Statement is missing transactions; partial-upload HIGH issue fires |
| `out_monthly_with_fx_exchange` | Includes 3 FX_EXCHANGE transactions with paired legs |
| `out_monthly_with_unknown_blocker` | 1 transaction is UNKNOWN; user reclassifies during review |
| `out_monthly_re_enters_manual_upload_hold_after_recompute` | Tests the re-entry path per Block 12 scan |
| `out_monthly_user_documents_exception` | 1 transaction routed via `mark_as_no_invoice_available` |
| `out_monthly_concurrent_with_in_monthly` | Paired with IN_MONTHLY per `shared_phase_coordination_policy` |
| `out_adjustment_correct_vat_treatment` | OUT_ADJUSTMENT with single CORRECT_VAT_TREATMENT delta |
| `out_adjustment_multiple_concurrent` | Two OUT_ADJUSTMENT runs per `out_adjustment_policies` |

Each variant is a `.fixture.ts` file in `fixtures/out_workflow/`.

## IN-side variants

Block 13 contributes IN_MONTHLY fixtures with the same content shape, substituting:

- `statement_upload` → `invoice_creation` + `received_payment_statement_upload`
- Most expected `by_type` values shifted to IN_INCOME
- Review issues focus on `in_workflow.*` issue types
- Adjustment cases use `ISSUE_CREDIT_NOTE`, `WRITE_OFF_INVOICE`, `CONVERT_TO_TAX_INVOICE`

The IN_MONTHLY fixture file shape mirrors OUT_MONTHLY 1:1 with the substitutions; Block 13 sub-docs cover the variant set.

## Performance assertion

Each fixture asserts the cumulative per-call AI cost stays within `ai_cost_projection_policy` (now part of `redaction_policies` cross-references) defaults. Typical OUT_MONTHLY cost: < €0.20 per run.

## Cross-references

- `fixture_format_spec` — base shape
- `ai_response_recording_fixtures` — AI replay
- `cross_block_fixture_stitching` — multi-block stitching
- `fixture_performance_budget` — latency assertions
- `step_up_auth_fixture_simulation` — approval step-up simulation
- `transaction_type_enum` — `by_type` enum values
- `vat_treatment_enum` — `by_vat_treatment` enum values
- `severity_enum` — `severity` field
- `issue_group_enum` — `issue_group` field
- `audit_event_taxonomy` — expected_events list
- `recurring_vendor_memory` schema (Block 08) — setup block content
- `cyprus_default_chart_catalog` (Block 11) — setup chart of accounts
- Block 12 Phase 10 — end-to-end OUT workflow tests (canonical fixture host)
