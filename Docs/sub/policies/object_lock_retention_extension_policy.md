# Object Lock Retention Extension Policy

**Category:** Policies · **Owning block:** 04 — Data Architecture · **Co-owner:** 04 Phase 07 (Object Lock integration) · **Stage:** 4 sub-doc (Layer 2)

When a legal hold is filed on a business, the Object Lock retention on every archive bundle owned by that business is extended to cover the hold window. This policy pins the extension calculation, the COMPLIANCE-mode interaction, the per-bundle iteration, the post-lift behavior, and the failure handling.

Per the Phase 11 phase doc: "When a hold is set, all archive bundles for the business have their Object Lock retention extended to `max(current_lock_retention, hold_set_at + max_legal_hold_window)`. When a hold is lifted, the lock retention reverts to the standard policy."

The "reverts on lift" sentence in the phase doc is misleading and reconciled in §5: COMPLIANCE-mode Object Lock CANNOT be shortened, so once extended the retention floor stays at the extended value. The retention engine's deletion-eligibility check is what resumes after lift — Object Lock retention is the per-bundle platform floor that the engine respects but does not control after extension.

---

## 1. Trigger — hold filed

The `LEGAL_HOLD_SET` audit event (existing) is subscribed by an asynchronous job `archive.extend_object_lock_for_hold`. The job:

1. Reads the new `legal_holds` row.
2. Enumerates `archive.archive_packages WHERE business_id = $hold.business_id`.
3. For each package, calls `archive.extend_object_lock(p_archive_package_id, p_new_retention_until)` with the §2 formula.
4. Emits `OBJECT_LOCK_RETENTION_EXTENDED` per bundle (existing event).
5. Logs batch outcome in `archive.legal_hold_extension_log` (NEW table, §6).

Idempotent: re-running produces the same `max()` value — extension is monotonically non-decreasing.

---

## 2. Extension calculation

```
new_retention_until = max(
  current_object_lock_retention_until,                       -- floor preservation
  hold_started_at + max_legal_hold_window                    -- hold-side extension
)

where max_legal_hold_window comes from legal_hold_maximum_window_policy.md
       (default 10 years; per-business override possible)
```

Refinement when `hold_ends_at` is set (planned-end hold):

```
new_retention_until = max(
  current_object_lock_retention_until,
  min(hold_ends_at + INTERVAL '1 year',
      hold_started_at + max_legal_hold_window)
)
```

The 1-year post-hold buffer accommodates appeals/contestation. The `min()` caps at `max_legal_hold_window` from filing time so a long planned-end can't bypass the regional cap.

For open-ended holds (`hold_ends_at IS NULL`): uses `hold_started_at + max_legal_hold_window`. The hold may live longer than the Object Lock retention — the engine-layer hook check is the primary gate; Object Lock is defense-in-depth.

---

## 3. COMPLIANCE mode interaction

Per `object_lock_integration.md` §"Extend retention": retention CAN be extended (later date) but NEVER shortened. COMPLIANCE mode enforces this at the platform level.

The `archive.extend_object_lock` Postgres helper wraps the Supabase Storage admin API:

```
PUT /storage/v1/object/<bucket>/<key>?retention=true
X-Object-Lock-Retention-Until-Date: <new_retention_until>
```

Pre-call validation: assert `new_retention_until >= current_retention_until`. Supabase Storage also enforces this — a shortening attempt returns HTTP 409. Both checks kept (defense-in-depth).

Cannot operate on bundles in GOVERNANCE mode (not used for archives in MVP per `object_lock_integration.md`).

---

## 4. Per-bundle iteration

Iteration order: `(period_start ASC, promoted_at ASC)`. Each bundle is extended in its own transaction — partial-batch failure does not roll back successful extensions.

| Cardinality | Per-bundle latency | Batch latency |
|---|---|---|
| 1 bundle | P50 50 ms / P95 200 ms | < 200 ms |
| 72 bundles (6-year monthly cadence) | as above | P50 3.6 s / P95 14 s |

Time-budget cap: 30 minutes per business. Past 30 min, the job emits `LEGAL_HOLD_EXTENSION_TIMEOUT` (HIGH) and remaining bundles queue for the next scheduled retry pass at 04:00 UTC.

---

## 5. Trigger — hold lifted (Object Lock NOT shortened)

Critical: when a hold is lifted, the Object Lock retention is **NOT** shortened — COMPLIANCE mode does not allow it. Instead:

1. The retention engine's hook (per `retention_legal_hold_hook_contract.md`) now returns `on_hold = false`.
2. The engine resumes deletion-eligibility checks against the business's bundles.
3. Bundles whose Object Lock retention has now passed AND have age past the per-business `retention_years` become deletion-eligible.
4. Bundles whose Object Lock retention is still in the future (because the hold extended it) remain locked at the platform layer until that date passes — the engine respects this as a hard floor.

The phase doc line "lock retention reverts to the standard policy" is reconciled HERE: the engine's deletion gate reverts (engine-layer behavior); Object Lock retention itself does not revert (platform-layer floor).

`LEGAL_HOLD_LIFTED` triggers no Object-Lock-side companion job — there is no extension to perform.

---

## 6. Extension log

```sql
CREATE TABLE archive.legal_hold_extension_log (
  id                     uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  legal_hold_id          uuid NOT NULL REFERENCES legal_holds(id),
  business_id            uuid NOT NULL,
  bundles_extended       integer NOT NULL DEFAULT 0,
  bundles_skipped        integer NOT NULL DEFAULT 0,
  total_bundles_seen     integer NOT NULL DEFAULT 0,
  extension_started_at   timestamptz NOT NULL,
  extension_completed_at timestamptz NULL,
  outcome                text NOT NULL DEFAULT 'IN_PROGRESS',
  -- outcome: IN_PROGRESS | COMPLETED | PARTIAL | TIMEOUT | FAILED
  notes                  text NULL
);

CREATE INDEX idx_legal_hold_extension_log_hold ON archive.legal_hold_extension_log(legal_hold_id);
```

One row per `LEGAL_HOLD_SET` event. Visible to Owner + auditors. `PARTIAL`/`FAILED` outcomes trigger operator review.

---

## 7. Failure handling

| Failure | Behavior |
|---|---|
| Storage API rejects extension (transient 5xx) | Retry per `retry_policy.md` standard tier (N=3, base 2s exponential, ±10% jitter, cap 30s); on exhaustion mark bundle as skipped in this pass; next-day retry pass picks it up |
| Storage API returns 409 (cannot shorten) | Should never occur — §2 uses `max()`. If it does, emit `OBJECT_LOCK_EXTENSION_REJECTED_SHORTEN` (HIGH) and continue with next bundle |
| Storage credential failure | Abort batch + emit `LEGAL_HOLD_EXTENSION_AUTH_ERROR` (HIGH); the hold remains active in DB so the engine still blocks deletion via the hook; operator escalation required for the Object Lock layer |
| Network timeout | Transient; retry |

The hold's effectiveness for the retention engine is NOT dependent on Object Lock extension success — the engine consults the `legal_holds` table directly via the hook. Extension is platform-layer defense-in-depth.

---

## 8. Audit events

| Event | Severity | When |
|---|---|---|
| `LEGAL_HOLD_OBJECT_LOCK_EXTENSION_STARTED` | LOW | Batch begins for a hold |
| `LEGAL_HOLD_OBJECT_LOCK_EXTENSION_COMPLETED` | LOW | Batch finishes (all bundles processed) |
| `LEGAL_HOLD_EXTENSION_TIMEOUT` | HIGH | 30-min cap exceeded |
| `LEGAL_HOLD_EXTENSION_AUTH_ERROR` | HIGH | Credential failure mid-batch |
| `OBJECT_LOCK_EXTENSION_REJECTED_SHORTEN` | HIGH | Shorten attempt rejected by Storage (should never occur) |
| `OBJECT_LOCK_RETENTION_EXTENDED` | LOW | Per-bundle extension success (EXISTING event in taxonomy) |

5 NEW events; added to `audit_event_taxonomy.md` this cycle.

---

## 9. Mobile rejection

Extension is an async backend job; no client surface exists.

---

## 10. Cross-references

- `legal_hold_lifecycle_policy.md` (B04·P11 seq 426) — `LEGAL_HOLD_SET` triggers this policy's job; `LEGAL_HOLD_LIFTED` triggers no companion
- `legal_hold_ui_spec.md` — UI surfaces extension-log outcomes via the panel history
- `legal_hold_maximum_window_policy.md` (B04·P11 seq 430) — `max_legal_hold_window` constant + per-business override
- `legal_hold_reason_guidance.md` — `hold_kind` referenced in extension log
- `object_lock_integration.md` — Object Lock COMPLIANCE mode + extend-only semantics
- `retention_legal_hold_hook_contract.md` — engine consults `legal_holds` directly; extension is defense-in-depth
- `retention_deletion_atomicity_policy.md` — engine's deletion gate respects Object Lock retention as platform floor
- `retry_policy.md` — standard tool tier for transient Storage errors
- `audit_event_taxonomy.md` — `LEGAL_HOLD_*` + `OBJECT_LOCK_*` event families
- Block 04 Phase 07 — Object Lock integration owner
- Block 04 Phase 11 — owning phase
- Stage 1 decision — Object Lock COMPLIANCE mode for archive bundles
