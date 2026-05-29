# Retention Legal-Hold Hook Contract

**Category:** Policies · **Owning block:** 04 — Data Architecture · **Co-owners:** 04 Phase 11 (Legal Hold), 02 Phase 04 (`legal_holds` admin) · **Stage:** 4 sub-doc (Layer 2)

The binding function-signature contract between the retention engine (Block 04 Phase 10) and the legal-hold mechanism (Block 04 Phase 11). Phase 10 ships with a **placeholder hook implementation that always returns "no hold"**; Phase 11 swaps in the real `legal_holds`-table-consulting implementation **without requiring a Phase 10 code change**.

Per the Phase 10 phase doc Companion-Phase section: "There is no code dependency from Phase 10 on Phase 11 — Phase 10 ships and runs end-to-end with the placeholder; Phase 11 swaps in the real hook implementation when it lands."

---

## 1. Function signature

The hook is a SECURITY DEFINER Postgres function with a fixed signature, registered in a runtime function-pointer table that the retention engine consults each pass.

```sql
-- Return composite type (declared once, used by all implementations)
CREATE TYPE archive.legal_hold_hook_result AS (
  on_hold        boolean,
  hold_reasons   text[]
);

-- The hook function signature (multiple implementations live in the registry)
-- CREATE FUNCTION archive.legal_hold_hook_<impl>(p_business_id uuid)
--   RETURNS archive.legal_hold_hook_result
--   LANGUAGE sql
--   SECURITY DEFINER
--   STABLE;
```

Return shape:

- `on_hold` — `true` if any active legal hold prevents deletion for the business; `false` otherwise.
- `hold_reasons` — array of human-readable reasons (empty array `ARRAY[]::text[]` when `on_hold = false`); used in audit payloads and operator alerts.

Volatility:

- `STABLE` (not `IMMUTABLE`): the result depends on `now()` and the current `legal_holds` table contents, both of which change over time but not within a single transaction.

Security:

- `SECURITY DEFINER`: the hook runs as the function owner regardless of the calling role. The `retention_engine` role does NOT have direct read access to `legal_holds` (cross-tenant data); the hook is the controlled gateway.

---

## 2. The registry table

The runtime registry decouples the hook caller (retention engine) from the implementation:

```sql
CREATE TABLE archive.runtime_hook_registry (
  hook_name       text PRIMARY KEY,                       -- e.g., 'legal_hold_hook'
  function_ref    text NOT NULL,                          -- fully-qualified function name (schema.function)
  registered_at   timestamptz NOT NULL DEFAULT now(),
  registered_by   uuid NOT NULL REFERENCES users(id),
  notes           text NULL
);
```

The retention engine calls the hook via a single dispatcher function:

```sql
CREATE FUNCTION archive.call_legal_hold_hook(p_business_id uuid)
  RETURNS archive.legal_hold_hook_result
  LANGUAGE plpgsql
  SECURITY DEFINER
  STABLE
AS $$
DECLARE
  v_hook_ref text;
  v_result   archive.legal_hold_hook_result;
BEGIN
  SELECT function_ref INTO v_hook_ref
  FROM archive.runtime_hook_registry
  WHERE hook_name = 'legal_hold_hook';

  IF v_hook_ref IS NULL THEN
    RAISE EXCEPTION 'No legal_hold_hook registered; retention engine cannot proceed';
  END IF;

  EXECUTE format('SELECT * FROM %s($1)', v_hook_ref)
  INTO v_result
  USING p_business_id;

  RETURN v_result;
END;
$$;
```

The `EXECUTE format` dynamic dispatch lets the function pointer be swapped at runtime without recompiling the calling function. Boot-time validation confirms the registered function's signature matches the contract (§6).

---

## 3. Placeholder implementation (Phase 10)

Phase 10 ships a placeholder that always returns "no hold":

```sql
CREATE FUNCTION archive.legal_hold_hook_placeholder(p_business_id uuid)
  RETURNS archive.legal_hold_hook_result
  LANGUAGE sql
  SECURITY DEFINER
  STABLE
AS $$
  SELECT
    false::boolean AS on_hold,
    ARRAY[]::text[] AS hold_reasons;
$$;
```

Registered at boot:

```sql
INSERT INTO archive.runtime_hook_registry (hook_name, function_ref, registered_by, notes)
VALUES (
  'legal_hold_hook',
  'archive.legal_hold_hook_placeholder',
  '<bootstrap_user_id>',
  'Phase 10 placeholder — to be replaced by Phase 11'
)
ON CONFLICT (hook_name) DO NOTHING;
```

`ON CONFLICT DO NOTHING` ensures Phase 11's real implementation (registered later) is not overwritten by a re-boot of Phase 10's placeholder.

---

## 4. Phase 11 implementation (real)

Phase 11 registers the real implementation that consults `legal_holds` per the table DDL in `adjustment_six_year_cap_policy.md`:

```sql
CREATE FUNCTION archive.legal_hold_hook_v1(p_business_id uuid)
  RETURNS archive.legal_hold_hook_result
  LANGUAGE sql
  SECURITY DEFINER
  STABLE
AS $$
  WITH active AS (
    SELECT lh.hold_kind, lh.hold_authority
    FROM legal_holds lh
    WHERE lh.business_id = p_business_id
      AND lh.hold_started_at <= now()
      AND (lh.hold_ends_at IS NULL OR lh.hold_ends_at >= now())
  )
  SELECT
    EXISTS (SELECT 1 FROM active) AS on_hold,
    COALESCE(
      array_agg(format('%s (authority: %s)', hold_kind, hold_authority)),
      ARRAY[]::text[]
    ) AS hold_reasons
  FROM active;
$$;
```

Phase 11 swaps the registration in a single UPDATE:

```sql
UPDATE archive.runtime_hook_registry
SET function_ref  = 'archive.legal_hold_hook_v1',
    registered_at = now(),
    registered_by = '<phase_11_deploy_user_id>',
    notes         = 'Phase 11 swap-in; consults legal_holds table'
WHERE hook_name = 'legal_hold_hook';
```

The retention engine picks up the new function ref on the NEXT scheduled pass — no Phase 10 code change, no restart needed.

---

## 5. Swap atomicity

The registry UPDATE is transactional. Within a single retention pass, the engine reads the registry once at the start and holds the resolved `function_ref` for the duration. A swap during a pass affects the NEXT pass; the current pass continues with the function ref it captured.

Both the placeholder and Phase 11 implementations are `STABLE`, so re-reading the registry mid-pass would not change correctness — `STABLE` guarantees the result within a single SQL statement and (by Postgres convention) within a single transaction for the same arguments.

---

## 6. Signature validation at boot

The boot script verifies the registered implementation's signature matches the contract before the retention engine is allowed to schedule:

```sql
DO $$
DECLARE
  v_registered_ref text;
  v_schema text;
  v_name text;
BEGIN
  SELECT function_ref INTO v_registered_ref
  FROM archive.runtime_hook_registry
  WHERE hook_name = 'legal_hold_hook';

  IF v_registered_ref IS NULL THEN
    RAISE EXCEPTION 'No legal_hold_hook registered';
  END IF;

  v_schema := split_part(v_registered_ref, '.', 1);
  v_name   := split_part(v_registered_ref, '.', 2);

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = v_schema
      AND p.proname = v_name
      AND p.pronargs = 1
      AND p.prorettype = 'archive.legal_hold_hook_result'::regtype
  ) THEN
    RAISE EXCEPTION 'legal_hold_hook signature mismatch for %', v_registered_ref;
  END IF;
END $$;
```

Boot failure on signature mismatch prevents the retention engine cron schedule from being enabled — the system refuses to proceed with a malformed hook.

---

## 7. Test fixtures

For Phase 10 end-to-end testing without Phase 11 shipped:

```sql
-- Test-only fixture; toggles the hook to return on_hold=true for a specific business
CREATE FUNCTION archive.legal_hold_hook_test_fixture(p_business_id uuid)
  RETURNS archive.legal_hold_hook_result
  LANGUAGE sql
  SECURITY DEFINER
  STABLE
AS $$
  SELECT
    current_setting('app.test_legal_hold_business_id', true) = p_business_id::text AS on_hold,
    CASE
      WHEN current_setting('app.test_legal_hold_business_id', true) = p_business_id::text
        THEN ARRAY['TEST_FIXTURE_HOLD']
      ELSE ARRAY[]::text[]
    END AS hold_reasons;
$$;
```

CI tests register this fixture per `race_condition_test_fixture_policy.md` patterns + set the `app.test_legal_hold_business_id` GUC to verify the skip path:

```sql
SET LOCAL app.test_legal_hold_business_id = '<some_business_id>';
SELECT archive.run_retention_pass('EU');  -- should skip that business
```

The CI-only `engine.test_role` grant per the race-condition fixture policy is the gate that allows the test fixture to be registered. Production deployments register the real Phase 11 implementation; the test fixture is never registered in production.

---

## 8. Audit events

The hook itself does NOT emit audit events — it is a pure read. The consuming retention engine emits `RETENTION_DELETION_SKIPPED_LEGAL_HOLD` (LOW) when `on_hold = true`, with the `hold_reasons` array carried in the payload per `retention_deletion_atomicity_policy.md` §7.

Registry changes emit `RETENTION_HOOK_REGISTERED` (MEDIUM): one event per registry INSERT or UPDATE. Payload:

| Field | Value |
|---|---|
| `hook_name` | e.g. `'legal_hold_hook'` |
| `prior_function_ref` | NULL on initial INSERT; previous `function_ref` on UPDATE |
| `new_function_ref` | e.g. `'archive.legal_hold_hook_v1'` |
| `registered_by_user_id` | uuid |
| `notes` | text |
| `registered_at` | timestamptz |

**Cross-block coordination flagged for B05·P02:** 1 NEW event kind (`RETENTION_HOOK_REGISTERED`).

---

## 9. Mobile rejection

Hook registration is a DBA-console action (or migration script) only; no mobile or application surface exists.

---

## 10. Cross-references

- `retention_scheduling_policy.md` — engine pass that calls this hook
- `retention_deletion_atomicity_policy.md` — §3 hook call ordering before deletion
- `retention_dry_run_mode_policy.md` — hook is called identically in dry-run mode
- `adjustment_six_year_cap_policy.md` — `legal_holds` table DDL + active-hold query pattern (Phase 11's real impl matches this)
- `processing_zone_ttl_and_prune_policy.md` — sibling processing-zone path that also consults `legal_holds`
- `archive.runtime_hook_registry` table — defined here; generic mechanism reusable for other Phase-X-implements-Phase-Y-defines hook patterns (Stage-2 extension flagged)
- `race_condition_test_fixture_policy.md` — pattern for the §7 test fixture; `engine.test_role` + `app.test_*` GUC family
- `audit_event_taxonomy.md` — RETENTION domain
- Block 04 Phase 10 — owning phase (consumer)
- Block 04 Phase 11 — provider (swaps in real impl)
- Block 02 Phase 04 — `legal_holds` table administration RPCs
- Block 02 Phase 09 — legal-hold lifecycle (file, lift)
