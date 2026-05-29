# Next session start prompt — copy-paste into a fresh Claude session

(Copy everything between the `---` lines below and paste as your first message.)

---

You're picking up the **Cyprus Bookkeeping SaaS** project (multi-tenant accounting platform, Cyprus VAT, accountant pack, finalization archive). Stage 3 (sub-doc backlog walk) is mid-flight.

**Last extended session ended 2026-05-28 (session-c).** Three cycles fully closed (**B02 + B10 + B03** ✅). Cycle B04 (Data Architecture) is **45/65 done** — P01–P06 sub-doc clusters complete. **20 backlog tickets remaining in B04 across 5 clusters (P07–P11).**

## First move (do these in parallel, single message)

1. `mempalace_status` — palace overview + protocol
2. `mempalace_get_drawer(drawer_id="drawer_cyprus_bookkeeping_project-meta_3425d21389e8094e778df48c")` — canonical "where am I" drawer
3. `Read("/Users/pep_o23kd/Desktop/Cursor/Personal/boekhoudings_Ai_software/Docs/handoff/2026-05-28c_session_end_handoff.md")` — extended session-end handoff with B04 mid-cycle state (REQUIRED — do not skip)
4. `Read("/Users/pep_o23kd/Desktop/Cursor/Personal/boekhoudings_Ai_software/Docs/handoff/2026-05-28_cycle_B03_complete.md")` — B03 cycle wrap-up with load-bearing cross-block punch list
5. `mcp__plane__retrieve_cycle(project_id="28b250c0-d991-4dcb-a48c-51af27aa17dd", cycle_id="1de935db-12b4-4eb9-aa0b-4731cdf56725")` — Cycle B04 status

## Project facts

- **Repo root:** `/Users/pep_o23kd/Desktop/Cursor/Personal/boekhoudings_Ai_software`
- **Supabase project:** `noxvmnxrqlzsdfngfiww` (EU eu-west-1)
- **Plane project:** `BOOK` · `project_id = 28b250c0-d991-4dcb-a48c-51af27aa17dd`
- **Plane states:** Backlog `06b2fd3b-5d0c-486a-9a37-fe086b725315` · In Progress `d349cb35-77f8-45f8-bbf7-98b6fbf39329` · Done `6e8dcd01-8ef8-4f8f-a3c4-99e73bb5ec98`

## Cycle UUIDs

| Cycle | Block | UUID | Status |
|---|---|---|---|
| B02 Tenancy & Access | 02 | `381c73b1-4d67-42bb-8d01-5ac691218f76` | ✅ DONE (54/54) |
| B03 Workflow Engine | 03 | `430809b2-3204-4401-8bf9-833c7e2de000` | ✅ **DONE (54/54)** ← closed prior session |
| **B04 Data Architecture** | 04 | `1de935db-12b4-4eb9-aa0b-4731cdf56725` | **IN PROGRESS — 20 backlog · P07 next** |
| B05 Security & Audit | 05 | `14cf9a0f-24d0-4c60-9883-c3e363c3d6c6` | Not started — 47 backlog |
| B06 AI Layer | 06 | `c1dc65f4-8cd8-479c-90a0-e7234af73147` | 47 backlog |
| B07 Bank Statement Pipeline | 07 | `8c9854e0-48d8-4b15-a75a-99abae48b994` | 44 backlog |
| B08 Classification & Tagging | 08 | `4138ad1c-e8a6-4b79-bb7c-9be6b3f59fdb` | 38 backlog |
| B09 Document Intake | 09 | `34fe7710-0ff4-4b06-8023-76d7061d0857` | 39 backlog |
| B10 Matching Engine | 10 | `2b0d88ce-3bf2-4e9c-b9fe-91d91fe08985` | ✅ DONE (45/45) |
| B11 Ledger & Cyprus VAT | 11 | `a6fb501c-8ff3-4754-991a-e9839d636f0a` | 43 backlog |
| B12 OUT Workflow | 12 | `ac437187-e9df-4725-8a2b-10b66b6ee189` | 43 backlog |
| B13 IN Workflow + Invoice Gen | 13 | `91c1c6ba-2a2a-4ca3-83e2-0dd0406e26a0` | 52 backlog |
| B14 Review Queue | 14 | `174814ff-75bf-4d92-aafa-0405d84c31a9` | 54 backlog |
| B15 Finalization & Archive | 15 | `f07310c0-7e1e-4142-93b9-5eaed044a8fd` | 52 backlog |
| B16 Dashboard & Reporting | 16 | `d06a5244-c620-4a18-ab6c-bdea26766ee9` | 87 backlog |

## Execution order

**Continue B04 (P07–P11) → B05 → B06 → B07 → B08 → B09 → B11 → B12 → B13 → B14 → B15 → B16 → Cycle-16 reconciliation.**

(B02 + B10 + B03 already done.)

## Cycle B04 next-pickup — start here

**BOOK seq 386 `[B04·P07·SD] Archive schema`** — opens the P07 (Finalized Secure Archive Zone) cluster.

**Remaining B04 clusters (5 clusters · 20 tickets):**

| Cluster | Tickets | Predicted disposition |
|---|---|---|
| P07 Finalized Secure Archive Zone | 4 (seq 386/388/390/392) | Likely 4 verify — `archive_schema.md`, `object_lock_integration.md`, `archive_bundle_layout_schema.md`, `archive_read_api` likely exist (B15-adjacent) |
| P08 Zone Promotion Pipeline | 5 (seq 396/398/400/402/404) | Mixed — atomicity / bundle gen / additive layering / hash anchor / failure rollback |
| P09 Analytics Zone | 5 (seq 406/407/408/409/410) | Mixed — aggregate schemas / refresh / cross-business / stale UX / aggregate-source |
| P10 Retention Engine | 5 (seq 412/414/416/418/420) | Mixed — policy schema / scheduling / atomicity / **legal-hold (must align with prior session's legal_holds table)** / dry-run |
| P11 Legal Hold | 6 (seq 421/424/426/428/430/436) | Mixed — already partially seeded by prior session's `adjustment_six_year_cap_policy` `legal_holds` table DDL |

To find the lowest sequence_id in backlog:
```
mcp__plane__list_cycle_work_items(project_id="28b250c0-d991-4dcb-a48c-51af27aa17dd", cycle_id="1de935db-12b4-4eb9-aa0b-4731cdf56725", params={"per_page": 100, "fields": "id,sequence_id,name,state"})
```
Filter by Backlog state `06b2fd3b-5d0c-486a-9a37-fe086b725315`, sort by sequence_id, take lowest.

## Critical alignment risks for B04·P10 + B04·P11

**`legal_holds` table** was introduced by prior session's `adjustment_six_year_cap_policy.md` with this DDL:

```sql
CREATE TABLE legal_holds (
  id                          uuid PRIMARY KEY DEFAULT gen_uuid_v7(),
  business_id                 uuid NOT NULL,
  hold_kind                   text NOT NULL,
  hold_started_at             timestamptz NOT NULL,
  hold_ends_at                timestamptz NULL,
  hold_authority              text NOT NULL,
  filed_by_user_id            uuid NOT NULL,
  filed_at                    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT legal_hold_dates_valid CHECK (hold_ends_at IS NULL OR hold_ends_at > hold_started_at)
);
```

B04·P10 + B04·P11 sub-docs MUST conform to this shape OR explicitly extend it. Flag any drift.

Also `processing_zone_ttl_and_prune_policy` (this session) reads from this table — B04·P10 retention engine must coordinate.

## Cadence — adaptive batching (unchanged)

| Ticket type | Per-turn cadence |
|---|---|
| Easy verify-only (clear canonical doc + hook matches) | 5-10 per turn, batched; one-line DoD comments |
| Verify-only with drift | 3-5 per turn, terser comments |
| Routine write-required (derivative pattern) | Write directly, ~120-180 lines / 8-10 sections, NO propose-wait |
| Novel write-required (new mechanism / anchor doc) | Keep propose-wait, ~180-280 lines / 10 sections max |

Block 04 has been heavy verify-only — most P-clusters batch close in one turn. Only P06 needed writes (3 sub-docs) because the processing-zone hooks introduce novel artefact-taxonomy material.

## Cross-reference discipline — LOAD-BEARING, never cut

User binding rule: *"if we build A and after 2 weeks B is also done, but then A doesn't work because you didn't listen to the cross reference, everything will break."*

1. Every new sub-doc ends with a Cross-references section (5-15 entries — the actual dependencies).
2. New audit event / column / RPC / migration → flag in DoD comment as **"Cross-block coordination flagged for B##·P## implementation"** + file a KG triple.
3. Anchor docs get FULL scope. Routine derivative docs get tighter scope but KEEP complete cross-refs.
4. Drift items captured per-ticket via KG triples + DoD comments — they feed Cycle-16 reconciliation.
5. Per-cycle wrap-up: when a cycle is done, produce a 1-page summary at `Docs/handoff/<date>_cycle_B##_complete.md`.

## Canonical retry constants (ratified)

- **Standard tools**: `N=3` retries, exponential backoff `base * 2^(attempt-1)` with base 2s → ~2s/4s/8s, cap 30s, ±10% jitter
- **AI EXTERNAL tier**: `N=2` retries, base 5s
- **Retryable classes**: TRANSIENT_NETWORK, RATE_LIMITED, TIMEOUT, SERVICE_UNAVAILABLE
- **Non-retryable**: VALIDATION_ERROR, PERMISSION_DENIED, DATA_INTEGRITY_ERROR, UNKNOWN
- Per-tool override via `tool_registry.retry_policy jsonb`

## Two distinct idempotency mechanisms (both legitimate)

- **`tool_invocations.dedup_key`** — engine-level cache; skips tool invocation entirely on retry.
- **`workflow_phase_states.idempotency_key`** — single-writer DB-write guard via `ON CONFLICT DO NOTHING`.
- **NOT to use:** `caller_idempotency_key` SHA-256-of-concat from `resumability_and_idempotency.md` — Stage-6 retire.

## Stage-6 doc-write candidates — HIGH PRIORITY (cumulative)

- **`audit_event_payload_schemas.md`** — STILL missing; ~40+ event kinds across B03 + B04. **HIGHEST PRIORITY.**
- `audit_event_external_visibility_policy.md`, `audit_pii_redaction_policy.md`, `audit_log_volume_policy.md`, `audit_log_visibility_policy.md`
- `bank_connector_replay_capability_table.md` (B07)
- `cost_alerting_runbook.md`, `engine_estimator_accuracy_dashboard.md`, `engine_estimator_cold_start_constants.md`
- `step_up_token_policy.md`, `test_factories.md`
- 6 reason-validation message templates `{code}.{en,el}.md`
- B05 ops: `engineering_bug_reports` table

## Quality bar

User's explicit instruction: *"I would rather have longer building time than shorter with bad quality."*

**Quality is KING. Cross-references are LOAD-BEARING. Speed is secondary.**

## How to report back after loading context

In your first response after the parallel reads complete:

1. One sentence confirming context loaded (drawer + handoff + Cycle B04).
2. "Cycle B04 has 20 backlog tickets. Lowest sequence_id in backlog is seq 386 (next is P07 Archive Zone cluster)."
3. Proceed to process seq 386 per the disposition cadence.

Don't recap the prior sessions. Don't restate the handoff doc. Just orient and execute.

## Pinned MemPalace queries

```
mempalace_kg_query(entity="Cycle_B03")              # confirms B03 closed
mempalace_kg_query(entity="B04_P06_cluster")        # last cluster closed in prior session
mempalace_kg_query(entity="stage3_next_action")     # current resume pointer
```

(Known transient bug: `kg_query` occasionally returns "Internal tool error." KG _add_ is reliable. If query fails, drawer state holds canonical data.)

## Tone

Terse status updates. Complete sentences for any user-facing text. Don't narrate internal deliberation. End each cluster with one sentence: cluster closed, KG triples filed, next cluster up.

Go.

---

(End of paste content.)
