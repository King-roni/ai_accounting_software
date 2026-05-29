# Block 15 — Phase 07: Storage Object Lock & Three-Layer Immutability

## References

- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (Immutability — three layers)
- Block doc: `Docs/blocks/04_data_architecture.md` (Phase 07 — Finalized Secure Archive zone; Storage Object Lock)
- Block doc: `Docs/blocks/05_security_and_audit.md` (Phase 03 — audit-log tamper resistance; Phase 06 — access control runtime; Phase 10 — security alerting)
- Decisions log: `Docs/decisions_log.md` (Storage Object Lock for archive files; hash-chained audit log + RFC 3161 timestamping)

## Phase Goal

Wire the three independent immutability layers that protect locked archives from silent change: Layer 1 (schema-level RLS), Layer 2 (storage Object Lock), Layer 3 (audit-log read-tracking + tamper detection). After this phase, a locked period cannot be silently changed even by a privileged operator — any change requires coordinated bypass of all three layers, which Block 05's audit infrastructure detects.

## Dependencies

- Phase 01 (`locked_ledger_entries` separate-schema RLS — Layer 1)
- Phase 04 (lock sequence step 5 invokes Object Lock — Layer 2)
- Phase 05 (bundle constructed with per-file hashes — feeds Layer 3 detection)
- Block 04 Phase 07 (Finalized Secure Archive zone — owns the storage-layer Object Lock primitive)
- Block 05 Phase 02 (audit-log API)
- Block 05 Phase 03 (audit-log hash-chain tamper resistance + RFC 3161 timestamping)
- Block 05 Phase 06 (access control runtime)
- Block 05 Phase 10 (security alerting — fires on tamper detection)

## Deliverables

- **Layer 1 — Schema-level immutability** (applies uniformly to all four archive tables; INSERT-gating uses two session variables to distinguish original vs adjustment lock contexts — closes the M3 ambiguity):
  - **Session variables** set by the lock-sequence executors:
    - `app.original_lock_active = true` — set by Phase 04's `finalization.execute_lock_sequence`.
    - `app.adjustment_lock_active = true` — set by Phase 06 / Phase 08's `finalization.execute_adjustment_lock_sequence`.
    - The two are mutually exclusive — exactly one is true during any active sequence.
  - **`archive.locked_ledger_entries`** (Phase 01): UPDATE / DELETE forbidden through every application role (Owner included). INSERT permitted when `app.original_lock_active = true` OR `app.adjustment_lock_active = true` (with `archive_manifest_version = 1` for original; `> 1` for adjustment — RLS predicate enforces).
  - **`archive_manifests`**: UPDATE / DELETE forbidden. INSERT with `manifest_version_number = 1` requires `app.original_lock_active = true`; INSERT with `manifest_version_number > 1` requires `app.adjustment_lock_active = true`.
  - **`archive_packages`**: UPDATE / DELETE forbidden post-creation (the `bundle_hash_anchor` field and all other columns are immutable). INSERT requires `app.original_lock_active = true` (adjustments do NOT create new package rows; they create new manifest rows pointing at an existing package).
  - **`archive_files`**: UPDATE / DELETE forbidden. INSERT permitted under either lock-active flag, with the predicate that `archive_manifest_id` references a manifest in the right active sequence.
  - **Bypass path:** direct database administrator access (DBA-level superuser) can theoretically bypass RLS, but:
    - The DBA path is out of scope for application-level policy.
    - Layer 3's audit-log detects the resulting hash mismatch (per the bypass-detection contract below).
    - Sub-doc tracks operator-level controls (Vault-managed superuser credentials, MFA, alerting on superuser session).
- **Layer 2 — Storage-level Object Lock:**
  - At Phase 04 step 5, the lock sequence applies Object Lock to the sealed zip bundle file in the Finalized Secure Archive zone (Block 04 Phase 07).
  - **Retention policy:** Object Lock retention = 6 years from `archive_packages.created_at` per the canonical retention window. After retention expires, the storage layer permits deletion (Block 04 Phase 10's retention engine handles).
  - **What's locked** (per Phase 05's pinned storage model — each bundle is a separate zone object):
    - `bundle_v1.zip` — the original finalization bundle (locked once at Phase 04 step 5).
    - `bundle_v2.zip`, `bundle_v3.zip`, ... — each adjustment-finalization produces a new zone object that is independently locked at its own lock time.
    - **Manifest files** (`manifest_v1.json` inside `bundle_v1.zip`; `manifest_v2.json` inside `bundle_v2.zip`, etc.) are sealed by being inside their respective Object-Locked zips — the manifest is not a separate zone object.
    - **Evidence files** are inside the `evidence/` directory of each bundle; they inherit the bundle's Object Lock.
  - **What's NOT locked:**
    - The operational `transactions`, `match_records`, `draft_ledger_entries` tables (these are the pre-lock state; they may be amended by future runs against future periods, just not modified for the locked period).
    - Files in zones other than the Finalized Secure Archive (Raw Upload, Processing, Operational DB).
  - **Storage-level write attempt** on a locked file (overwrite, delete) is rejected by the storage layer with a structured error; the Block 04 Phase 07 wrapper catches and re-emits as `STORAGE_OBJECT_LOCK_VIOLATION_ATTEMPT` (Block 05 audit event).
  - **Bypass path:** the storage admin / cloud-provider root can theoretically remove Object Lock retention. Same as Layer 1 — out of scope for application policy; sub-doc tracks operator controls; Layer 3 detects.
- **Layer 3 — Audit-level read tracking + tamper detection:**
  - **Read tracking:** every read of `archive.locked_ledger_entries`, every download of an archive bundle, every manifest read is logged via Block 05 Phase 02's audit-log API. Sub-doc owns the read-event structure (canonical: `ARCHIVE_DATA_READ` with subject + actor + accessed-resource).
  - **Tamper detection mechanism:**
    - Periodically (sub-doc tracks frequency; Stage 1 default — daily reconciliation job + on-demand verification), a verification pass:
      1. For every `archive_packages` row, recompute the SHA-256 of the bundle file in storage.
      2. Compare to the stored `bundle_hash_anchor`.
      3. For every `archive_manifests` row, recompute the manifest file's hash and compare.
      4. For every `archive_files` row, recompute and compare.
      5. Walk the audit-log hash chain for the `archive_package_id` and verify chain integrity.
      6. Verify RFC 3161 timestamp anchors (Block 05 Phase 03) against the chain heads.
    - **Mismatch detection:** any of the six checks failing fires `ARCHIVE_TAMPER_DETECTED` (Block 05 Phase 10's security-alerting path) AND raises a BLOCKING-severity review issue. The mismatch payload identifies the specific file or chain segment.
  - **Audit-log forensic tracing:** when tampering is detected, the audit log's hash chain reveals what changed when by walking the chain backwards from the current head. RFC 3161 timestamps establish that the chain segments existed at known prior times.
- **Combined-layer guarantee:**
  - A silent change to a locked period requires:
    1. Bypassing Layer 1 (DBA superuser modification of `archive.locked_ledger_entries`).
    2. Bypassing Layer 2 (storage admin removal of Object Lock retention OR direct cloud-provider intervention).
    3. Bypassing Layer 3 (rewriting the audit log hash chain consistently AND forging an RFC 3161 timestamp anchor — RFC 3161 anchors are signed by an external timestamp authority, so forgery requires breaking the timestamp authority's signing key).
  - All three bypasses must succeed AND remain undetected. Each bypass leaves trace: Layer 1 leaves DB-server logs; Layer 2 leaves cloud-provider audit logs; Layer 3 leaves the timestamp-authority's external record. The architecture commits that **at least one trace is visible**, making coordinated tampering effectively impossible without external collusion.
- **Tamper-detection scheduling:**
  - **Daily reconciliation pass** (Block 03 Phase 09 scheduled job): runs the verification on a sliding window of recently finalized packages (Stage 1 default — packages finalized in the last 30 days, plus a random 1% of older packages).
  - **On-demand verification:** any user with `REVIEW_QUEUE_VIEW` can request verification of a specific archive package; the verification runs synchronously and returns a verdict. Audit-logged.
  - **Pre-read verification (Stage 1 caching default):** before an archive bundle is read for the first time in a session, Layer 3's hash check fires once per session per `archive_package_id`; the verification result is cached for the session duration (default 30 minutes; sub-doc tunes). Subsequent reads in the same session skip the check. **Cache is invalidated** by: (a) cache TTL expiry, (b) explicit on-demand verification request, (c) adjustment-run intake (which always re-verifies — adjustment intake is high-stakes and worth the cost). Mismatch blocks the read for the rest of the session and surfaces a BLOCKING tamper alert. The daily reconciliation pass handles long-tail verification independently — the per-session cache is for hot-path reads (dashboard drill-down, exports). Without this caching, a 200MB bundle would re-hash on every dashboard click — the strict pre-read pattern is unusable at scale.
- **Detection-event severity & scope:**
  - `ARCHIVE_TAMPER_DETECTED` is BLOCKING in Block 14's review queue.
  - **Business-wide blocking scope (intentional):** a tamper alert against ANY archive package for a business halts all new finalizations AND adjustments for that business. Phase 02's `gate.finalization.zero_blocking_issues` predicate counts BLOCKING issues at the run scope, but tamper-detection issues are scoped to `business_id` (not `workflow_run_id`); the gate accordingly extends to "no tamper-BLOCKING issue exists for the business." A tampering event in a 3-year-old period is serious enough to halt operations on every period for that business until resolved.
  - Resolution requires Owner-level investigation and either a forensic recovery (out of MVP scope) or formal acceptance with reason logged. Owner-level acceptance writes a `ARCHIVE_TAMPER_FORMALLY_ACCEPTED` audit event with mandatory reason text; this re-enables finalization for the business.
- **Audit events** (`<DOMAIN>_<PAST_VERB>` convention; domain = `FINALIZATION` for layer setup, `ARCHIVE` for ongoing tamper-detection):
  - `FINALIZATION_OBJECT_LOCK_APPLIED` (Phase 04 step 5 success)
  - `FINALIZATION_OBJECT_LOCK_FAILED` (transient or permanent failure)
  - `ARCHIVE_DATA_READ` — **aggregated per-session per-resource** (Stage 1 budget: one event per `(session_id, archive_package_id)` first-read; subsequent reads in the same session for the same package update an in-memory counter that is flushed at session-end as `ARCHIVE_DATA_READ_SESSION_SUMMARY` with total count). Per-event logging would explode audit volume; per-session aggregation preserves forensic traceability while staying bounded.
  - `ARCHIVE_VERIFICATION_PASSED` (per verification pass)
  - `ARCHIVE_VERIFICATION_FAILED` (specific layer + file)
  - `ARCHIVE_TAMPER_DETECTED` (canonical alert event — fed into Block 05 Phase 10's alerting)
  - `STORAGE_OBJECT_LOCK_VIOLATION_ATTEMPT` (Layer 2 reject; out-of-band write attempt)

## Definition of Done

- A test attempting UPDATE on `archive.locked_ledger_entries` from any role is rejected at the database layer (Layer 1).
- A test attempting INSERT on `archive.locked_ledger_entries` outside an active lock sequence is rejected.
- A test calling the storage layer's overwrite API on an archive bundle file is rejected (Layer 2).
- A test calling Block 05 Phase 02's audit-log read-event API for a bundle read produces the right `ARCHIVE_DATA_READ` event.
- The daily reconciliation pass runs against a fixture of 10 archived packages and produces an `ARCHIVE_VERIFICATION_PASSED` event for each.
- A test that intentionally corrupts a stored bundle (tampering simulation) is detected on next verification; `ARCHIVE_TAMPER_DETECTED` fires; a BLOCKING review issue surfaces.
- A pre-read verification on a tampered package blocks the read.
- An on-demand verification API call returns the correct verdict.
- All audit events fire with the right payloads.

## Sub-doc Hooks (Stage 4)

- **Object Lock retention-policy SQL sub-doc** — exact storage API; per-region behavior.
- **Verification-pass scheduling sub-doc** — sliding-window vs full-scan trade-off; per-archive cost.
- **Tamper-detection forensic-trace sub-doc** — what to surface to the user; investigation runbook.
- **Pre-read verification sub-doc** — caching the verification result for a session vs re-running on every read.
- **DBA-bypass detection sub-doc** — operator-level controls; DB-server log integration.
- **RFC 3161 timestamp anchor sub-doc** — per-chain-head anchoring frequency; recovery from authority outages.
- **Audit-volume aggregation sub-doc** — `ARCHIVE_DATA_READ` per-session vs per-read trade-off.
