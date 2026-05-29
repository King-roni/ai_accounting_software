# vat_rate_table_reference

**Category:** Reference data · **Owning block:** 11 — Ledger & Cyprus VAT (co-owner: Block 11 Phases 05 and 08) · **Stage:** 4 sub-doc (Layer 2)

This sub-doc defines the Cyprus VAT rate table for MVP, the mapping between each rate and the 8 VAT treatments in `vat_treatment_enum`, and the mid-period rate change handling policy. The rate table is versioned in the database: queries always join on the `effective_from` date to select the applicable rate for any given transaction date. This sub-doc serves both Block 11 Phase 05 (VAT treatment classifier) and Block 11 Phase 08 (VAT amount computation).

---

## Cyprus VAT rates (MVP — effective as of Stage 1 freeze)

| Rate name | Rate | Applies to |
|---|---|---|
| Standard | 19% | General goods and services supplied within Cyprus; B2B and B2C where no reduced or zero rate applies |
| Reduced rate 1 | 9% | Accommodation services (hotel, short-term rental); restaurant and catering services (excluding alcoholic beverages); certain domestic services (hairdressing, minor household repairs) |
| Reduced rate 2 | 5% | Books and newspapers (physical); certain food items (basic groceries as defined by Cyprus VAT law); pharmaceuticals; certain social housing |
| Zero | 0% | Exports of goods to destinations outside the EU; international passenger transport; intra-EU supply of goods with valid EU VAT number (zero-rated on the supplier invoice, reverse-charged on the buyer); certain exemptions treated as zero-rated under Cyprus VAT law |
| Exempt | — | Financial services; certain educational services; certain medical and healthcare services; insurance; leasing of residential property. No VAT is charged; no input VAT is reclaimable on associated costs |

### Key distinction: zero-rated vs. exempt

Zero-rated supplies are taxable at 0% — the supplier is VAT-registered, files VAT returns, and can reclaim input VAT on related costs. Exempt supplies are not in scope for VAT at all — no output VAT is charged and no input VAT recovery is permitted on directly associated costs. This distinction is material for ledger entry generation (Block 11 Phase 07) and for Cyprus VAT return preparation (Block 16).

---

## Rate-to-treatment mapping

The following table maps each Cyprus VAT rate to the corresponding `vat_treatment_enum` value(s). A single treatment may apply at different rates depending on context (e.g., `DOMESTIC_REDUCED` covers both 9% and 5%).

| `vat_treatment_enum` value | Applicable rate(s) | Direction | Notes |
|---|---|---|---|
| `DOMESTIC_STANDARD` | 19% | OUT or IN | Standard Cyprus domestic supply |
| `DOMESTIC_REDUCED` | 9% or 5% | OUT or IN | The specific reduced rate is determined by the expense/income category; Block 11 Phase 08 resolves 9% vs 5% from the tag's category mapping |
| `DOMESTIC_ZERO` | 0% | OUT or IN | Zero-rated domestic supply; distinct from exports |
| `EU_REVERSE_CHARGE` | 0% on invoice | OUT or IN | Output VAT = 0 on the invoice; reverse-charged VAT is self-assessed at the applicable Cyprus rate (typically 19% for services). The reverse-charge amount is computed in Block 11 Phase 06 |
| `IMPORT_OR_ACQUISITION` | Self-assessed at applicable Cyprus rate | OUT only | Rate determined by the goods category (typically 19%; reduced rates apply to qualifying goods). Block 11 Phase 08 applies the rate from this table |
| `NON_EU_SERVICE` | 0% | IN | Zero-rated export of services; reportable on Cyprus VAT return; NOT VIES-reportable |
| `OUTSIDE_SCOPE` | — | OUT or IN | No VAT rate applies; no VAT entry generated |
| `UNKNOWN` | — | OUT or IN | Deferred; no rate applied until accountant review resolves to a definite treatment |

---

## `vat_rates` table definition

The rate table is versioned. Each row represents a rate entry effective from a given date.

```sql
CREATE TABLE vat_rates (
  rate_id               uuid        PRIMARY KEY DEFAULT gen_uuid_v7(),
  rate_name             text        NOT NULL,                    -- e.g., 'STANDARD', 'REDUCED_1', 'REDUCED_2', 'ZERO', 'EXEMPT'
  rate_percentage       numeric(5, 2) NOT NULL,                 -- e.g., 19.00, 9.00, 5.00, 0.00
  effective_from        date        NOT NULL,
  notes                 text,
  created_by            uuid        REFERENCES users(id),       -- null for seeded rows
  created_at            timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT uq_vat_rate_name_effective
    UNIQUE (rate_name, effective_from)
);
```

### Rate resolution query

For any transaction with `transaction_date = $date`, the applicable rate for a given `rate_name` is:

```sql
SELECT rate_percentage
FROM vat_rates
WHERE rate_name = $rate_name
  AND effective_from <= $date
ORDER BY effective_from DESC
LIMIT 1;
```

This pattern ensures that rates effective before the transaction date are selected, and the most-recent rate before the transaction date wins. The query is deterministic for a given `(rate_name, date)` pair — no clock-dependent inputs.

---

## Mid-period rate change handling

**Policy (deferred Stage 1 item — now resolved for MVP):**

When Cyprus changes a VAT rate mid-period, the following rules apply:

1. **Transaction date governs.** The applicable rate is determined by `transaction.transaction_date`, not by the workflow run date, the ledger preparation date, or the finalization date.

2. **New rate row insertion.** When a rate change is announced, a new `vat_rates` row is inserted with `effective_from` set to the change date (the first day the new rate applies). No existing rows are modified.

3. **Historical immutability.** Transactions whose `transaction_date` falls before `effective_from` of the new rate continue to resolve to the old rate via the rate-resolution query above. No retroactive re-computation of historical transactions is needed.

4. **In-flight workflow runs.** If a workflow run spans the rate change date (e.g., the run covers a month that includes the change date), transactions on either side of the change date resolve to their respective rates within the same run. The run does not need to be paused or restarted.

5. **Draft entry recomputation.** If a draft ledger entry was prepared before the new rate row was inserted, and the transaction date falls on or after the new `effective_from`, `ledger.prepare_entries` will use the new rate on the next recomputation. The `last_recomputed_at` column on `draft_ledger_entries` identifies entries that may need re-running.

6. **Finalized periods are immutable.** A rate change does not trigger retroactive re-finalization of locked periods. Locked ledger entries carry `vat_rate_table_version` (pinned at draft time per Block 11 Phase 01); the archive preserves the rate snapshot as-of finalization.

---

## Seeded rates (MVP initial data)

The following rows are seeded at deployment time:

| `rate_name` | `rate_percentage` | `effective_from` | Notes |
|---|---|---|---|
| `STANDARD` | 19.00 | 2018-01-15 | Cyprus standard rate (unchanged since 2018) |
| `REDUCED_1` | 9.00 | 2018-01-15 | Hospitality and restaurant reduced rate |
| `REDUCED_2` | 5.00 | 2018-01-15 | Books, pharma, certain food |
| `ZERO` | 0.00 | 2018-01-15 | Zero-rated supplies |
| `EXEMPT` | 0.00 | 2018-01-15 | Exempt supplies (rate column = 0 by convention; actual exemption is tracked by `vat_treatment`, not by this table) |

The `effective_from` date of 2018-01-15 is set conservatively earlier than any transaction the system will ever process, ensuring the seed data is always the applicable rate for all historical transactions unless a more recent rate row is inserted.

---

## No read events; one write event

Rate table reads are high-frequency (every ledger entry preparation reads this table) and do not generate audit events. An admin-only write operation (inserting a new rate row for a future rate change) emits one audit event:

| Event | When | Severity |
|---|---|---|
| `LEDGER_VAT_RATE_TABLE_UPDATED` | New row inserted into `vat_rates` (admin-only operation) | MEDIUM |

No update or delete of existing `vat_rates` rows is permitted (the table is append-only; historical rates are immutable once seeded or inserted). Attempted updates or deletes are blocked by a trigger. Emitted via `emitAudit()` per `audit_log_policies`; exists in `audit_event_taxonomy`.

---

## Indexes

```sql
-- Rate resolution hot path
CREATE INDEX idx_vat_rates_name_date
  ON vat_rates (rate_name, effective_from DESC);
```

---

## RLS

The `vat_rates` table contains no tenant-specific data. It is readable by all authenticated sessions. Write access is restricted to platform-admin role via Block 02 Phase 04 `canPerform`.

```sql
-- No RLS policy on vat_rates; it is a global reference table.
-- Read access: all authenticated roles.
-- Write access: platform admin only (enforced via canPerform at application layer).
```

---

## Cross-references

- `vat_treatment_enum` — the 8-value closed enum; every treatment in that enum is mapped to a rate (or rate range) in this sub-doc
- `audit_log_policies` — `LEDGER_*` domain; `<DOMAIN>_<PAST_VERB>` naming
- `audit_event_taxonomy` — `LEDGER_VAT_RATE_TABLE_UPDATED`
- `data_layer_conventions_policy` — UUID v7 PK
- Block 11 Phase 05 — VAT treatment classifier (uses this table's rate-resolution pattern; declares this sub-doc as a binding dependency)
- Block 11 Phase 06 — reverse-charge and VIES relevance (uses this table to compute reverse-charge amounts)
- Block 11 Phase 08 — VAT amount computation (consumes the resolved rate for each treatment)
- Block 16 Phase 11 — accountant pack and VIES export (reads VAT amounts computed from this table)
- `tool_naming_convention_policy` — `ledger.*` namespace for all tools using this table
