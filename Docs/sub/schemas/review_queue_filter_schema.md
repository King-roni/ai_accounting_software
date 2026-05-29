# Review Queue Filter Schema

**Category:** Schemas · **Owning block:** 14 — Review Queue · **Stage:** 4 sub-doc (Layer 2)

Defines the `review_queue_filter_states` table — the persisted filter and sort configuration a user has applied to a specific run's review queue view. One row per `(user_id, business_id, workflow_run_id)` triple. Filter state is scoped to a run because the queue's content is run-bound; carrying filter state from a prior run's view into a new run's queue would produce misleading pre-filtered views.

---

## 1. Table definition

```sql
CREATE TABLE review_queue_filter_states (
  filter_state_id       uuid PRIMARY KEY DEFAULT gen_uuid_v7(),

  -- Actor and tenant context
  user_id               uuid NOT NULL
                          REFERENCES users(id),
  business_id           uuid NOT NULL,

  -- Run scope — filter state is tied to a specific run's review queue
  workflow_run_id       uuid NOT NULL
                          REFERENCES workflow_runs(workflow_run_id),

  -- Active filter set (see Section 2 for JSONB structure)
  filters_json          jsonb NOT NULL DEFAULT '{}'::jsonb,

  -- Sort configuration
  sort_column           text NOT NULL DEFAULT 'severity'
                          CHECK (sort_column IN (
                            'severity', 'created_at', 'group',
                            'assigned_to', 'updated_at'
                          )),
  sort_direction        sort_direction_enum NOT NULL DEFAULT 'DESC',

  -- Pagination preference
  page_size             integer NOT NULL DEFAULT 25
                          CHECK (page_size BETWEEN 1 AND 200),

  -- Last-modified timestamp
  updated_at            timestamptz NOT NULL DEFAULT now(),

  -- One filter state row per user per business per run
  UNIQUE (user_id, business_id, workflow_run_id)
);

CREATE TYPE sort_direction_enum AS ENUM ('ASC', 'DESC');

CREATE INDEX idx_rq_filter_states_user_business
  ON review_queue_filter_states(user_id, business_id);

CREATE INDEX idx_rq_filter_states_run
  ON review_queue_filter_states(workflow_run_id);
```

---

## 2. Field reference

| Field | Type | Notes |
|---|---|---|
| `filter_state_id` | UUID v7 PK | Monotonically increasing per `data_layer_conventions_policy` |
| `user_id` | UUID FK | References `users.id`; RLS-enforced per Section 4 |
| `business_id` | UUID | Tenant scope; RLS-enforced per Section 4 |
| `workflow_run_id` | UUID FK | References `workflow_runs.workflow_run_id`; filter state is scoped to a specific run |
| `filters_json` | JSONB | Active filter set; see Section 3 for canonical structure |
| `sort_column` | text | One of `severity`, `created_at`, `group`, `assigned_to`, `updated_at` — CHECK-constrained |
| `sort_direction` | sort_direction_enum | `ASC` or `DESC`; default `DESC` |
| `page_size` | integer | Per-page row count; minimum 1, maximum 200, default 25 |
| `updated_at` | timestamptz | Set on upsert; not a blockchain-linked field — this is a preference, not operational data |

---

## 3. `filters_json` structure

The JSONB object is a sparse map of active filter keys. Absent keys imply no filter for that dimension. All values are nullable — an explicit `null` clears a previously set filter on upsert.

```typescript
interface ReviewQueueFilters {
  /** Subset of the 5 closed issue_group_enum values */
  issue_groups?: string[];

  /** Subset of {LOW, MEDIUM, HIGH, BLOCKING} */
  severities?: ('LOW' | 'MEDIUM' | 'HIGH' | 'BLOCKING')[];

  /** Assigned-to user UUID(s); empty array = unassigned only */
  assigned_to_user_ids?: string[];

  /** Subset of review_issues.status enum values */
  statuses?: string[];

  /** ISO 8601 date range for issue created_at */
  created_after?: string;
  created_before?: string;
}
```

The UI reads this object and applies it client-side at view construction time. The server does not auto-apply filter state on API calls — clients fetch the filter state and pass it as explicit query parameters in subsequent `report.drill_down` calls. This separation ensures that a stale or mis-configured filter state does not silently restrict what the server returns.

---

## 4. Write path — `review_queue.save_filter_state`

Filter state is read and written exclusively by the `review_queue.save_filter_state` tool. The tool performs an upsert on the `(user_id, business_id, workflow_run_id)` unique constraint and updates `updated_at` on every write.

```typescript
engine.registerTool({
  name: "review_queue.save_filter_state",
  schema_version: "1.0",
  side_effect_class: ["WRITES_RUN_STATE"],
  ai_tier: "NONE",
  audit_events: [],
  description_ref: "Docs/sub/tools/tool_review_queue_save_filter_state.md",
});
```

No audit event is emitted for filter state saves. Filter configuration is a UI preference, not an operational action. It carries no regulatory significance and is not included in the audit hash chain.

---

## 5. Application behaviour

**Load on queue open:** when a user opens the review queue for a run, the client fetches the filter state row for `(current_user_id, business_id, workflow_run_id)`. If no row exists, all filters default to "no filter" and the queue shows all issues.

**Auto-apply:** the filter state is NOT automatically applied server-side. The API always requires explicit filter parameters. The client reads the saved state and populates the UI filter controls; the user sees their previous settings pre-filled, but the API call that follows is a fresh parameterised request.

**Run lifecycle:** filter state rows are not deleted when a run reaches a terminal state (`FINALIZED`, `FAILED`, `CANCELLED`). They persist so that users reviewing a completed run's queue (read-only) see their last filter settings.

---

## 6. Mobile rejection

`review_queue.save_filter_state` is a write action. Mobile clients attempting to save filter state receive HTTP 405 `MOBILE_WRITE_REJECTED`. The endpoint is listed in `mobile_write_rejection_endpoints`. Reading the existing filter state on mobile is permitted (the row is readable); only the write/upsert path is blocked.

---

## 7. RLS

```sql
-- Users may only access their own filter state rows
CREATE POLICY rq_filter_states_owner_only
  ON review_queue_filter_states
  FOR ALL
  USING (user_id = auth.current_user_id());
```

No cross-user access. Owner and Admin do not see other users' filter states. Cross-business access is impossible via the session-scoped `auth.current_user_id()` check combined with the `business_id` column on the row.

---

## 8. Audit events

No audit events are emitted for filter state reads or writes. Filter configuration is classified as non-operational preference data, equivalent to `dashboard_preferences_schema` preferences. It is excluded from the audit hash chain and from RLS-visible event reads.

---

## Cross-references

- `data_layer_conventions_policy` — UUID v7 PK generation; JSONB canonical encoding for `filters_json`; `updated_at` timestamptz convention
- `review_issue_card_schema` — `issue_group_enum`, `severity_enum`, and `status` vocabulary used as filter dimensions in `filters_json`
- `dashboard_preferences_schema` — analogous per-user preference pattern; same no-audit-event rule for UI preferences
- `snooze_carry_forward_schema` — `review_queue` namespace context; `review_queue.unsnooze_at_run_start` sibling tool
- `tool_naming_convention_policy` — `review_queue.save_filter_state` tool name; `review_queue` namespace; side-effect class declaration
- `mobile_write_rejection_endpoints` — `review_queue.save_filter_state` listed as a mobile-rejected write surface
- `workflow_state_enum` — `workflow_run_id` FK target; run lifecycle context
- `audit_log_policies` — rationale for no audit event on preference writes
- Block 14 Phase 01 — `review_issues` schema context
- Block 14 Phase 02 — `issue_group_enum` and `severity_enum` canonical values
- Block 16 Phase 08 — drill-down list view that consumes filter parameters derived from this schema
