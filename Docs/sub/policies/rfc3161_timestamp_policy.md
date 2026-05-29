# RFC 3161 Timestamp Policy

**Category:** Policies · **Owning block:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 2)

Rules governing the application of RFC 3161 trusted timestamps to finalized archive bundles. Every finalized archive bundle receives a timestamp token from a qualified external Time Stamping Authority (TSA) as Step 4 of the Block 15 lock sequence. The timestamp provides cryptographic proof that the bundle existed in its current form at a specific point in time, independent of any system clock the platform controls.

This policy is the single binding source for TSA endpoint configuration, token request construction, retry behaviour, storage conventions, token validation rules, and the relationship between the RFC 3161 timestamp and the post-finalization verification pass defined in `archive_verification_policy`.

---

## 1. Placement in the lock sequence

RFC 3161 timestamping is Step 4 of the 5-step lock sequence per `lock_sequence_policies`. It executes after the bundle ZIP has been Object-Locked in the `archive-bundles` bucket (Step 3). The tool that owns Step 4 is `archive.apply_rfc3161_timestamp`.

Step 4 must complete (either with a valid token or after exhausting retries — see Section 3) before Step 5 (manifest promotion) begins.

---

## 2. TSA configuration

The TSA endpoint is configured in platform settings under the key `platform.tsa_endpoint_url`. The default value is a qualified EU TSA that meets eIDAS Regulation requirements (Annex III — requirements for trust service providers issuing qualified certificates for electronic signatures). The platform operator may configure an alternative TSA endpoint; the alternative must appear in the EU Trust Service Status Lists (EU TSL) for Time-Stamping.

The TSA certificate chain used for token validation is fetched from the TSA's published trust service information and cached in platform configuration. The chain is validated against the EU Trusted Lists as part of token verification (see Section 4).

---

## 3. Timestamp request construction

The timestamp request (TimeStampReq, per RFC 3161 Section 2.4.1) is constructed as follows:

1. **Message imprint:** SHA-256 hash of the bundle ZIP bytes. The hash is the same value stored on `archive_packages.bundle_hash` (hex-encoded per `data_layer_conventions_policy`). The hash algorithm identifier in the request is `id-sha256`.
2. **nonce:** a randomly generated 64-bit integer, included to prevent replay attacks.
3. **certReq:** `true` — the response must include the TSA signing certificate chain.
4. **reqPolicy:** omitted (accept any TSA-supported policy OID).

The request is submitted as an HTTP POST to the configured TSA endpoint with `Content-Type: application/timestamp-query`.

---

## 4. Response validation

Before the TSA response token is accepted and stored, `archive.apply_rfc3161_timestamp` validates the response:

1. The HTTP response status must be `200 OK` with `Content-Type: application/timestamp-reply`.
2. The `PKIStatus` in the response must be `granted` (0) or `grantedWithMods` (1). Any other status is treated as a TSA failure.
3. The `messageImprint` in the `TSTInfo` structure must match the SHA-256 hash of the bundle ZIP submitted in the request. A mismatch is treated as a fatal validation error — the response is discarded, the token is not stored, and `RFC3161_TIMESTAMP_FAILED` is emitted.
4. The `nonce` in the response must match the nonce sent in the request. A mismatch indicates a replay or tampering; the response is discarded.
5. The TSA signing certificate chain is validated against the EU Trusted Lists. A chain that does not validate is treated as a fatal validation error.
6. The `genTime` in the `TSTInfo` must fall within [run `FINALIZING` entry timestamp, current time + 60 seconds] to bound clock skew tolerance.

If validation passes, the DER-encoded TSA response token is stored in the `archive-bundles` bucket at the path `{bundle_key}.tsr`. The `tsa_token_hash` (SHA-256 of the `.tsr` bytes, hex-encoded) is recorded on `archive_packages.tsa_token_hash`.

---

## 5. Retry behaviour

If the TSA HTTP call fails (network error, timeout, non-200 response, or a `PKIStatus` other than `granted`/`grantedWithMods`), `archive.apply_rfc3161_timestamp` retries up to 3 times with 10-second backoff between attempts (10s, 10s, 10s — not exponential).

After 3 failures without a valid response, the compensation sequence is triggered:

1. The run transitions from `FINALIZING` to `COMPENSATING`.
2. The compensating rollback runs in reverse step order per `lock_sequence_policies` Section 3.
3. `RFC3161_TIMESTAMP_FAILED` is emitted with `attempt_count = 3`.

A validation error on a TSA response (e.g., `messageImprint` mismatch) does **not** trigger a retry — it is a hard failure that immediately triggers the compensation sequence, because retrying with the same bundle hash to the same endpoint would produce the same response.

---

## 6. Storage

The TSA response token is stored at:

```
archive-bundles/{business_id}/{period_year}/{period_month}/{archive_package_id}.tsr
```

The path mirrors the bundle ZIP storage key with a `.tsr` extension. The `.tsr` file is stored with the same Object Lock settings as the bundle ZIP (COMPLIANCE mode, Cyprus 6-year retention) so that the timestamp token is retained for the same regulatory period as the evidence it timestamps.

---

## 7. Verification

The TSA response token is validated as part of the post-finalization verification pass (Check 2 in `archive_verification_policy`). The verification re-runs the validation steps in Section 4 above on the stored `.tsr` bytes. If the `.tsr` file is absent because Step 4 never completed, Check 2 is marked `SKIPPED_TSA_UNAVAILABLE` rather than `FAILED` — the absence was recorded in the bundle's `manifest.json` at Step 2 of the lock sequence.

---

## 8. Relationship to Block 05 audit-chain anchoring

Block 05 Phase 03 performs periodic RFC 3161 anchoring of the audit-chain hash-chain heads (per `audit_log_policies` Section 4 — "Anchoring (Phase 03)"). That anchoring is independent of this policy. The two uses of RFC 3161 are:

| Context | Tool | Object being timestamped | Storage |
|---|---|---|---|
| Archive bundle (this policy) | `archive.apply_rfc3161_timestamp` | Bundle ZIP SHA-256 | `{bundle_key}.tsr` in `archive-bundles` bucket |
| Audit chain anchoring (Block 05 Phase 03) | Block 05 tool | Audit chain head hash | Separate anchor records per Block 05 Phase 03 |

Neither anchoring operation replaces or depends on the other.

---

## 9. TSA endpoint change management

The TSA endpoint is a platform-level configuration value. Changing the TSA endpoint requires:

1. The replacement TSA must appear in the EU Trust Service Status Lists.
2. The change must be tested against a non-production environment with a real TSA call to confirm that `messageImprint` round-trip validation passes.
3. The platform settings key `platform.tsa_endpoint_url` is updated by a platform admin.
4. The change takes effect for the next bundle that enters Step 4 of the lock sequence. Previously issued `.tsr` files are valid regardless of which TSA endpoint produced them, provided the TSA's certificate chain was valid at the time of issuance.

No `decisions_log.md` amendment is required for a TSA endpoint change unless the replacement TSA is outside the EU Trusted Lists (which would require a policy amendment). A same-or-equivalent qualified EU TSA substitution is an operational configuration change.

---

## 10. Mobile rejection

`archive.apply_rfc3161_timestamp` is a server-side tool invoked exclusively as Step 4 of the lock sequence. It is not accessible from any client surface. The lock sequence tools are listed in `mobile_write_rejection_endpoints.md`.

---

## 11. Audit events

| Event | Severity | When |
|---|---|---|
| `RFC3161_TIMESTAMP_APPLIED` | LOW | TSA response passes all validation checks; `.tsr` file written; `tsa_token_hash` recorded on `archive_packages` |
| `RFC3161_TIMESTAMP_FAILED` | HIGH | Three retries exhausted without a valid TSA response, or a hard validation error on the response; compensation sequence initiated |

Both events are emitted on the business-scoped hash chain per `audit_log_policies`. They are in the `ARCHIVE` domain.

---

## Cross-references

- `lock_sequence_policies` — the 5-step lock sequence; Step 4 placement; compensation trigger on TSA failure
- `archive_verification_policy` — Check 2 (RFC 3161 token validity); `SKIPPED_TSA_UNAVAILABLE` outcome
- `data_layer_conventions_policy` — SHA-256 hex encoding for bundle hash and `tsa_token_hash`; canonical JSON for audit payloads
- `audit_log_policies` — `RFC3161_TIMESTAMP_APPLIED` and `RFC3161_TIMESTAMP_FAILED` event naming; `ARCHIVE` domain; business-scoped hash chain; Block 05 Phase 03 audit-chain anchoring relationship
- `audit_event_taxonomy` — `ARCHIVE` domain canonical events; `RFC3161_TIMESTAMP_APPLIED` and `RFC3161_TIMESTAMP_FAILED` entries
- `tool_naming_convention_policy` — `archive.apply_rfc3161_timestamp` tool name; `WRITES_ARCHIVE | EXTERNAL_CALL | WRITES_AUDIT` side-effect class
- `archive_bundle_file_manifest` — bundle ZIP structure; `bundle_hash` source field; `.tsr` storage path convention
- `tool_side_effect_taxonomy` — `WRITES_ARCHIVE | EXTERNAL_CALL` class definitions
- `mobile_write_rejection_endpoints` — lock sequence tools listed as mobile-rejected
- Block 15 Phase 04 — `archive.apply_rfc3161_timestamp` implementation; lock sequence Step 4 architecture
- Block 05 Phase 03 — independent audit chain anchoring via RFC 3161
