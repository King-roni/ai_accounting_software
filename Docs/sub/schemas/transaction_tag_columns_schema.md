# transaction_tag_columns_schema

**Category:** Schemas · **Owning block:** 04 — Data Architecture · **Co-owner:** 08 — Transaction Classification & Tagging · **Stage:** 4 sub-doc (Layer 1 cross-block schema)

Per Stage 1: "One primary tag (drives ledger path) + optional secondary tags (reporting/analytics only)." This sub-doc defines the columns on `transactions` that carry the primary + secondary tag relationships, plus the taxonomy-version pinning that ensures finalized periods stay reproducible across taxonomy evolutions.

---

## Columns on `transactions` (subset of `transactions_schema`)

```sql
-- Primary tag — drives Block 11 ledger path
primary_tag_id                       uuid REFERENCES tags(id),
primary_tag_taxonomy_version_id      uuid REFERENCES tag_taxonomy_versions(id),

-- Secondary tags — reporting / analytics only
secondary_tag_ids                    uuid[],
secondary_tag_taxonomy_version_id    uuid REFERENCES tag_taxonomy_versions(id),
```

These four columns are declared in `transactions_schema`; this sub-doc owns the semantics.

## Semantics

### Primary tag

- Exactly one tag per transaction (after classification completes)
- NULL while `classification_status = 'PENDING'`
- Drives the Block 11 ledger preparation path — per Stage 1: "Each per-business custom tag maps to exactly one of the 12 transaction types"; per `cyprus_default_chart_catalog`, the tag maps to a chart-of-accounts node
- Cannot be NULL after `classification_status = 'CONFIRMED'`

### Secondary tags

- Zero, one, or many secondary tags
- Used by Block 16 for reporting drill-downs (e.g., "all 'Travel — deductible' transactions in Q1")
- DO NOT affect the ledger path
- DO NOT affect Block 11 VAT treatment

### Both taxonomy version columns

- Reference the same `tag_taxonomy_versions.id` in practice — primary and secondary tags must share a version (the classifier emits both at once)
- `primary_tag_taxonomy_version_id` is the canonical version pin for ledger / reporting consumers

The two columns exist (rather than one) for the unusual case where a Stage 2+ migration re-tags secondaries without touching primaries; this is forward-compatible.

## Taxonomy version pinning

Per Stage 1: "Tag taxonomy versioning: Finalized periods preserve the tag taxonomy version active at finalization; new runs use the latest version."

Mechanism:

1. At classification time, the engine reads the current `tag_taxonomy_versions.id` (the "current version") and writes it on the transaction
2. At finalization, the workflow run's snapshot captures the taxonomy version per `archive_manifest_schemas`
3. Future tag-taxonomy changes (new tags added, old tags retired) DO NOT alter past transactions
4. Reports rendered for finalized periods use the pinned version's tag names; reports for the operational period use the current version

The taxonomy is versioned by Block 08 Phase 08 (`tag_taxonomy_versions_schema`); this column carries the pinning.

## Retired-tag handling

Per `custom_tag_policies` (the merged Block 08 policies sub-doc):

- A tag retired in version N+1 still appears on transactions classified under version N
- Reports rendering version-N data render the retired tag's display name as it was at version N (frozen)
- The UI may show a "(retired)" marker per `historical_taxonomy_rendering_policy` (now merged into `custom_tag_policies`)
- Retired tags cannot be selected as a new primary or secondary tag for new classifications

## Mid-run mutation

Per `custom_tag_policies` (mid-run mutation section): if a tag is retired or remapped while a workflow run is in flight, the run uses the snapshot it started under — per the principal-context-snapshot pattern in `workflow_run_schema`. The custom_tag_taxonomy_version_id at run start is the version the run uses.

## Block 16 analytics consumption

Per Stage 1: "Non-deductible expenses: Separate sub-accounts per expense category (e.g., 'Travel — deductible' / 'Travel — non-deductible'), so reports preserve category visibility."

Block 16's analytics MV joins on both `primary_tag_id` and `secondary_tag_ids` (via array-unnest). The 11 dashboard cards consume the primary tag for category breakdowns; drill-downs consume secondary tags for further filtering.

## Cardinality

The `secondary_tag_ids` array is bounded:

- Soft limit: 5 secondary tags per transaction (UI hint)
- Hard limit: 20 secondary tags per transaction (CHECK constraint)

Beyond 5 in the UI is rare and indicates the user might want to reconsider their tagging. The hard limit prevents pathological cases.

```sql
CHECK (cardinality(secondary_tag_ids) <= 20)
```

## Indexes

```sql
-- Primary tag lookup (e.g., "all Travel transactions in Q1")
CREATE INDEX idx_transactions_primary_tag
  ON transactions(business_id, primary_tag_id, transaction_date);

-- Secondary tag lookup via GIN (supports any of N secondaries)
CREATE INDEX idx_transactions_secondary_tags
  ON transactions USING GIN (secondary_tag_ids)
  WHERE secondary_tag_ids IS NOT NULL AND cardinality(secondary_tag_ids) > 0;

-- Taxonomy version lookup (for migration / audit queries)
CREATE INDEX idx_transactions_taxonomy_version
  ON transactions(business_id, primary_tag_taxonomy_version_id);
```

## Audit events

Tagging is recorded as part of classification events per `audit_event_taxonomy`:

| Event | When |
| --- | --- |
| `CLASSIFICATION_LAYER_1_DECIDED` | Tag assigned by Layer 1 rule |
| `CLASSIFICATION_LAYER_2_DECIDED` | Tag assigned via vendor memory |
| `CLASSIFICATION_LAYER_3_DECIDED` | Tag assigned via AI fallback |
| `CLASSIFICATION_USER_RECLASSIFIED` | Tag changed via review-queue action |

The audit payload includes the prior tag (if any) and the new tag for forensic trace.

## Validation

Insert / update constraints (via trigger):

- `primary_tag_id` exists in `tags` and is `active = true` in the pinned taxonomy version (or transactions with `classification_status = 'PENDING'` where the tag isn't set yet)
- All `secondary_tag_ids` exist in `tags` and are `active = true` in the pinned taxonomy version
- `primary_tag_taxonomy_version_id` equals `secondary_tag_taxonomy_version_id` (single-version constraint in MVP)

## Cross-references

- `data_layer_conventions_policy` — UUID v7 for tag IDs, canonical JSON for any tag-payload columns
- `transactions_schema` — host table
- `transaction_type_enum` — primary tag maps to one of the 12 types
- `tag_taxonomy_versions_schema` (Block 08) — version table
- `custom_tag_policies` — tag lifecycle policies (merged)
- `cyprus_default_chart_catalog` — primary tag → chart account mapping
- `audit_log_policies` — `CLASSIFICATION_*` event family
- `permission_matrix` — tag editing is `BUSINESS_SETTINGS_EDIT` (per-business custom tags)
- Block 04 Phase 02 — column declarations
- Block 08 Phase 05 — tag system & default taxonomy (architecture)
- Block 08 Phase 06 — per-business custom tags
- Block 08 Phase 08 — tag taxonomy versioning
- Block 16 Phase 06 — default dashboard cards (consumer)
- Stage 1 decision — primary tag drives ledger path
