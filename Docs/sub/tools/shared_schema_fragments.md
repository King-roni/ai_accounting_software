# Shared Schema Fragments

**Category:** Tools · Shared Utilities
**Cross-ref:** `tool_schema_definition_policy.md`, `audit_event_taxonomy.md`

---

## Overview

This file contains shared Zod type definitions used across tool input and output schemas. Import these types rather than redefining them inline. Consistent usage ensures that schema validation behaviour, error messages, and TypeScript inference are uniform across all tools.

All types in this file are re-exported from the tool schema barrel file at `src/tools/schemas/index.ts`.

---

## Import Convention

```typescript
import {
  AuditTrailEntry,
  PaginationInput,
  PaginationOutput,
  BusinessContext,
  ErrorResponse,
  MoneyAmount,
  DateRange,
} from '@/tools/schemas';
```

Do not copy-paste type definitions from this file into individual tool schema files. Import instead.

---

## AuditTrailEntry

Represents a single audit log entry, used in tool output schemas that include audit trail history in their response.

```typescript
import { z } from 'zod';

export const AuditTrailEntry = z.object({
  event_name: z.string().min(1).max(100),
  occurred_at: z.string().datetime({ offset: true }),
  actor_id: z.string().uuid().nullable(),
  metadata: z.record(z.unknown()).optional(),
});

export type AuditTrailEntry = z.infer<typeof AuditTrailEntry>;
```

**Field notes:**
- `event_name` must match a registered event name in `audit_event_taxonomy.md`. No validation is enforced at the schema layer; validation occurs in the audit emission layer.
- `occurred_at` is an ISO 8601 datetime with timezone offset. UTC (`+00:00`) is the canonical form for stored events.
- `actor_id` is null for system-generated events (engine, scheduler, background jobs).
- `metadata` is a free-form object; individual event types define their required payload keys in `audit_event_taxonomy.md`.

---

## PaginationInput

Standard pagination parameters accepted by all list endpoints.

```typescript
import { z } from 'zod';

export const PaginationInput = z.object({
  limit: z.number().int().min(1).max(500).default(50),
  offset: z.number().int().min(0).default(0).optional(),
  cursor: z.string().max(500).optional(),
});

export type PaginationInput = z.infer<typeof PaginationInput>;
```

**Field notes:**
- `limit` is capped at 500. Requests with `limit > 500` are rejected with `PAGINATION_LIMIT_EXCEEDED`.
- `offset` and `cursor` are mutually exclusive. If both are provided, `cursor` takes precedence and `offset` is ignored.
- Cursor-based pagination is preferred for large datasets (> 10,000 rows) because offset pagination degrades at high offsets on large tables.
- The format of `cursor` is opaque to callers; it is a base64-encoded internal pointer. Callers must treat it as an opaque string.

---

## PaginationOutput

Standard pagination metadata included in all list endpoint responses.

```typescript
import { z } from 'zod';

export const PaginationOutput = z.object({
  total_count: z.number().int().min(0),
  has_more: z.boolean(),
  next_cursor: z.string().max(500).nullable(),
});

export type PaginationOutput = z.infer<typeof PaginationOutput>;
```

**Field notes:**
- `total_count` reflects the total number of rows matching the query filters, not the number of rows in the current page.
- `has_more` is `true` if there are additional rows beyond the current page.
- `next_cursor` is `null` when `has_more` is `false`. When `has_more` is `true`, `next_cursor` contains the cursor value to pass in the next request's `PaginationInput.cursor`.

---

## BusinessContext

Contextual identifiers required by all tool invocations. Every tool input schema must embed `BusinessContext`.

```typescript
import { z } from 'zod';

export const BusinessContext = z.object({
  business_id: z.string().uuid(),
  run_id: z.string().uuid().optional(),
  period_id: z.string().uuid().optional(),
  actor_id: z.string().uuid(),
});

export type BusinessContext = z.infer<typeof BusinessContext>;
```

**Field notes:**
- `business_id` is required on all tool calls. It scopes all database queries and audit events.
- `run_id` is required for tools that operate within a workflow run context (most tools in Blocks 07–11). It is optional only for tools that operate at the business level independent of a run (e.g., registry tools, settings tools).
- `period_id` is optional; required only for tools that need explicit VAT period context (ledger posting, VAT return tools).
- `actor_id` is the user or service account making the call. For engine-invoked tools, this is the engine service account UUID. For human-invoked tools, it is the authenticated user's UUID.

**Embedding in tool input:**

```typescript
const MyToolInput = z.object({
  context: BusinessContext,
  // ... tool-specific fields
});
```

---

## ErrorResponse

Standard error response shape returned by all tools on failure. Tools do not return partial data on error; they return only this schema.

```typescript
import { z } from 'zod';

export const ErrorResponse = z.object({
  code: z.string().min(1).max(100),
  message: z.string().min(1).max(1000),
  details: z.record(z.unknown()).optional(),
  request_id: z.string().uuid(),
});

export type ErrorResponse = z.infer<typeof ErrorResponse>;
```

**Field notes:**
- `code` is a machine-readable error code from `error_code_catalog.md`. Never expose raw database error codes or internal exception names in `code`.
- `message` is a human-readable description safe to display in the UI. It must not contain sensitive data (user passwords, secret values, internal stack traces).
- `details` is an optional object providing additional structured context for the error (e.g., `{ file_name, file_size_bytes, limit_bytes }` for an intake size error).
- `request_id` is a UUID generated per request and logged in `audit_logs` for correlation. Include `request_id` in all error reports to support teams.

---

## MoneyAmount

Represents a monetary value with currency. Used in all schemas that handle financial amounts.

```typescript
import { z } from 'zod';

export const MoneyAmount = z.object({
  amount: z.string().regex(/^-?\d+(\.\d{1,8})?$/, 'Must be a decimal string'),
  currency: z.string().length(3).toUpperCase(),
});

export type MoneyAmount = z.infer<typeof MoneyAmount>;
```

**Field notes:**
- `amount` is a string representation of a decimal value to avoid IEEE 754 floating-point precision loss. The regex allows up to 8 decimal places to accommodate crypto amounts in future; for EUR/USD/GBP accounting use cases, 2 decimal places are standard.
- `currency` is a 3-character ISO 4217 currency code (e.g., `EUR`, `USD`, `GBP`). The schema enforces exactly 3 characters and converts to uppercase. Invalid currency codes are not validated at the schema layer; validation against the set of supported currencies occurs in the tool business logic layer.
- Do not use JavaScript `number` type for monetary amounts anywhere in the tool layer. Always use `MoneyAmount` or a `Decimal` library instance internally.

---

## DateRange

Represents an inclusive or exclusive date range. Used in reporting and filtering schemas.

```typescript
import { z } from 'zod';

export const DateRange = z.object({
  from: z.string().date(),
  to: z.string().date(),
  inclusive: z.boolean().default(true),
});

export type DateRange = z.infer<typeof DateRange>;
```

**Field notes:**
- `from` and `to` are ISO 8601 date strings (`YYYY-MM-DD`), not datetimes. Time components are not supported; use the tool's `as_of_date` or `at` fields for datetime precision where needed.
- `inclusive` defaults to `true`, meaning both `from` and `to` dates are included in the range.
- Callers must ensure `from <= to`. Tools validate this and return `DATE_RANGE_INVALID` if violated.
- Do not use `DateRange` for VAT period references; use `period_id` (UUID reference to `vat_periods` table) instead.

---

## Usage Example

The following shows how to compose these fragments into a tool's input and output schema:

```typescript
import { z } from 'zod';
import {
  BusinessContext,
  PaginationInput,
  PaginationOutput,
  MoneyAmount,
  DateRange,
  ErrorResponse,
} from '@/tools/schemas';

// Input schema for a hypothetical list-transactions tool
const ListTransactionsInput = z.object({
  context: BusinessContext,
  date_range: DateRange,
  amount_min: MoneyAmount.optional(),
  pagination: PaginationInput,
});

// Output schema (success path)
const ListTransactionsOutput = z.object({
  transactions: z.array(
    z.object({
      transaction_id: z.string().uuid(),
      amount: MoneyAmount,
      booking_date: z.string().date(),
      description: z.string().max(500),
    })
  ),
  pagination: PaginationOutput,
});

// Tool implementation uses ErrorResponse on the failure path:
// return { success: false, error: ErrorResponse.parse({ code, message, details, request_id }) };
```

---

## Policy Reference

All tool schema definitions must comply with `tool_schema_definition_policy.md` (line 44 references this file). Key rules from that policy:

- Every tool input schema must include `BusinessContext`.
- No tool may define its own `PaginationInput` or `PaginationOutput` inline.
- Monetary amounts must use `MoneyAmount`; `number` types for currency values are prohibited.
- Error responses must use `ErrorResponse`; ad-hoc error objects are not permitted.

---

## Adding New Shared Types

New shared types must be reviewed and approved by the platform architecture owner before addition to this file. Proposed additions should:
1. Be used by at least 3 tools (otherwise define inline in the specific tool schema).
2. Have stable semantics (types that change frequently create versioning complexity).
3. Not duplicate a type already defined in `@/lib/types` (check before proposing).

Add new types with a PR that includes: the type definition, field notes, at least one usage example, and a reference to the tools that will consume it.
