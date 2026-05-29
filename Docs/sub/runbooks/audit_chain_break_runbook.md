# Runbook: Audit Chain Break (ARCHIVE_TAMPER_DETECTED)

**Block:** Archive & Integrity
**Layer:** 2 — Sub-Doc
**Type:** Runbook
**Severity:** BLOCKING
**Status:** Draft

## Overview

This runbook describes the procedure to follow when hash chain integrity verification returns `ARCHIVE_TAMPER_DETECTED`. This event indicates that the sequential hash chain recorded in `hash_chain_schema.md` has broken — a link in the chain does not match the expected hash of the preceding entry.

A chain break does not automatically confirm tampering. It may result from hardware failure, a storage corruption event, a botched migration, or deliberate modification. The investigation procedure is the same regardless of suspected cause; the response actions differ based on the finding.

---

## 1. Symptoms

The following indicate a potential chain break:

- `tool_archive_verify` returns `status: ARCHIVE_TAMPER_DETECTED` for one or more audit entries.
- The platform emits an `ARCHIVE_TAMPER_DETECTED` audit event (note: this event is self-referential — it appears in the audit log as a record of the detected anomaly).
- An alert fires on the `ARCHIVE_INTEGRITY_FAILURE` alert rule (configured in `alert_rule_configuration_schema.md`).
- A scheduled integrity check job (`scheduled_job_schema.md` job type `AUDIT_CHAIN_VERIFY`) fails with a non-zero exit code.

Any one of these symptoms is sufficient to initiate this runbook.

---

## 2. Immediate Actions

Take the following steps immediately upon detection — do not skip or reorder:

1. **Do not delete anything.** Do not truncate, DROP, or DELETE any row from `audit_logs`, `hash_chain` entries, or any related table in scope. Do not run retention jobs on these tables. Do not restart any service in a way that flushes in-memory buffers to disk (this could overwrite evidence).
2. **Preserve all log entries.** Application server logs, database query logs, and WAL segments for the affected period must be preserved. Contact the infrastructure team immediately to prevent log rotation from overwriting relevant files.
3. **Quarantine the affected run or period.** If the chain break is associated with a specific workflow run, set the run status to `QUARANTINED` via the service role. Do not allow further writes to the affected run's scope. No new match proposals, ledger entries, or archive bundles should be created within the quarantined scope.
4. **Raise an incident.** Open a SEV-1 or SEV-2 incident per `security_incident_response_policy.md`. Assign the Security Lead immediately. If personal data is in scope, notify the DPO within 1 hour.
5. **Notify `org:owner`** of the affected business entity. Do not share forensic details at this stage — notify them that an integrity alert has been raised and is under investigation.

---

## 3. Investigation Steps

### 3.1 Identify the Chain Break Point

Run the following query to find the first entry where the recorded hash does not match the recomputed hash:

```sql
-- Identify chain break: find entries where prev_hash does not match
-- the hash of the actual preceding row (ordered by sequence_number)
SELECT
  h.id,
  h.sequence_number,
  h.prev_hash,
  h.entry_hash,
  lag(h.entry_hash) OVER (ORDER BY h.sequence_number) AS actual_prev_hash,
  h.created_at
FROM hash_chain h
WHERE h.run_id = '<affected_run_id>'  -- or scope as appropriate
ORDER BY h.sequence_number;
```

The first row where `prev_hash != actual_prev_hash` is the break point. Record the `sequence_number`, `id`, and `created_at` of the breaking entry.

### 3.2 Determine Scope of the Break

Check whether the break is:
- **Single-entry**: only one entry is affected (the hash of that entry does not match its predecessor).
- **Cascading**: all entries from the break point onward are invalid (because each entry's hash incorporates the previous hash — a single falsified entry cascades).
- **Partial**: a section of entries is missing entirely (gap in sequence numbers).

A partial break (gap) is more indicative of deletion than corruption.

### 3.3 Correlate with Infrastructure Events

Cross-reference the `created_at` of the break point against:
- Database maintenance windows.
- Migration execution logs (`supabase_migration_tooling_policy.md`).
- Storage incident records.
- Backup restore events (`backup_and_recovery_policy.md`).
- Any personnel access to the database outside normal application paths.

If the break timestamp correlates with a known maintenance event, hardware failure is the likely cause. If no infrastructure event explains the break, treat as potential tampering.

### 3.4 Query Surrounding Chain Entries

Retrieve the five entries before and after the break point to understand the pattern:

```sql
SELECT id, sequence_number, entry_hash, prev_hash, created_at, actor_id
FROM hash_chain
WHERE sequence_number BETWEEN <break_seq - 5> AND <break_seq + 5>
  AND run_id = '<affected_run_id>'
ORDER BY sequence_number;
```

Look for: duplicate sequence numbers, timestamp anomalies (entries out of chronological order), unexpected actor IDs, or missing entries in the sequence.

---

## 4. Escalation

### 4.1 Notify Required Parties

| Party | When | How |
|---|---|---|
| Security Lead | Immediately on detection | Incident ticket + direct message |
| DPO | Within 1 hour if personal data in scope | Email + incident ticket |
| `org:owner` of affected tenant | Within 2 hours | In-app notification + email |
| Cyprus DPA | Within 72 hours if personal data confirmed affected | Formal DPA notification (DPO leads) |
| Legal counsel | If tampering is confirmed or suspected | DPO or CTO initiates |

### 4.2 Regulatory Notification

If the investigation confirms that personal data was accessible during the breach window, the Cyprus Data Protection Authority must be notified within 72 hours of discovery. See `security_incident_response_policy.md` Section 5 for the notification procedure.

---

## 5. Remediation Options

### 5.1 Hardware or Software Failure (Non-Tamper)

If the investigation concludes that the chain break resulted from hardware failure, storage corruption, or a software bug (not deliberate tampering):

1. **Annotate the chain break** — insert a `CHAIN_BREAK_ANNOTATION` record at the break point. This record contains: the incident ID, the break sequence number, the probable cause, the investigation conclusion, and the names of the Security Lead and DPO who reviewed the finding. The annotation does not repair the chain; it documents the gap.
2. **Resume chain from break point** — the chain continues from the annotation entry as a new valid chain root. Entries before and after the break are preserved intact.
3. **Update audit record** — close the SEV-2 incident with full documentation. The incident record is the authoritative explanation for the break.

### 5.2 Tampering Confirmed

If the investigation cannot rule out deliberate tampering, or if tampering is confirmed:

1. **Legal hold** — all data within the affected scope is placed under legal hold. No automated deletions.
2. **DPA notification** — if personal data is in scope, formally notify the Cyprus DPA. The DPO drafts the notification; the Security Lead provides the technical annex.
3. **Law enforcement** — if tampering constitutes a criminal act under Cyprus law, legal counsel advises whether to report to the Cyprus Police.
4. **Preserve the break** — do not annotate or repair the chain. The broken chain is evidence. Its state must be preserved exactly.
5. **Platform access review** — audit all user and service-account access to the affected tables in the period surrounding the break. Revoke any unexplained access.

---

## 6. What Cannot Be Done

The following actions are explicitly prohibited during and after a chain break investigation:

- **The hash chain cannot be repaired.** There is no legitimate operational procedure to reconstruct or re-hash entries to restore chain continuity. Any such action would itself constitute evidence tampering and would invalidate the chain's evidentiary value.
- **Log entries cannot be deleted** to "clean up" the break or simplify the investigation.
- **Affected run cannot be finalised** while under QUARANTINED status. Finalisation is blocked at the phase gate level.
- **Automated retention jobs cannot run** on in-scope data while the legal hold is active.

These prohibitions are absolute and are not subject to override by any business entity or platform operator.

---

## 7. Post-Incident Documentation

After the investigation is complete, produce and retain:

- Full incident record per `security_incident_response_policy.md` Section 7.
- Chain break analysis report: break point, scope, cause, evidence reviewed.
- If annotated (non-tamper): annotation record ID and content.
- If tampering confirmed: legal hold record, DPA notification reference, law enforcement contact (if applicable).

---

## Related Documents

- `hash_chain_schema.md` — hash chain DDL and entry structure
- `archive_integrity_policy.md` — integrity verification rules
- `hash_chain_verification_policy.md` — verification procedure details
- `tamper_detection_forensic_runbook.md` — broader tamper detection forensics
- `security_incident_response_policy.md` — incident classification and GDPR notification
- `archive_verification_policy.md` — scheduled verification configuration
- `audit_log_schema.md` — audit log that feeds the hash chain
- `backup_and_recovery_policy.md` — recovery options for non-tamper corruption
- `data_retention_policy.md` — retention job suspension rules
