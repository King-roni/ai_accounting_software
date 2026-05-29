# Accountant Pack Config Schema

**Category:** Schemas · **Owning block:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

The per-business configuration record for the Accountant Pack export — a curated, sealed bundle of period documents sent to or downloaded by an external accountant. One config row per business governs which components are included in the pack and how delivery is triggered. The pack itself is assembled by `report.generate_accountant_pack` from the finalized archive bundle.

---

## 1. Table definition

```sql
CREATE TABLE accountant_pack_configs (
  pack_config_id          uuid PRIMARY KEY DEFAULT gen_uuid_v7(),

  -- One config per business (unique constraint)
  business_id             uuid NOT NULL UNIQUE,
  organization_id         uuid NOT NULL,

  -- Accountant delivery target
  -- Must be a valid email format (RFC 5322 simplified check)
  recipient_email         text NOT NULL
                            CHECK (recipient_email ~* '^[^@]+@[^@]+\.[^@]+$'),

  -- Component inclusion flags (default: all true)
  include_ledger_csv          boolean NOT NULL DEFAULT true,
  include_vat_summary         boolean NOT NULL DEFAULT true,
  include_period_report_pdf   boolean NOT NULL DEFAULT true,
  include_invoice_pack        boolean NOT NULL DEFAULT false,
  include_evidence_pack       boolean NOT NULL DEFAULT false,

  -- Delivery trigger
  -- MANUAL: user initiates via dashboard export action
  -- AUTO_ON_FINALIZATION: pack is generated and emailed automatically
  --   when a run transitions to FINALIZED (Stage 2+ feature; see note below)
  delivery_trigger        delivery_trigger_enum NOT NULL DEFAULT 'MANUAL',

  -- Last delivery tracking
  last_sent_at            timestamptz,
  last_sent_run_id        uuid
                            REFERENCES workflow_runs(workflow_run_id),

  -- Standard timestamps
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),

  -- Constraints
  CONSTRAINT accountant_pack_configs_one_per_business
    UNIQUE (business_id)
);

CREATE TYPE delivery_trigger_enum AS ENUM ('MANUAL', 'AUTO_ON_FINALIZATION');

CREATE INDEX idx_accountant_pack_configs_business
  ON accountant_pack_configs(business_id);

CREATE INDEX idx_accountant_pack_configs_org
  ON accountant_pack_configs(organization_id);
```

---

## 2. Field reference

| Field | Type | Default | Notes |
|---|---|---|---|
| `pack_config_id` | UUID v7 PK | `gen_uuid_v7()` | Monotonically increasing per `data_layer_conventions_policy` |
| `business_id` | UUID | — | Unique; one config per business |
| `organization_id` | UUID | — | Denormalized for org-level queries; not an FK in this table |
| `recipient_email` | text | — | Accountant's email; validated by CHECK constraint; used for `AUTO_ON_FINALIZATION` delivery |
| `include_ledger_csv` | boolean | `true` | Include `ledger_entries.csv` from the archive bundle |
| `include_vat_summary` | boolean | `true` | Include `vat_summary.json` from the archive bundle |
| `include_period_report_pdf` | boolean | `true` | Include `period_report.pdf` from the archive bundle |
| `include_invoice_pack` | boolean | `false` | Include the `invoice_pack/` directory from the archive bundle |
| `include_evidence_pack` | boolean | `false` | Include the `evidence_pack/` directory from the archive bundle |
| `delivery_trigger` | enum | `MANUAL` | `MANUAL` or `AUTO_ON_FINALIZATION`; AUTO is Stage 2+ but column is present in MVP schema |
| `last_sent_at` | timestamptz | `NULL` | Updated after every successful pack delivery |
| `last_sent_run_id` | UUID FK nullable | `NULL` | The `workflow_run_id` for which the most recent pack was sent |
| `created_at` | timestamptz | `now()` | Row creation timestamp |
| `updated_at` | timestamptz | `now()` | Updated via trigger on every UPDATE |

`updated_at` is maintained by the standard `set_updated_at()` trigger function (shared utility, Block 04 Phase 01), applied `BEFORE UPDATE FOR EACH ROW`.

---

## 3. Component inclusion semantics

The five `include_*` boolean flags correspond to the file groups defined in `archive_bundle_file_manifest`:

| Flag | Bundle source |
|---|---|
| `include_ledger_csv` | `ledger_entries.csv` (always present in the archive bundle) |
| `include_vat_summary` | `vat_summary.json` (always present in the archive bundle) |
| `include_period_report_pdf` | `period_report.pdf` (always present in the archive bundle) |
| `include_invoice_pack` | `invoice_pack/` directory (conditional in the archive bundle) |
| `include_evidence_pack` | `evidence_pack/` directory (conditional in the archive bundle) |

If `include_invoice_pack = true` but the period has no invoices (the archive bundle has no `invoice_pack/` directory), the component is silently omitted from the pack and not counted as a failure.

The pack always includes `manifest.json` regardless of flag values — the manifest is the integrity envelope for the pack.

---

## 4. RLS

```sql
-- Tenant isolation: only users with an active role on the business may read
CREATE POLICY accountant_pack_configs_select
  ON accountant_pack_configs
  FOR SELECT
  USING (business_id = ANY (auth.business_ids_for_session()));

-- Writes (INSERT/UPDATE) are gated by BUSINESS_SETTINGS_EDIT permission surface
-- enforced at the application layer; RLS here allows authenticated sessions
-- to write; the application gate prevents unpermitted roles from reaching the endpoint
CREATE POLICY accountant_pack_configs_write
  ON accountant_pack_configs
  FOR ALL
  USING (business_id = ANY (auth.business_ids_for_session()));
```

**Permission surface for writes:** `BUSINESS_SETTINGS_EDIT` — Owner and Admin only. Bookkeeper, Accountant, Reviewer, and Read-only may VIEW the config (the settings page is readable by all roles) but cannot update any field. The application enforces this gate before writing; the RLS above is the tenant isolation layer, not the permission layer.

---

## 5. The `report.generate_accountant_pack` tool

```typescript
engine.registerTool({
  name: "report.generate_accountant_pack",
  schema_version: "1.0",
  side_effect_class: ["READ_ONLY", "WRITES_AUDIT", "EXTERNAL_CALL"],
  // EXTERNAL_CALL: reads from archive-bundles bucket (Block 04 Phase 07)
  ai_tier: "NONE",
  audit_events: [
    "ACCOUNTANT_PACK_SENT",
    "ACCOUNTANT_PACK_DELIVERY_FAILED",
  ],
  description_ref: "Docs/sub/tools/tool_report_generate_accountant_pack.md",
});
```

**Input schema:**

```typescript
interface GenerateAccountantPackInput {
  business_id: string;               // UUID v7
  workflow_run_id: string;           // UUID v7 — must reference a FINALIZED run
  // Scope may be extended to 'period' | 'quarter' | 'year' in Stage 2+
  scope: 'period';
}
```

**Pre-generation validation:**
1. The `workflow_run_id` must reference a run in `FINALIZED` state. Non-finalized runs are rejected with `ACCOUNTANT_PACK_REJECTED_PERIOD_NOT_FINALIZED` (already in `audit_event_taxonomy`).
2. Block 15 Phase 07's pre-read verification fires on every archive read. If tamper is detected, generation is blocked with `ACCOUNTANT_PACK_REJECTED_TAMPER_DETECTED` (already in `audit_event_taxonomy`).
3. `accountant_pack_configs` row must exist for the `business_id`. If not found, the generator uses all-included defaults without writing a new config row (lazy-init semantics, symmetric with `dashboard_preferences_schema` Section 4).

**Assembly pipeline:**
1. Load the `accountant_pack_configs` row for the business (or use all-included defaults).
2. Retrieve the archive bundle from the archive zone for the specified `workflow_run_id`.
3. Select components matching the `include_*` flags from the archive bundle.
4. Assemble a new sealed ZIP with the selected components plus a fresh `manifest.json` referencing the source `archive_package_id`.
5. Compute SHA-256 of the pack ZIP → `bundle_hash_anchor`.
6. Persist the pack to the Raw Upload zone (Block 04 Phase 05) and populate the `exports` row.
7. Update `last_sent_at` and `last_sent_run_id` on the config row.
8. Emit `ACCOUNTANT_PACK_SENT` on successful delivery or `ACCOUNTANT_PACK_DELIVERY_FAILED` on failure.

**Permission gate:** `REPORT_EXPORT_FULL` (Owner, Admin, Accountant) per `export_pipeline_policy` Section 5.

---

## 6. Mobile rejection

Config updates (`INSERT` / `UPDATE` on `accountant_pack_configs`) are a write surface. The config update endpoint is listed in `mobile_write_rejection_endpoints`. Mobile clients attempting to update the config receive HTTP 405 `MOBILE_WRITE_REJECTED`. Pack generation (export download initiation) is permitted on mobile per `export_pipeline_policy` Section 6 — export initiation is a read-intent surface.

---

## 7. `AUTO_ON_FINALIZATION` delivery (Stage 2+ note)

The `delivery_trigger = AUTO_ON_FINALIZATION` variant is schema-present in MVP but not yet implemented. When active (Stage 2+), the delivery is triggered by the `ARCHIVE_PROMOTION_COMPLETED` event subscription (Block 16's event subscriber). The pack is generated and emailed to `recipient_email` automatically after every finalization. MVP implementations must check `delivery_trigger = MANUAL` and skip auto-delivery.

---

## 8. Audit events

| Event | Severity | When |
|---|---|---|
| `ACCOUNTANT_PACK_CONFIG_UPDATED` | LOW | Any UPDATE to an `accountant_pack_configs` row; payload includes `business_id`, `actor_user_id`, `actor_role`, changed fields |
| `ACCOUNTANT_PACK_SENT` | LOW | Pack successfully assembled and delivered (or download URL generated); payload includes `workflow_run_id`, `pack_config_id`, `components_included`, `bundle_hash_anchor` |
| `ACCOUNTANT_PACK_DELIVERY_FAILED` | MEDIUM | Pack generation or delivery fails; payload includes `reason`, `workflow_run_id`, `pack_config_id` |

`ACCOUNTANT_PACK_CONFIG_UPDATED` already exists in `audit_event_taxonomy`. `ACCOUNTANT_PACK_SENT` and `ACCOUNTANT_PACK_DELIVERY_FAILED` are new events defined in this sub-doc (see Step 3 audit taxonomy extension).

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK generation; `updated_at` trigger; decimal amounts in pack contents
- `archive_bundle_file_manifest` — source file groups for each `include_*` flag; mandatory vs conditional file classification
- `export_pipeline_policy` — `REPORT_EXPORT_FULL` permission gate; async dispatch; export-temp 24h TTL; archive-derived exports use permanent Object Lock retention
- `tool_naming_convention_policy` — `report.generate_accountant_pack` tool name; `report` namespace; `EXTERNAL_CALL` side-effect class
- `audit_log_policies` — `ACCOUNTANT_PACK_CONFIG_UPDATED`, `ACCOUNTANT_PACK_SENT`, `ACCOUNTANT_PACK_DELIVERY_FAILED` event naming; `ACCOUNTANT_PACK` domain
- `audit_event_taxonomy` — `ACCOUNTANT_PACK` domain events
- `mobile_write_rejection_endpoints` — config update endpoint listed as mobile-rejected
- `permission_matrix` — `BUSINESS_SETTINGS_EDIT` surface (Owner/Admin); `REPORT_EXPORT_FULL` surface
- `dashboard_preferences_schema` — lazy-init semantics pattern (missing row = all defaults)
- Block 16 Phase 11 — accountant pack architecture; component matrix; manifest schema
- Block 15 Phase 07 — pre-read verification; tamper detection
- Block 04 Phase 05 — Raw Upload zone; export artifact storage
- Block 04 Phase 07 — Finalized Archive zone; source of archive bundle files
