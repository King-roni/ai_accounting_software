# Retention Dry-Run Mode Policy

**Category:** Policies · **Owning block:** 04 — Data Architecture · **Stage:** 4 sub-doc (Layer 2)

The dry-run mode of the retention engine: the invocation surface, output format, when to use it, and how it differs from a live pass. A dry-run produces the same eligibility decisions + planning audit-log emissions as a live pass but **performs no Storage DELETE and no DB row removal**. Used for policy-change verification, sweep preview, and pre-promotion confirmation.

Per the Phase 10 phase doc: "The engine supports a `--dry-run` flag that emits the planned deletions to the audit log without performing them. Used for verification when policy changes."

---

## 1. Invocation

Dry-run is a parameter on the standard retention-pass function defined in `retention_scheduling_policy.md`:

```sql
-- Live pass (default)
SELECT archive.run_retention_pass('EU');

-- Dry-run pass
SELECT archive.run_retention_pass('EU', p_dry_run := true);
```

The default `p_dry_run` is `false`. Setting it to `true` for the lifetime of the pass changes behavior at the deletion step (§3); all other engine behavior — legal-hold check, eligibility computation, advisory locking — is identical.

DBA-console invocation:

```bash
psql -c "SELECT archive.run_retention_pass('EU', p_dry_run := true)"
```

There is no automatic-schedule dry-run — the cron schedule per `retention_scheduling_policy.md` always runs in live mode. Dry-runs are manual, operator-initiated invocations only.

---

## 2. When to use

| Scenario | Use dry-run? | Why |
|---|---|---|
| Operator changed a business's `retention_years` and wants to preview impact | Yes | Confirms which bundles would be deleted before the next live pass |
| Verifying a `legal_holds` row was filed correctly (should block deletion) | Yes | Confirms the hook returns `on_hold = true` for the protected business |
| Routine nightly retention | No | The scheduled job is always live |
| First-time deployment of the retention engine in a new region | Yes | Sanity-check that no business has surprising deletions on day-one |
| Investigating a `RETENTION_INCONSISTENCY_DETECTED` alert | Yes | Reproduce the eligibility computation without taking destructive action |
| After a `legal_holds` lift to preview the deletions about to resume | Yes | Stakeholder review before the next live pass |
| Pre-flight to `admin_retention_override_runbook` Step 2 | Yes | Confirms no in-flight or imminent destructive action against the business |

The general rule: any operator action that changes retention-eligibility inputs should be followed by a dry-run before the next live pass.

---

## 3. Behavioral differences from live mode

Within `archive.run_retention_pass(p_region, p_dry_run)`:

| Step | Live mode | Dry-run mode |
|---|---|---|
| Legal-hold hook call | Called | Called (identical) |
| Eligibility threshold computation | Computed | Computed (identical) |
| Per-business advisory lock | Acquired | Acquired (identical — prevents concurrent dry-run + live) |
| `RETENTION_DELETION_PLANNED` audit event | Emitted | **Replaced by `_PLANNED_DRY_RUN`** (§4) |
| Storage `HEAD` (eligibility verification) | Called | Called (identical — read-only) |
| Storage `DELETE` call | Issued | **SKIPPED** |
| DB DELETE of archive rows | Issued | **SKIPPED** |
| `deletion_state` mutation | `PENDING → IN_PROGRESS → row removed` | **No mutation** |
| `RETENTION_DELETION_EXECUTED` audit event | Emitted | **NOT emitted** |
| `retention_pass_log` outcome | `COMPLETED` | `DRY_RUN_COMPLETED` |
| Pre-flight orphan reconciliation | Executed | **SKIPPED** (observe-only mode does not reconcile) |
| Pass time budget | 30 min soft / 2 hour hard | **10 min soft / 30 min hard** (dry-runs should be fast) |

The advisory-lock acquisition in dry-run mode is identical to live mode — this intentionally prevents a dry-run and a live pass from running concurrently for the same region, which would observe partially-mutated state and report misleading "planned" deletions.

---

## 4. The `RETENTION_DELETION_PLANNED_DRY_RUN` event

```
Event:    RETENTION_DELETION_PLANNED_DRY_RUN
Severity: LOW
Domain:   RETENTION (Block 04)

Payload:
  business_id              uuid
  archive_package_id       uuid
  bundle_object_uri        text
  bundle_size_bytes        bigint
  archived_at              timestamptz
  eligibility_threshold    timestamptz
  retention_years          integer
  pass_id                  uuid                 (from retention_pass_log)
  emitted_at               timestamptz
```

One event per bundle that would be deleted in a live pass. Operators reviewing a dry-run query the audit log filtered on this event and the `pass_id`.

**Cross-block coordination flagged for B05·P02:** 1 NEW event kind (`RETENTION_DELETION_PLANNED_DRY_RUN`).

---

## 5. Dry-run output query

Operators retrieve a dry-run's planned actions via a canonical query:

```sql
WITH latest_dry_run AS (
  SELECT pass_id
  FROM retention_pass_log
  WHERE outcome = 'DRY_RUN_COMPLETED'
    AND region = 'EU'
  ORDER BY pass_started_at DESC
  LIMIT 1
)
SELECT
  al.audit_event_payload->>'business_id'         AS business_id,
  al.audit_event_payload->>'archive_package_id'  AS archive_package_id,
  al.audit_event_payload->>'bundle_object_uri'   AS bundle_object_uri,
  (al.audit_event_payload->>'bundle_size_bytes')::bigint AS bundle_size_bytes,
  al.audit_event_payload->>'archived_at'         AS archived_at,
  al.audit_event_payload->>'eligibility_threshold' AS eligibility_threshold
FROM audit_log al
INNER JOIN latest_dry_run ldr
  ON al.audit_event_payload->>'pass_id' = ldr.pass_id::text
WHERE al.event_type = 'RETENTION_DELETION_PLANNED_DRY_RUN'
ORDER BY al.appended_at;
```

The query returns the full list of bundles the most-recent dry-run intended to delete. Operators compare this against expectations + business-Owner confirmations before scheduling or allowing the next live pass.

For a per-business dry-run output:

```sql
SELECT
  al.audit_event_payload->>'archive_package_id'  AS archive_package_id,
  al.audit_event_payload->>'archived_at'         AS archived_at,
  al.audit_event_payload->>'eligibility_threshold' AS eligibility_threshold
FROM audit_log al
INNER JOIN latest_dry_run ldr
  ON al.audit_event_payload->>'pass_id' = ldr.pass_id::text
WHERE al.event_type = 'RETENTION_DELETION_PLANNED_DRY_RUN'
  AND al.audit_event_payload->>'business_id' = '<business_id>'
ORDER BY al.appended_at;
```

---

## 6. Concurrency: dry-run + live coexistence

The per-region advisory lock per `retention_scheduling_policy.md` §3 applies to both modes:

- A live pass blocks a concurrent dry-run for the same region.
- A dry-run blocks a concurrent live pass for the same region.
- Both emit `RETENTION_PASS_SKIPPED_CONCURRENT` (LOW) when the lock is unavailable.

This is intentional: a dry-run that ran alongside a live pass would observe a partially-mutated state (some bundles deleted, others not) and report misleading "planned" deletions. The mutual exclusion preserves the dry-run's observe-only semantics.

---

## 7. What dry-run does NOT include

- **No orphan reconciliation.** Live-mode pre-flight scans for `deletion_state = IN_PROGRESS` orphans and reconciles them per `retention_deletion_atomicity_policy.md` §5. Dry-run mode SKIPS this scan — observe-only behavior, not state correction. Operators investigating an inconsistency use the dedicated `RETENTION_INCONSISTENCY_DETECTED` review issue path + manual operator action; they do not rely on a dry-run to clean up.
- **No `deletion_state` mutation.** The `IN_PROGRESS` marker is a live-mode-only artifact.
- **No `RETENTION_DELETION_EXECUTED` emission.** The execution event semantically implies state change; dry-run emits only the planning event.

---

## 8. Mobile rejection

Dry-run invocation is DBA-console-only; no mobile or application-API surface exists.

---

## 9. Cross-references

- `retention_policies_schema.md` — per-business `retention_years` source
- `retention_scheduling_policy.md` (B04·P10 seq 414) — live-mode schedule + advisory-lock model (dry-run shares both)
- `retention_deletion_atomicity_policy.md` (B04·P10 seq 416) — the steps dry-run skips (Storage DELETE, DB DELETE, orphan reconcile)
- `retention_legal_hold_hook_contract.md` (B04·P10 seq 418) — the hook dry-run still calls
- `admin_retention_override_runbook.md` — Step 2 references dry-run as the pre-flight verification step
- `audit_event_taxonomy.md` — RETENTION domain (must absorb `RETENTION_DELETION_PLANNED_DRY_RUN`)
- Block 04 Phase 10 — owning phase
