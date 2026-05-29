# Block 05 — Phase 01: TLS & At-Rest Encryption Baseline

## References

- Block doc: `Docs/blocks/05_security_and_audit.md` (Encryption Strategy — In transit / At rest sections)
- Decisions log: `Docs/decisions_log.md` (EU only; Supabase Postgres + Storage)

## Phase Goal

Establish the foundational network and storage encryption baseline before any application logic touches sensitive data: TLS 1.3 on every endpoint, certificate pinning for outbound calls to known external services, and verification that Supabase's at-rest encryption is correctly configured for both database and storage layers.

## Dependencies

- None at the database level; this is the first thing built in Block 05 and runs in parallel with Block 02 Phase 01.

## Deliverables

- **TLS configuration:**
  - TLS 1.3 minimum on every client-facing endpoint.
  - HSTS header with `max-age=31536000` (1 year), `includeSubDomains`, `preload`.
  - Disable TLS 1.0, 1.1, 1.2 fallback paths.
  - Certificate transparency monitoring for production domains.
- **Certificate pinning** for outbound calls to known external services:
  - Anthropic API (Tier 3 LLM).
  - Google APIs (Gmail, Drive, Document AI).
  - RFC 3161 timestamping service (used by Phase 03).
  - Any other external service introduced post-MVP gets a pinned cert before being called.
  - Pinning uses the public-key fingerprint, not the certificate; rotation is documented in the sub-doc.
- **At-rest encryption verification:**
  - Confirm Supabase Postgres has at-rest encryption enabled (default; verified via configuration check).
  - Confirm Supabase Storage buckets have at-rest encryption enabled (default; verified per bucket).
  - Add a startup self-check that fails fast if any audited service reports at-rest encryption disabled.
- **No-plaintext-fallback assertion:**
  - For each external integration (Anthropic, Google, OCR, RFC 3161): refuse to issue any call without TLS. The HTTP client used for outbound traffic forbids plaintext requests at compile time or runtime.
- **Tests:**
  - Inbound: a connection attempt over TLS 1.2 is rejected.
  - Inbound: HSTS header present.
  - Outbound: a simulated cert mismatch on a pinned service fails the call cleanly.
  - At-rest: the startup self-check fails when one of the buckets is misconfigured (test with a deliberate misconfiguration).

## Definition of Done

- All inbound endpoints enforce TLS 1.3+.
- HSTS is configured and verifiable via `curl -I`.
- Outbound calls to every listed external service succeed only with valid pinned certificates.
- The startup self-check verifies at-rest encryption on every Supabase service the application uses.
- Tests pass for the four scenarios above.

## Sub-doc Hooks (Stage 4)

- **TLS configuration sub-doc** — exact cipher suite list, key exchange algorithms, ALPN protocols.
- **Certificate pinning sub-doc** — per-service pinning configuration, rotation cadence, how to roll a new pin without an outage.
- **At-rest verification sub-doc** — exact configuration checks, alerting if a check fails post-startup.
- **No-plaintext-fallback sub-doc** — how the HTTP client enforces this, exception process if a future service genuinely needs an alternative path.
