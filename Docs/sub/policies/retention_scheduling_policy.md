# Retention Scheduling Policy

**Category:** Policies · **Owning block:** 04 — Data Architecture · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

The scheduling contract for the retention engine background job: when it runs, what windows it uses per region, how concurrency is enforced, and which runner technology executes it. Per `retention_policies_schema.md` §3 the engine reads per-business `retention_years` to compute deletion-eligibility thresholds; this policy pins the timing and concurrency of those reads.

---

## 1. Job runner choice

The retention engine runs on **`pg_cron`** as the canonical job runner. Rationale:

- The engine's work is entirely Postgres-resident — reads `retention_policies`, walks `archive.*` tables, calls `legal_holds` lookups via the hook (per `retention_legal_hold_hook_contract.md`), performs DELETE under the `retention_engine` role. pg_cron keeps the work inside the same transactional context as the data.
- External schedulers (cron + external worker) introduce a network hop and service-discovery dependency without value for an entirely-DB workload.
- pg_cron's PostgreSQL-native advisory-lock interaction (per §3) is simpler than coordinating distributed locks across an external worker fleet.

The job target is `archive.run_retention_pass(p_region text)` — a SECURITY DEFINER function that internally enumerates eligible businesses and processes each per `retention_deletion_atomicity_policy.md`.

Object Storage operations (Object Lock check, bundle DELETE) are issued via a Postgres function wrapping the Supabase Storage admin API — staying inside the pg_cron context.

---

## 2. Cron expression and off-peak windows

Default schedule for EU MVP (Europe/Athens timezone — matches Cyprus business locale):

```sql
-- Registered in pg_cron under the 'platform_dba' role
SELECT cron.schedule(
  'retention_engine_eu',
  '0 2 * * *',                                       -- 02:00 daily, server TZ = Europe/Athens
  $$ SELECT archive.run_retention_pass('EU') $$
);
```

Per-region windows:

| Region | Cron expression | Local timezone | Window |
|---|---|---|---|
| EU (MVP) | `0 2 * * *` | `Europe/Athens` | 02:00 daily |
| US (Stage-2; deferred) | `0 23 * * *` | `America/New_York` | 23:00 local |
| Off-peak fallback (any region) | `0 4 * * 0` | UTC | Weekly Sunday 04:00 catch-up sweep |

EU-only in MVP per Stage 1 EU-residency requirement. US support is contingent on a US-region deployment.

The 02:00 EU-Athens window is chosen because:

- It runs AFTER the daily 03:00 UTC analytics-refresh job (per `dashboard_preferences_schema.md` §2) — analytics is current before retention deletions invalidate any caches.
- It is well before EU-business operational hours (typically 08:00+ Cyprus time).
- It avoids the 23:00–01:00 nightly backup window per `backup_schedule_policy` (cross-block coordination flagged for B05·P05).

---

## 3. Advisory-lock concurrency

Per the P10 phase contract: only one retention pass runs at a time per region. The `archive.run_retention_pass` function acquires a session-scope advisory lock for its duration:

```sql
-- Inside archive.run_retention_pass:
IF NOT pg_try_advisory_lock(hashtext('retention_pass_' || p_region::text)) THEN
  -- Emit RETENTION_PASS_SKIPPED_CONCURRENT; return
  PERFORM audit.emit_audit('RETENTION_PASS_SKIPPED_CONCURRENT', NULL, ...);
  RETURN;
END IF;
```

Lock key: `hashtext('retention_pass_' || region)`. The region is an enum-like text (`'EU'`, `'US'`, ...). The hash narrows to a `bigint` for the advisory-lock signature (the only overload available per `phase_execution_locking_policy.md`).

If a prior pass is still running when the schedule fires, the new invocation logs a skip and exits. The next scheduled fire continues normally — no auto-retry; the next day's pass picks up the work.

---

## 4. Per-business iteration order

Within a pass, businesses are processed in **uuid-ascending order** to align with the cross-run advisory-lock ordering convention per `phase_execution_locking_policy.md` (B03·P06). This produces deterministic ordering and avoids deadlocks against in-flight workflow runs touching the same business.

Each business's processing acquires its own advisory lock keyed on `hashtext('retention_business_' || business_id::text)`. The lock is held only for the duration of that business's pass — released before moving to the next.

---

## 5. Per-pass time budget

Each retention pass has a soft target of **30 minutes** total and a hard cap of **2 hours**. If the pass exceeds 2 hours, `RETENTION_PASS_TIMEOUT` (HIGH) is emitted and the pass is aborted — the next-day's pass picks up where this one left off.

Per-business processing within the pass has a soft target of **5 seconds** and a hard cap of **5 minutes**. Per-business overruns are tracked per `retention_pass_log` (§6) and surfaced for operator review.

---

## 6. Retention pass log

```sql
CREATE TABLE retention_pass_log (
  pass_id                 uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  region                  text NOT NULL,                      -- 'EU' for MVP
  pass_started_at         timestamptz NOT NULL,
  pass_completed_at       timestamptz NULL,
  outcome                 text NOT NULL DEFAULT 'IN_PROGRESS',
  -- outcome values: IN_PROGRESS | COMPLETED | SKIPPED_CONCURRENT | TIMEOUT
  --                 | ABORTED | DRY_RUN_COMPLETED
  businesses_processed    integer NOT NULL DEFAULT 0,
  bundles_deleted         integer NOT NULL DEFAULT 0,
  bundles_skipped_hold    integer NOT NULL DEFAULT 0,
  bundles_planned_dry_run integer NOT NULL DEFAULT 0,
  triggered_by_user_id    uuid NULL REFERENCES users(id),     -- null for scheduled invocations
  notes                   text NULL
);

CREATE INDEX idx_retention_pass_log_region_started
  ON retention_pass_log(region, pass_started_at DESC);
```

The log is read by `retention_dashboard_query` (Stage-2 instrumentation) and by `admin_retention_override_runbook.md` Step 2 (verify no in-flight sweep before override).

---

## 7. Manual invocation

Operators can manually trigger a retention pass via the DBA console:

```sql
-- Live pass
SELECT archive.run_retention_pass('EU');

-- Dry-run pass (per retention_dry_run_mode_policy.md)
SELECT archive.run_retention_pass('EU', p_dry_run := true);
```

Manual invocation emits `RETENTION_PASS_TRIGGERED_MANUAL` (LOW) with the operator's user_id captured in `triggered_by_user_id`. Useful for verification after policy changes or after lifting a legal hold.

---

## 8. Audit events

| Event | Severity | When |
|---|---|---|
| `RETENTION_PASS_STARTED` | LOW | Pass begins (advisory lock acquired); a `retention_pass_log` row is inserted with `outcome = IN_PROGRESS` |
| `RETENTION_PASS_COMPLETED` | LOW | Pass exits normally; the log row's `outcome` is updated and counts written |
| `RETENTION_PASS_SKIPPED_CONCURRENT` | LOW | Advisory lock busy — another pass in flight |
| `RETENTION_PASS_TIMEOUT` | HIGH | Pass exceeded 2-hour hard cap; the next scheduled fire resumes |
| `RETENTION_PASS_TRIGGERED_MANUAL` | LOW | Operator-invoked pass via DBA console |

All in the Block 04 RETENTION domain per `audit_event_taxonomy.md`. **Cross-block coordination flagged for B05·P02:** 5 NEW event kinds.

---

## 9. Mobile rejection

Retention pass orchestration is a backend job — no mobile surface exists. The DBA manual invocation in §7 is desktop-only.

---

## 10. Cross-references

- `retention_policies_schema.md` — per-business `retention_years` source
- `data_retention_policy.md` — zone-level retention contract
- `object_lock_integration.md` — Storage delete semantics + Object Lock expiry
- `retention_deletion_atomicity_policy.md` (B04·P10 seq 416) — the per-bundle deletion procedure run inside the pass
- `retention_legal_hold_hook_contract.md` (B04·P10 seq 418) — hook called per business
- `retention_dry_run_mode_policy.md` (B04·P10 seq 420) — `p_dry_run` parameter behavior
- `legal_holds` table (per `adjustment_six_year_cap_policy.md`) — consulted via the hook
- `processing_zone_ttl_and_prune_policy.md` — sibling processing-zone scheduler (hourly, distinct from this nightly engine)
- `analytics_refresh_runbook.md` — 03:00 UTC analytics job; runs BEFORE retention pass to ensure analytics is current
- `backup_schedule_policy` (B05·P05 cross-block coordination flagged) — 23:00–01:00 backup window; retention pass scheduled outside
- `phase_execution_locking_policy.md` — advisory-lock ordering convention + `bigint` overload requirement
- `audit_event_taxonomy.md` — RETENTION domain
- `admin_retention_override_runbook.md` — references `retention_pass_log` to verify no in-flight sweep
- Block 04 Phase 10 — owning phase
