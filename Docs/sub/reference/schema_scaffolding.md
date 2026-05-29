# Schema Scaffolding Reference

**Category:** Reference · **Owning block:** 04 — Data Architecture · **Stage:** 4 sub-doc (Layer 2)

The canonical scaffolding rules every new table DDL must follow. Every schema author and migration
writer binds to this document. CI verifies these rules after every migration run using a structural
analysis of the applied DDL. Deviations are build-blocking.

---

## Section 1 — Standard column set

Every table in the system must include the following columns with exactly this DDL:

```sql
id          uuid        NOT NULL DEFAULT gen_uuid_v7() PRIMARY KEY,
created_at  timestamptz NOT NULL DEFAULT now(),
updated_at  timestamptz NOT NULL DEFAULT now()
```

No exceptions. Tables that do not require a surrogate key (pure junction tables) must still carry
`id` as the primary key — composite PKs are not used in this system. Composite unique constraints
are permitted alongside the `id` PK.

The `created_at` column is write-once: application code never updates it. The `updated_at` column
is managed exclusively by the trigger described in Section 4.

---

## Section 2 — Multi-tenant tables

Any table that stores business-scoped data must additionally include:

```sql
business_id  uuid  NOT NULL REFERENCES business_entities(id)
```

This column must be declared immediately after `id` in the column list. The reference target is
always `business_entities(id)` — never an alias or a schema-qualified variant.

The foreign key constraint must use `ON DELETE RESTRICT`. Cascading deletes on business-scoped
tables are prohibited; the retention engine handles record lifecycle explicitly.

Every multi-tenant table must have a corresponding `tenant_isolation` RLS policy per
`row_level_security_policies.md`.

---

## Section 3 — Soft-delete tables

Tables that support soft-delete must include:

```sql
deleted_at  timestamptz  NULL
```

A `deleted_at IS NULL` partial index is required for all queries that filter out deleted rows.
This index must be declared in the schema migration file.

Boolean `is_deleted` columns are prohibited. The `deleted_at` timestamp records when deletion
occurred, which is necessary for the retention engine, GDPR export, and forensic audit queries.
A boolean discards this information.

The `soft_delete_vs_status_policy.md` governs when soft-delete is appropriate versus a `status`
enum column.

---

## Section 4 — updated_at maintenance

The `updated_at` column is maintained exclusively via a Postgres trigger using the `moddatetime`
extension:

```sql
CREATE TRIGGER set_updated_at
BEFORE UPDATE ON <table>
FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);
```

Application-layer `updated_at` writes are prohibited. This includes Supabase client SDK writes
that set `updated_at` explicitly in the update payload. The trigger fires after any UPDATE on
any column, including UPDATE calls that do not change any data values.

The `moddatetime` extension must be enabled in the migration that first uses it. It is enabled
once at the schema level; subsequent tables reference the same function.

---

## Section 5 — Index requirements

The following indexes are mandatory. The migration file must declare them; missing indexes fail
the CI structural check.

| Condition | Required index |
| --- | --- |
| Every foreign key column | `CREATE INDEX ON <table>(<fk_column>)` |
| Every `business_id` column | `CREATE INDEX ON <table>(business_id)` |
| `deleted_at` on soft-delete tables | `CREATE INDEX ON <table>(deleted_at) WHERE deleted_at IS NULL` |

Composite indexes for common query patterns must be declared in the schema sub-doc for the table,
in a dedicated "Index strategy" section. Composite indexes are not auto-required by CI; they are
the schema author's responsibility to declare and justify.

The `transaction_indexing_strategy.md` policy provides additional guidance on index selection for
high-volume tables.

---

## Section 6 — Enum columns

Enum-like columns must use a PostgreSQL `CREATE TYPE` declaration:

```sql
CREATE TYPE run_status_enum AS ENUM (
  'CREATED', 'RUNNING', 'PAUSED', 'REVIEW_HOLD',
  'AWAITING_APPROVAL', 'FINALIZING', 'FINALIZED',
  'FAILED', 'CANCELLED', 'COMPENSATING'
);
```

Plain `text` columns with a `CHECK` constraint are prohibited for enum-like values. The `CHECK`
constraint approach does not enforce the enum at the type system level and is not introspectable
by the ORM. `CREATE TYPE` enums are.

Enum type names follow the convention `<domain>_enum` or `<domain>_status_enum`. The type is
declared in the same migration as the first table that uses it. If a second table uses the same
type, it references the existing type — no duplicate type declarations.

Adding a value to an existing enum requires an `ALTER TYPE ... ADD VALUE` statement in a new
migration. Removing a value requires a multi-step migration (add new type, migrate column,
drop old type) and an amendment to this document.

---

## Section 7 — NOT NULL defaults

Prefer `NOT NULL` with a sensible `DEFAULT` over nullable columns. The rationale: nullable columns
introduce a three-valued logic surface (NULL, false, true) that produces subtle bugs in WHERE
clauses and application code.

Acceptable nullable columns:
- `deleted_at` — by definition NULL until deleted
- `resolved_at`, `finalized_at`, `completed_at` — lifecycle timestamps that are NULL until the
  event occurs
- `user_id` on tables that allow anonymous or system-generated rows
- `payload` fields for optional JSON data

Nullable columns that are not in the above categories require a justification comment in the
migration DDL.

---

## Section 8 — Prohibited patterns

The following patterns are prohibited and will fail code review or CI:

| Pattern | Reason |
| --- | --- |
| `SERIAL` or `BIGSERIAL` primary keys | Use `uuid DEFAULT gen_uuid_v7()` instead |
| `BIGINT GENERATED ALWAYS AS IDENTITY` PKs | Same reason; UUID v7 is the standard |
| `text` column with `CHECK (value IN (...))` for enum-like data | Use `CREATE TYPE` |
| Boolean `is_deleted` column | Use `deleted_at timestamptz NULL` |
| Missing `NOT NULL` on mandatory business fields | Add `NOT NULL DEFAULT <value>` |
| `ON DELETE CASCADE` on business-scoped FK | Use `ON DELETE RESTRICT` |
| `updated_at` set in application code | Use the moddatetime trigger |

---

## Section 9 — Migration policy

Every schema change must be delivered as a Supabase migration file in the `supabase/migrations/`
directory. Manual `ALTER TABLE` statements run against the database directly are prohibited.

Migration files are named following the convention in `supabase_migration_tooling_policy.md`.
Each file is idempotent where possible. Destructive migrations (column drops, type changes) must
be preceded by a compatibility migration in a separate file.

---

## Cross-references

- `data_layer_conventions_policy.md` — identifier generation (gen_uuid_v7 vs gen_random_uuid)
- `supabase_migration_tooling_policy.md` — migration file naming and execution
- `soft_delete_vs_status_policy.md` — when to use deleted_at versus a status enum
- `row_level_security_policies.md` — RLS requirements for new tables
- `transaction_indexing_strategy.md` — index selection guidance for high-volume tables
