# archive_hash_anchor_integration

**Category:** Integrations · **Owning block:** 04 — Data Architecture · **Co-owners:** 05, 15 · **Stage:** 4 sub-doc (Layer 1 cross-block integration)

The integration that anchors archive bundle hashes to external RFC 3161 timestamp authorities. Per Block 15 Phase 07's three-layer immutability model, this is Layer 3 — the external proof that the bundle existed in this form at the recorded time, surviving any compromise of the operator's own infrastructure.

Sibling integration of `rfc_3161_timestamp_integration` — uses the same TSA providers and the same RFC 3161 protocol, but for archive bundle hashes rather than audit chain heads.

---

## What gets anchored

Per `archive_manifest_schemas` and `archive_bundle_layout_schema`:

| Anchored value | When | Provenance |
| --- | --- | --- |
| `manifest_v1.json` hash | At original finalization | Block 15 Phase 04 step 7 |
| `manifest_v{N}.json` hash for N > 1 | At adjustment-finalization | Block 15 Phase 06 |
| `bundle_hash` (the zip's hash) | Optional — at original + adjustment | Block 15 Phase 05 |

The manifest hash is the primary anchor. The bundle hash is anchored as a secondary precaution (so even if the manifest is somehow recreated, the bundle bytes are independently proven).

## Anchor process

```
1. At lock-sequence step 7 (original) or adjustment-finalization step 5:
   - Take the manifest's canonical JSON
   - Compute SHA-256 (hex) — already stored as archive_manifests.manifest_hash

2. Build RFC 3161 TimeStampReq:
   - MessageImprint = manifest_hash bytes (decoded from hex)
   - HashAlgorithm = SHA-256 OID

3. POST to TSA endpoint (per rfc_3161_timestamp_integration provider list)

4. Receive TimeStampResp:
   - Store the signed timestamp token + TSA cert chain + parsed timestamp_value
   - Link to the archive_manifests row via rfc_3161_timestamp_id

5. Emit audit event TIMESTAMP_RECORDED with payload referencing archive_manifest_id
```

## Storage

Reuses the `rfc_3161_timestamps` table per `rfc_3161_timestamp_integration`. The integration disambiguates between audit-chain-head anchors and archive-manifest anchors via the `chain_id` field:

| `chain_id` value | Anchor type |
| --- | --- |
| `global` / `org:<uuid>` / `business:<uuid>` | Audit-chain anchor |
| `archive_manifest:<archive_manifest_id>` | Archive manifest anchor |
| `archive_bundle:<archive_package_id>` | Archive bundle anchor |

## Verification

Re-verifying an archive bundle:

1. Read `archive_packages` row for the bundle in question
2. Read the corresponding `archive_manifests` row (typically the latest version, but any can be verified)
3. Read the corresponding `rfc_3161_timestamps` row via the FK
4. Re-compute `archive_manifests.manifest_hash` from `archive_manifests.manifest_canonical_json` — assert match
5. Verify the timestamp_token's signature against the stored cert chain (per `rfc_3161_timestamp_integration` Section "Verification")
6. Extract MessageImprint from the timestamp_token — assert it matches the manifest hash
7. Extract `genTime` — that's the proven moment

Any failure raises `ARCHIVE_TAMPER_DETECTED` per `audit_event_taxonomy` (BLOCKING; halts the business per Block 15 Phase 07).

## Cross-version manifest chain

Adjustment-finalization writes a new manifest with `prior_manifest_hash` pointing at the prior version's hash. The chain back to v1 is independently verifiable:

```
manifest_v3.json: prior_manifest_hash = hash(manifest_v2)
manifest_v2.json: prior_manifest_hash = hash(manifest_v1)
manifest_v1.json: prior_manifest_hash = null  (original)
```

Verifying v3 means re-verifying v2 means re-verifying v1 — each via its own RFC 3161 anchor. The chain is full proof that the entire version sequence is genuine.

## Multi-TSA redundancy

Per `rfc_3161_timestamp_integration`: each manifest hash MAY be anchored at multiple TSAs (primary + secondary). The verification surface accepts any one valid timestamp as proof — the system is robust to TSA-cert revocation or vendor disappearance.

Default policy in MVP: anchor at primary only. Anchor at secondary on suspected primary instability. Anchor at three on critical-stakes runs (manual override via `BUSINESS_SETTINGS_EDIT`).

## Failure handling

| Failure | Behavior |
| --- | --- |
| TSA unreachable during lock-sequence step 7 | Lock-sequence does NOT fail (anchor is best-effort); the manifest is committed without a timestamp; deferred-anchor flag set; retry on next workflow run start |
| Anchor retry exhausted (multiple failures) | Audit event `TIMESTAMP_AUTHORITY_UNREACHABLE`; admin alert; the period is finalized but unanchored — operator must remediate before audit confidence is met |
| Anchor verification fails post-write | BLOCKING — `ARCHIVE_TAMPER_DETECTED`; business-wide halt |

Per Block 15 Phase 07: anchor failure is recorded but does not block finalization. Anchor verification failure (tampering detected) is blocking.

## Audit events

| Event | When |
| --- | --- |
| `TIMESTAMP_AUTHORITY_INVOKED` | Per anchor call (inherited from `rfc_3161_timestamp_integration`) |
| `TIMESTAMP_RECORDED` | Successful storage |
| `TIMESTAMP_AUTHORITY_UNREACHABLE` | Anchor failure |
| `ARCHIVE_TAMPER_DETECTED` | Verification mismatch (BLOCKING) |
| `AUDIT_CHAIN_HEAD_ANCHORED` | Sibling event for audit-chain anchoring (different chain_id pattern) |

## EU residency

Same TSA provider list as `rfc_3161_timestamp_integration` — EU-domiciled only.

## Performance budget

Per `fixture_performance_budget`:

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| Single anchor call (manifest) | 500 ms | 2 s | 5 s |
| Verification (re-hash + verify token) | 50 ms | 200 ms | 500 ms |

## Cost

Same per-call TSA cost as `rfc_3161_timestamp_integration` — ~$0.001-0.005 per anchor. Per period: 1 anchor (manifest) + optional 1 anchor (bundle) = ~$0.01 per finalization. Per business per year: ~$0.15 (12 monthly + 2-3 adjustments).

## Anchor failure handling and retry semantics

When the RFC 3161 timestamp service is unavailable during lock-sequence step 7, the behavior is:

1. The anchor call times out after the P99 budget (5 s). The system does not wait indefinitely.
2. A `TIMESTAMP_AUTHORITY_UNREACHABLE` audit event is emitted immediately.
3. A `deferred_anchor_pending = true` flag is set on the `archive_manifests` row.
4. The lock-sequence proceeds and commits — finalization is NOT blocked by an anchor failure (the manifest and bundle are already Object-Locked via Layer 2; RFC 3161 is a belt-and-suspenders third layer).
5. A background retry job (`archive.retry_deferred_anchors`) runs every 15 minutes and attempts to anchor any manifests with `deferred_anchor_pending = true`.
6. Retry uses the same exponential backoff scheme as `event_emission_transactional_policy` (1 s → 2 s → 4 s → 8 s, max 4 retries per job run).
7. If all retries in a 24-hour window are exhausted without a successful anchor, the severity is escalated to HIGH and an admin alert is raised. The period remains finalized but is flagged as `anchor_confidence = UNANCHORED` in the archive dashboard.

Operators can view unanchored manifests via:

```sql
SELECT archive_manifest_id, business_id, manifest_version_number, created_at
FROM archive_manifests
WHERE deferred_anchor_pending = true
ORDER BY created_at;
```

## Cross-references

- `rfc_3161_timestamp_integration` — sibling integration (audit chain anchors); TSA provider list
- `rfc3161_timestamp_policy` — RFC 3161 protocol requirements; TSA selection criteria; cert rotation
- `archive_schema` — `archive_manifests.rfc_3161_timestamp_id` FK; `deferred_anchor_pending` flag
- `archive_manifest_schemas` (Block 15) — manifest chain
- `archive_bundle_layout_schema` — what gets hashed
- `object_lock_integration` — Layer 2 of the three-layer immutability
- `archive_bundle_policies` — manifest two-pass construction
- `audit_log_policies` — `TIMESTAMP_*` / `ARCHIVE_TAMPER_DETECTED` events
- `key_rotation_runbook` — TSA cert rotation
- Block 04 Phase 07 — Finalized Secure Archive zone
- Block 05 Phase 03 — audit log tamper resistance (shared anchor infrastructure)
- Block 15 Phase 07 — three-layer immutability
- Stage 1 decision — RFC 3161 third-party timestamping
