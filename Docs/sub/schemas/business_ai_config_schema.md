# Schema: business_ai_config

**Category:** Schemas · **Owning block:** 06 — AI Layer · **Stage:** 4 sub-doc (Layer 2)

`business_ai_config` stores per-business AI cost and tier configuration. Every AI invocation dispatched through `ai.invoke` reads this table to determine the active cost ceiling, current month spend, and any tier override. The table is single-row-per-business and is created automatically when a `business_entities` row is inserted.

---

## Purpose

AI invocations carry real per-token costs. Without a ceiling, a single misconfigured run could exhaust significant budget. `business_ai_config` gives platform operators and business owners a hard stop at a configurable monthly cost threshold, with a graceful degradation path (tier 3 → tier 1 fallback) rather than hard rejection of the entire invocation.

The table is part of the Operational data zone and is subject to the 7-year post-deactivation retention policy.

---

## Table DDL

```sql
CREATE TABLE business_ai_config (
  business_id               uuid          NOT NULL
    REFERENCES business_entities(id)
    ON DELETE RESTRICT,

  monthly_cost_ceiling_usd  numeric(10,2) NOT NULL DEFAULT 50.00,

  tier_override             text          NULL
    CHECK (tier_override IN ('TIER_1', 'TIER_2', 'TIER_3')),

  spend_current_month_usd   numeric(10,2) NOT NULL DEFAULT 0.00,

  spend_reset_at            timestamptz   NOT NULL
    DEFAULT date_trunc('month', now()) + interval '1 month',

  created_at                timestamptz   NOT NULL DEFAULT now(),
  updated_at                timestamptz   NOT NULL DEFAULT now(),

  CONSTRAINT business_ai_config_pkey PRIMARY KEY (business_id),
  CONSTRAINT business_ai_config_spend_non_negative
    CHECK (spend_current_month_usd >= 0),
  CONSTRAINT business_ai_config_ceiling_positive
    CHECK (monthly_cost_ceiling_usd > 0)
);
```

Primary key on `business_id` directly — no separate `id` column — because this is a 1:1 extension of `business_entities`. The FK is `ON DELETE RESTRICT` because deleting an AI config without deactivating the business first is a data consistency error.

`business_id` uses UUID v7 per `data_layer_conventions_policy` (FK inherits the type of the referenced PK on `business_entities`).

---

## Column reference

### `business_id`

UUID v7. Primary key and foreign key to `business_entities.id`. The row is created by an AFTER INSERT trigger on `business_entities`; application code must not insert directly.

### `monthly_cost_ceiling_usd`

`numeric(10,2)`. Maximum USD spend allowed for AI invocations in the current calendar month. Default is 50.00. The platform admin may adjust this per business; a business owner cannot modify it from the product UI (admin-only setting via the `admin_settings` surface — see `auth.can_perform`).

Stored in USD. The tier rate table in `ai_gateway_schema` is also denominated in USD. Conversion to EUR for display purposes is the responsibility of the reporting layer.

### `tier_override`

`text`, nullable. When non-null, overrides automatic tier selection for every invocation for this business. Valid values: `TIER_1`, `TIER_2`, `TIER_3`. When null, tier selection is automatic per `ai_tier_escalation_policy`.

A `TIER_3` override on a business that has hit its cost ceiling is superseded by the cost-ceiling downgrade; see Cost Ceiling Enforcement below.

### `spend_current_month_usd`

`numeric(10,2)`. Running total of AI spend for the current calendar month. Incremented by the `fn_increment_ai_spend` trigger after each completed invocation. Reset to `0.00` by the monthly reset job on the 1st of each month at 00:00 UTC.

This column is updated by trigger only. Application code and tools must not write it directly. The constraint `spend_current_month_usd >= 0` prevents underflow from concurrent decrements.

### `spend_reset_at`

`timestamptz`. The timestamp when `spend_current_month_usd` will next be reset to `0.00`. Always the first instant of the next calendar month in UTC. Updated by the same reset job that zeroes the spend.

This column is informational — the reset job uses it to select rows due for reset, not as the authoritative clock source.

### `created_at` / `updated_at`

Standard operational timestamps. `updated_at` is maintained by an AFTER UPDATE trigger.

---

## Spend tracking

### Increment trigger

`fn_increment_ai_spend` fires AFTER INSERT on `ai_invocation_records` when the new row has `status = 'SUCCESS'`. It computes cost as:

```sql
cost_usd := NEW.total_tokens * tier_rate.cost_per_token_usd;
```

where `tier_rate` is looked up from `ai_tier_rates` by `NEW.ai_tier`. The increment is:

```sql
UPDATE business_ai_config
SET
  spend_current_month_usd = spend_current_month_usd + cost_usd,
  updated_at = now()
WHERE business_id = NEW.business_id;
```

The trigger runs in the same transaction as the `ai_invocation_records` insert to ensure spend and invocation record are consistent. If the increment causes `spend_current_month_usd >= monthly_cost_ceiling_usd`, the trigger also emits `AI_COST_CEILING_REACHED` (see below). The emission is out-of-band via `emit_audit_api` per the short-transaction pattern in `audit_log_policies`.

### Monthly reset job

A scheduled job (`job_ai_spend_reset`) runs at 00:00 UTC on the 1st of each calendar month. It executes:

```sql
UPDATE business_ai_config
SET
  spend_current_month_usd = 0.00,
  spend_reset_at          = date_trunc('month', now()) + interval '1 month',
  updated_at              = now()
WHERE spend_reset_at <= now();
```

The job processes all rows in a single statement. There is no per-business job scheduling — the condition `spend_reset_at <= now()` handles any row that was missed by a previous run (e.g., due to a job outage).

---

## Cost ceiling enforcement

When `spend_current_month_usd >= monthly_cost_ceiling_usd`:

1. Tier 3 invocation requests are downgraded to tier 1. The caller (always `ai.invoke`) checks the ceiling before dispatching and substitutes `TIER_1` for the effective tier.
2. The original `tier_hint` or `tier_override` value is logged in the `ai_invocation_records` row as `requested_tier`; the actual dispatched tier is logged as `ai_tier`.
3. `AI_COST_CEILING_REACHED` is emitted once per crossing event, not on every subsequent invocation. The deduplication key is `(business_id, month_year)` — the event fires at most once per business per month.

The fallback to tier 1 is silent from the product UI. The business owner does not receive a real-time notification that tier 3 has been downgraded; the audit log and admin dashboard reflect the crossing. A platform admin can raise the ceiling or reset the spend for exceptional cases.

### Audit event: `AI_COST_CEILING_REACHED`

**Severity:** HIGH

**Payload:**

| Field | Type | Description |
| --- | --- | --- |
| `business_id` | uuid | The business that crossed the ceiling |
| `ceiling_usd` | text | The `monthly_cost_ceiling_usd` value at crossing time (decimal string) |
| `spend_usd` | text | The `spend_current_month_usd` value after the triggering increment (decimal string) |
| `month_year` | text | Calendar month, format `YYYY-MM` |
| `triggering_invocation_id` | uuid | The `ai_invocation_records.id` of the invocation that caused the crossing |

Currency amounts in audit payloads are decimal strings per `data_layer_conventions_policy` currency special case.

---

## Tier override semantics

| `tier_override` value | Effect |
| --- | --- |
| `NULL` (default) | Tier selection is automatic. `ai_tier_escalation_policy` governs escalation. |
| `TIER_1` | Every invocation uses tier 1 regardless of confidence or escalation signals. Cost ceiling is irrelevant (tier 1 is already the cheapest). |
| `TIER_2` | Every invocation uses tier 2. Tier 3 is not reachable. Cost ceiling downgrade still applies (tier 2 → tier 1). |
| `TIER_3` | Every invocation attempts tier 3. Cost ceiling downgrade takes precedence and may substitute tier 1. |

`tier_override` is set by the platform admin only. A business owner sees their current tier assignment in the admin dashboard but cannot change it. Changes are recorded via `BUSINESS_UPDATED` (Block 02) with the changed field included in the payload.

---

## RLS

`business_ai_config` is a multi-tenant table and carries RLS. The active policy:

```sql
CREATE POLICY rls_business_ai_config_tenant_isolation
  ON business_ai_config
  USING (business_id = current_setting('app.current_business_id', true)::uuid);
```

Only the `admin_settings` surface grants WRITE access. Owner and Admin roles can read this row; Bookkeeper and below cannot read it. Platform admin role bypasses RLS.

---

## Cross-references

- `ai_gateway_schema.md` — `ai_invocation_records` table and `ai_tier_rates` table
- `tool_gateway_invoke_ai.md` — the `ai.invoke` tool that reads and triggers updates on this table
- `ai_tier_escalation_policy.md` — governs automatic tier selection when `tier_override` is null
- `data_layer_conventions_policy.md` — numeric/currency serialization rules
- `audit_event_taxonomy.md` — canonical entry for `AI_COST_CEILING_REACHED`
- Block 06 AI Layer — AI gateway phase docs
