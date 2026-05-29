# report_output_schema

**Category:** Schemas — Block 16: Dashboard & Reporting
**Table:** `report_outputs`

---

## Purpose

`report_outputs` stores the generated report files produced by the reporting pipeline.
Each row represents a single output file awaiting download. Files are stored in the
Export-temp S3 bucket with a 24-hour TTL. For report types that require permanent
retention (e.g., `ACCOUNTANT_PACK`), the bundle is promoted to Archive zone via
`archive.promote` after generation completes.

---

## DDL

```sql
CREATE TABLE report_outputs (
    id                        uuid              NOT NULL DEFAULT gen_uuid_v7()   PRIMARY KEY,
    business_id               uuid              NOT NULL REFERENCES business_entities(id),
    report_job_id             uuid              NOT NULL REFERENCES report_jobs(id),
    report_type               report_type_enum  NOT NULL,
    output_format             report_format_enum NOT NULL,
    storage_path              text              NOT NULL,
    file_size_bytes           integer           NULL,
    file_hash                 text              NULL,
    generation_started_at     timestamptz       NOT NULL DEFAULT now(),
    generation_completed_at   timestamptz       NULL,
    generation_failed_at      timestamptz       NULL,
    failure_reason            text              NULL,
    status                    report_output_status NOT NULL DEFAULT 'GENERATING',
    download_count            integer           NOT NULL DEFAULT 0,
    last_downloaded_at        timestamptz       NULL,
    expires_at                timestamptz       NOT NULL
        GENERATED ALWAYS AS (generation_started_at + INTERVAL '24 hours') STORED,
    created_at                timestamptz       NOT NULL DEFAULT now()
);

CREATE TYPE report_type_enum AS ENUM (
    'PERIOD_SUMMARY',
    'VAT_RETURN',
    'AUDIT_LOG_EXPORT',
    'ACCOUNTANT_PACK',
    'LEDGER_EXPORT',
    'VIES_SUBMISSION_REPORT'
);

CREATE TYPE report_format_enum AS ENUM (
    'PDF',
    'CSV',
    'XLSX',
    'ZIP'
);

CREATE TYPE report_output_status AS ENUM (
    'GENERATING',
    'READY',
    'FAILED',
    'EXPIRED'
);
```

---

## Column Notes

**storage_path** — Full S3 object key in the Export-temp bucket. Format:
`export-temp/{business_id}/{report_job_id}/{id}.{format_extension}`. This path is
used directly to generate pre-signed download URLs. The path is set at row creation
time (before generation begins) so that the pipeline can write to a deterministic
location.

**file_hash** — SHA-256 hex digest of the generated file, computed after generation
completes. NULL while status is `GENERATING`. Required for integrity verification
before a pre-signed download URL is issued. The hash is stored on `generation_completed_at`
transition.

**file_size_bytes** — Set when generation completes. NULL while `GENERATING`. Used by
the download API to set `Content-Length`.

**expires_at** — Computed as `generation_started_at + 24 hours`. The background
expiry job reads this column to find eligible rows. After the file is deleted from
Export-temp, the row status is set to `EXPIRED`; the row is retained indefinitely
for audit trail.

**failure_reason** — Free-text error message set when `status = 'FAILED'`. NULL for
all other statuses.

**download_count** — Incremented each time a pre-signed URL is successfully issued
for this output. Does not track actual download completions (pre-signed URL issuance
is the tracked event).

---

## Indexes

```sql
CREATE INDEX report_outputs_business_id_idx   ON report_outputs (business_id);
CREATE INDEX report_outputs_report_job_id_idx ON report_outputs (report_job_id);
CREATE INDEX report_outputs_status_idx        ON report_outputs (status);
CREATE INDEX report_outputs_expires_at_idx    ON report_outputs (expires_at)
    WHERE status = 'READY';
```

The `expires_at` partial index covers only `READY` rows, since `GENERATING`, `FAILED`,
and `EXPIRED` rows are not eligible for TTL deletion.

---

## Status Transitions

| From         | To         | Trigger                                               |
|---|---|---|
| `GENERATING` | `READY`    | Report pipeline writes file; hash computed            |
| `GENERATING` | `FAILED`   | Generation error; failure_reason set                  |
| `READY`      | `EXPIRED`  | Background TTL job; file deleted from Export-temp     |
| `FAILED`     | `EXPIRED`  | Background TTL job; row aged past 24 hours            |

There is no transition back to `GENERATING` from `FAILED`. A failed report requires a
new `report_jobs` entry and a new `report_outputs` row.

---

## Permanent Retention (ACCOUNTANT_PACK)

For `report_type = 'ACCOUNTANT_PACK'`, the report pipeline calls `archive.promote`
after `status` transitions to `READY`. The promoted archive bundle receives Object Lock
(COMPLIANCE, 7-year retention) in the Archive zone. The `report_outputs` row is not
deleted at `expires_at` expiry -- it is retained with `status = 'EXPIRED'` and the
`storage_path` reflects the Archive zone path after promotion.

All other report types are ephemeral: the file is deleted at `expires_at` and
`status` transitions to `EXPIRED`.

---

## Pre-Signed URL Policy

Pre-signed download URLs are generated on demand by the reporting API. URLs are valid
for 15 minutes. The API checks `status = 'READY'` and `expires_at > now()` before
issuing a URL. URLs are NOT stored in this table; only `download_count` and
`last_downloaded_at` are updated on each issuance. See `export_pipeline_policy.md`
for URL expiry configuration and IP-restriction rules.

---

## Data Zone Summary

| Status       | Storage zone   | File present | TTL behavior                         |
|---|---|---|---|
| `GENERATING` | Export-temp    | In progress  | 24-hour TTL clock starts at insert   |
| `READY`      | Export-temp    | YES          | Deleted at expires_at                |
| `READY`      | Archive zone   | YES (PACK)   | Object Lock; no TTL deletion         |
| `FAILED`     | Export-temp    | Partial      | Background job removes at expires_at |
| `EXPIRED`    | --             | NO           | Row retained; file deleted           |

---

## Audit Events

| Event                          | Severity | Trigger                                   |
|---|---|---|
| `REPORT_GENERATION_COMPLETED`  | LOW      | status transitions to READY               |
| `REPORT_GENERATION_FAILED`     | MEDIUM   | status transitions to FAILED              |
| `REPORT_DOWNLOADED`            | LOW      | Pre-signed URL issued; download_count incremented |

All events include `business_id`, `report_job_id`, `id` (report_output_id), and
`report_type` in the audit payload.

---

## Cross-References

- `report_job_schema.md` -- DDL for the report_jobs table (parent of report_outputs)
- `export_pipeline_policy.md` -- generation pipeline, pre-signed URL policy, TTL config
- `export_definitions_catalog.md` -- available report types, format matrix, field spec
- `archive_bundle_construction_schema.md` -- archive bundle DDL used by ACCOUNTANT_PACK promotion
