# ECB Rate Freshness Policy

**Scope:** All FX conversion operations performed within the Cyprus bookkeeping SaaS platform.
**Owning team:** Platform / Ledger Block (Block 11)
**Last reviewed:** 2026-05-17
**Cross-ref:** `tool_fx_convert.md`, `audit_event_taxonomy.md`, `error_code_catalog.md`

---

## Overview

The European Central Bank publishes daily reference exchange rates at approximately 16:00 CET. All FX conversions on this platform must use ECB reference rates cached in the `ecb_rate_cache` table. This policy defines the freshness thresholds, fetch schedule, fallback behaviour, audit obligations, and override procedures that govern ECB rate usage.

---

## Rate Freshness Thresholds

| Threshold | Age | Behaviour |
|---|---|---|
| Fresh | < 24 hours | Rate accepted without warning |
| Stale warning | ≥ 24 hours and < 48 hours | Conversion proceeds; `ECB_RATE_STALE` audit event emitted at MEDIUM severity |
| Blocking | ≥ 48 hours | FX conversion is blocked; `FX_RATE_STALE` error returned to caller |

Age is calculated from `ecb_rate_cache.published_at`, not from the cache insertion time. If the ECB publication timestamp is unavailable, the fetch timestamp is used as a conservative substitute.

---

## Daily Fetch Schedule

The ECB publishes reference rates at approximately 16:00 CET on each TARGET2 business day. The platform fetch job runs at **16:30 CET** Monday through Friday, allowing 30 minutes for ECB publication propagation.

The fetch job:
1. Requests `https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml`.
2. Parses the XML envelope and extracts all currency/rate pairs.
3. Upserts rows into `ecb_rate_cache` keyed on `(currency_code, published_date)`.
4. Emits `ECB_RATE_FETCHED` (LOW) on success with payload: `currency_count`, `published_date`, `fetched_at`.
5. On failure, emits `ECB_RATE_FETCH_FAILED` (HIGH) and initiates the fallback procedure described below.

The fetch job is idempotent — re-running it for the same `published_date` performs an upsert and does not create duplicate rows.

---

## Fallback Procedure

If the fetch job fails (network error, ECB unavailability, XML parse failure):

1. The system continues to use the most recent successfully cached rate.
2. If the cached rate is less than 24 hours old at the time of the failed fetch, no user-visible degradation occurs.
3. If the cached rate is between 24 and 48 hours old, `ECB_RATE_STALE` (MEDIUM) is emitted on each FX conversion that uses the stale rate.
4. If the cached rate reaches 48 hours old, FX conversions are blocked and callers receive `FX_RATE_STALE` until either a successful fetch completes or an admin override is applied (see Admin Override section).

The fetch job retries up to 3 times with exponential backoff (1 min, 5 min, 15 min) before emitting `ECB_RATE_FETCH_FAILED`.

---

## Bank Holiday Grace Period

The ECB does not publish rates on TARGET2 bank holidays or weekends. The following rules apply:

- On weekends (Saturday and Sunday): the Friday rate remains valid and is not considered stale until 48 hours after the **next TARGET2 business day's** expected publication time.
- On TARGET2 bank holidays (Good Friday, Easter Monday, 1 May, 25 December, 26 December): the same extended validity applies — the previous business day's rate is valid until 48 hours after the next expected publication.
- The `ecb_rate_cache` table includes a `is_holiday_carry` boolean column set to `true` for rates that are being carried forward under this grace period.
- `ECB_RATE_STALE` is suppressed during the grace period (no false-positive MEDIUM events on weekends and holidays).

The platform maintains a `target2_holiday_calendar` table populated annually from the ECB's published TARGET2 holiday schedule.

---

## Audit Events

| Event | Severity | Trigger | Key Payload Fields |
|---|---|---|---|
| `ECB_RATE_FETCHED` | LOW | Successful fetch and cache upsert | `currency_count`, `published_date`, `fetched_at` |
| `ECB_RATE_STALE` | MEDIUM | FX conversion uses a rate ≥ 24 hours old | `currency_code`, `rate_age_hours`, `published_date`, `run_id`, `business_id` |
| `ECB_RATE_FETCH_FAILED` | HIGH | All fetch retries exhausted | `error_type`, `last_error_message`, `retry_count`, `failed_at` |
| `ECB_RATE_OVERRIDE_APPLIED` | HIGH | Admin force-accepts a stale rate | `currency_code`, `rate_age_hours`, `override_by_user_id`, `approval_gate_id`, `business_id` |

All events are routed to the `audit_logs` table under the `ECB` domain prefix. See `audit_event_taxonomy.md` for full payload schemas.

---

## Admin Override

An authorised platform administrator may force-accept a stale rate (age ≥ 48 hours) when ECB publication is delayed beyond normal parameters (e.g., extended ECB system outage).

Override requirements:

1. **Approval gate:** The override request must pass a `BLOCKING`-level approval gate before taking effect. At least one OWNER-role user must explicitly approve via the admin console or the `engine.approval_gate.resolve` API endpoint.
2. **Scope:** Overrides are scoped to a specific `currency_code` and expire after 24 hours or at the next successful ECB fetch, whichever comes first.
3. **Audit:** `ECB_RATE_OVERRIDE_APPLIED` (HIGH) is emitted immediately on override activation, containing the approving user ID and the approval gate ID for traceability.
4. **Limitation:** Override does not suppress the `ECB_RATE_STALE` (MEDIUM) event — conversions performed under an override still emit the stale event so that the audit trail records the degraded data quality.

Override activation path: `admin.ecb_rate.force_accept_stale` (requires `PLATFORM_ADMIN` role).

---

## Integration with tool_fx_convert.md

The `ledger.fx_convert` tool performs a `rate_check` step as the first action of every FX conversion:

1. Query `ecb_rate_cache` for the most recent rate for the requested `currency_code`.
2. Compute `rate_age_hours = (now() - published_at) / 3600`.
3. If `rate_age_hours >= 48` and no active admin override exists → return `FX_RATE_STALE` error (HTTP 422).
4. If `rate_age_hours >= 24` → proceed but emit `ECB_RATE_STALE` (MEDIUM) before returning the rate.
5. If fresh → proceed without additional events.

The `rate_check` step result is included in the `ledger.fx_convert` response as `rate_freshness_status` (`FRESH` | `STALE_WARNING` | `STALE_BLOCKED`).

---

## Monitoring and Alerting

| Signal | Threshold | Action |
|---|---|---|
| `ECB_RATE_FETCH_FAILED` emitted | Any occurrence | Page on-call SRE; begin manual rate fallback assessment |
| `ECB_RATE_STALE` emitted more than 50 times in 1 hour | > 50 occurrences/hour | Alert platform team; indicates widespread FX activity on stale data |
| `ecb_rate_cache` most recent `published_date` | > 2 business days old | Critical alert; escalate to CTO |
| Fetch job duration | > 5 minutes | Warning alert; ECB endpoint may be slow |

Alerting is configured in the platform observability stack. The `ECB_RATE_FETCH_FAILED` alert has a zero-tolerance threshold — one failure triggers a page, no minimum count required.

---

## Related Documents

- `tool_fx_convert.md` — implementation of the `rate_check` step
- `audit_event_taxonomy.md` — full ECB domain event definitions
- `error_code_catalog.md` line 79 — `FX_RATE_STALE` error code definition
- `ledger_entry_schema.md` — `fx_rate`, `fx_rate_date`, `ecb_cache_record_id` columns

---

## Change Log

| Version | Date | Author | Summary |
|---|---|---|---|
| 1.0 | 2026-05-17 | Platform team | Initial policy definition |
| 1.1 | 2026-05-17 | Platform team | Added bank holiday grace period, admin override procedure |

---

## Compliance Notes

The ECB rate freshness policy supports accurate financial reporting obligations under Cyprus company law and IFRS requirements for entities reporting in EUR. Using stale FX rates can result in material misstatement of non-EUR transactions. The 48-hour hard block is set conservatively to ensure no more than one business day of rate staleness can affect finalized ledger entries.

Ledger entries that were posted using a stale rate (even under admin override) are flagged with `ecb_rate_cache.is_stale_override = true` in the linked cache record, providing a permanent audit marker for compliance review.
