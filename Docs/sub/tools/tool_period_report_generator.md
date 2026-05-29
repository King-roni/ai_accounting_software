# tool_period_report_generator

**Category:** Tools · **Owning block:** 16 — Dashboard & Reporting · **Co-owner:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 1 cross-block tool)

The canonical period-report PDF generator. Called synchronously by Block 15 during the lock sequence (step 3) and asynchronously by Block 16 on-demand. Produces a deterministic PDF for a given period snapshot.

Renamed from `report.generatePeriodReport` (camelCase, original 2026-05-09 amendment) to the snake_case canonical form per the 2026-05-09 Stage 4 Layer 1 convention amendment in `Docs/decisions_log.md`.

---

## Function signature

```ts
report.generate_period_report({
  workflow_run_id: uuid,
  period_snapshot: PeriodSnapshot,
}): pdf_bytes
```

### `PeriodSnapshot` shape

The snapshot is the deterministic structured-data input prepared at Block 15 Phase 04's lock-sequence step 1 ("Snapshot operational records"). It carries every field the report renders — the function never re-queries operational DB state.

```ts
type PeriodSnapshot = {
  snapshot_id: uuid,                    // unique per snapshot build; cache key component
  business_id: uuid,
  period_start: date,                   // inclusive
  period_end: date,                     // inclusive
  workflow_run_id: uuid,                // for traceback in the rendered footer
  workflow_type: "OUT_MONTHLY" | "OUT_ADJUSTMENT" | "IN_MONTHLY" | "IN_ADJUSTMENT" | "FINALIZATION",
  ledger_entries: LockedLedgerEntry[],  // already snapshotted from draft_ledger_entries
  transactions: Transaction[],          // canonical projection per snapshot
  documents: Document[],                // canonical projection per snapshot
  match_records: MatchRecord[],         // canonical projection per snapshot
  review_issues: ReviewIssue[],         // state at lock-sequence-step-1 moment
  vat_summary: VatSummary,              // pre-computed
  chart_mapping_version_id: uuid,       // pinned chart version (per Block 11 Phase 03)
  adjustment_overlay?: AdjustmentOverlay, // present only on adjustment-finalization
  business_metadata: BusinessMetadata,  // legal name, VAT number, address, logo file ref
};
```

For adjustment-finalization, `adjustment_overlay` carries the original-locked entries + the adjustment-draft entries; the renderer overlays the adjustment delta on the original layout.

For user-triggered re-render of a finalized period (rare), the caller rebuilds the snapshot from `archive.locked_ledger_entries` (per the 2026-05-09 amendment).

### Return

`pdf_bytes` — the rendered PDF as a binary buffer.

## Side-effect class and AI tier

- **Side-effect class:** `READ_ONLY | WRITES_AUDIT`
- **AI tier:** `NONE`

The tool reads `business_metadata` (logo file ref → Storage read) and renders the PDF. No operational-DB writes. Audit events on success and failure (below).

## Audit events emitted

| Event | When | Payload |
| --- | --- | --- |
| `EXPORT_PDF_RENDERED` | Successful render | `{ workflow_run_id, business_id, snapshot_id, byte_size, render_duration_ms, font_bundle_sha }` |
| `EXPORT_FAILED` | Any failure | `{ workflow_run_id, business_id, snapshot_id, failure_class, failure_message }` |

## Determinism

Same `(workflow_run_id, period_snapshot)` → byte-identical PDF. Determinism is the contract:

- **Font pinning** per `pdf_generation_policies` (Inter / Inter Display / JetBrains Mono with pinned SHAs)
- **Library version pinning** per `csv_xlsx_pdf_library_integration` (Stage 4 sub-doc, Block 16)
- **Deterministic ordering** of every list: ledger entries by `(entry_date, entry_kind, account_code, primary_entry_id)`; transactions by `(date, source_row_hash)`; documents by `(supplier_normalized, document_date)`
- **No timestamps in the body** (a render timestamp appears in the footer; its value is deterministic from `period_snapshot.snapshot_id` — not from `now()`)
- **No locale-sensitive sort** — every sort uses byte-codepoint ordering with explicit collation

Determinism is asserted in CI by the `pdf_determinism_fixtures` test (Block 16 Phase 13). Two renders of the same snapshot must produce byte-identical bytes; failure blocks merge.

## Failure path

When called by Block 15 during finalization:

1. Tool fails with a structured exception (`PeriodReportFailedException`)
2. Block 15 Phase 04's auto-retry-once contract triggers per `lock_sequence_policies`
3. If the retry also fails, Block 15 raises `archive.finalization_period_report_failed` review issue (HIGH severity) and halts the lock sequence at the precondition gate
4. User intervention: investigate root cause; re-trigger finalization once resolved
5. The lock sequence resumes from where it stopped (Block 03 Phase 07 resumability)

When called on-demand by Block 16 (re-render):

1. Tool fails with a structured exception
2. Block 16 surfaces the failure via the export pipeline (`report.export_failed` review issue, HIGH)
3. No automatic retry on-demand; user retries manually

## Failure classes

| Class | Recovery | Notes |
| --- | --- | --- |
| `SNAPSHOT_INVALID` | Permanent | Snapshot violates schema; caller error |
| `FONT_RESOLUTION_FAILED` | Transient (auto-retry) | Font asset missing or SHA mismatch; redeploy fix |
| `LIBRARY_FAILURE` | Mixed | Underlying PDF library threw — retry once; permanent on second failure |
| `STORAGE_READ_FAILED` | Transient (auto-retry) | Business logo Storage fetch failed |
| `OUT_OF_MEMORY` | Permanent | Snapshot too large; investigate and split-render (not in MVP) |

## Performance budget

Per `fixture_performance_budget` Block 16 row:

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| `report.generate_period_report` (50 entries) | 5 s | 15 s | 30 s |
| `report.generate_period_report` (500 entries) | 30 s | 90 s | 180 s |

If P95 exceeds budget during lock sequence (during finalization), the lock-sequence performance contract per `lock_sequence_policies` carries the burden — block 15's perf budget includes this tool's cost.

## Concurrency

Multiple concurrent invocations against different `workflow_run_id`s are safe — the tool reads per-snapshot data with no shared state.

The same `workflow_run_id` invoked concurrently (one from Block 15, one from Block 16) is also safe — both read the same snapshot deterministically; the rendered output is identical.

## Cross-block contract

This tool is the contract surface for the `report.generate_period_report({ workflow_run_id, period_snapshot }) → pdf_bytes` cross-block call. Block 15 Phase 04 / 05 / 06 calls it; Block 16 owns implementation. The contract is binding per the 2026-05-09 decisions-log amendment.

Signature changes require an amendment. Major-bump (per `tool_naming_convention_policy`) deprecation lives one workflow-run cycle.

## Registration

```ts
engine.registerTool({
  name: "report.generate_period_report",
  schema_version: "1.0",
  side_effect_class: ["READ_ONLY", "WRITES_AUDIT"],
  ai_tier: "NONE",
  input_schema_ref: "tool_period_report_generator#v1.input",
  output_schema_ref: "tool_period_report_generator#v1.output",
  audit_events: ["EXPORT_PDF_RENDERED", "EXPORT_FAILED"],
  description_ref: "Docs/sub/tools/tool_period_report_generator.md",
});
```

## Mobile

`report.generate_period_report` is invoked internally by the archive and reporting pipeline and is not a direct user-callable endpoint. Mobile write rejection is enforced at the `report.trigger_export` layer per `mobile_write_rejection_endpoints.md`. This tool itself has no independent mobile exposure.

## Cross-references

- `tool_naming_convention_policy` — naming + registration shape
- `audit_log_policies` — `EXPORT_*` event naming
- `pdf_generation_policies` — font SHA pinning
- `pdf_generation_policies` — PDF/A-2a vs tagged PDF/1.7 format choice
- `csv_xlsx_pdf_library_integration` — library version pinning
- `lock_sequence_policies` — Block 15's auto-retry-once contract
- `archive_manifest_schemas` — manifest carries `period_report_sha`
- `pdf_determinism_fixtures` — CI determinism assertion
- `fixture_performance_budget` — latency targets
- Block 15 Phase 04 — lock sequence step 3 calls this tool
- Block 16 Phase 10 — PDF generators (architecture)
- 2026-05-09 decisions-log amendments — snapshot-input contract + snake_case rename
- `mobile_write_rejection_endpoints.md` — mobile write rejection policy; enforced at `report.trigger_export` layer
