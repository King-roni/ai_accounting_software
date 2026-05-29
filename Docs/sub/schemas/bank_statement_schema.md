# Schema: bank_statements

**Namespace:** data  
**Owning Block:** 07 — Bank Statement Pipeline  
**Layer:** 2 — Sub-Doc  
**Status:** Draft

---

## Overview

`bank_statements` is the header-level record for a parsed bank statement. Each row represents one imported statement: a date range, an account (identified by IBAN last four digits), opening and closing balances, and the import lifecycle status. Individual transaction lines are stored in `bank_statement_lines` with a FK back to this table.

This table is the authority on what period a statement covers and whether the lines inside it are consistent (sum of line amounts equals the difference between closing and opening balance). The consistency check is enforced at import time by `intake.import_bank_statement` and recorded in `balance_verified`.

`bank_statements` sits in the Persistent zone and is protected by Row Level Security. It is distinct from `bank_statement_raw` (upload metadata) and `bank_statement_rows` (Processing-zone parse output). Those tables track the pre-import lifecycle; this table is created only after a statement successfully passes validation.

---

## Enum types

```sql
CREATE TYPE bank_statement_import_status_enum AS ENUM (
  'IMPORTED',
  'BALANCE_MISMATCH',
  'DUPLICATE',
  'VOIDED'
);
```

---

## DDL

```sql
CREATE TABLE bank_statements (
  id                        uuid            NOT NULL DEFAULT gen_uuid_v7(),
  business_entity_id        uuid            NOT NULL
                              REFERENCES business_entities(id) ON DELETE RESTRICT,
  run_id                    uuid
                              REFERENCES workflow_runs(id) ON DELETE SET NULL,
  iban_last4                char(4)         NOT NULL,
  currency                  char(3)         NOT NULL DEFAULT 'EUR',
  period_start              date            NOT NULL,
  period_end                date            NOT NULL,
  opening_balance           numeric(15,2)   NOT NULL,
  closing_balance           numeric(15,2)   NOT NULL,
  line_count                integer         NOT NULL DEFAULT 0,
  balance_verified          boolean         NOT NULL DEFAULT false,
  import_status             bank_statement_import_status_enum
                              NOT NULL DEFAULT 'IMPORTED',
  source_file_id            uuid
                              REFERENCES intake_files(id) ON DELETE SET NULL,
  imported_by               uuid
                              REFERENCES auth.users(id) ON DELETE SET NULL,
  imported_at               timestamptz     NOT NULL DEFAULT now(),
  created_at                timestamptz     NOT NULL DEFAULT now(),

  CONSTRAINT bank_statements_pkey
    PRIMARY KEY (id),
  CONSTRAINT bank_statements_period_valid
    CHECK (period_end >= period_start),
  CONSTRAINT bank_statements_line_count_nonneg
    CHECK (line_count >= 0),
  CONSTRAINT bank_statements_currency_length
    CHECK (char_length(currency) = 3),
  CONSTRAINT bank_statements_iban_last4_length
    CHECK (char_length(iban_last4) = 4)
);
```

---

## Dedup index

```sql
CREATE UNIQUE INDEX bank_statements_period_account_uidx
  ON bank_statements (business_entity_id, iban_last4, period_start, period_end)
  WHERE import_status = 'IMPORTED';
```

Prevents two active (non-VOIDED, non-DUPLICATE) statements from covering the same period and account for the same business. The partial index condition excludes voided and duplicate records so they do not block re-import after correction.

---

## Indexes

```sql
CREATE INDEX bank_statements_business_entity_id_idx
  ON bank_statements (business_entity_id);

CREATE INDEX bank_statements_run_id_idx
  ON bank_statements (run_id)
  WHERE run_id IS NOT NULL;

CREATE INDEX bank_statements_period_start_idx
  ON bank_statements (business_entity_id, period_start);
```

---

## Column notes

- `id` — UUID v7 PK per `data_layer_conventions_policy §2`.
- `business_entity_id` — tenant scope. All downstream joins use this for isolation.
- `run_id` — nullable FK to `workflow_runs`. Set when the import occurs inside an active run. Null for ad-hoc imports outside a run context.
- `iban_last4` — last four digits of the IBAN as extracted from the statement header. Used for period-account deduplication. Full IBANs are not stored here; they are held in the business entity's bank account config.
- `currency` — ISO 4217 code for the account currency. Defaults to EUR.
- `period_start` / `period_end` — inclusive date range of the statement. Validated by the import tool to match the date range of the parsed lines.
- `opening_balance` / `closing_balance` — as reported in the statement header. Used to verify balance consistency: `closing_balance - opening_balance` must equal the net of all line amounts (sum of CREDITs minus sum of DEBITs). Stored as `numeric(15,2)`.
- `line_count` — count of lines inserted into `bank_statement_lines` for this statement. Set after line insertion completes. Used for quick consistency checks without a COUNT query.
- `balance_verified` — `true` if the import tool confirmed that line amounts reconcile to the header balances. `false` if verification failed or was skipped (e.g., format does not include a header balance). A statement with `balance_verified = false` triggers a review queue issue.
- `import_status` — `IMPORTED` (normal), `BALANCE_MISMATCH` (verification failed), `DUPLICATE` (dedup collision), `VOIDED` (manually voided after import).
- `source_file_id` — FK to `intake_files`. Links the statement back to the raw uploaded file for audit purposes. Nullable because legacy re-imports may not have a corresponding intake_files row.
- `imported_by` — FK to `auth.users`. The user who triggered the import. Null for system-triggered imports.

---

## Row Level Security

```sql
ALTER TABLE bank_statements ENABLE ROW LEVEL SECURITY;

CREATE POLICY bank_statements_tenant_read
  ON bank_statements
  FOR SELECT
  USING (
    business_entity_id =
      current_setting('app.current_business_id')::uuid
  );

CREATE POLICY bank_statements_service_write
  ON bank_statements
  FOR ALL
  USING (current_setting('app.role', true) = 'service_role');
```

---

## Audit events

`intake.import_bank_statement` emits `BANK_STATEMENT_IMPORTED` on successful row creation.

Audit event notes:
- `BANK_STATEMENT_IMPORTED` — not yet in the taxonomy as of this writing. Must be added to `audit_event_taxonomy.md` before production use.
- Existing taxonomy entries `BANK_STATEMENT_PARSED` and `BANK_STATEMENT_UPLOADED` (emitted by earlier pipeline stages in `bank_statement_raw` lifecycle) are separate events and continue to apply.

---

## Related Documents

- `bank_statement_line_schema.md` — child lines table; FK `bank_statement_id` points here
- `bank_statement_raw_schema.md` — upload-stage metadata preceding this record
- `bank_statement_rows_schema.md` — Processing-zone parse output feeding this record
- `intake_file_schema.md` — `source_file_id` FK target
- `tool_bank_statement_import.md` — tool that creates and populates this table
- `deduplication_policy.md` — dedup rules enforced via the period-account unique index
- `data_layer_conventions_policy.md` — UUID v7 and numeric precision rules
- `rls_policy_template.md` — RLS session variable pattern
