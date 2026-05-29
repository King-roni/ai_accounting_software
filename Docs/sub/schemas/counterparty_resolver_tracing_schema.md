# counterparty_resolver_tracing_schema

**Category:** Schemas · **Owning block:** 11 — Ledger & Cyprus VAT Engine · **Co-owner:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 2)

The trace table that records every per-attempt step Block 11 Phase 04's counterparty resolver tries. Per Block 11 Phase 04's sub-doc hook "Resolver tracing sub-doc — what we record for each resolution attempt (used for debugging accountant-review cases)." When a draft ledger entry surfaces in the accountant-review queue with an `LEDGER_COUNTERPARTY_UNRESOLVED` or `LEDGER_COUNTERPARTY_DISAGREEMENT_DETECTED` flag, the accountant needs a forensic record of every step the resolver attempted — which source it consulted, what it observed, why each step succeeded or failed.

The trace is write-once, append-only, and queryable by ledger-entry-id. It is NOT part of the operational hot path — production code paths emit traces asynchronously, and a trace failure never blocks the resolver from advancing.

---

## Resolution chain reference

Per Block 11 Phase 04 (with the 2026-05-08 amendment's IN-side branch), the chain is:

| Step | Source | Run-type conditional |
| --- | --- | --- |
| 1 | Matched-document extracted fields (Block 09) | all run types |
| 1.5 | `clients` registry (IN-side via `tool_clients_registry`) | IN_MONTHLY, IN_ADJUSTMENT only |
| 2 | Vendor memory (Block 08 Phase 03) | all run types |
| 3 | Transaction metadata (IBAN/BIC country prefix, descriptor patterns) | all run types |
| 4 | VIES online validation | only for steps that produced a VAT number |
| 5 | Manual override (per-entry override row) | always evaluated last; short-circuits if present |

Each step the resolver attempts gets one trace row. The accountant reviewer reads the trace top-to-bottom to reconstruct the resolution attempt.

## Table definition

```sql
CREATE TYPE resolver_step_kind_enum AS ENUM (
  'DOCUMENT_FIELDS',
  'CLIENTS_REGISTRY',
  'VENDOR_MEMORY',
  'TRANSACTION_METADATA',
  'VIES_VALIDATION',
  'MANUAL_OVERRIDE'
);

CREATE TYPE resolver_step_outcome_enum AS ENUM (
  'HIT',
  'MISS',
  'SKIPPED',
  'DISAGREEMENT',
  'FAILED'
);

CREATE TYPE resolver_confidence_enum AS ENUM (
  'HIGH',
  'MEDIUM',
  'LOW'
);

CREATE TABLE counterparty_resolver_traces (
  trace_id                  uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id               uuid NOT NULL REFERENCES business_entities(id),

  -- Subject of the resolution attempt
  draft_ledger_entry_id     uuid NOT NULL REFERENCES draft_ledger_entries(id),
  transaction_id            uuid NOT NULL REFERENCES transactions(transaction_id),
  match_record_id           uuid REFERENCES match_records(match_record_id),
  workflow_run_id           uuid NOT NULL REFERENCES workflow_runs(workflow_run_id),

  -- Step identity
  step_index                smallint NOT NULL,                       -- 1..N within this resolution attempt
  step_kind                 resolver_step_kind_enum NOT NULL,
  step_outcome              resolver_step_outcome_enum NOT NULL,
  step_confidence           resolver_confidence_enum,                -- present on HIT / DISAGREEMENT

  -- Step input (canonical JSON, fully replayable)
  input_canonical_json      text NOT NULL,
  input_hash                text NOT NULL,                           -- hex SHA-256 of input_canonical_json

  -- Step output / observation
  observed_country_iso      char(2),
  observed_vat_number       text,
  observed_source_pointer   jsonb,                                   -- { document_id?, client_id?, vendor_memory_id?, transaction_field? }
  miss_or_skip_reason       text,                                    -- present on MISS / SKIPPED / FAILED

  -- Disagreement linkage (when this step's output conflicts with an earlier HIT)
  disagrees_with_trace_id   uuid REFERENCES counterparty_resolver_traces(trace_id),

  -- Step timing
  started_at                timestamptz NOT NULL,
  finished_at               timestamptz NOT NULL,
  duration_ms               integer NOT NULL,

  -- Audit linkage
  audit_event_id            uuid,                                    -- FK-like to audit_log.event_id

  created_at                timestamptz NOT NULL DEFAULT now(),

  -- Constraints
  CHECK (
    step_outcome IN ('MISS', 'SKIPPED', 'FAILED')
    OR step_confidence IS NOT NULL
  ),
  CHECK (
    step_outcome NOT IN ('MISS', 'SKIPPED', 'FAILED')
    OR miss_or_skip_reason IS NOT NULL
  ),
  CHECK (
    step_outcome <> 'DISAGREEMENT'
    OR disagrees_with_trace_id IS NOT NULL
  ),
  CHECK (
    finished_at >= started_at
  ),
  UNIQUE (draft_ledger_entry_id, step_index)
);
```

The `UNIQUE (draft_ledger_entry_id, step_index)` constraint enforces idempotency: a retry of a step writes the same `step_index` value and either re-INSERTs (failing on the unique constraint, signalling the retry's redundancy) or no-ops via `ON CONFLICT DO NOTHING`. The audit chain captures the retry independently.

## Per-step recording contract

Each step records:

- **Input** — exactly what the resolver gave the step. Canonical JSON per `data_layer_conventions_policy` so the trace is byte-stable across replicas and the hash can verify integrity.
- **Output** — what the step observed (or nothing, on MISS / SKIPPED). The observation is two scalar fields (`observed_country_iso`, `observed_vat_number`) plus the `observed_source_pointer` JSONB that pins the row the observation came from.
- **Confidence** — when the step produced an observation, its self-reported confidence (`HIGH` / `MEDIUM` / `LOW` per Block 11 Phase 04's per-step rules).
- **Outcome** — one of five closed values (`HIT`, `MISS`, `SKIPPED`, `DISAGREEMENT`, `FAILED`).
- **Reason** — required on MISS / SKIPPED / FAILED; human-readable explanation.
- **Timing** — `started_at`, `finished_at`, `duration_ms` for per-step latency forensics.

### Outcome semantics

| Outcome | When |
| --- | --- |
| `HIT` | Step produced a candidate country/VAT-number pair |
| `MISS` | Step ran but found no candidate (e.g., vendor memory lookup empty) |
| `SKIPPED` | Step skipped per the chain's run-type rule (e.g., CLIENTS_REGISTRY on an OUT-side run) |
| `DISAGREEMENT` | Step produced a candidate that conflicts with a prior `HIT` — `disagrees_with_trace_id` points at the prior trace |
| `FAILED` | Step threw an unrecoverable error (e.g., VIES service unreachable mid-validation) |

A `DISAGREEMENT` outcome corresponds to `LEDGER_COUNTERPARTY_DISAGREEMENT_DETECTED` per `audit_event_taxonomy`. The resolver continues per Phase 04's rule (higher-confidence source wins), but every disagreement is recorded.

## Hashing contract

`input_hash` is hex SHA-256 of the canonical JSON per `data_layer_conventions_policy`. The hash lets forensic readers verify two equivalent inputs produced the same step outcome — useful when investigating "this transaction resolved differently last week" cases. The hashing is mandatory; a step that cannot canonicalize its input must FAIL rather than INSERT a non-replayable row.

## Retention

Traces follow the parent draft-ledger-entry's retention. Per `retention_policies_schema` (Block 04): when the draft entry is finalized into `archive.locked_ledger_entries`, the traces are copied as-is into `archive.counterparty_resolver_traces` (sibling archive table; structure identical). The operational `counterparty_resolver_traces` row is then eligible for retention pruning per the standard Cyprus 6-year window.

Adjustment-run traces (per `adjustment_entry_schema`) are linked via the entry's `adjustment_record_id`. The trace lifecycle follows the adjustment record's lifecycle.

## Query patterns for accountant-review forensics

### Pattern 1 — Full trace for a specific entry

```sql
SELECT step_index, step_kind, step_outcome, step_confidence,
       observed_country_iso, observed_vat_number,
       miss_or_skip_reason, duration_ms
FROM counterparty_resolver_traces
WHERE business_id  = $1
  AND draft_ledger_entry_id = $2
ORDER BY step_index;
```

Backed by the `UNIQUE (draft_ledger_entry_id, step_index)` index. P95 < 50 ms (per the Block 11 row of `fixture_performance_budget`'s "Manual override pre-check" budget tier for similar single-entry lookups).

### Pattern 2 — All disagreements for a business in a window

```sql
SELECT *
FROM counterparty_resolver_traces
WHERE business_id  = $1
  AND step_outcome = 'DISAGREEMENT'
  AND started_at  >= $2
  AND started_at  <  $3
ORDER BY started_at DESC
LIMIT 100;
```

Backed by `(business_id, step_outcome, started_at)` partial index. Used by the accountant pack's "investigations" view.

### Pattern 3 — Step performance distribution

```sql
SELECT step_kind, percentile_cont(0.5)  WITHIN GROUP (ORDER BY duration_ms) AS p50,
                  percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms) AS p95
FROM counterparty_resolver_traces
WHERE business_id  = $1
  AND started_at  >= $2
GROUP BY step_kind;
```

Used by ops to confirm the resolver is within `fixture_performance_budget`'s Block 11 "VAT classifier per transaction" budget (per-step traces should sum to under the per-transaction line).

## Indexes

```sql
CREATE UNIQUE INDEX idx_resolver_traces_entry_step
  ON counterparty_resolver_traces(draft_ledger_entry_id, step_index);

CREATE INDEX idx_resolver_traces_disagreement
  ON counterparty_resolver_traces(business_id, step_outcome, started_at DESC)
  WHERE step_outcome = 'DISAGREEMENT';

CREATE INDEX idx_resolver_traces_by_transaction
  ON counterparty_resolver_traces(business_id, transaction_id, step_index);

CREATE INDEX idx_resolver_traces_by_run
  ON counterparty_resolver_traces(business_id, workflow_run_id, started_at);
```

## RLS

Standard tenant isolation. Per `audit_log_policies` Section 2's role-overlay rules, the trace is visible to roles with the LEDGER domain — Owner / Admin / Bookkeeper / Accountant. Reviewer and Read-only roles see no rows.

```sql
CREATE POLICY resolver_traces_business_isolation ON counterparty_resolver_traces
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));

CREATE POLICY resolver_traces_role_read ON counterparty_resolver_traces
  FOR SELECT
  USING (
    business_id = ANY (auth.business_ids_for_session())
    AND auth.has_surface(business_id, 'LEDGER_FORENSICS_READ')
  );

CREATE POLICY resolver_traces_no_user_write ON counterparty_resolver_traces
  FOR INSERT, UPDATE, DELETE
  USING (false);
```

Writes happen exclusively via the resolver's elevated service role.

## Audit emission

Each step's trace insert emits `LEDGER_COUNTERPARTY_RESOLVER_TRACE_RECORDED` per `audit_event_taxonomy` (added in this PR), payload:

```jsonc
{
  "draft_ledger_entry_id": "...",
  "transaction_id": "...",
  "step_index": 1,
  "step_kind": "DOCUMENT_FIELDS",
  "step_outcome": "HIT",
  "step_confidence": "HIGH",
  "input_hash": "<hex sha256>",
  "duration_ms": 12
}
```

The emit follows `audit_log_policies` Section 4's per-business chain partitioning. Per the emit-as-separate-transaction rule, the audit row is written out-of-band of the trace INSERT; a trace INSERT that succeeds but whose audit emit fails is recovered by Block 03 Phase 07's resumability framework.

The resolver itself continues to emit the canonical `LEDGER_COUNTERPARTY_RESOLVED`, `LEDGER_COUNTERPARTY_UNRESOLVED`, and `LEDGER_COUNTERPARTY_DISAGREEMENT_DETECTED` events at the resolution boundary — those events summarise the outcome; the trace events record the per-step detail.

## Mobile considerations

Traces are server-internal write surface. Read access via the accountant-pack APIs is allowed on mobile (read-only intent per `mobile_write_rejection_endpoints`). No writes from the user surface ever reach this table.

## Cross-references

- `tool_clients_registry` — IN-side resolution step (Step 1.5)
- `tool_vendor_memory_writeback` — Step 2 producer; writeback after Step 1 HIGH-confidence HITs
- `data_layer_conventions_policy` — UUID v7 for `trace_id`, SHA-256 hex for `input_hash`, canonical JSON for `input_canonical_json`
- `audit_log_policies` — emit-as-separate-transaction; per-business chain partitioning
- `audit_event_taxonomy` — `LEDGER_COUNTERPARTY_RESOLVER_TRACE_RECORDED` (added in this PR), `LEDGER_COUNTERPARTY_RESOLVED`, `LEDGER_COUNTERPARTY_UNRESOLVED`, `LEDGER_COUNTERPARTY_DISAGREEMENT_DETECTED`
- `compliance_fields_schema` — sibling schema; the resolver writes `counterparty_country_iso` and `counterparty_vat_number` on `draft_ledger_entries` based on the chain's final outcome
- `adjustment_entry_schema` — adjustment-path entries also produce traces, linked via the entry's `adjustment_record_id`
- `vat_treatment_enum` — `UNKNOWN` is the canonical fallback when the chain ends unresolved
- `severity_enum` — `MEDIUM` for `COUNTERPARTY_COUNTRY_DISAGREEMENT` review issues raised alongside disagreements
- `retention_policies_schema` (Block 04) — retention contract
- Block 11 Phase 04 — counterparty resolution chain
- Block 11 Phase 05 — classifier that consumes the resolver's output
- Block 14 Phase 02 — accountant-review queue surface
