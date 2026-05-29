# Tool: matching.propose

**Namespace:** matching  
**WRITES_RUN_STATE:** No  
**WRITES_AUDIT:** Yes  
**Idempotent:** No  
**Mobile:** No

---

## Purpose

Proposes a match between a `bank_statement_lines` row and a `transactions` row (which may represent an invoice or an expense). Inserts a `match_proposals` row with status `PROPOSED`. When `match_level = EXACT` and `proposed_by = 'system'`, the tool auto-confirms the match without human review by calling `matching.confirm_match` internally and emitting `MATCHING_AUTO_CONFIRMED`. In all other cases the proposal is left in `PROPOSED` status for reviewer action.

---

## Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `bank_statement_line_id` | uuid | Yes | FK to `bank_statement_lines.id`. The line being matched. |
| `transaction_id` | uuid | Yes | FK to `transactions.id`. The transaction proposed as the match. |
| `proposed_by` | text | Yes | `org_member_id` (UUID string) of the proposer, or the literal string `'system'` for engine-generated proposals. |
| `match_level` | match_level_enum | Yes | `EXACT`, `STRONG_PROBABLE`, `WEAK_POSSIBLE`, or `NO_MATCH`. |
| `match_score` | numeric(4,2) | Yes | Confidence score in the range 0.00–1.00. |
| `match_reason` | text | Yes | Human-readable explanation of the match signal, e.g. `"amount=1250.00, invoice_ref=INV-2024-0088, date_delta=0"`. |

---

## Steps

### 1. Load and validate both records

Fetch the `bank_statement_lines` row for `bank_statement_line_id`. If not found, return `ERR_LINE_NOT_FOUND`.

Fetch the `transactions` row for `transaction_id`. If not found, return `ERR_TRANSACTION_NOT_FOUND`.

Confirm both rows have `business_entity_id` equal to the same value. If not, return `ERR_CROSS_TENANT_MATCH`. This check is a hard guard; it must run before any write.

### 2. Check for existing matches

If `bank_statement_lines.transaction_id IS NOT NULL` (the line is already matched), return `ERR_LINE_ALREADY_MATCHED`.

Query `match_proposals` for any row with `(bank_statement_line_id, transaction_id)` pair that has `status IN ('PROPOSED', 'CONFIRMED', 'AUTO_CONFIRMED')`. If found, return `ERR_PROPOSAL_ALREADY_EXISTS` with the existing proposal ID. This prevents duplicate proposals for the same pair.

If the `transactions` row has `matched_at IS NOT NULL`, return `ERR_TRANSACTION_ALREADY_MATCHED`.

### 3. Insert match_proposals row

Insert a `match_proposals` row:
- `status = 'PROPOSED'`
- `match_level = <param>`
- `composite_score = <match_score>`
- `proposed_by = <proposed_by>` (stored as text; UUID or 'system')
- `match_reason = <match_reason>`
- `proposed_at = now()`

Capture the new row's `id` as `proposal_id`.

### 4. Auto-confirm path

If `match_level = 'EXACT'` AND `proposed_by = 'system'`:
- Call `matching.confirm_match` internally with `match_proposal_id = proposal_id` and `confirmed_by = 'system'`.
- If the internal call succeeds, emit `MATCHING_AUTO_CONFIRMED` (see §Audit events).
- If the internal call fails for any reason, do not roll back the proposal insert. Leave the proposal in `PROPOSED` status and include the internal error detail in the response. Log the failure for operator review.

For all other combinations (`match_level != EXACT` OR `proposed_by != 'system'`), skip auto-confirm. Emit `MATCHING_PROPOSED` and return.

### 5. Emit audit event

**Standard proposal path:** emit `MATCHING_PROPOSED` with payload:
```json
{
  "proposal_id": "<uuid>",
  "bank_statement_line_id": "<uuid>",
  "transaction_id": "<uuid>",
  "business_entity_id": "<uuid>",
  "proposed_by": "<uuid|system>",
  "match_level": "<enum>",
  "match_score": <numeric>
}
```

**Auto-confirm path:** emit `MATCHING_AUTO_CONFIRMED` with payload identical to the above plus `"confirmed_at": "<timestamptz>"`.

Audit event notes:
- `MATCHING_AUTO_CONFIRMED` exists in `audit_event_taxonomy.md` (line 497).
- `MATCHING_PROPOSED` — not yet in the taxonomy. Must be added before production use.

---

## Error paths

| Error code | Condition |
|---|---|
| `ERR_LINE_NOT_FOUND` | No `bank_statement_lines` row for `bank_statement_line_id` |
| `ERR_TRANSACTION_NOT_FOUND` | No `transactions` row for `transaction_id` |
| `ERR_CROSS_TENANT_MATCH` | Line and transaction belong to different `business_entity_id` |
| `ERR_LINE_ALREADY_MATCHED` | Line's `transaction_id` is already set |
| `ERR_TRANSACTION_ALREADY_MATCHED` | Transaction's `matched_at` is already set |
| `ERR_PROPOSAL_ALREADY_EXISTS` | Active proposal for same (line, transaction) pair exists |
| `ERR_SCORE_OUT_OF_RANGE` | `match_score` outside 0.00–1.00 |

All errors are returned without side effects. No rows are inserted on error.

---

## Mobile

This tool is not available on mobile clients. Match proposals are initiated from the desktop review queue or by the matching engine. Mobile clients may read proposal state but cannot write. Any invocation from a mobile client returns HTTP 405 `MOBILE_WRITE_REJECTED`.

---

## Related Documents

- `bank_statement_line_schema.md` — `bank_statement_line_id` FK source
- `transactions_schema.md` — `transaction_id` FK source
- `match_proposal_schema.md` — table written by this tool
- `tool_matching_confirm.md` — called internally on the auto-confirm path
- `tool_matching_score_pair.md` — computes `match_score` and `match_level` before calling this tool
- `matching_policy.md` — auto-confirm threshold rules
- `matching_confidence_policy.md` — score calibration and escalation
- `audit_event_taxonomy.md` — MATCHING_AUTO_CONFIRMED and MATCHING_PROPOSED definitions

---

## Idempotency note

This tool is explicitly **not idempotent**. Calling it twice with the same parameters will return `ERR_PROPOSAL_ALREADY_EXISTS` on the second call, not a duplicate insert. Callers should treat that error as a signal to look up the existing proposal rather than retry.

The matching engine is responsible for deduplicating its own proposal calls. If the engine restarts mid-run and replays its scoring output, it must first query `match_proposals` for existing proposals before calling this tool.

---

## Interaction with match_scoring_configs

Before calling `matching.propose`, the matching engine calls `tool_matching_score_pair.md` to compute `match_score` and `match_level`. The score is produced using the active `match_scoring_configs` row for the business entity. The config's `weight_sum_check` must equal 1.0; otherwise `MATCHING_SCORING_CONFIG_INVALID` (BLOCKING) was already emitted and the run is halted before proposal begins.

The `match_reason` parameter passed to this tool is the human-readable summary produced by the scoring tool. It should include the top contributing signals (e.g., amount match, invoice reference match, date proximity) so that reviewers in the review queue can evaluate the proposal without re-running scoring.

---

## Relationship to review queue

Proposals with `status = 'PROPOSED'` and `match_level` of `STRONG_PROBABLE` or `WEAK_POSSIBLE` are surfaced in the review queue as matching issues. The review queue issue is created by the matching engine after this tool returns successfully. The issue card links to this proposal by `proposal_id`.

`NO_MATCH` proposals are not surfaced in the review queue by default. The matching engine creates a separate `MATCHING_EXCEPTION` record for lines with no viable match, which is routed to review queue per `matching_policy`.
