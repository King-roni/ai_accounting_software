# Finalization Per-Fixture Content

**Category:** Fixtures · **Owning block:** 15 — Finalization & Secure Archive · **Block reference:** Block 15 § Phase 04 (Lock Sequence), Phase 06 (Archive Promotion), Phase 09 (Compensation) · **Stage:** 4 sub-doc (Layer 2 fixture corpus)

**Purpose:** Defines the canonical fixture set for finalization live integration tests. Three scenarios cover the normal path, the compensation path, and tamper detection. These fixtures are the primary deterministic test corpus for the Block 15 lock sequence; the live integration tests described in `finalization_failure_per_mode_runbook.md` reference these fixture IDs directly. Any engineer adding a new finalization test scenario must register a new fixture here before writing the test.

All fixture files live at `fixtures/archive/` per the `fixture_format_spec.md` block-short-name convention (`archive` namespace per `tool_naming_convention_policy`).

---

## Fixture format reference

Each fixture conforms to `fixture_format_spec.md`. The fields below are the binding contract:

| Field | Type | Description |
|---|---|---|
| `fixture_id` | string | Stable identifier; never renamed after creation |
| `scenario_name` | string | Human description of what this fixture exercises |
| `setup_steps` | ordered list | Pre-test database and object storage state |
| `expected_events` | ordered list | Audit events in the order they must be emitted |
| `expected_terminal_state` | `run_status_enum` value | The workflow run state after the scenario completes |

---

## Scenario 1 — Normal finalization path

**Fixture ID:** `archive_finalization_normal_path_v1`
**File:** `fixtures/archive/finalization_normal_path.fixture.ts`

### Scenario

A workflow run completes all phases, passes all 8 finalization gates, receives a valid step-up approval, and completes the 5-step lock sequence without error. This is the expected production path; the fixture asserts every step of the lock sequence completes and the archive bundle is integrity-verified.

### Setup steps

1. Insert a `workflow_runs` row with `run_status = AWAITING_APPROVAL`, `period_start = 2026-03-01`, `period_end = 2026-03-31`.
2. Insert 3 `draft_ledger_entries` rows scoped to the run, all with valid VAT treatment and counterparty.
3. Insert 2 documents in `PROCESSED` state scoped to the run, with valid `evidence_hash` and `content_hash` values.
4. Insert a valid `workflow_run_approvals` row with `approval_method = STEP_UP`, `status = APPROVED`, and `data_state_hash` matching the run's current state.
5. Assert all 8 finalization gates return `ADVANCE` for this run (`engine.gate_finalization_preconditions_satisfied`).

### Expected events (ordered)

1. `FINALIZATION_PRECONDITION_EVALUATED`
2. `FINALIZATION_LOCK_STARTED`
3. `FINALIZATION_LEDGER_BULK_LOCKED`
4. `ARCHIVE_BUNDLE_PASS1_COMPLETED`
5. `ARCHIVE_BUNDLE_PASS2_COMPLETED`
6. `ARCHIVE_PACKAGE_BUILT`
7. `OBJECT_LOCK_RETENTION_SET`
8. `TIMESTAMP_RECORDED`
9. `ARCHIVE_PROMOTION_COMPLETED`
10. `FINALIZATION_LOCK_COMMITTED`
11. `ARCHIVE_VERIFIED`

### Assertions

- All 5 lock sequence steps complete in order (Steps 1–5 per `lock_sequence_policies`).
- The `archive_bundles` row has a non-null `bundle_hash` (hex SHA-256 of the sealed ZIP bytes).
- The `bundle_hash` is stored in `archive.archive_packages.bundle_hash` and matches the `manifest_hash` field in `archive.archive_manifests.manifest_canonical_json`.
- The `archive.archive_manifests` row has `manifest_version_number = 1` and `is_current = true`.
- The `period_lock_status` row has `manifest_version = 1` and `is_current = true`.
- The workflow run transitions to `run_status = FINALIZED`.

### Expected terminal state

`FINALIZED`

---

## Scenario 2 — Compensation path

**Fixture ID:** `archive_finalization_compensation_path_v1`
**File:** `fixtures/archive/finalization_compensation_path.fixture.ts`

### Scenario

A workflow run begins the lock sequence and completes Step 1 (ledger snapshot freeze). Step 2 (archive bundle creation) and Step 3 (Object Lock application) succeed. At Step 3, the Object Lock call succeeds on the storage side but returns a network timeout before the response is recorded — simulating a partial-write failure after Object Lock is applied. This triggers compensation. Because Object Lock cannot be deleted (immutable by design), the `archive_packages` row is marked `COMPENSATION_ORPHAN`. The run transitions to `FAILED` after compensation completes.

### Setup steps

1. Insert a `workflow_runs` row with `run_status = AWAITING_APPROVAL`.
2. Insert 2 `draft_ledger_entries` rows scoped to the run.
3. Insert a valid `workflow_run_approvals` row with `approval_method = STEP_UP` and `status = APPROVED`.
4. Configure the test harness to inject a network timeout after Step 3 Object Lock write, before the ETag response is recorded on `archive_packages`.

### Expected events (ordered)

1. `FINALIZATION_PRECONDITION_EVALUATED`
2. `FINALIZATION_LOCK_STARTED`
3. `FINALIZATION_LEDGER_BULK_LOCKED`
4. `ARCHIVE_BUNDLE_PASS1_COMPLETED`
5. `ARCHIVE_BUNDLE_PASS2_COMPLETED`
6. `ARCHIVE_PACKAGE_BUILT`
7. `OBJECT_LOCK_RETENTION_SET` (emitted by the storage layer before the timeout)
8. `FINALIZATION_FAILED` (emitted when the step-3 timeout is detected)
9. `FINALIZATION_ROLLED_BACK` (compensation sequence initiates)

### Assertions

- The workflow run transitions to `COMPENSATING` before transitioning to `FAILED`.
- A `compensation_log` row exists for the run with `compensation_outcome = SUCCEEDED` and `compensation_completed_at` not null.
- The `archive_packages` row for this run has `bundle_object_uri` populated (the Object Lock was applied) and is marked with the `COMPENSATION_ORPHAN` flag.
- No `period_lock_status` row exists for this run (lock sequence did not reach Step 5).
- The workflow run terminal state is `FAILED`, not `FINALIZED`.
- No `ARCHIVE_PROMOTION_COMPLETED` event is emitted.

### Expected terminal state

`FAILED`

---

## Scenario 3 — Tamper detection (non-production only)

**Fixture ID:** `archive_tamper_detection_sim_v1`
**File:** `fixtures/archive/tamper_detection_sim.fixture.ts`

**Warning:** This fixture must not run in production environments. It intentionally corrupts stored data to simulate tampering. The test harness marks this fixture with `@NonProductionOnly` and the CI pipeline gates it behind `TEST_ENV = staging | ci`. Any attempt to run this fixture against a production database is blocked by the fixture loader.

### Scenario

A workflow run completes normal finalization (same setup as Scenario 1). After `ARCHIVE_PROMOTION_COMPLETED` is emitted, the test harness directly corrupts the `bundle_hash` value in `archive.archive_packages` to simulate an attacker or storage corruption event. The archive verification tool is then run against the corrupted bundle. The fixture asserts that tamper detection fires, the correct audit event is emitted, and integrity is restored after the correct hash is written back.

### Setup steps

1. Run Scenario 1 setup steps (insert run, 3 ledger entries, 2 documents, approval row).
2. Execute the full normal finalization path and assert `ARCHIVE_PROMOTION_COMPLETED` is emitted.
3. Record the correct `bundle_hash` value from `archive.archive_packages`.
4. Directly overwrite `archive.archive_packages.bundle_hash` with a deterministically corrupted value: SHA-256 hex of the string `"tampered"`.
5. Assert the run is `FINALIZED` and `ARCHIVE_VERIFIED` was emitted during normal finalization.

### Expected events on tamper detection run (ordered)

1. `ARCHIVE_TAMPER_DETECTED`

### Expected events on restoration run (ordered)

1. `ARCHIVE_VERIFIED`

### Assertions — tamper detection

- Calling `archive.verify_bundle` on the corrupted package emits `ARCHIVE_TAMPER_DETECTED` with `archive_package_id`, `business_id`, `period_start`, `period_end`, and `failure_detail` indicating the hash mismatch.
- `ARCHIVE_TAMPER_DETECTED` severity is `BLOCKING` per `audit_event_taxonomy`.
- A `SECURITY_ALERT` is raised alongside the tamper event.
- No `ARCHIVE_VERIFIED` event is emitted during the corrupted run.

### Assertions — restoration

- Restore the correct `bundle_hash` to `archive.archive_packages`.
- Call `archive.verify_bundle` again.
- Assert `ARCHIVE_VERIFIED` is emitted and no tamper event is emitted.
- Assert `ARCHIVE_TAMPER_FALSE_POSITIVE_CLEARED` is NOT emitted (this is not a false positive — the restoration is a deliberate test step).

### Expected terminal state

`FINALIZED` (the run state is not changed by the verification pass; the tamper detection raises an alert but does not alter run state)

---

## Cross-references

- `finalization_failure_per_mode_runbook.md` — runbook for handling actual finalization failures; references these fixture IDs
- `archive_bundle_construction_schema.md` — two-pass manifest construction, `bundle_hash` storage, and `manifest_canonical_json` format
- `lock_sequence_policies.md` — 5-step lock sequence, compensation semantics, `COMPENSATION_ORPHAN` handling
- `compensation_log_schema.md` — `compensation_log` table structure and `compensation_outcome_enum`
