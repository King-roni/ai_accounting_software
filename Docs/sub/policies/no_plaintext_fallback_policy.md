# No Plaintext Fallback Policy

**Block:** 05 — Security & Audit
**Category:** Policies
**Stage:** 4 sub-doc (Layer 2)

---

## Purpose

Prohibits any code path from writing, transmitting, or logging sensitive field values
in plaintext. This policy is the enforcement contract that backs the encryption
requirements in `encryption_at_rest_policy.md`. It defines the scope, the transport
rule, the storage rule, the logging rule, the code-level enforcement mechanism, and
the failure path when encryption is unavailable.

---

## Scope

This policy applies to all of the following:

**Fields:** Any field classified as PII or sensitive in `redaction_field_map.md`.
Examples include: `email`, `display_name`, `vat_number` (counterparty), `iban`,
`access_token`, `refresh_token`, `password_hash` input before hashing, and any field
tagged `SENSITIVITY_HIGH` or `SENSITIVITY_PII` in the redaction map.

**API transport:** All HTTP requests and responses between clients and the platform
API, and all inter-service HTTP calls (service-to-service, platform-to-Supabase,
platform-to-Vault, platform-to-LLM providers).

**Object Storage writes:** All files written to any Object Storage bucket (Raw Upload
zone, Processing zone, Operational zone, Archive zone, Export temp zone). Bucket-level
server-side encryption is always on; this policy also covers application-layer
encryption for fields extracted and re-stored in structured form.

**Inter-service calls:** gRPC and HTTP calls between internal services. No
service-to-service path transmits a sensitive field value without TLS.

---

## Transport Rule

All API calls must use TLS 1.3 (the canonical floor per `tls_configuration_policy.md` §1). No HTTP plaintext fallback is permitted.

Enforcement is at the load balancer layer:
- A request arriving on port 80 receives a 301 redirect to the HTTPS equivalent.
- If the client follows the redirect but presents a connection that the load balancer
  identifies as already-cleartext (e.g., via a misconfigured proxy), the load balancer
  returns 403 and does not forward the request to the application tier.
- TLS 1.0, 1.1, AND 1.2 are disabled at the TLS termination layer. Connections negotiating
  these versions are dropped.

Cipher suite configuration is owned by `tls_configuration_policy.md` §2. This policy
commits only to the TLS version floor and the no-HTTP-fallback rule.

Inter-service calls use mTLS where the service mesh supports it. In cases where mTLS
is not enforced (e.g., a managed cloud service that does not support client
certificates), the call must still use TLS 1.3 and the certificate is validated
against the service's expected CA; self-signed certificates are not accepted in
production.

---

## Storage Rule

Sensitive fields must be encrypted with AES-256-GCM before any database write. The
encryption helper from `encryption_at_rest_policy.md` is the only approved encryption
path. Inline encryption (constructing AES ciphers directly in application code) is
prohibited.

No code path may write a sensitive field to the database in plaintext. This is
enforced at two levels:

1. **Column-level encryption hooks:** Database columns that store encrypted values
   (e.g., `oauth_tokens.access_token_enc`, `counterparties.vat_number_enc`) are typed
   `BYTEA`. The application schema does not expose a plaintext `TEXT` column for these
   fields. Attempting to insert a non-BYTEA value triggers a Postgres type error before
   the row reaches storage.

2. **Application-layer lint rule** (see "Code Enforcement" below): The ESLint rule
   fires at build time before the code reaches the database.

---

## Logging Rule

Sensitive field values must not appear in application logs at any log level (DEBUG,
INFO, WARN, ERROR). A log entry that would expose a sensitive field value must
substitute the redacted placeholder `[REDACTED]` in place of the value.

The redaction map in `redaction_field_map.md` lists all field names whose values must
be redacted in log output. The `logger` wrapper in the application enforces redaction
automatically for structured log entries that include known-sensitive keys. Callers
that build log messages manually (string interpolation) are caught by the
`no-plaintext-sensitive` ESLint rule.

Structured error objects logged on exception paths must not include a sensitive field
in the `.message`, `.stack`, or `.context` properties. Error-serialization helpers
strip known-sensitive keys before passing to the logger.

Log entries emitted by the audit log writer (`emitAudit()`) are not application logs;
they are written to the append-only audit chain and are not subject to this rule's
`[REDACTED]` substitution requirement. However, the audit payload schema itself never
includes plaintext sensitive values — encrypted field access is logged as an access
event, not by logging the decrypted value.

---

## Code Enforcement

The ESLint rule `no-plaintext-sensitive` is enabled in `.eslintrc` with `error` level.
It operates as follows:

- The rule maintains a set of known sensitive field names drawn from
  `redaction_field_map.md` (imported at lint time as a JSON fixture).
- Any direct assignment of a sensitive field name to a variable or object property
  without calling one of the approved encryption helpers (`encryptField`,
  `encryptToken`) is a lint error.
- Any interpolation of a sensitive field name into a template literal, string
  concatenation, or `console.*` call is a lint error.

**Exception path:** A code line may bypass the lint rule by appending the comment
`// plaintext: justified` on the same line. This exception requires a Jira ticket
reference in the same comment (e.g., `// plaintext: justified SEC-1042`). The CI job
scans for bare `// plaintext: justified` comments with no ticket reference and fails
the build if found. Exception usage is tracked quarterly in the security review.

Exceptions are appropriate only for:
- Test fixtures that explicitly exercise the encryption helper's output (the test
  constructs the plaintext specifically to pass into the helper).
- Migration scripts that read an old unencrypted column and write the encrypted
  replacement (the migration is by definition a one-time path that handles the
  pre-encryption legacy state).

---

## Failure Path

If the encryption helper is unavailable at write time (Vault unreachable, DEK
unavailable, helper throws an unhandled error), the write **must fail**. The error
thrown is `ENCRYPTION_UNAVAILABLE`.

There is no silent fallback to writing the value in plaintext. The caller receives the
`ENCRYPTION_UNAVAILABLE` error and must propagate it. In the context of a workflow
tool, this means the tool fails, triggering the retry and failure policy from Block 03
Phase 08. In the context of a user-initiated write (e.g., saving OAuth tokens), the
API call returns HTTP 503 with a structured error body.

The `ENCRYPTION_UNAVAILABLE` error is treated as a transient infrastructure failure
(retryable), not a data error. The retry policy applies the same backoff as for Vault
connectivity failures.

---

## Runtime Detection and Audit

**`SECURITY_PLAINTEXT_FALLBACK_DETECTED`** — emitted when the gateway bypass detection
layer (`gateway_bypass_detection_policy.md`) detects that a request or response
contains an unencrypted sensitive field value at the transport layer. This is a
defence-in-depth check; it should never fire if the application-layer rules above are
correctly applied. Severity: BLOCKING.

BLOCKING is used because a confirmed plaintext exposure in transit or storage is a
data breach scenario that must halt the affected pipeline immediately and trigger an
incident response.

Payload: `detection_point` (`REQUEST_BODY` | `RESPONSE_BODY` | `LOG_LINE` |
`STORAGE_WRITE`), `field_name`, `business_id` (nullable), `request_id`, `detected_at`.

The event is written to the global audit chain (no `business_id` required) to ensure
it is not silenced by per-business RLS.

---

## Cross-references

- `encryption_at_rest_policy.md` — AES-256-GCM helper, DEK hierarchy, key rotation
- `redaction_field_map.md` — canonical list of PII and sensitive field names
- `gateway_bypass_detection_policy.md` — transport-layer detection that emits
  `SECURITY_PLAINTEXT_FALLBACK_DETECTED`
- `audit_event_naming_convention_policy.md` — naming rationale for the
  `SECURITY_*` domain prefix
- `audit_event_taxonomy.md` — `SECURITY_PLAINTEXT_FALLBACK_DETECTED` entry
- Block 05 Phase 01 — TLS and at-rest encryption baseline (phase doc)
- Block 05 Phase 04 — Vault setup and DEK hierarchy
- Block 05 Phase 05 — pgcrypto field-level encryption
