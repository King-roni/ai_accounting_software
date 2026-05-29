# object_lock_integration

**Category:** Integrations · **Owning block:** 04 — Data Architecture · **Co-owner:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 1 cross-block integration)

The Supabase Storage Object Lock integration for archive bundles. Per Stage 1: "Finalized Archive physical model: separate Postgres schema with stricter RLS + Supabase Storage Object Lock for archive files."

Object Lock prevents object deletion and modification during the retention window — the platform-level immutability layer in the three-layer immutability model (Block 15 Phase 07: per-row Postgres CHECK, per-bundle storage Object Lock, external RFC 3161 anchor).

---

## Provider configuration

| Setting | Value |
| --- | --- |
| Provider | Supabase Storage (managed; backed by AWS S3 EU regions per Supabase's documented infrastructure) |
| Object Lock mode | `COMPLIANCE` (default; not overridable even by the Supabase admin) |
| Object Lock alternative mode | `GOVERNANCE` (admin-overridable; reserved for non-archive use cases) |
| Region | EU-only per Stage 1 (Supabase configured for EU regions) |

## Retention model

Per-bundle retention timestamp; the bundle is locked until the timestamp passes. Cyprus regulator-driven baseline: 6 years.

| Source | Retention period |
| --- | --- |
| Default | 6 years from `archive_packages.promoted_at` (per Cyprus VAT/books retention) |
| Per-business override | Available via `retention_policies_schema` for businesses with longer retention requirements (e.g., audit subjects) |
| Legal hold extension | Indefinite — see "Legal hold interaction" below |

## API operations

### Set retention (at promotion)

```
PUT /storage/v1/object/<bucket>/<key>?lock=true
X-Object-Lock-Mode: COMPLIANCE
X-Object-Lock-Retention-Until-Date: 2032-02-05T14:23:00Z
```

Invoked during Block 15 lock-sequence step 5 (archive bundle construction). The bundle bytes are uploaded; the retention attribute is set in the same operation.

### Read with verification

```
GET /storage/v1/object/<bucket>/<key>
```

Returns the object bytes + the current Object Lock attributes (mode, retention-until). Block 15 Phase 07's pre-read verification compares stored attributes against expected attributes; mismatch raises `OBJECT_LOCK_VIOLATION_DETECTED` (BLOCKING).

### Extend retention

```
PUT /storage/v1/object/<bucket>/<key>?retention=true
X-Object-Lock-Retention-Until-Date: 2034-02-05T14:23:00Z
```

Per `object_lock_retention_extension_policy` (merged into `data_layer_conventions_policy` cross-references): retention CAN be extended (later date) but NEVER shortened. Compliance mode enforces this at the platform level.

### Delete (after retention)

```
DELETE /storage/v1/object/<bucket>/<key>
```

Only succeeds after `retention-until-date < now()` AND no active legal hold. The `retention_engine` role per `retention_policies_schema` is the only caller authorised to attempt this.

## COMPLIANCE vs GOVERNANCE

| Mode | Override possible? | Use case |
| --- | --- | --- |
| `COMPLIANCE` | No — even the Supabase admin cannot unlock or shorten retention | Archive bundles (Stage 1 default) |
| `GOVERNANCE` | Yes — Supabase admin can override with a special permission | Not used for archives in MVP; reserved for future temporary-hold use cases |

Stage 1 mandates COMPLIANCE for archive bundles. The platform-level immutability is intentional — if the operator's own infrastructure is compromised, the bundles remain immutable.

## Legal hold interaction

Per `legal_hold_policies` (the merged Block 04 policy): a business-level legal hold extends Object Lock retention indefinitely. Implementation:

1. Legal hold flag set on `businesses.legal_hold_active = true`
2. The retention engine consults `retention_policies_schema`; if legal hold is active, retention deletion is deferred regardless of `retention-until-date`
3. The Object Lock retention is NOT extended dynamically (no need — the deletion gate is at the operator's retention engine layer, not at Supabase Storage)
4. When legal hold is lifted, the retention engine resumes normal deletion eligibility checks

`retention_policies_schema`'s `RETENTION_DELETION_SKIPPED_LEGAL_HOLD` event fires per Block 04 Phase 11 when retention would otherwise apply.

## Three-layer immutability summary

Per Block 15 Phase 07:

1. **Layer 1** — Postgres CHECK constraint on `archive.locked_ledger_entries` rejects writes outside the Block 15 lock-sequence context (per `archive_schema`)
2. **Layer 2** — Object Lock on the bundle bytes (this integration)
3. **Layer 3** — RFC 3161 external anchor on the bundle hash (per `archive_hash_anchor_integration`)

Any single layer's failure does not compromise the others. Reading from the archive verifies all three independently.

## Bundle versioning

Per Stage 1: "Adjustment-finalization writes a new manifest version; old versions remain queryable." This translates to Object Lock as:

- Original bundle: `archive_v1_bundle.zip` — Object-Locked at promotion
- First adjustment bundle: `archive_v2_bundle.zip` — separate object, separately Object-Locked
- Each bundle's retention runs independently

Per the Block 15 scan: each bundle is a separate zone object; the manifest files live INSIDE their respective zip bundles (not as separate Object-Locked objects).

## Audit events

| Event | When |
| --- | --- |
| `OBJECT_LOCK_RETENTION_SET` | Initial setting at promotion |
| `OBJECT_LOCK_RETENTION_EXTENDED` | Retention extension via API call |
| `OBJECT_LOCK_VIOLATION_DETECTED` | Pre-read verification or write-attempt detected tampering |

Per `audit_log_policies` Section 1 and Block 04 Phase 07 (the Block 05 scan fix added `OBJECT_LOCK_VIOLATION_DETECTED` to Block 04's audit list).

## Storage cost

Cost-bearing model: Supabase Storage charges per GB-month. Object-Locked bundles cost the same as regular objects; no premium.

Approximate per-business cost (assuming 100 KB average bundle, monthly cadence over 6 years):

| Bundles per year | Per-business storage | Annual cost (EU regions) |
| --- | --- | --- |
| 12 (monthly) | ~1.2 MB / year | < $0.01 |
| 14 (monthly + 2 adjustments / year) | ~1.4 MB / year | < $0.01 |
| 72 over 6 years | ~7.2 MB cumulative | ~$0.05 cumulative |

Storage cost is negligible compared to compute cost.

## Failure handling

| Failure | Behavior |
| --- | --- |
| Upload fails | Block 15 lock-sequence rolls back per `lock_sequence_policies`; retry once; permanent failure raises HIGH issue |
| Retention setting fails | Re-attempt; if persistent, raise `ARCHIVE_PROMOTION_FAILED` |
| Verification mismatch (pre-read) | BLOCKING — business-wide halt per Block 15 Phase 07 |

## EU residency

Supabase Storage is configured for EU regions per Stage 1. Object bytes never leave EU. Cross-region replication is NOT enabled in MVP (single-region storage with cross-AZ redundancy).

## Cross-references

- `archive_bundle_layout_schema` — bundle internal structure that is Object-Locked
- `archive_schema` — `archive_packages.bundle_object_uri` + `object_lock_retention_until` columns
- `archive_promotion_failure_runbook` — failure response procedure
- `legal_hold_policies` — legal-hold interaction
- `retention_policies_schema` — retention engine integration
- `audit_log_policies` — `OBJECT_LOCK_*` event family
- `archive_bundle_policies` — bundle determinism + retention
- Block 04 Phase 07 — Finalized Secure Archive zone (architecture)
- Block 15 Phase 07 — Storage Object Lock & three-layer immutability
- Stage 1 decision — Object Lock for archive files
