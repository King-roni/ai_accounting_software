# client_vat_validation_policy

**Category:** Policies · **Owning block:** 13 — IN Workflow + Invoice Generator · **Stage:** 4 sub-doc (Layer 2)

Rules governing VAT number validation for client records. This policy specifies when and how `in_workflow.validate_client_vat` is invoked, how the VIES response is written back to the `clients` table, how validation failures are surfaced, and how validated status drives automatic `vat_treatment` defaults on invoice line items. It is the normative source for the VIES-integration path on the client side; the counterparty-side VIES flow is owned by Block 11.

---

## 1. Scope

This policy applies to `clients` rows where `vat_number IS NOT NULL`. Clients with `vat_number = NULL` are not validated; they remain unverified indefinitely without raising any review issue. When a VAT number is added to an existing client record (UPDATE), the policy applies as if the record were newly created.

---

## 2. Validation is asynchronous — client saved immediately

When a VAT number is provided on a `clients` row (INSERT or UPDATE), the client record is saved immediately with `vat_number_verified_at = NULL`. The write is not gated on a VIES response.

After the client row is written, `in_workflow.validate_client_vat` is enqueued as an asynchronous job. This tool:

1. Looks up or creates a `vies_records` row for the `(vat_number, query_country_code)` pair per `vies_record_schema`.
2. If a cached valid result exists (within the 30-day TTL per Section 4 below), writes `clients.vat_number_verified_at` to the cache entry's `queried_at` timestamp immediately without calling the VIES SOAP endpoint.
3. If no valid cached result exists, invokes the VIES SOAP service (registered as `EXTERNAL_CALL` on `in_workflow.validate_client_vat`).
4. On a successful VIES response, writes `clients.vat_number_verified_at = now()` and creates or refreshes the `vies_records` row.
5. On a failed VIES response (see Section 6), does not update `vat_number_verified_at` and raises a review issue.

The asynchronous execution ensures that invoice creation is never blocked waiting for VIES availability.

---

## 3. Validation result written to clients table

The VIES response result is written back to the `clients` table as follows:

- **Successful validation (VIES confirms VAT number is valid):** `clients.vat_number_verified_at = now()`. The VIES result is also stored in `vies_records` for caching.
- **Invalid VAT number (VIES confirms the number is not registered):** `clients.vat_number_verified_at` remains `NULL`. A review issue is raised (severity `MEDIUM`; see Section 6). The `vies_records` row records the invalid result.
- **VIES service unresolvable (all retry attempts exhausted):** `clients.vat_number_verified_at` remains `NULL`. A review issue is raised (severity `MEDIUM`). No `vies_records` row is created.

`VIES_LOOKUP_COMPLETED` is emitted on a successful VIES call per `audit_event_taxonomy`. `VIES_LOOKUP_FAILED` is emitted when all attempts are exhausted.

---

## 4. VIES result caching — 30-day TTL

VIES results are cached in the `vies_records` table per `vies_record_schema`. The cache TTL is 30 days from the `queried_at` timestamp. A cached result within TTL satisfies the validation check:

- If a `vies_records` row exists for the `(vat_number, query_country_code)` pair with `queried_at >= now() - 30 days` AND `is_valid = true`, the `validate_client_vat` tool writes `clients.vat_number_verified_at` from the cache without calling VIES.
- If the cached result is `is_valid = false`, no re-query is attempted within the TTL; the review issue remains active.
- If the cache entry is expired (older than 30 days), a fresh VIES call is made regardless of the prior result.

This caching policy applies equally to the counterparty-side VIES flow (Block 11) because both flows share the `vies_records` table. A VIES result cached from a Block 11 counterparty lookup satisfies the Block 13 client lookup for the same VAT number, and vice versa.

---

## 5. Unverified VAT number does not block invoice issuance

An invalid or unresolvable VAT number, or a client with `vat_number_verified_at = NULL`, does not block invoice issuance. The `in_workflow.send_invoice` transition (`DRAFT → SENT`) does not check `vat_number_verified_at`. The validation policy surfaces the unverified or invalid status as a review item in Block 14, not as a hard blocker on the invoice lifecycle.

This is a deliberate design decision: VIES service unavailability must not prevent legitimate invoice issuance. The review queue provides the operator visibility into unverified clients without gating their workflow.

---

## 6. Invalid or unresolvable VAT number — review issue

When VIES returns `is_valid = false`, or when all retry attempts for the VIES SOAP call are exhausted without a usable result, a review issue is raised in Block 14 at severity `MEDIUM`. The issue attributes:

- **Issue type:** Client VAT number unverified or invalid (issue type registered in Block 14's issue type registry).
- **Subject:** `client_id` of the affected client record.
- **Severity:** `MEDIUM`.
- **Auto-resolution:** The issue is auto-resolved if `in_workflow.validate_client_vat` is subsequently called (e.g., after a VIES service recovery) and returns a valid result, which updates `vat_number_verified_at`.

A `MEDIUM` severity review issue does not block the `IN_MONTHLY` workflow run from advancing through gates. The income matching gate and approval gate do not check for open `MEDIUM` client-VAT issues. Only `HIGH` and `BLOCKING` severity issues are gating per `in_phase_gate_policy`.

---

## 7. Automatic vat_treatment default for EU clients with valid VIES-confirmed VAT numbers

When `in_workflow.validate_client_vat` completes with a valid VIES confirmation (`is_valid = true`) for a client, the system automatically sets the default `vat_treatment` on new invoice line items issued to that client:

- **EU client (non-Cyprus) with VIES-confirmed VAT number:** default `vat_treatment = INTRAEU_SUPPLY_ZERO`. This reflects the zero-rate treatment for intra-EU B2B supplies where the recipient is VAT-registered in another EU member state (reverse charge applies).
- **Non-EU client:** default `vat_treatment = OUTSIDE_SCOPE`. VAT does not apply to supplies outside the EU.
- **Cyprus client (country_code = 'CY'):** default `vat_treatment` is the standard 19% treatment (`STANDARD_RATED` per `vat_treatment_enum`), regardless of whether the VAT number is verified.

These defaults are applied at invoice line-item creation time as pre-populated values in the invoice UI and in the automated invoice generation path. They may be overridden per-line-item by Owner, Admin, or Bookkeeper.

The automatic default is set only when all of the following are true:
1. A valid VIES result exists for the client (`vat_number_verified_at IS NOT NULL`).
2. The client's `country_code` places them in the EU.
3. The client's `country_code != 'CY'` (Cyprus domestic clients use standard rate).

If the VIES result is invalid or unavailable, the default `vat_treatment` falls back to the per-business default configured in Block 13's IN workflow config.

---

## 8. Re-validation trigger

`in_workflow.validate_client_vat` is re-triggered in the following scenarios:
- The `vat_number` field is updated on an existing client record (UPDATE triggering the async job).
- The cached `vies_records` entry for the client's VAT number expires (30-day TTL elapsed), and a new invoice is being issued to the client (lazy re-validation on invoice generation).
- An operator explicitly requests re-validation via the client record UI (Block 13 client management surface).

Re-validation does not modify `vat_number_verified_at` to a null value during the pending period — the existing value is retained until a new VIES response is received.

---

## 9. Mobile write restriction on client VAT fields

All write operations to `clients.vat_number` and manual VAT validation requests are rejected for sessions where `client_form_factor = MOBILE`. Rejection fires before the permission check and emits `MOBILE_WRITE_REJECTED` per `mobile_write_rejection_endpoints.md`. The read of `vat_number_verified_at` is permitted on mobile.

---

## 10. Audit events

| Event | Severity | Trigger |
| --- | --- | --- |
| `VIES_LOOKUP_COMPLETED` | LOW | Successful VIES SOAP call; `vies_records` row inserted |
| `VIES_LOOKUP_FAILED` | MEDIUM | All VIES retry attempts exhausted without result |
| `CLIENT_UPDATED` | LOW | `vat_number_verified_at` written back to `clients` row |
| `REVIEW_ISSUE_CREATED` | MEDIUM | Review issue raised on invalid/unresolvable VAT number |
| `MOBILE_WRITE_REJECTED` | LOW | Write attempt from mobile client on VAT fields |

---

## 11. Tool registration summary

| Tool | Side-effect class | AI tier | Trigger |
| --- | --- | --- | --- |
| `in_workflow.validate_client_vat` | `WRITES_RUN_STATE`, `EXTERNAL_CALL`, `WRITES_AUDIT` | `NONE` | Async, post-client INSERT/UPDATE |

The `EXTERNAL_CALL` class reflects the VIES SOAP invocation. The tool is registered at engine boot per `tool_naming_convention_policy` and is listed in the `in_workflow` block namespace. The tool is not available on mobile clients; the async enqueue path does not expose a direct mobile surface, but the client record write that triggers the enqueue is itself mobile-rejected per Section 9.

---

## Cross-references

- `client_schema` — `vat_number`, `vat_number_verified_at` columns; `country_code`; unique VAT number constraint; `is_active` semantics
- `vies_record_schema` — `vies_records` table; `is_valid`; `queried_at`; 30-day TTL; `query_country_code`
- `vat_rate_table_reference` — Cyprus VAT rates; standard 19% treatment
- `vat_treatment_enum` — `INTRAEU_SUPPLY_ZERO`, `OUTSIDE_SCOPE`, `STANDARD_RATED`, `REVERSE_CHARGE_EU` values
- `in_phase_gate_policy` — `MEDIUM` severity review issues do not block gates; only `HIGH`/`BLOCKING` are gating
- `invoice_amendment_policy` — per-line `vat_treatment` override by eligible roles
- `invoice_line_item_schema` — `vat_treatment` column on line items; automatic default application
- `audit_event_taxonomy` — `VIES_LOOKUP_COMPLETED`, `VIES_LOOKUP_FAILED` under VIES domain; `CLIENT_UPDATED` under CLIENT domain
- `audit_log_policies` — `VIES` and `CLIENT` domains; past-tense event naming
- `mobile_write_rejection_endpoints.md` — mobile write rejection on client VAT fields
- Block 11 Phase 05 — counterparty-side VIES flow; shared `vies_records` cache
- Block 13 Phase 07 — `in_workflow.validate_client_vat` tool registration; client management surface
- Block 14 — review queue; issue creation and resolution for unverified client VAT
