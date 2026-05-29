# match_reason_regeneration_audit_policy

**Category:** Policies · **Owning block:** 10 — Matching Engine · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

The contract for **preserving match-reason history** across regeneration events. Defines: when regeneration happens, how the old reason is captured before the new one overwrites the column, the audit-event shape that records the swap, and the retention rule for historical reasons.

Companion to `match_reason_prompt.md` (the prompt being regenerated) and `match_reason_sample_output_corpus.md` (which validates each generation/regeneration output against the golden corpus).

---

## 1. The invariant

> `match_records.match_reason_plain_language` carries the **current** reason. The **prior** reason (and all prior reasons in chronological order) is preserved in audit, never overwritten in a way that loses forensic trace.

This is the phase-doc commitment ("the old reason is preserved in audit (the match record's history)") operationalised. The reason an accountant sees today on a finalised match must be the reason that justified the match at finalisation time, even if signals or AI prompt versions have changed since.

---

## 2. Regeneration triggers

Four distinct events cause regeneration. Each emits `MATCHING_REASON_REGENERATED` (LOW severity) with a typed `trigger` field in the payload.

| Trigger | When | Payload `trigger` value |
|---|---|---|
| **User-edited signals** | An accountant modifies the match signals via the match-review UI (e.g., reclassifies the supplier match from fuzzy to exact). | `USER_SIGNAL_EDIT` |
| **Re-scoring after schema change** | A migration extends `match_signals.score_breakdown` with new signal fields. The matching engine re-scores affected runs and regenerates their reasons. | `SCHEMA_MIGRATION_RESCORE` |
| **Prompt version bump** | `match_reason_v1` deprecates; `match_reason_v2` becomes default. Active matches (non-finalised) regenerate with v2. **Finalised matches do NOT regenerate** — their reason is locked per §6. | `PROMPT_VERSION_BUMP` |
| **Fallback recovery** | A match's plain-language reason currently carries the fallback template (per `match_reason_prompt.md` fallback). User clicks "Regenerate" on the LOW-severity review issue per phase doc §"Failure handling". | `FALLBACK_REGENERATE_REQUESTED` |

A regeneration that produces a byte-identical output (i.e., the AI returned the same string as the existing reason) is **still audited as `MATCHING_REASON_REGENERATED`** but with `payload.output_changed = false`. The audit chain captures the regeneration attempt even when the visible state is unchanged — this is the "did we re-run the AI call?" forensic signal.

---

## 3. The preservation mechanism

A separate table `match_reason_history` stores the prior reason on every regeneration. The mechanism is a SECURITY DEFINER RPC `matching.regenerate_reason(match_id uuid, trigger text)` that runs the swap atomically:

```sql
CREATE TABLE match_reason_history (
  id                             uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  match_record_id                uuid NOT NULL REFERENCES match_records(id) ON DELETE CASCADE,
  reason_text                    text NOT NULL,
  prompt_version                 text NOT NULL,                  -- e.g., 'match_reason_v1'
  generated_at                   timestamptz NOT NULL,           -- when this version was created
  superseded_at                  timestamptz NOT NULL DEFAULT now(),
  trigger                        match_reason_trigger_enum NOT NULL,
  trigger_actor_user_id          uuid REFERENCES users(id),     -- NULL for SCHEMA_MIGRATION_RESCORE / PROMPT_VERSION_BUMP
  ai_tier_used                   ai_tier_enum NOT NULL,
  fallback_applied               boolean NOT NULL DEFAULT false,
  fallback_category              text,                           -- AI_TIMEOUT etc, per match_reason_prompt.md §Error handling
  audit_event_id                 uuid NOT NULL REFERENCES audit_events(id)
);

CREATE TYPE match_reason_trigger_enum AS ENUM (
  'USER_SIGNAL_EDIT',
  'SCHEMA_MIGRATION_RESCORE',
  'PROMPT_VERSION_BUMP',
  'FALLBACK_REGENERATE_REQUESTED'
);

CREATE INDEX mrh_by_match
  ON match_reason_history(match_record_id, superseded_at DESC);
```

`matching.regenerate_reason` runs in a single transaction:

1. SELECT the current `match_records.match_reason_plain_language` and metadata (the in-force values BEFORE this regeneration).
2. INSERT the captured values into `match_reason_history` (becoming the "prior" row).
3. Invoke the AI (or apply fallback) to produce the new reason.
4. UPDATE `match_records.match_reason_plain_language` to the new value.
5. Emit `MATCHING_REASON_REGENERATED` audit event referencing both the `match_record_id` and the new `match_reason_history.id`.

The whole sequence is atomic — either the swap completes with both the history row inserted AND the column updated AND the audit emitted, or none of it commits. No interleaved-state-visible window exists.

**Cross-block coordination flagged for B10·P07 migration:** `match_reason_history` table + `match_reason_trigger_enum` + 1 index + `matching.regenerate_reason(match_id, trigger)` SECURITY DEFINER RPC.

---

## 4. Audit event shape

`MATCHING_REASON_REGENERATED` payload per `audit_event_payload_schemas.md`:

```jsonc
{
  "match_record_id":          "uuid",
  "match_reason_history_id":  "uuid",           // the row that captured the prior value
  "trigger":                  "USER_SIGNAL_EDIT | SCHEMA_MIGRATION_RESCORE | PROMPT_VERSION_BUMP | FALLBACK_REGENERATE_REQUESTED",
  "trigger_actor_user_id":    "uuid | null",
  "prior_reason_prompt_version": "string",      // e.g., 'match_reason_v1'
  "new_reason_prompt_version":   "string",      // e.g., 'match_reason_v2'
  "prior_ai_tier":            "TIER_1 | TIER_2 | TIER_3",
  "new_ai_tier":              "TIER_1 | TIER_2 | TIER_3",
  "prior_fallback_applied":   "boolean",
  "new_fallback_applied":     "boolean",
  "output_changed":           "boolean",        // false when byte-identical regeneration
  "regenerated_at":           "timestamptz"
}
```

The payload deliberately carries identifiers (`match_reason_history_id`), not raw text. Reconstructing the actual prior text is a JOIN against `match_reason_history`. This keeps `audit_events` lean and concentrates the higher-volume text storage in the dedicated history table.

---

## 5. Retention

Retention follows the **business's data retention regime** per `retention_policies_schema.md` (default 6 years for Cyprus statutory accounting):

| Class | Retention |
|---|---|
| `match_reason_history` rows for a match that finalised inside the retention window | Retained for the full retention window. Hard-deletable only after the parent `match_records` row is also retention-eligible. |
| `match_reason_history` rows for a match in an ACTIVE (non-finalised) state | Retained indefinitely while the match is active. |
| `match_reason_history` rows for a CANCELLED match | Follow `match_records` retention — typically purged 90 days after cancellation. |
| `audit_events` rows for `MATCHING_REASON_REGENERATED` | Follow the canonical audit-event retention per `audit_log_policies.md` — 6 years minimum, integrated into the hash-chain so deletion within retention is forbidden anyway. |

The retention enforcement is per-business, not per-row, so a business in a multi-jurisdiction edge case can extend its retention without per-row overrides.

---

## 6. Finalised matches — no regeneration

Once a match's `workflow_run.status = 'FINALIZED'`, **the match's `match_reason_plain_language` becomes immutable**. Any regeneration request for a finalised match's reason is **rejected** with error `MATCH_REASON_LOCKED_BY_FINALIZATION`.

The locking is enforced two ways:

1. **At the RPC layer:** `matching.regenerate_reason` checks the parent workflow-run's status before SELECT-FOR-UPDATEing the `match_records` row. If FINALIZED, the RPC raises.
2. **At the archive layer per `archive_finalization_policy.md`:** `match_records` rows belonging to FINALIZED runs are projected into `archive.locked_ledger_entries` (or equivalent), which has FORCE RLS denying UPDATE except under the archive-lock GUC. The `matching.regenerate_reason` RPC does NOT set that GUC, so even if the RPC layer check were bypassed, the underlying write would be denied.

`PROMPT_VERSION_BUMP` regenerations explicitly skip FINALIZED matches per §2.

**Rationale:** the reason on a finalised match is what justified the accountant's acceptance at finalisation time. Retroactively rewriting it (even with a "better" prompt version) would corrupt the audit narrative. The history table preserves prior reasons; the finalised match's `match_reason_plain_language` column is the canonical record at finalisation moment.

---

## 7. Display: showing reason history

The match-review UI surfaces a "Reason history" disclosure under the active reason. Expanded view shows each prior reason in reverse-chronological order:

```
Active reason (v2):
  "Likely match: amount EUR 49.00 and currency match exactly..."

  ▼ Reason history (2 prior versions)
    ─ Regenerated 2026-04-15 by Andreas K. — trigger: User edited signals
      v2: "Matched: invoice amount EUR 49.00..."
    ─ Regenerated 2026-03-22 by system — trigger: Prompt version bump v1 → v2
      v1: "Matched to invoice INV-2026-0042 based on exact amount..."
```

The history view is gated by `MATCHING_AUDIT_VIEW` surface in `permission_matrix.md` — Owner/Admin/Accountant by default. Bookkeepers see the current reason only.

The disclosure is collapsed by default to avoid visual noise; expanded state is per-user (not per-session) and persists via user preferences.

---

## 8. Edge cases

| Case | Behaviour |
|---|---|
| Two concurrent regenerations for the same match | The `matching.regenerate_reason` RPC takes a row-level lock on `match_records.id` via `SELECT ... FOR UPDATE`. The second caller blocks until the first completes; the second then sees the post-first-regeneration state and proceeds. Both produce history rows; the audit chain shows both attempts. |
| Regeneration that produces a byte-identical output | History row IS still written (the prior reason is captured). Audit `output_changed = false`. The next reader of the column sees no change but the chain shows the regen happened. |
| User triggers a regeneration on a fallback'd reason that succeeds at AI tier this time | Trigger = `FALLBACK_REGENERATE_REQUESTED`. The LOW-severity review issue per `match_reason_prompt.md` §Failure handling auto-resolves with resolution action `AUTO_RESOLVED_BY_RESCAN`. |
| `SCHEMA_MIGRATION_RESCORE` triggers regeneration on 10,000 matches in a batch | The migration script invokes `matching.regenerate_reason` per match. Each row is independently audited. Performance: targeted at 100 regenerations/second sustained (AI-rate-limit-bounded; gateway concurrency cap from `ai_gateway_schema.md`). For larger batches, run during off-peak hours per `runbook_high_volume_rescore.md` (Stage-6 candidate — not yet written). |
| User edits a signal but the resulting score is below the matching threshold (match would now be rejected) | The match's `match_status` transitions to REJECTED via a separate flow per `match_record_schema.md`; the reason is regenerated to reflect the rejection rationale ("No match found within the configured thresholds..."). |
| Migration script crashes mid-batch | Each regeneration is its own transaction. Crashed runs leave some matches regenerated and others not. The migration script is idempotent — re-running it skips matches whose `match_reason_history` already contains the migration's marker (passed in `trigger_actor_user_id = NULL` + a known `prompt_version` value). |

---

## 9. Cross-references

- `match_reason_prompt.md` — the prompt being regenerated (Stage-6 drift queue noted there)
- `match_reason_sample_output_corpus.md` — validates output of every regeneration (BOOK-215 sibling doc)
- `match_record_schema.md` — `match_records.match_reason_plain_language` column source; FK source for history table
- `audit_event_taxonomy.md` — `MATCHING_REASON_REGENERATED` (LOW), `MATCHING_REASON_GENERATED`, `MATCHING_REASON_FALLBACK_APPLIED`, `MATCHING_REASON_CACHE_HIT`
- `audit_event_payload_schemas.md` — payload shape for `MATCHING_REASON_REGENERATED` per §4
- `audit_log_policies.md` — 6-year retention; hash-chain immutability
- `retention_policies_schema.md` — per-business retention regime governing §5
- `archive_finalization_policy.md` — finalisation-lock that prevents §6 regeneration
- `prompt_management_policies.md` — `match_reason_v2` deprecation overlap window driving `PROMPT_VERSION_BUMP` regenerations
- `permission_matrix.md` — `MATCHING_AUDIT_VIEW` surface gating §7 disclosure
- `ai_gateway_schema.md` — concurrency cap relevant to §8 high-volume case
- Block 10 Phase 07 — match reason generation (owning phase)
- Block 05 Phase 02 — audit taxonomy (consumer)
- Block 05 Phase 03 — `audit_events` table + emission RPC
- Block 14 — review-queue auto-resolution for FALLBACK_REGENERATE_REQUESTED
- Stage 1 decision — preserve historical reasons (binding to §1 invariant)
