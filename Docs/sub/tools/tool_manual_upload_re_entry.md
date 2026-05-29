# tool_manual_upload_re_entry

**Category:** Tools · **Owning block:** 09 — Document Intake & Extraction · **Co-owner:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 1 cross-block tool)

The re-entry helper that processes user resolution of `DUPLICATE_PROBABLE` and `NEEDS_REVIEW` document states. Per the Block 07 scan fix: documents in these states resolved as "confirm as new" must re-enter the intake pipeline with a fresh dedup key, otherwise the dedup engine immediately marks them as duplicate again.

Block 09 Phase 02 owns the document lifecycle state machine; this tool is the user-action surface (called from Block 14 resolution actions) that drives the appropriate state transition.

---

## Function signature

```ts
intake.manual_upload_re_entry({
  document_id: uuid,
  business_id: uuid,
  user_decision: "CONFIRM_AS_NEW" | "CONFIRM_AS_DUPLICATE" | "DISMISS",
  duplicate_link_target_id?: uuid,        // required when user_decision = "CONFIRM_AS_DUPLICATE"
  new_dedup_key_seed?: string,             // required when user_decision = "CONFIRM_AS_NEW"
  reason?: string,                         // optional note attached
  actor_user_id: uuid,
  actor_role: Role,
}): {
  document: Document,                      // updated state
  new_document_id?: uuid,                  // present only for CONFIRM_AS_NEW
  pipeline_re_entered: boolean,
}
```

## State-machine transitions

| Starting state | `user_decision` | Ending state | New `document_id` issued? |
| --- | --- | --- | --- |
| `DUPLICATE_PROBABLE` | `CONFIRM_AS_NEW` | `NEW` (with new dedup key) | ✓ (new row inserted; old `DUPLICATE_PROBABLE` row marked `RESOLVED_AS_NEW`) |
| `DUPLICATE_PROBABLE` | `CONFIRM_AS_DUPLICATE` | `LINKED_TO_<target_id>` (terminal) | ✗ (existing target row gets a new `document_source_links` row) |
| `DUPLICATE_PROBABLE` | `DISMISS` | `DISMISSED` (terminal) | ✗ |
| `NEEDS_REVIEW` | `CONFIRM_AS_NEW` | `NEW` (re-runs intake pipeline) | ✗ (same row reused; state advances) |
| `NEEDS_REVIEW` | `DISMISS` | `DISMISSED` (terminal) | ✗ |

`CONFIRM_AS_DUPLICATE` and `CONFIRM_AS_NEW` MUST NOT be applied to documents already in `DISMISSED` state — the tool rejects with `INVALID_STATE_TRANSITION`.

## `new_dedup_key_seed` requirement

For `DUPLICATE_PROBABLE` + `CONFIRM_AS_NEW`: the user (UI) supplies an additional component that ensures the new document's dedup key differs from the prior one. Typical seed: a timestamp, a free-text discriminator, or a hash of the user's confirmation rationale.

Without a seed, the new dedup key would compute identically and the dedup engine would immediately re-mark the document as duplicate. The seed is the explicit user signal: "this is intentionally a new document despite the system thinking it's duplicate."

Validation: seed must be ≥ 4 chars; the audit trail records the seed alongside the user's reason for forensic clarity.

## Side-effect class and AI tier

- **Side-effect class:** `WRITES_RUN_STATE | WRITES_AUDIT`
- **AI tier:** `NONE`

For `CONFIRM_AS_NEW` from `DUPLICATE_PROBABLE`: the tool writes a new `documents` row, then re-invokes the dedup engine (`intake.cross_source_dedupe`) which carries `WRITES_PROCESSING_ZONE` separately. The downstream pipeline (`intake.ocr_and_extract`, etc.) handles its own side-effect classes.

For `CONFIRM_AS_NEW` from `NEEDS_REVIEW`: the same row advances; the cross-source-dedup step is skipped (already passed once); pipeline resumes from extraction.

## Audit events

| Event | When |
| --- | --- |
| `DOCUMENT_STATE_CHANGED` | Per state transition (per Block 09 Phase 02) |
| `DOCUMENT_DISMISSED` | When `user_decision = "DISMISS"` |
| `DOCUMENT_CROSS_SOURCE_DEDUPED` | When re-entering pipeline (resumed from cross-source dedup) |
| `DOCUMENT_MANUAL_UPLOADED` | When re-entering pipeline (initial intake) — for the new row's audit trail |

The state-transition event captures the user's decision and the actor:

```json
{
  "document_id": "...",
  "from_state": "DUPLICATE_PROBABLE",
  "to_state": "NEW",
  "user_decision": "CONFIRM_AS_NEW",
  "new_dedup_key_seed": "...",            // present when applicable
  "duplicate_link_target_id": "...",      // present when CONFIRM_AS_DUPLICATE
  "actor_user_id": "...",
  "actor_role": "Bookkeeper",
  "reason": "..."                          // user-provided text, ≤ 1000 chars
}
```

## Pre-conditions

The tool fails with structured errors for:

| Error | Cause |
| --- | --- |
| `INVALID_STATE_TRANSITION` | Document not in `DUPLICATE_PROBABLE` or `NEEDS_REVIEW` state |
| `NEW_DEDUP_KEY_SEED_REQUIRED` | `CONFIRM_AS_NEW` from `DUPLICATE_PROBABLE` without seed |
| `DUPLICATE_LINK_TARGET_REQUIRED` | `CONFIRM_AS_DUPLICATE` without `duplicate_link_target_id` |
| `DUPLICATE_LINK_TARGET_INVALID` | `duplicate_link_target_id` does not exist or is in a non-`NEW`/`LINKED` state |
| `PERMISSION_DENIED` | Actor lacks `REVIEW_QUEUE_RESOLVE` surface |
| `MOBILE_WRITE_REJECTED` | Called from a mobile client (per `mobile_write_rejection_endpoints`) |

## Concurrency

Per-document advisory lock prevents two re-entry attempts on the same `document_id` from running concurrently. Cross-document attempts on different documents proceed independently.

## Permission

`REVIEW_QUEUE_RESOLVE` surface — invoked from the review queue per `resolution_action_enum`'s `confirm_match` action (analogous to invoice match confirmation but for document intake).

Mobile rejection: REJECT.

## Performance budget

Per `fixture_performance_budget`:

| Operation | P50 | P95 | P99 |
| --- | --- | --- | --- |
| `intake.manual_upload_re_entry` (without re-running pipeline) | 50 ms | 200 ms | 500 ms |
| `intake.manual_upload_re_entry` + pipeline re-entry (small doc) | 5 s | 12 s | 30 s |
| `intake.manual_upload_re_entry` + pipeline re-entry (PDF with OCR) | 8 s | 20 s | 60 s |

Pipeline re-entry latency dominates when applicable. The tool returns synchronously after state change; pipeline re-entry runs asynchronously per the engine's task queue.

## Registration

```ts
engine.registerTool({
  name: "intake.manual_upload_re_entry",
  schema_version: "1.0",
  side_effect_class: ["WRITES_RUN_STATE", "WRITES_AUDIT"],
  ai_tier: "NONE",
  input_schema_ref: "tool_manual_upload_re_entry#v1.input",
  output_schema_ref: "tool_manual_upload_re_entry#v1.output",
  audit_events: ["DOCUMENT_STATE_CHANGED", "DOCUMENT_DISMISSED", "DOCUMENT_CROSS_SOURCE_DEDUPED", "DOCUMENT_MANUAL_UPLOADED"],
  description_ref: "Docs/sub/tools/tool_manual_upload_re_entry.md",
});
```

## Cross-references

- `tool_naming_convention_policy` — naming + registration
- `audit_log_policies` — `DOCUMENT_*` event family
- `permission_matrix` — `REVIEW_QUEUE_RESOLVE` surface
- `mobile_write_rejection_endpoints` — rejection contract
- `resolution_action_enum` — the resolution surface that invokes this tool
- Block 09 Phase 02 — document lifecycle state machine (state machine home)
- Block 09 Phase 07 — manual upload path
- Block 09 Phase 08 — cross-source dedupe
- Block 07 scan fix — the original requirement (Phase 06 manual confirm-as-new re-entry path)

## Mobile

All write operations in this tool are rejected on mobile clients. Mobile apps receive `HTTP 405 Method Not Allowed` with error code `MOBILE_WRITE_REJECTED`. See `mobile_write_rejection_endpoints.md` for the full endpoint rejection list.