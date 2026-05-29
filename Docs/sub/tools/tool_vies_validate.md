# Tool: ledger.validate_vies

**Block:** Ledger / Compliance
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

`ledger.validate_vies` validates a European Union VAT number against the EU VIES (VAT Information Exchange System) SOAP API before it is recorded as a counterparty on an intra-EU supply transaction. The tool confirms that the VAT number is currently active, retrieves the registered trader name and address, and caches the result to reduce API calls and stay within VIES per-IP rate limits.

This tool is called during the `out_workflow` VIES phase and during manual invoice creation when a new EU counterparty VAT number is entered.

## Tool Identity

| Property | Value |
|---|---|
| Tool name | `ledger.validate_vies` |
| Namespace | `ledger` |
| Action | `validate_vies` |
| Side effects | WRITES_AUDIT |
| Step-up required | No |
| Mobile | Yes — see Mobile section |

## Inputs

| Field | Type | Required | Description |
|---|---|---|---|
| `vat_number` | TEXT | Yes | Full VAT number including country prefix (e.g. `DE123456789`, `FR12345678901`). Alphanumeric, 2–15 chars after country prefix. |
| `country_code` | CHAR(2) | Yes | ISO 3166-1 alpha-2 country code of the counterparty (e.g. `DE`, `FR`, `NL`). Must be an EU member state code. |
| `business_id` | UUID | Yes | The business requesting validation. Used for audit scoping and rate-limit bucketing. |
| `run_id` | UUID | No | If called within a workflow run, pass the `run_id` for audit event correlation. |
| `force_refresh` | BOOLEAN | No | Default `false`. If `true`, bypasses the 24-hour cache and calls the VIES API directly. Reserved for manual re-validation by accountants. |

### Input Validation

Before calling the VIES API, the tool performs local validation:
1. `country_code` must match the 2-letter prefix in `vat_number`.
2. `country_code` must be an EU member state (validated against internal enum; does not include Cyprus's own country code `CY` for domestic VAT — VIES is for intra-EU counterparties only).
3. `vat_number` must match the format for the given member state (format rules encoded per EU VIES spec; see `vat_validation_cache_schema.md` for format regex per country).

Format validation failures return a `VALIDATION_ERROR` response immediately without calling the VIES API.

## Outputs

```json
{
  "validation_result": {
    "valid": true,
    "vat_number": "DE123456789",
    "country_code": "DE",
    "trader_name": "Example GmbH",
    "trader_address": "Musterstraße 1, 10115 Berlin",
    "request_date": "2026-05-17",
    "consultation_number": "DE/2026/12345678",
    "cache_hit": false,
    "cached_at": null,
    "cache_expires_at": "2026-05-18T14:30:00Z"
  }
}
```

| Field | Description |
|---|---|
| `valid` | `true` if the VIES API confirms the VAT number is active. `false` if the number is inactive, unknown, or deregistered. |
| `trader_name` | Registered business name as returned by VIES. May be null if the member state does not share this information. |
| `trader_address` | Registered address as returned by VIES. May be null. |
| `request_date` | Date of the VIES API query (or cache date if `cache_hit = true`). |
| `consultation_number` | Unique reference assigned by the VIES system for audit trail purposes. |
| `cache_hit` | Whether the response was served from cache or a live API call. |
| `cache_expires_at` | When the cached response will expire (24 hours from `cached_at`). |

## Behaviour

### Cache Lookup

On every call (unless `force_refresh = true`), the tool first queries `vat_validation_cache_schema.md`:

```sql
SELECT * FROM vat_validation_cache
WHERE vat_number = :vat_number
  AND country_code = :country_code
  AND cached_at > now() - INTERVAL '24 hours'
ORDER BY cached_at DESC
LIMIT 1;
```

If a valid cache entry exists, the tool returns it immediately with `cache_hit = true`. No VIES API call is made.

### VIES API Call

If no cache entry exists (or `force_refresh = true`), the tool calls the EU VIES SOAP API:

- Endpoint: `https://ec.europa.eu/taxation_customs/vies/services/checkVatService`
- Operation: `checkVat`
- Request: `<countryCode>`, `<vatNumber>` (without country prefix)

The SOAP response contains `<valid>`, `<name>`, `<address>`, `<requestDate>`, `<consultationNumber>`.

The response is stored in `vat_validation_cache` regardless of whether `valid` is true or false. Negative results (invalid VAT numbers) are also cached to prevent repeated API calls for the same invalid number.

### Retry Policy

| Attempt | Delay |
|---|---|
| 1 | Immediate |
| 2 | 2 seconds |
| 3 | 8 seconds |

After 3 failed attempts (network error, SOAP fault, HTTP 5xx), the tool returns a `VIES_API_UNAVAILABLE` error. The calling workflow places the affected transaction in REVIEW_HOLD and creates a review issue with severity MEDIUM. Validation is not blocking — a failed validation does not prevent the transaction from being recorded, but the counterparty VAT number is flagged as unverified.

### Invalid VAT Number Handling

If `valid = false` in the VIES response:
- The tool returns `valid: false` to the caller.
- A review issue is created with severity MEDIUM (not BLOCKING).
- The transaction or invoice is classified as `WEAK_POSSIBLE` match level until the VAT number is corrected or explicitly accepted by an accountant.
- The transaction is NOT blocked from advancing, but the VIES submission for this counterparty will be flagged for review before filing.

Invalid VAT number responses do not prevent invoice creation or ledger posting. They surface as review queue issues for accountant attention.

### Rate Limiting

The VIES API is subject to per-IP rate limits enforced by the European Commission's servers. Observed limit: approximately 100 requests per minute per IP in normal conditions. Limits are not published officially and may vary by member state queried.

To stay within limits:

1. All validation calls from the platform are routed through a shared rate-limited job queue (Redis-backed, token bucket algorithm, 80 requests/minute ceiling to leave headroom).
2. Batch validation (e.g. validating all counterparties in a new bank statement upload) is queued and processed asynchronously rather than synchronously.
3. Cache hit rate is monitored; if it falls below 60% over a 1-hour window, an alert is raised to investigate whether the 24-hour TTL should be extended.
4. `force_refresh` calls bypass the queue and count against the rate limit directly. They must only be used when the accountant explicitly requests re-validation.

## Audit Events

| Event | Severity | Description |
|---|---|---|
| `VIES_VALIDATION_COMPLETED` | LOW | Emitted when validation returns a result (cache hit or live API). Payload: `vat_number`, `country_code`, `valid`, `cache_hit`, `consultation_number`. |
| `VIES_VALIDATION_FAILED` | MEDIUM | Emitted when the VIES API call fails after all retries. Payload: `vat_number`, `country_code`, `error_type`, `attempts`. |

Both events are emitted via `emit_audit_api.md` and stored in `audit_log_schema.md`. `business_id` and optionally `run_id` are included in every event payload for tenant correlation.

## Mobile Section

`ledger.validate_vies` is invoked from mobile clients during invoice creation when a user manually enters a new EU counterparty VAT number.

**Mobile constraints:**
- Synchronous validation (waiting for VIES API) is not permitted on the mobile invoice creation form. The tool is always called asynchronously on mobile.
- The invoice creation form accepts the VAT number input and saves the invoice in a `PENDING_VAT_VALIDATION` state. A spinner is shown while validation runs in the background.
- On validation success (`valid = true`), the invoice status advances and the trader name is pre-filled in the counterparty name field if it was blank.
- On validation failure or `valid = false`, a banner is displayed: "We could not confirm this VAT number. Your accountant will review it before filing."
- `force_refresh` is not available on mobile; it is restricted to the web admin interface.
- Rate-limited queue behaviour is identical to web — mobile calls enter the same shared queue.

## Related Documents

- `vat_validation_cache_schema.md` — DDL for the validation cache table
- `vies_submission_schema.md` — VIES filing tables that consume validated VAT numbers
- `client_vat_validation_policy.md` — policy for when validation is required vs. optional
- `vies_submission_failure_runbook.md` — handling rejected submissions linked to invalid VAT numbers
- `tool_ledger_post.md` — downstream tool that posts validated transactions to the ledger
- `tool_review_queue_create_issue.md` — tool called when invalid VAT triggers a review issue
- `emit_audit_api.md` — audit event emission
