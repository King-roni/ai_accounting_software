# Disaster Recovery Restore Runbook

**Block ref:** 05 — Security & Audit · **Category:** Runbooks · **Stage:** 4 sub-doc (Layer 2)

---

## Purpose

Step-by-step procedure for restoring the platform after a data-loss or data-corruption event. Covers Supabase Postgres restore, Object Storage restore, and audit log restore. This runbook is also the procedure for quarterly DR drills.

All personnel executing this runbook must have read it in full before starting. Do not skip steps. Do not promote a restored environment to production until every listed verification has passed.

---

## Scope

| Component | Covered |
|---|---|
| Supabase Postgres (primary + replicas) | Yes — PITR restore |
| Object Storage (Processing zone, Operational zone, Archive zone) | Yes — bundle restore from cold storage |
| Audit log | Yes — Operational zone backup; gap documentation |
| Application secrets / Vault | No — see `secrets_management_policy.md` |
| DNS / load balancer cutover | No — see `infrastructure_cutover_runbook.md` |

---

## DR drill cadence

Quarterly. A drill run is mandatory before each major version deploy (any deploy that includes a schema migration touching `workflow_runs`, `transactions`, `audit_log`, or `archive_packages`).

A drill is the full procedure below executed against a non-production environment using the most recent production backup. Drills that skip any step are invalid. The drill result is recorded by emitting `SECURITY_DR_DRILL_COMPLETED` against the global audit chain. The payload must include `drill_environment`, `drill_start_at`, `drill_end_at`, `rto_achieved_minutes`, `rpo_achieved_minutes`, and `conducted_by_user_id`.

---

## RTO / RPO targets

| Metric | Target |
|---|---|
| RTO (Recovery Time Objective) | 4 hours |
| RPO (Recovery Point Objective) | 1 hour |

Supabase PITR granularity is 1 second for WAL-based recovery; the 1-hour RPO reflects the guaranteed minimum interval between confirmed backup checkpoints, not PITR precision. If the failure event is between two checkpoints, recovery to the last clean checkpoint is the baseline; WAL replay forward from that point is attempted but not guaranteed.

---

## Step 1 — Identify the restore point

1. Determine whether the event is a data-loss failure (missing rows), data-corruption failure (hash chain broken, RLS policy missing), or infrastructure failure (Supabase project unavailable).
2. For data-loss and corruption: identify the last known-good timestamp by inspecting the `audit_log` chain. The last event with a valid `chain_hash` before the anomaly defines the upper boundary of clean data.
3. For infrastructure failure: use the Supabase dashboard to identify the most recent PITR snapshot available. Confirm the snapshot timestamp is within the RPO window.
4. Record the chosen restore point timestamp in `decisions_log.md` before proceeding.

---

## Step 2 — Spin up the restore environment (Postgres)

1. In the Supabase dashboard, navigate to the target project → Settings → Backups.
2. Select "Restore to a point in time". Enter the restore point timestamp identified in Step 1.
3. Alternatively, use the Supabase Management API: `POST /v1/projects/{ref}/database/backups/restore` with body `{ "recovery_time_target": "<ISO 8601 timestamp>" }`.
4. Do NOT restore into the production project directly. Use a new project or a dedicated DR project. The production project must remain intact for forensic purposes until the restore is verified.
5. Wait for the restore to reach `ACTIVE_HEALTHY` project status. This typically takes 20–40 minutes depending on database size.
6. Record the actual restore start time and completion time in `decisions_log.md`.

---

## Step 3 — Post-restore row count verification

Run the following queries against the restored environment and compare to the pre-failure snapshot values recorded in the monitoring baseline (`dr_baseline_snapshots.md`):

```sql
SELECT COUNT(*) FROM workflow_runs;
SELECT COUNT(*) FROM transactions;
SELECT COUNT(*) FROM audit_log;
SELECT COUNT(*) FROM archive_packages;
SELECT COUNT(*) FROM match_records;
```

If any count is more than 0.1% below the pre-failure snapshot, do not proceed. Escalate to engineering with the discrepancy values and the restore point used.

---

## Step 4 — RLS policy verification

Run the following query against the restored environment:

```sql
SELECT tablename, policyname, cmd, roles
FROM pg_policies
ORDER BY tablename, policyname;
```

Export the result set. Compare it to the baseline policy manifest stored in `dr_rls_policy_baseline.sql`. Diff must show zero added rows, zero removed rows. If any policy is missing:

- Do NOT promote to production.
- Re-apply the missing policy from `dr_rls_policy_baseline.sql`.
- Re-run Step 4.
- Document the discrepancy and the remediation in `decisions_log.md`.

---

## Step 5 — Hash chain integrity check

Run the hash chain verification tool against all finalized runs in the restored environment:

```
data.verify_hash_chain({ run_ids: all_finalized_run_ids })
```

This tool recomputes the `chain_hash` for each event in the business chains and compares to the stored values. It also walks the global chain.

If the tool returns `CHAIN_INTACT` for all chains: proceed to Step 6.

If the tool returns `CHAIN_BROKEN` for any chain:

- **Do not promote the restored environment to production.**
- Record the broken chain ID, the first broken sequence number, and the restore point in `decisions_log.md`.
- Escalate to engineering. The engineering resolution options are: (a) restore to an earlier PITR point that predates the break; (b) accept a data gap up to the break point if the WAL replay confirms the break is irrecoverable.
- Do not re-run `data.verify_hash_chain` as a workaround — chain breaks require human review, not automated retry.

---

## Step 6 — Live integration runbook pass

Run all live integration runbooks listed in `live_integration_test_runbook.md`. Every runbook must return `PASS` before traffic is switched. A partial pass is a fail.

Common runbooks in the set:

- Authentication baseline (login, MFA challenge, session refresh)
- Workflow run creation and gate evaluation
- Bank statement upload and ingestion parse
- Ledger entry creation for a test transaction
- Archive bundle verification for a sealed test period

Record the pass/fail result of each runbook in `decisions_log.md` with the runbook name and the timestamp of the pass.

---

## Step 7 — Traffic cutover

After all verifications in Steps 3–6 pass:

1. Update DNS / load balancer to point to the restore environment. See `infrastructure_cutover_runbook.md` for the specific procedure.
2. Monitor error rates for 30 minutes post-cutover. Target: P95 error rate below pre-incident baseline.
3. Retain the original (failed) Supabase project in read-only state for 14 days before decommissioning. This preserves forensic access.

---

## Object Storage restore

Object Storage restore is independent of the Postgres restore and must be completed in parallel if Object Storage was affected.

1. Identify which archive bundles are affected. Query `archive_packages` in the restored Postgres environment for any row where `storage_status != 'OBJECT_LOCKED'` or where `bundle_hash` does not match the cold storage manifest.
2. For each affected bundle: download the sealed archive bundle from cold storage (S3-compatible cold tier). The bundle is identified by `archive_packages.storage_key`.
3. Verify the SHA-256 of the downloaded bundle against the `bundle_hash` stored in `archive_packages`. Command: `sha256sum <bundle_file>`. The hex output must match exactly.
4. If the hash matches: re-upload the bundle to the restore environment's Object Storage and re-apply the Object Lock retention rule.
5. If the hash does not match: the bundle is corrupted in cold storage. Document the affected `archive_package_id` in `decisions_log.md`. The period will require a re-finalization run — a decision that requires Owner approval and an `OUT_ADJUSTMENT` run.

---

## Audit log restore

The audit log is append-only and immutable. The `audit_log` table is restored from the Postgres PITR backup along with all other tables.

Any events that occurred after the restore point timestamp and before the failure event are irrecoverable. This gap represents the RPO window:

1. Determine the gap window: from `restore_point_timestamp` to `failure_event_timestamp`.
2. Document the gap explicitly in `decisions_log.md`, including: start timestamp, end timestamp, duration in minutes, and whether any BLOCKING-severity events are likely to have occurred in the window based on the operational context at the time of failure.
3. Emit a manual `SECURITY_DR_DRILL_COMPLETED` event (or if this is a real incident, a `BACKUP_RESTORED` event) against the global chain after the restored environment is live. The payload must note the gap window timestamps.
4. Do not attempt to reconstruct audit events for the gap period from application logs. Application logs are not a valid substitute for the audit chain. If audit coverage during the gap is required for regulatory purposes, document the gap formally with the business owner.

---

## Cross-references

- `hash_chain_schema.md` — chain structure, `sequence_number`, `chain_hash` column definitions
- `archive_verification_policy.md` — bundle SHA-256 verification procedure
- `audit_log_policies.md` — hash-chain partitioning, `emitAudit()` function
- `live_integration_test_runbook.md` — list of runbooks that must pass before traffic cutover
- `dr_rls_policy_baseline.sql` — baseline RLS policy manifest for Step 4 comparison
- `decisions_log.md` — where all DR decisions and discrepancies are recorded
- `audit_event_taxonomy.md` — `SECURITY_DR_DRILL_COMPLETED`, `BACKUP_RESTORED`, `BACKUP_VERIFIED`
- `infrastructure_cutover_runbook.md` — DNS / load balancer procedure for Step 7
