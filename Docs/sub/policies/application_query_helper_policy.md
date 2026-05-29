# application_query_helper_policy

**Category:** Policies · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 03 — Workflow Engine · **Stage:** 4 sub-doc (Layer 2)

The application-layer wrapper around `@supabase/supabase-js` v2 calls that every API handler and Edge Function uses for RLS-scoped reads and writes. This policy commits to the **API surface** (function shapes), **error shapes** (canonical `ApiError` union with PG-error mapping table), and **Supabase-client integration** (client construction, header propagation, session model).

Companion to `rls_helper_functions.md` (the PG-side helpers — BOOK-189), `principal_context_schema.md` (the per-request authority bundle — BOOK-181), `tool_can_perform_helper.md` (the permission-check helper — BOOK-183), `rls_policy_template.md` (the RLS templates these queries pass through — BOOK-187).

---

## 1. What it is

A thin TypeScript helper module published as `@platform/db-helpers` that wraps Supabase JS client calls with four platform-specific concerns:

1. Authenticated client construction (two distinct client kinds — §2).
2. Automatic principal-context propagation via JWT + headers.
3. Standard error-shape mapping (`ApiError` union — §5).
4. Audit emission on RLS-deny observations (`RLS_DENY_OBSERVED` per `rls_deny_audit_pattern_policy`).

API handlers never call the Supabase client directly. All reads and writes go through these helpers.

---

## 2. Two distinct clients

| Client kind | Constructor | Key used | RLS applies? | Used by |
|---|---|---|---|---|
| User-authenticated | `withUserClient(jwt)` | Anon key + user JWT | **Yes** | Edge Functions handling authenticated user requests |
| Service-internal | `withServiceClient()` | Service-role key | **No** (bypasses RLS) | Background jobs, retention engine, migrations, SECURITY DEFINER bridge calls |

```ts
import { withUserClient, withServiceClient } from '@platform/db-helpers';

// Inside an Edge Function for a user request:
const client = withUserClient(req.jwt);

// Inside a scheduled background job:
const client = withServiceClient();
```

**The two clients are NOT interchangeable.** Helpers that expect a `UserClient` refuse a `ServiceClient` at the type level (branded types: `type UserClient = SupabaseClient & { __brand: 'user' }`; `type ServiceClient = SupabaseClient & { __brand: 'service' }`). Calling `tenantSelect` with a `ServiceClient` is a compile error.

Service-role-key usage is **strictly limited** to:

- Retention engine deletes (the only path that physically deletes rows in operational tables).
- Background reconciliation jobs that need cross-tenant reads (e.g., `sweep_storage_orphans` from B15·P09).
- Migration scripts.
- The audit-write side of `audit.emit_audit` (service role is needed to insert into immutable audit tables).

Any other use is a code-review-blocking violation.

---

## 3. The query wrapper API surface

Three function shapes cover all RLS-scoped database access. All three return a discriminated-union `Result<T>`; **none throws** — exceptions inside helpers are caught and converted to `Result.err`.

```ts
type Result<T> =
  | { ok: true;  data: T }
  | { ok: false; error: ApiError };
```

### 3.1 `tenantSelect<T>`

```ts
async function tenantSelect<T extends keyof Database['public']['Tables']>(
  client: UserClient,
  table: T,
  options: {
    columns?: string;              // default '*'; column-projection string
    filter?: PostgrestFilter<T>;   // chainable filter builder
    limit?: number;                // default 50; max 1000
    offset?: number;
    orderBy?: { column: string; ascending: boolean }[];
    cursor?: string;               // base64 cursor; mutually exclusive with offset
  }
): Promise<Result<Database['public']['Tables'][T]['Row'][]>>;
```

RLS-aware SELECT returning typed rows. The `table` parameter is constrained to known table names from the generated `Database` type; arbitrary string passthrough is rejected.

### 3.2 `tenantInsert<T>`

```ts
async function tenantInsert<T extends keyof Database['public']['Tables']>(
  client: UserClient,
  table: T,
  payload: Database['public']['Tables'][T]['Insert'],
  options: {
    returning?: string;            // default '*'; column-projection on returned row
    permission_surface: PermissionSurface;  // REQUIRED — used for can_perform pre-check
  }
): Promise<Result<Database['public']['Tables'][T]['Row']>>;
```

INSERT returning the newly-inserted row. Performs an `auth.can_perform` pre-check (per BOOK-183 `tool_can_perform_helper`) against the declared `permission_surface` BEFORE the write attempt. The pre-check is defence-in-depth — RLS still enforces at the DB level — but it produces a cleaner `PERMISSION_DENIED` error than a generic RLS-deny.

### 3.3 `tenantRpc<TName, TArgs, TResult>`

```ts
async function tenantRpc<
  TName extends keyof Database['public']['Functions']
>(
  client: UserClient,
  fn_name: TName,
  args: Database['public']['Functions'][TName]['Args']
): Promise<Result<Database['public']['Functions'][TName]['Returns']>>;
```

Typed RPC call to a SECURITY DEFINER PG function. **This is the canonical write path** per project-meta drawer's rule: "All writes blocked from authenticated role; SECURITY DEFINER RPCs only." Direct INSERT/UPDATE through `tenantInsert` is permitted only for tables explicitly designated as authenticated-writable in their RLS policy (a small set — most domain tables go through RPC).

---

## 4. Implicit principal-context propagation

The application code does NOT manually pass `org_id` / `business_id` / `role` to query helpers. Those flow via the JWT-derived principal context per BOOK-181 (`principal_context_schema`):

1. `withUserClient(jwt)` sets the JWT on the Supabase client.
2. Every query call carries the JWT in the `Authorization` header.
3. PostgREST extracts the JWT claims into the `request.jwt.claims` GUC.
4. The RLS helpers (`current_org()`, `current_user_id()`, etc. — per BOOK-189) read from that GUC.
5. The principal context is materialised server-side per BOOK-181 §15 GUC mechanism.

Application code never manually reads or writes principal-context fields. The only manually-passed scoping signal is the `X-Cypbk-Business-Id` header (per §7), which feeds into business+role resolution at principal-context construction time.

---

## 5. The canonical `ApiError` shape

```ts
type ApiError =
  | { kind: 'AUTH_REQUIRED';         http: 401; message: string }
  | { kind: 'PERMISSION_DENIED';     http: 403; surface: PermissionSurface; role_at_check?: user_role | null }
  | { kind: 'STEP_UP_REQUIRED';      http: 403; surface: PermissionSurface }
  | { kind: 'NOT_FOUND';             http: 404; table: string }
  | { kind: 'CONFLICT';              http: 409; constraint: string }
  | { kind: 'VALIDATION_FAILED';     http: 422; field: string; reason: string }
  | { kind: 'MOBILE_WRITE_REJECTED'; http: 403; surface: PermissionSurface }
  | { kind: 'RATE_LIMIT_EXCEEDED';   http: 429; retry_after_ms: number }
  | { kind: 'UNAVAILABLE';           http: 503; reason: 'VAULT' | 'DATABASE' | 'EXTERNAL_API' }
  | { kind: 'INTERNAL';              http: 500; request_id: string };
```

The `kind` is the discriminator. Every `ApiError` carries an `http` field that the API handler uses to set the HTTP response status. The `request_id` on `INTERNAL` errors is the correlation token for log triage; the actual error detail is logged server-side and never returned to the client.

This shape is **stable**: adding a new kind requires a `Docs/decisions_log.md` amendment because clients depend on the discriminated union for error handling.

---

## 6. Error mapping table

Supabase client errors → `ApiError`:

| Source error | Maps to |
|---|---|
| PostgrestError code `42501` (insufficient_privilege from RLS deny) | `PERMISSION_DENIED` |
| PostgrestError code `23505` (unique_violation) | `CONFLICT { constraint: <constraint_name> }` |
| PostgrestError code `23503` (foreign_key_violation) | `CONFLICT { constraint: <constraint_name> }` |
| PostgrestError code `23514` (check_constraint_violation) | `VALIDATION_FAILED { field: <best-effort parsed>, reason: <constraint name> }` |
| PostgrestError code `22P02` (invalid_text_representation, e.g., bad UUID) | `VALIDATION_FAILED { field: '<best-effort>', reason: 'INVALID_INPUT' }` |
| PG raise with `MOBILE_WRITE_REJECTED` (per `mobile_write_rejection_endpoints`) | `MOBILE_WRITE_REJECTED` |
| PG raise with `STEP_UP_REQUIRED` (per `permission_matrix` step-up surfaces) | `STEP_UP_REQUIRED` |
| PG raise with `RATE_LIMIT_EXCEEDED` (per `rate_limit_configuration_policy`) | `RATE_LIMIT_EXCEEDED { retry_after_ms }` |
| PostgrestError HTTP 401 (JWT expired / invalid) | `AUTH_REQUIRED` |
| PostgrestError HTTP 404 (row-not-found via `.single()`) | `NOT_FOUND { table }` |
| Network error / fetch throw | `UNAVAILABLE { reason: 'DATABASE' }` |
| PG raise with `KEY_UNAVAILABLE` (Vault outage per `vault_kek_access_failure`) | `UNAVAILABLE { reason: 'VAULT' }` |
| Any uncategorised error | `INTERNAL { request_id }` |

The mapping is deterministic; helpers do NOT attempt to interpret error messages beyond reading the `code` field and known custom raise codes.

---

## 7. Supabase client construction

```ts
function withUserClient(jwt: string, opts: ClientOptions): UserClient {
  return createClient(SUPABASE_URL, ANON_KEY, {
    auth: {
      persistSession: false,           // mandatory — see §8
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
    db: { schema: 'public' },
    global: {
      headers: {
        Authorization: `Bearer ${jwt}`,
        'X-Cypbk-Business-Id':   opts.business_id   ?? '',
        'X-Client-Form-Factor':  opts.form_factor   ?? 'WEB',
        'X-Cypbk-Request-Id':    opts.request_id,
      },
    },
  }) as UserClient;
}
```

Service client uses `SERVICE_ROLE_KEY` in place of `ANON_KEY` and omits the per-user headers.

---

## 8. Session model: `persistSession: false`

**The platform does NOT use Supabase's built-in client-side session storage.** Sessions are managed server-side in `public.user_sessions` per `session_lifetime_policy.md` (BOOK-167).

Consequences:

- No localStorage / sessionStorage / cookie persistence by the Supabase client.
- The JWT is delivered to the client per request by the platform's auth Edge Function and stored by the application layer using its own session-management strategy.
- `autoRefreshToken: false` because refresh is driven by platform middleware on `session_lifetime_policy.md`'s schedule, not by the Supabase client polling.
- `detectSessionInUrl: false` to prevent the Supabase client from auto-parsing OAuth callback URLs (the platform's auth flow handles that explicitly).

This decoupling matters because the platform's session model (8h absolute / 12h Accountant / 30-min idle / 5-concurrent cap) is not expressible via Supabase's client-side session primitive.

---

## 9. PG advisory check (early-fail)

`tenantSelect` performs an early-fail check before issuing the SELECT:

```sql
SELECT current_org();
```

If the result is NULL → no valid principal context → return `AUTH_REQUIRED` immediately. The check costs one extra round-trip but keeps unauthenticated requests from probing for table-existence signals via error-message inspection.

For high-volume read paths, this check can be skipped via an opt-out flag `{ skipAuthPreCheck: true }` — used only for known-authenticated callers (e.g., already-validated by an upstream middleware). Default behaviour is to perform the check.

---

## 10. Audit emission on RLS-deny observation

RLS is silent by design — a row that's hidden by RLS looks identical to a row that doesn't exist. To make denial observable for security forensics, the wrapper implements the `rls_deny_audit_pattern_policy`:

1. After a SELECT returns zero rows, the wrapper optionally issues a follow-up `COUNT(*)` with `business_id` explicitly filtered.
2. If the count is non-zero AND the user's row count is zero → RLS denied a row the user is asking about → emit `RLS_DENY_OBSERVED` (MEDIUM).
3. The follow-up uses the service client (RLS-bypassing) to perform the COUNT. **This is the one sanctioned use of the service client inside a user-request path** and is gated behind a feature flag (`rls_deny_observe_enabled`) because it doubles the read cost.

The emission is application-layer manufactured because PG itself emits no signal on RLS-deny. The trade-off (cost vs forensic signal) is configurable per-business at Stage 2+.

---

## 11. Pagination + ordering

Standard `tenantSelect` options:

| Option | Default | Notes |
|---|---|---|
| `limit` | `50` | Max `1000`. Larger pages forbidden — encourages cursor pagination. |
| `offset` | `0` | Discouraged for tables >100k rows; use cursor. |
| `orderBy` | `[{ column: 'created_at', ascending: false }]` if absent | Helpers warn at runtime if absent. |
| `cursor` | (none) | Base64-encoded `(value_date, id)` tuple per the canonical ordering. |

Cursor pagination uses the canonical tuple `(value_date DESC, id DESC)` where applicable (transactions, documents, invoices). For tables without a `value_date`, the cursor falls back to `(created_at DESC, id DESC)`.

---

## 12. Transaction support

`withTransaction(client, callback)` wraps a SECURITY DEFINER `transaction.run_in_tx(operations jsonb)` PG function call where the callback constructs the operations payload:

```ts
const result = await withTransaction(client, (tx) => {
  tx.insert('invoices', { /* ... */ });
  tx.rpc('matching.confirm', { /* ... */ });
  tx.update('transactions', { /* ... */ }, { id: txn_id });
});
```

The TypeScript builder produces a single jsonb operations array; the PG function executes all operations in a single transaction. Multi-statement client-driven transactions are NOT supported (Supabase doesn't expose them; the single-RPC pattern is the canonical alternative).

---

## 13. Retry policy

Automatic retry **only** for `UNAVAILABLE` errors. Three attempts at backoff `100ms / 500ms / 2000ms`.

NO retry for:

- `PERMISSION_DENIED` / `STEP_UP_REQUIRED` (deterministic deny — retrying produces the same error).
- `CONFLICT` (deterministic; resolution requires app logic change).
- `VALIDATION_FAILED` / `MOBILE_WRITE_REJECTED` (deterministic).
- `RATE_LIMIT_EXCEEDED` (client should honour `retry_after_ms`; helpers don't auto-retry past the rate-limit window).

Idempotency for write paths: callers may pass `{ idempotency_key: uuid }`; the wrapper threads it through to the underlying PG advisory-lock pattern (cross-references `bulk_preview_tokens` pattern from B14).

---

## 14. TypeScript types

Types generated from PG schema via:

```bash
supabase gen types typescript --linked > types/database.ts
```

Re-generated after every migration; checked into source control. The query helpers import from `Database['public']['Tables'][T]['Row']` etc. to enforce return-shape correctness at compile time.

**Hand-written type assertions are forbidden in application code.** Any TypeScript file containing `as ` followed by a database row type literal fails CI lint. Type-safety derives strictly from the generated types.

---

## 15. Logging

Each helper call emits a structured log record at INFO level:

```json
{
  "level": "info",
  "helper": "tenantSelect" | "tenantInsert" | "tenantRpc" | "withTransaction",
  "target": "<table_or_fn_name>",
  "request_id": "<uuid>",
  "business_id": "<uuid | null>",
  "latency_ms": 42,
  "result_ok": true,
  "error_kind": null
}
```

**NO row content** in logs. The `business_id` is included for cardinality but no PII surface. Logging is application-layer infrastructure — orthogonal to the audit chain (which captures business-meaningful events, not query telemetry).

---

## 16. Mobile-write rejection wiring

When `X-Client-Form-Factor: MOBILE` header is present AND the operation is `tenantInsert` / `tenantRpc` against a `mobile_write_rejection_endpoints` surface, the helper rejects with `MOBILE_WRITE_REJECTED` **BEFORE** the network round-trip.

Defense-in-depth: PG-side `_reject_mobile_write` trigger (per project-meta drawer) still fires server-side. The application-layer reject saves the round-trip and produces a more specific error than the generic `PERMISSION_DENIED` that would otherwise mask the mobile-rejection reason.

Per project-meta drawer's note: "Mobile-write rejection (B16·P12) is UX guard NOT security event — NO audit emit." Both layers respect that — no `MOBILE_WRITE_REJECTED` audit is emitted on either the app side or PG side.

---

## 17. Cross-references

- `rls_helper_functions.md` (BOOK-189) — PG-side helpers consumed via JWT-loaded principal context
- `principal_context_schema.md` (BOOK-181) — per-request authority bundle the helpers depend on
- `tool_can_perform_helper.md` (BOOK-183) — application-layer permission check used in `tenantInsert` pre-check (subject to BOOK-183 Stage-6 drift)
- `rls_policy_template.md` (BOOK-187) — RLS policies the helpers operate against
- `rls_deny_audit_pattern_policy` — `RLS_DENY_OBSERVED` emission pattern (§10)
- `mobile_write_rejection_endpoints.md` — mobile-write surface enumeration
- `session_lifetime_policy.md` (BOOK-167) — server-side session model (the `persistSession: false` rationale)
- `rate_limit_configuration_policy.md` (BOOK-169) — rate-limit error mapping
- `currency_comparison_reference_policy.md` (BOOK-178) — response-shape EUR normalisation
- `permission_matrix.md` (BOOK-179) — `PermissionSurface` enum
- `data_layer_conventions_policy.md` — integer minor units, no floats
- `audit_event_taxonomy.md` — `RLS_DENY_OBSERVED`, `AUTH_PERMISSION_DENIED`
- Block 02 Phase 05 — owning phase (RLS policies)
- Block 03 — SECURITY DEFINER RPC pattern (the canonical write path that `tenantRpc` wraps)
