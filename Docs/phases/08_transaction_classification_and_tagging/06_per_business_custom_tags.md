# Block 08 — Phase 06: Per-Business Custom Tags

## References

- Block doc: `Docs/blocks/08_transaction_classification_and_tagging.md` (custom tags section)
- Decisions log: `Docs/decisions_log.md` (each custom tag maps to exactly one transaction type)

## Phase Goal

Let business owners define their own tag names that fit how they think about their books, without breaking the type system. Every custom tag maps to exactly one of the 12 transaction types (Stage 1) so Block 11's ledger logic stays deterministic. Custom tags coexist with the default taxonomy and participate in vendor memory.

## Dependencies

- Phase 01 (`business_custom_tags` table — already enforces the one-type-per-tag NOT NULL constraint)
- Phase 03 (vendor memory — custom tags can be the suggested tag in a vendor memory row)
- Phase 05 (default taxonomy — custom tags layer on top, not in place of)
- Block 02 Phase 04 (Owner permission for tag management)
- Block 02 Phase 06 (step-up required for delete)

## Deliverables

- **Custom tag CRUD API** (Owner only):
  - `POST /custom-tags` body `{ tag_name, mapped_transaction_type }`. Validation: tag name non-empty, unique within business case-insensitive, `mapped_transaction_type` is one of the 12 types.
  - `PUT /custom-tags/:id` — rename or remap. Remap is allowed but audit-logged (it can affect future classifications, not historical ones — historical assignments stay tied to the tag's id).
  - `DELETE /custom-tags/:id` — soft-delete; sets a `retired_at` timestamp, prevents future assignment, preserves historical assignments. Step-up auth required.
- **Validation rules:**
  - Tag name uniqueness is case-insensitive within a business (`Software` and `software` are the same tag).
  - Tag name must not collide with the active default taxonomy's tag names. On collision: reject with a clear error suggesting either pick a different name or rely on the default.
  - Tag name length 1–60 characters.
  - `mapped_transaction_type` must be a current valid type code; setting it to `UNKNOWN` is allowed (a custom tag for "things to look at later").
- **Coexistence with default taxonomy:**
  - When the classifier or user picks a tag, the resolution lookup checks both the active default taxonomy AND the business's active custom tags.
  - In the UI's tag-assignment dropdown, custom tags appear in a separate section "Custom for this business" below the default taxonomy.
- **Vendor-memory interaction:**
  - A vendor memory row's `suggested_tag` can reference a custom tag (by name; the memory stores the literal tag name and the active taxonomy resolves it at suggestion time).
  - If the custom tag is later soft-deleted, vendor memory still returns the suggestion but the UI shows it as `(retired)` and prompts the user to pick a current tag.
- **Versioning interaction (Phase 08):**
  - When a period is finalized, the snapshot includes the active custom tags at the time, so historical reports render correctly even if custom tags are later renamed or retired.
- **Audit events:** `CUSTOM_TAG_CREATED`, `CUSTOM_TAG_RENAMED`, `CUSTOM_TAG_REMAPPED`, `CUSTOM_TAG_RETIRED`, `CUSTOM_TAG_RESTORED` (un-retire path).

## Definition of Done

- Owner can create a custom tag mapping to one of the 12 types and use it on a transaction.
- Renaming a custom tag preserves all existing assignments (the tag id stays).
- Remapping a custom tag's `mapped_transaction_type` is audit-logged but does not silently change historical transactions' types — only future classifications.
- Soft-deleting a custom tag prevents future assignment but historical reports still show it (with `(retired)` marker in UI).
- A custom tag whose name collides with the default taxonomy is rejected at create time with a clear message.
- A vendor memory row that references a retired custom tag prompts the user to pick a current tag on the next match.
- Tests cover the full CRUD lifecycle plus the interaction with vendor memory and default-taxonomy collisions.

## Sub-doc Hooks (Stage 4)

- **Custom tag management UI sub-doc** — settings page layout, validation messaging, retired-tag handling.
- **Default-taxonomy collision sub-doc** — exact comparison rules, error message text, resolution flow.
- **Soft-delete & historical preservation sub-doc** — exact `retired_at` semantics, what shows in UI for retired tags, restore flow.
- **Custom-tag remapping audit sub-doc** — when remap is dangerous, when the system warns the user vs requires step-up.
- **`UNKNOWN`-mapping UX sub-doc** — when the UI should warn that a custom tag mapped to `UNKNOWN` will route every assignment back to the review queue; whether to require explicit confirmation at create time.
